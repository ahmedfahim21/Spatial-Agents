// One conversational turn with a personal or public agent, through the 0G Compute Router.
// Streams the reply back as SSE: `data: {"text": "..."}` chunks, then `data: [DONE]`.
import { admin, caller, cors, json } from "../_shared/common.ts";

const ROUTER = "https://router-api.0g.ai/v1/chat/completions";
const MODEL = Deno.env.get("ZG_MODEL") ?? "claude-haiku-5.5";
const MAX_TURNS = 24;
const MAX_CHARS = 2000;

type Turn = { role: "user" | "assistant"; content: string };

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "POST only" }, 405);

  const db = admin();
  const uid = await caller(req, db);
  if (!uid) return json({ error: "Sign in first" }, 401);

  let body: { agent_id?: string; messages?: Turn[] };
  try {
    body = await req.json();
  } catch {
    return json({ error: "Invalid JSON" }, 400);
  }
  if (!body.agent_id) return json({ error: "agent_id is required" }, 400);

  const { data: agent, error } = await db
    .from("agents")
    .select("id, owner_id, name, anchor, visibility, greeting, context")
    .eq("id", body.agent_id)
    .maybeSingle();
  if (error) return json({ error: error.message }, 500);
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
              if (text) send(`data: ${JSON.stringify({ text })}\n\n`);
            } catch { /* keep-alive or partial line */ }
          }
        }
      } catch (e) {
        send(`data: ${JSON.stringify({ error: String(e) })}\n\n`);
      }
      send("data: [DONE]\n\n");
      controller.close();
    },
  });
  return new Response(stream, { headers: { ...cors, "Content-Type": "text/event-stream", "Cache-Control": "no-cache" } });
});

function systemPrompt(a: { name: string; anchor: string; visibility: string; greeting: string; context: string }): string {
  const where = a.anchor === "geo"
    ? "You live at a real place; people walk up to you and talk to you through their AirPods."
    : "You travel with your owner, sitting around them in spatial audio.";
  return [
    `You are ${a.name}, an agent in Agentsphere. ${where}`,
    a.context ? `What you know and how you behave:\n${a.context}` : "",
    a.greeting ? `You introduced yourself with: "${a.greeting}"` : "",
    "Your replies are spoken aloud. Keep them to one to three short sentences, conversational, " +
    "with no markdown, lists, links, or emoji. If you don't know something, say so briefly.",
  ].filter(Boolean).join("\n\n");
}
