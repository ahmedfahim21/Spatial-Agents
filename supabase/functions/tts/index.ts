// Speaks a line in an agent's voice: proxies ElevenLabs streaming TTS so the app ships no key.
// Returns raw 16-bit little-endian mono PCM at 24 kHz.
import { admin, caller, cors, json } from "../_shared/common.ts";

const DEFAULT_VOICE = "21m00Tcm4TlvDq8ikWAM"; // ElevenLabs premade "Rachel"

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "POST only" }, 405);

  const uid = await caller(req, admin());
  if (!uid) return json({ error: "Sign in first" }, 401);

  const key = Deno.env.get("ELEVENLABS_API_KEY");
  if (!key) return json({ error: "No ElevenLabs key configured" }, 503);

  let body: { text?: string; voice_id?: string };
  try {
    body = await req.json();
  } catch {
    return json({ error: "Invalid JSON" }, 400);
  }
  const text = (body.text ?? "").trim().slice(0, 800);
  if (!text) return json({ error: "text is required" }, 400);
  const voice = /^[A-Za-z0-9]{10,40}$/.test(body.voice_id ?? "") ? body.voice_id! : DEFAULT_VOICE;

  const upstream = await fetch(
    `https://api.elevenlabs.io/v1/text-to-speech/${voice}/stream?output_format=pcm_24000`,
    {
      method: "POST",
      headers: { "Content-Type": "application/json", "xi-api-key": key },
      body: JSON.stringify({ text, model_id: "eleven_flash_v2_5" }),
    },
  );
  if (!upstream.ok || !upstream.body) {
    console.error("ElevenLabs error", upstream.status, (await upstream.text().catch(() => "")).slice(0, 300));
    return json({ error: "Voice unavailable", status: upstream.status }, 502);
  }
  return new Response(upstream.body, { headers: { ...cors, "Content-Type": "application/octet-stream" } });
});
