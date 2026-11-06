// One conversational turn with a personal or public agent, through the 0G Compute Router.
// Streams the reply back as SSE: `data: {"text": "..."}` chunks, then `data: [DONE]`.
// Shop agents can also take an order: the model ends its reply with a hidden
// `[[order item=<n> qty=<q>]]` line, which is never streamed; instead this asks the visitor's
// wallet agent (the pay function) to pay, and sends `data: {"order": ...}` events.
import { admin, caller, cors, json } from "../_shared/common.ts";
import { TOOL_PROMPT, toolsFor } from "./tools.ts";

const ROUTER = "https://router-api.0g.ai/v1/chat/completions";
const MODEL = Deno.env.get("ZG_MODEL") ?? "claude-haiku-5.5";
const MAX_TURNS = 40;
const MAX_CHARS = 2000;
const MAX_TOOL_CHARS = 6000;

type ToolCall = { id: string; type: "function"; function: { name: string; arguments: string } };
type Turn =
  | { role: "user"; content: string }
  | { role: "assistant"; content: string | null; tool_calls?: ToolCall[] }
  | { role: "tool"; tool_call_id: string; content: string };
// deno-lint-ignore no-explicit-any
type RawTurn = any;
type AgentRow = {
  id: string; owner_id: string; name: string; anchor: string; visibility: string; greeting: string; context: string;
  pricing: string; model: string | null; items: Item[];
};
type Item = { id: string; name: string; note: string; price_usdc: number };
const ORDER = /\[\[\s*order\s+item\s*=\s*(\d+)\s+qty\s*=\s*(\d+)\s*\]\]/i;

// Agents change rarely; keep them for 30 s per worker so a conversation doesn't hit the DB every turn.
const agentCache = new Map<string, { row: AgentRow | null; at: number }>();
async function loadAgent(db: ReturnType<typeof admin>, id: string): Promise<AgentRow | null> {
  const hit = agentCache.get(id);
  if (hit && Date.now() - hit.at < 30_000) return hit.row;
  // `*` so this keeps working whether or not the `model` column exists yet.
  const { data, error } = await db.from("agents").select("*").eq("id", id).maybeSingle();
  if (error) throw new Error(error.message);
  let row: AgentRow | null = data
    ? {
      id: data.id, owner_id: data.owner_id, name: data.name, anchor: data.anchor, visibility: data.visibility,
      greeting: data.greeting, context: data.context, pricing: data.pricing, model: data.model ?? null, items: [],
    }
    : null;
  if (row?.pricing === "paid" && row.visibility === "public") {
    const { data: items } = await db.from("catalog_items").select("id, name, note, price_usdc")
      .eq("agent_id", id).eq("active", true).order("position");
    row = { ...row, items: items ?? [] };
  }
  agentCache.set(id, { row, at: Date.now() });
  return row;
}

// The router's chat models and what each accepts, refreshed hourly. An agent's model must
// be on this list, or it falls back to the default.
type ModelInfo = { params: string[] };
let models: { at: number; byId: Map<string, ModelInfo> } | null = null;
async function chatModels(): Promise<Map<string, ModelInfo>> {
  if (models && Date.now() - models.at < 3_600_000) return models.byId;
  try {
    const r = await fetch("https://router-api.0g.ai/v1/models", { signal: AbortSignal.timeout(4000) });
    const list: { id: string; type?: string; supported_parameters?: string[] }[] = (await r.json()).data ?? [];
    const byId = new Map(list.filter((m) => m.type === "chatbot").map((m) => [m.id, { params: m.supported_parameters ?? [] }]));
    if (byId.size) models = { at: Date.now(), byId };
  } catch (e) {
    console.error("0G model list", String(e));
  }
  return models?.byId ?? new Map();
}

