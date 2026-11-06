// World ID (auth.world.org OIDC) for two moments:
//   verify_shop  a shop owner proves there's a real, unique human behind the shop (badge)
//   checkpoint   a buyer approves a purchase over their limit with a fresh World ID check
// The app opens the authorize URL in a web sheet; World redirects here; this exchanges the
// code, validates the ID token on the server, records the result and sends the app back to
// agentsphere://world?result=... (never with tokens in the URL).
//   POST /world/start {purpose, approval_id?}   signed in → {url}
//   GET  /world/callback                        from World
import { createRemoteJWKSet, jwtVerify } from "npm:jose@5";
import { admin, caller, cors, json } from "../_shared/common.ts";

const ISSUER = (Deno.env.get("WORLD_ISSUER") ?? "https://sandbox.auth.world.org").replace(/\/$/, "");
const CLIENT_ID = Deno.env.get("WORLD_CLIENT_ID") ?? "";
const CLIENT_SECRET = Deno.env.get("WORLD_CLIENT_SECRET") ?? "";
const REDIRECT = `${Deno.env.get("SUPABASE_URL")}/functions/v1/world/callback`;
const APP = "agentsphere://world";
/** Verified humans only: Orb or Selfie Check (and their Face Auth variants). */
const ACCEPTED = [
  "https://world.org/oidc/acr/orb", "https://world.org/oidc/acr/orb-face",
  "https://world.org/oidc/acr/selfie", "https://world.org/oidc/acr/selfie-face",
];
const ATTEMPT_TTL_MS = 10 * 60 * 1000;
const CLOCK_SKEW_S = 30;

type Discovery = { authorization_endpoint: string; token_endpoint: string; jwks_uri: string; acr_values_supported?: string[] };
let discovery: Discovery | null = null;
let jwks: ReturnType<typeof createRemoteJWKSet> | null = null;

async function idp(): Promise<Discovery> {
  if (discovery) return discovery;
  const r = await fetch(`${ISSUER}/.well-known/openid-configuration`);
  if (!r.ok) throw new Error(`World ID discovery failed (${r.status})`);
  discovery = await r.json();
  jwks = createRemoteJWKSet(new URL(discovery!.jwks_uri));
  return discovery!;
}

/** The verified-human levels this issuer offers (the sandbox has Orb only). */
async function acceptedHere(): Promise<string[]> {
  const offered = (await idp()).acr_values_supported;
  const both = offered ? ACCEPTED.filter((a) => offered.includes(a)) : ACCEPTED;
  return both.length ? both : ACCEPTED;
}

const b64url = (bytes: Uint8Array) => btoa(String.fromCharCode(...bytes)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
const random = (n = 32) => b64url(crypto.getRandomValues(new Uint8Array(n)));
const back = (result: string, purpose = "", detail = "") => {
  const q = new URLSearchParams({ result, purpose, ...(detail ? { detail } : {}) });
  return new Response(null, { status: 302, headers: { Location: `${APP}?${q}` } });
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  const path = new URL(req.url).pathname;
  if (!CLIENT_ID || !CLIENT_SECRET) return json({ error: "World ID isn't configured on the server yet" }, 503);
  try {
    if (req.method === "POST" && path.endsWith("/start")) return await start(req);
    if (req.method === "GET" && path.endsWith("/callback")) return await callback(req);
    return json({ error: "Not found" }, 404);
  } catch (e) {
    console.error("world: error", String(e));
    return path.endsWith("/callback") ? back("failed") : json({ error: String(e).slice(0, 200) }, 502);
  }
});

async function start(req: Request): Promise<Response> {
  const db = admin();
  const uid = await caller(req, db);
  if (!uid) return json({ error: "Sign in first" }, 401);
  const body = await req.json().catch(() => ({})) as { purpose?: string; approval_id?: string };
  const purpose = body.purpose === "checkpoint" ? "checkpoint" : body.purpose === "verify_shop" ? "verify_shop" : null;
  if (!purpose) return json({ error: "purpose must be verify_shop or checkpoint" }, 400);

  if (purpose === "checkpoint") {
    const { data: a } = await db.from("approvals").select("status, expires_at")
      .eq("id", body.approval_id ?? "").eq("user_id", uid).maybeSingle();
    if (!a || a.status !== "pending") return json({ error: "There's no purchase waiting for approval" }, 404);
    if (new Date(a.expires_at) < new Date()) {
      await db.from("approvals").update({ status: "expired" }).eq("id", body.approval_id!);
      return json({ error: "That approval request expired" }, 410);
    }
  }

  const state = random(), nonce = random(), verifier = random(48);
  const challenge = b64url(new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(verifier))));
  const { error } = await db.from("world_attempts").insert({
    state, nonce, verifier, user_id: uid, purpose, approval_id: purpose === "checkpoint" ? body.approval_id : null,
  });
  if (error) throw new Error(error.message);

  const { authorization_endpoint } = await idp();
  const params = new URLSearchParams({
    client_id: CLIENT_ID, redirect_uri: REDIRECT, response_type: "code", scope: "openid",
    state, nonce, code_challenge: challenge, code_challenge_method: "S256",
    // Always a fresh check: a checkpoint must not ride on an old session.
    max_age: "0",
    claims: JSON.stringify({ id_token: { acr: { essential: true, values: await acceptedHere() } } }),
  });
  return json({ url: `${authorization_endpoint}?${params}`, callback_scheme: "agentsphere" });
}

