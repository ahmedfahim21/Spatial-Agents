// One conversational turn with a personal or public agent, through the 0G Compute Router.
// Streams the reply back as SSE: `data: {"text": "..."}` chunks, then `data: [DONE]`.
// Shop agents can also take an order: the model ends its reply with a hidden
// `[[order item=<n> qty=<q>]]` line, which is never streamed; instead this asks the visitor's
// wallet agent (the pay function) to pay, and sends `data: {"order": ...}` events.
import { admin, caller, cors, json } from "../_shared/common.ts";

const ROUTER = "https://router-api.0g.ai/v1/chat/completions";
const MODEL = Deno.env.get("ZG_MODEL") ?? "claude-haiku-5.5";
const MAX_TURNS = 24;
const MAX_CHARS = 2000;

type Turn = { role: "user" | "assistant"; content: string };
type AgentRow = {
  id: string; owner_id: string; name: string; anchor: string; visibility: string; greeting: string; context: string;
  pricing: string; items: Item[];
};
type Item = { id: string; name: string; note: string; price_usdc: number };
const ORDER = /\[\[\s*order\s+item\s*=\s*(\d+)\s+qty\s*=\s*(\d+)\s*\]\]/i;

// Agents change rarely; keep them for 30 s per worker so a conversation doesn't hit the DB every turn.
const agentCache = new Map<string, { row: AgentRow | null; at: number }>();
async function loadAgent(db: ReturnType<typeof admin>, id: string): Promise<AgentRow | null> {
  const hit = agentCache.get(id);
  if (hit && Date.now() - hit.at < 30_000) return hit.row;
  const { data, error } = await db
    .from("agents")
    .select("id, owner_id, name, anchor, visibility, greeting, context, pricing")
    .eq("id", id)
    .maybeSingle();
  if (error) throw new Error(error.message);
  let row: AgentRow | null = data ? { ...data, items: [] } : null;
  if (row?.pricing === "paid" && row.visibility === "public") {
    const { data: items } = await db.from("catalog_items").select("id, name, note, price_usdc")
      .eq("agent_id", id).eq("active", true).order("position");
    row = { ...row, items: items ?? [] };
  }
  agentCache.set(id, { row, at: Date.now() });
  return row;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "POST only" }, 405);

  const t0 = performance.now();
  const marks: Record<string, number> = {};
  const mark = (k: string) => (marks[k] = Math.round(performance.now() - t0));
  let body: { agent_id?: string; messages?: Turn[]; warm?: boolean };
  try {
    body = await req.json();
  } catch {
    return json({ error: "Invalid JSON" }, 400);
  }
  // The app pings while you're still staring at an agent, so the worker is warm by the time you speak.
  if (body.warm) return new Response(null, { status: 204, headers: cors });
  if (!body.agent_id) return json({ error: "agent_id is required" }, 400);

  // Check the caller and load the agent at the same time.
  const db = admin();
  let uid: string | null, agent: AgentRow | null;
  try {
    [uid, agent] = await Promise.all([caller(req, db), loadAgent(db, body.agent_id)]);
  } catch (e) {
    return json({ error: String(e) }, 500);
  }
  mark("auth_db");
  if (!uid) return json({ error: "Sign in first" }, 401);
  // Private agents answer only their owner; don't reveal that they exist.
  if (!agent || (agent.visibility === "private" && agent.owner_id !== uid)) {
    return json({ error: "Agent not found" }, 404);
  }

  const turns = (body.messages ?? [])
    .filter((m) => (m.role === "user" || m.role === "assistant") && typeof m.content === "string")
    .slice(-MAX_TURNS)
    .map((m) => ({ role: m.role, content: m.content.slice(0, MAX_CHARS) }));
  // The greeting lives in the system prompt; the conversation itself must open with the user.
  while (turns.length > 0 && turns[0].role === "assistant") turns.shift();
  if (turns.length === 0 || turns[turns.length - 1].role !== "user") {
    return json({ error: "The last message must be from the user" }, 400);
  }

  const key = Deno.env.get("ZG_API_KEY");
  if (!key) return json({ error: "The server has no 0G API key configured" }, 500);

  const upstream = await fetch(ROUTER, {
    method: "POST",
    headers: { "Content-Type": "application/json", Authorization: `Bearer ${key}` },
    body: JSON.stringify({
      model: MODEL,
      stream: true,
      max_tokens: 400,
      messages: [{ role: "system", content: systemPrompt(agent) }, ...turns],
    }),
  });
  mark("router_headers");
  if (!upstream.ok || !upstream.body) {
    const detail = await upstream.text().catch(() => "");
    console.error("0G router error", upstream.status, detail.slice(0, 500));
    const message = upstream.status === 402
      ? "This agent's compute balance has run out."
      : upstream.status === 429
      ? "Too many requests right now. Try again in a moment."
      : "The agent couldn't think right now.";
    return json({ error: message, status: upstream.status }, 502);
  }

  // Re-emit only the text deltas, so the app's parser stays trivial.
  const encoder = new TextEncoder();
  const decoder = new TextDecoder();
  const stream = new ReadableStream({
    async start(controller) {
      const reader = upstream.body!.getReader();
      let buffer = "";
      const send = (s: string) => controller.enqueue(encoder.encode(s));
      let firstText = true;
      // Text from "[[" on is an order marker: held back, never spoken. A lone trailing "["
      // waits for the next chunk to tell.
      let held = "";
      let marker = "";
      const emit = (text: string) => {
        if (marker) { marker += text; return; }
        held += text;
        const at = held.indexOf("[[");
        let out: string;
        if (at >= 0) { out = held.slice(0, at); marker = held.slice(at); held = ""; }
        else if (held.endsWith("[")) { out = held.slice(0, -1); held = "["; }
        else { out = held; held = ""; }
        if (out) send(`data: ${JSON.stringify({ text: out })}\n\n`);
      };
      try {
        while (true) {
          const { value, done } = await reader.read();
          if (done) break;
          buffer += decoder.decode(value, { stream: true });
          let nl;
          while ((nl = buffer.indexOf("\n")) >= 0) {
            const line = buffer.slice(0, nl).trim();
            buffer = buffer.slice(nl + 1);
            if (!line.startsWith("data:")) continue;
            const payload = line.slice(5).trim();
            if (payload === "[DONE]") continue;
            try {
              const text = JSON.parse(payload).choices?.[0]?.delta?.content;
              if (text) {
                if (firstText) { firstText = false; mark("first_token"); }
                emit(text);
              }
            } catch { /* keep-alive or partial line */ }
          }
        }
      } catch (e) {
        send(`data: ${JSON.stringify({ error: String(e) })}\n\n`);
      }
      if (held) send(`data: ${JSON.stringify({ text: held })}\n\n`);
      mark("done");
      const order = agent!.items.length ? marker.match(ORDER) : null;
      const item = order ? agent!.items[Number(order[1]) - 1] : undefined;
      if (item) {
        const qty = Math.min(20, Math.max(1, Number(order![2])));
        const amount = Math.round(Number(item.price_usdc) * qty * 100) / 100;
        send(`data: ${JSON.stringify({ order: { status: "paying", item_name: item.name, qty, amount_usdc: amount } })}\n\n`);
        send(`data: ${JSON.stringify({ order: await placeOrder(req, agent!.id, item.id, qty) })}\n\n`);
        mark("order");
      } else if (marker) {
        console.warn("chat: unusable order marker", marker.slice(0, 80));
      }
      console.log("chat timing", JSON.stringify(marks));
      send(`data: ${JSON.stringify({ timing: marks })}\n\n`);
      send("data: [DONE]\n\n");
      controller.close();
    },
  });
  return new Response(stream, { headers: { ...cors, "Content-Type": "text/event-stream", "Cache-Control": "no-cache" } });
});

