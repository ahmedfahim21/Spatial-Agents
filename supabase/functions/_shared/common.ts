import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2";

export const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

export function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });
}

/** Server key: the legacy service-role key if the project has one, else a new-style secret key. */
function serverKey(): string {
  const legacy = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (legacy) return legacy;
  const explicit = Deno.env.get("AGENTSPHERE_SECRET_KEY");
  if (explicit) return explicit;
  try {
    const keys = JSON.parse(Deno.env.get("SUPABASE_SECRET_KEYS") ?? "{}");
    const first = keys.default ?? Object.values(keys)[0];
    if (typeof first === "string") return first;
  } catch { /* fall through */ }
  throw new Error("No server key available to the function");
}

/** Admin client: bypasses RLS, so every query here must check ownership itself. */
export function admin(): SupabaseClient {
  return createClient(Deno.env.get("SUPABASE_URL")!, serverKey(), {
    auth: { persistSession: false },
  });
}

/** The signed-in (possibly anonymous) user making the request, or null. */
export async function caller(req: Request, db: SupabaseClient): Promise<string | null> {
  const jwt = req.headers.get("Authorization")?.replace(/^Bearer\s+/i, "");
  if (!jwt) return null;
  const { data, error } = await db.auth.getUser(jwt);
  return error ? null : data.user?.id ?? null;
}