/// The request body for one model. Spoken replies need the answer quickly, so models that
/// can switch their "thinking" off get it off, and others get room to think before answering.
function completion(model: string, info: ModelInfo | undefined, messages: unknown[], tools: unknown[], final = false) {
  const body: Record<string, unknown> = { model, stream: true, max_tokens: model === MODEL ? 400 : 1200, messages };
  // The tools stay listed on the last round (earlier tool calls in the conversation need
  // them), but it may not call any more.
  if (tools.length) { body.tools = tools; if (final) body.tool_choice = "none"; }
  if (info?.params.includes("chat_template_kwargs")) body.chat_template_kwargs = { enable_thinking: false };
  return body;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "POST only" }, 405);

  const t0 = performance.now();
  const marks: Record<string, number> = {};
  const mark = (k: string) => (marks[k] = Math.round(performance.now() - t0));
  let body: {
    agent_id?: string;
    /** The last round of a reply: answer now, no more tool calls. */
    final?: boolean;
    messages?: RawTurn[];
    warm?: boolean;
    /** Tool groups the owner allowed for this agent on their phone (see tools.ts). */
    tools?: string[];
    /** The phone's local time, so "tomorrow at 10" means the right thing. */
    client?: { now?: string; timezone?: string };
  };
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

  const turns = cleanTurns(body.messages ?? []);
  // The greeting lives in the system prompt; the conversation itself must open with the user.
  while (turns.length > 0 && turns[0].role !== "user") turns.shift();
  const last = turns[turns.length - 1]?.role;
  if (last !== "user" && last !== "tool") {
    return json({ error: "The last message must be from the user" }, 400);
  }
  // Phone tools only for your own private agents: never a public agent, never someone else's.
  const tools = agent.owner_id === uid && agent.visibility === "private" ? toolsFor(body.tools) : [];

  const key = Deno.env.get("ZG_API_KEY");
  if (!key) return json({ error: "The server has no 0G API key configured" }, 500);

  const messages = [{ role: "system", content: systemPrompt(agent, tools.length > 0, body.client) }, ...turns];
  const ask = (model: string, info?: ModelInfo) =>
    fetch(ROUTER, {
      method: "POST",
      headers: { "Content-Type": "application/json", Authorization: `Bearer ${key}` },
      body: JSON.stringify(completion(model, info, messages, tools, body.final === true)),
    });
  let upstream: Response;
  const wanted = agent.model && agent.model !== MODEL ? agent.model : null;
  const info = wanted ? (await chatModels()).get(wanted) : undefined;
  if (wanted && info) {
    upstream = await ask(wanted, info);
    // A model that's down or out of capacity shouldn't leave the agent speechless.
    if (!upstream.ok && upstream.status !== 402) {
      console.error("0G model failed, using default", wanted, upstream.status, (await upstream.text().catch(() => "")).slice(0, 300));
      upstream = await ask(MODEL);
    }
  } else {
    upstream = await ask(MODEL);
  }
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
      // Tool calls arrive in pieces, by index.
      const calls: { id: string; name: string; args: string }[] = [];
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
              const delta = JSON.parse(payload).choices?.[0]?.delta;
              const text = delta?.content;
              if (text) {
                if (firstText) { firstText = false; mark("first_token"); }
                emit(text);
              }
              for (const tc of delta?.tool_calls ?? []) {
                const c = (calls[tc.index ?? 0] ??= { id: "", name: "", args: "" });
                if (tc.id) c.id = tc.id;
                // Names arrive whole; some providers repeat the finished call at the end, so
                // set rather than append, and let a repeated complete argument object replace.
                if (tc.function?.name) c.name = tc.function.name;
                const a = tc.function?.arguments;
                if (a) c.args = isJSON(c.args) && a.trimStart().startsWith("{") ? a : c.args + a;
              }
            } catch { /* keep-alive or partial line */ }
          }
        }
      } catch (e) {
        send(`data: ${JSON.stringify({ error: String(e) })}\n\n`);
      }
      if (held) send(`data: ${JSON.stringify({ text: held })}\n\n`);
      mark("done");
      const wanted = calls.filter((c) => c?.name).map((c, i) => ({
        id: c.id || `call_${i}`, name: c.name, arguments: firstJSON(c.args),
      }));
      if (wanted.length) {
        // The app runs these on the phone and asks again with the results.
        send(`data: ${JSON.stringify({ tool_calls: wanted })}\n\n`);
        mark("tool_calls");
      }
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

function isJSON(s: string): boolean {
  if (!s.trim()) return false;
  try { JSON.parse(s); return true; } catch { return false; }
}

/** The arguments as one JSON object (the first complete one if a provider doubled them). */
function firstJSON(s: string): string {
  if (isJSON(s)) return s;
  let depth = 0, inString = false, escaped = false;
  for (let i = 0; i < s.length; i++) {
    const ch = s[i];
    if (inString) { if (escaped) escaped = false; else if (ch === "\\") escaped = true; else if (ch === '"') inString = false; continue; }
    if (ch === '"') inString = true;
    else if (ch === "{") depth++;
    else if (ch === "}" && --depth === 0) { const head = s.slice(s.indexOf("{"), i + 1); if (isJSON(head)) return head; break; }
  }
  return "{}";
}

/** Keeps only well-formed user, assistant (with any tool calls) and tool messages. */
function cleanTurns(raw: RawTurn[]): Turn[] {
  const out: Turn[] = [];
  for (const m of raw.slice(-MAX_TURNS)) {
    if (!m || typeof m !== "object") continue;
    if (m.role === "user" && typeof m.content === "string") {
      out.push({ role: "user", content: m.content.slice(0, MAX_CHARS) });
    } else if (m.role === "assistant") {
      const calls: ToolCall[] = (Array.isArray(m.tool_calls) ? m.tool_calls : [])
        .filter((c: RawTurn) => typeof c?.id === "string" && typeof c?.function?.name === "string")
        .slice(0, 4)
        .map((c: RawTurn) => ({
          id: c.id, type: "function" as const,
          function: { name: c.function.name, arguments: String(c.function.arguments ?? "{}").slice(0, MAX_CHARS) },
        }));
      const content = typeof m.content === "string" ? m.content.slice(0, MAX_CHARS) : "";
      if (calls.length) out.push({ role: "assistant", content: content || null, tool_calls: calls });
      else if (content) out.push({ role: "assistant", content });
    } else if (m.role === "tool" && typeof m.tool_call_id === "string") {
      out.push({ role: "tool", tool_call_id: m.tool_call_id, content: String(m.content ?? "").slice(0, MAX_TOOL_CHARS) });
    }
  }
  return out;
}

function systemPrompt(a: AgentRow, tools = false, client?: { now?: string; timezone?: string }): string {
  const where = a.anchor === "geo"
    ? "You live at a real place; people walk up to you and talk to you through their AirPods."
    : "You travel with your owner, sitting around them in spatial audio.";
  return [
    `You are ${a.name}, an agent in Air Agents. ${where}`,
    a.context ? `What you know and how you behave:\n${a.context}` : "",
    a.greeting ? `You introduced yourself with: "${a.greeting}"` : "",
    a.items.length ? menu(a.items) : "",
    typeof client?.now === "string"
      ? `It's now ${client.now.slice(0, 40)}${typeof client.timezone === "string" ? ` (${client.timezone.slice(0, 40)})` : ""} for the person you're talking to.`
      : "",
    tools ? TOOL_PROMPT : "",
    "Your replies are spoken aloud. Keep them to one to three short sentences, conversational, " +
    "with no markdown, lists, links, or emoji. If you don't know something, say so briefly.",
  ].filter(Boolean).join("\n\n");
}