async function callback(req: Request): Promise<Response> {
  const db = admin();
  const q = new URL(req.url).searchParams;
  const state = q.get("state") ?? "";

  // Claim the attempt exactly once, so a replayed callback does nothing.
  const { data: claimed } = await db.from("world_attempts").update({ status: "failed" })
    .eq("state", state).eq("status", "pending").select("user_id, purpose, approval_id, nonce, verifier, created_at");
  const attempt = claimed?.[0];
  if (!attempt) return back("failed", "", "unknown or used request");
  const purpose = attempt.purpose as string;
  const deny = async (result: "denied" | "failed", detail: string) => {
    await db.from("world_attempts").update({ status: result === "denied" ? "denied" : "failed" }).eq("state", state);
    if (purpose === "checkpoint" && attempt.approval_id) {
      await db.from("approvals").update({ status: "denied" }).eq("id", attempt.approval_id).eq("status", "pending");
    }
    console.log(`world: ${purpose} ${result}: ${detail}`);
    return back(result, purpose, detail);
  };

  if (Date.now() - new Date(attempt.created_at).getTime() > ATTEMPT_TTL_MS) return deny("failed", "expired");
  const err = q.get("error");
  if (err) return deny(err === "access_denied" ? "denied" : "failed", err);
  if (q.get("iss") && q.get("iss") !== ISSUER) return deny("failed", "issuer mismatch");
  const code = q.get("code");
  if (!code) return deny("failed", "no code");

  // Redeem the code (confidential client, client_secret_basic, PKCE).
  const { token_endpoint } = await idp();
  const basic = btoa(`${encodeURIComponent(CLIENT_ID)}:${encodeURIComponent(CLIENT_SECRET)}`);
  const tr = await fetch(token_endpoint, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded", Authorization: `Basic ${basic}` },
    body: new URLSearchParams({ grant_type: "authorization_code", code, redirect_uri: REDIRECT, code_verifier: attempt.verifier }),
  });
  const tokens = await tr.json().catch(() => ({}));
  if (!tr.ok || typeof tokens.id_token !== "string") return deny("failed", `token exchange ${tr.status}`);

  // Validate the ID token here; nothing the app says counts.
  const { payload } = await jwtVerify(tokens.id_token, jwks!, { issuer: ISSUER, audience: CLIENT_ID });
  if (payload.nonce !== attempt.nonce) return deny("failed", "nonce mismatch");
  const acr = typeof payload.acr === "string" ? payload.acr : "";
  if (!ACCEPTED.includes(acr)) return deny("denied", "not a verified human");
  const authTime = Number(payload.auth_time ?? 0);
  if (authTime < new Date(attempt.created_at).getTime() / 1000 - CLOCK_SKEW_S) return deny("failed", "not a fresh check");
  const sub = String(payload.sub ?? "");
  if (!sub) return deny("failed", "no subject");

  const uid = attempt.user_id as string;
  const { data: mine } = await db.from("world_identities").select("iss, sub").eq("user_id", uid).maybeSingle();

  if (purpose === "checkpoint" && mine && (mine.iss !== ISSUER || mine.sub !== sub)) {
    // Only the human who owns this wallet can approve its spending.
    return deny("denied", "a different World ID");
  }
  if (!mine || mine.sub !== sub) {
    // First verification for this account, or verifying again with a different World ID:
    // link it. One human, one account: if this World ID was linked to another (e.g. an old
    // install), it moves here.
    await db.from("world_identities").delete().eq("iss", ISSUER).eq("sub", sub).neq("user_id", uid);
  }
  const { error } = await db.from("world_identities").upsert({
    user_id: uid, iss: ISSUER, sub, acr, verified_at: new Date().toISOString(),
  });
  if (error) return deny("failed", error.message);

  if (purpose === "checkpoint") {
    const { data: approved } = await db.from("approvals").update({ status: "approved" })
      .eq("id", attempt.approval_id).eq("user_id", uid).eq("status", "pending")
      .gt("expires_at", new Date().toISOString()).select("id");
    if (!approved?.length) return deny("failed", "approval expired");
  }
  await db.from("world_attempts").update({ status: "ok" }).eq("state", state);
  console.log(`world: ${purpose} ok (${acr})`);
  return back("ok", purpose);
}
