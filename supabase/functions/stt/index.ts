// Speech to text for what you say to an agent: Whisper Large v3 on the 0G Compute Router.
// POST a WAV (16 kHz mono is plenty) as the body; returns {"text": "..."}.
import { admin, caller, cors, json } from "../_shared/common.ts";

const ROUTER = "https://router-api.0g.ai/v1/audio/transcriptions";
const MODEL = Deno.env.get("ZG_STT_MODEL") ?? "whisper-large-v3";
// About 60 s of 16 kHz mono 16-bit audio.
const MAX_BYTES = 2_000_000;

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "POST only" }, 405);

  // An empty POST wakes the worker before you speak.
  if (req.headers.get("content-length") === "0") return new Response(null, { status: 204, headers: cors });
  const t0 = performance.now();
  if (!(await caller(req, admin()))) return json({ error: "Sign in first" }, 401);
  const key = Deno.env.get("ZG_API_KEY");
  if (!key) return json({ error: "The server has no 0G API key configured" }, 500);

  const audio = new Uint8Array(await req.arrayBuffer());
  if (audio.length < 1000) return json({ error: "No audio" }, 400);
  if (audio.length > MAX_BYTES) return json({ error: "Too long" }, 413);

  const form = new FormData();
  form.append("file", new Blob([audio], { type: "audio/wav" }), "speech.wav");
  form.append("model", MODEL);
  form.append("language", new URL(req.url).searchParams.get("language") ?? "en");
  form.append("response_format", "json");

  const r = await fetch(ROUTER, { method: "POST", headers: { Authorization: `Bearer ${key}` }, body: form });
  const body = await r.text();
  const ms = Math.round(performance.now() - t0);
  if (!r.ok) {
    console.error("0G whisper error", r.status, body.slice(0, 500));
    return json({ error: "Couldn't transcribe", status: r.status }, 502);
  }
  let text = "";
  try {
    text = (JSON.parse(body).text ?? "").trim();
  } catch {
    text = body.trim();
  }
  console.log(`stt ${audio.length} bytes -> ${text.length} chars in ${ms} ms`);
  return json({ text, ms });
});