/** Has the visitor's wallet agent pay the shop, as the visitor (same session token). */
async function placeOrder(req: Request, agentId: string, itemId: string, qty: number): Promise<Record<string, unknown>> {
  try {
    const r = await fetch(`${Deno.env.get("SUPABASE_URL")}/functions/v1/pay`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: req.headers.get("Authorization") ?? "",
        apikey: req.headers.get("apikey") ?? "",
      },
      body: JSON.stringify({ agent_id: agentId, item_id: itemId, qty }),
    });
    const body = await r.json().catch(() => ({}));
    return body.status ? body : { status: "failed", error: body.error ?? `Payment failed (${r.status})` };
  } catch (e) {
    console.error("chat: pay failed", String(e));
    return { status: "failed", error: "Couldn't reach your wallet." };
  }
}

function menu(items: Item[]): string {
  const lines = items.map((it, i) =>
    `${i + 1}. ${it.name}, $${Number(it.price_usdc).toFixed(2)}${it.note ? ` (${it.note})` : ""}`
  );
  return [
    "You run a shop and take payment in USDC through the visitor's wallet. The menu:",
    ...lines,
    "When, in their latest message, the visitor clearly asks to buy something on the menu, confirm it in " +
    "one short sentence and then end your reply with exactly one line `[[order item=<menu number> qty=<count>]]`. " +
    "That line is hidden and places the order; their wallet pays, and asks them to approve large amounts. " +
    "Never write it otherwise: not for questions, maybes, or anything already ordered. Never invent items or prices. " +
    "Don't say the payment went through; the app tells them.",
  ].join("\n");
}

function systemPrompt(a: AgentRow): string {
  const where = a.anchor === "geo"
    ? "You live at a real place; people walk up to you and talk to you through their AirPods."
    : "You travel with your owner, sitting around them in spatial audio.";
  return [
    `You are ${a.name}, an agent in Agentsphere. ${where}`,
    a.context ? `What you know and how you behave:\n${a.context}` : "",
    a.greeting ? `You introduced yourself with: "${a.greeting}"` : "",
    a.items.length ? menu(a.items) : "",
    "Your replies are spoken aloud. Keep them to one to three short sentences, conversational, " +
    "with no markdown, lists, links, or emoji. If you don't know something, say so briefly.",
  ].filter(Boolean).join("\n\n");
}
