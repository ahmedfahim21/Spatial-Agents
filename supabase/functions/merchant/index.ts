// Shop owners: turn on payments for a public agent and save its catalog.
//   POST /merchant {agent_id, items: [{id?, name, price_usdc, note?}]}
//        Requires a verified World ID (once World ID is configured on the server).
//        Creates the agent's Hedera wallet on first use.
//        An empty list turns payments off.
//   POST /merchant/setup   one-time, idempotent: operator USDC association + audit topic.
import { admin, caller, cors, json } from "../_shared/common.ts";
import { hashscanAccount, setup, wallet } from "../_shared/hedera.ts";

type ItemIn = { id?: string; name?: string; price_usdc?: number; note?: string };

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "POST only" }, 405);
  const db = admin();
  const uid = await caller(req, db);
  if (!uid) return json({ error: "Sign in first" }, 401);

  try {
    if (new URL(req.url).pathname.endsWith("/setup")) return json(await setup(db));

    const body = await req.json().catch(() => ({})) as { agent_id?: string; items?: ItemIn[] };
    const { data: agent } = await db.from("agents").select("id, owner_id, visibility, anchor")
      .eq("id", body.agent_id ?? "").maybeSingle();
    if (!agent || agent.owner_id !== uid) return json({ error: "Agent not found" }, 404);
    if (agent.visibility !== "public" || agent.anchor !== "geo") {
      return json({ error: "Only public agents placed in the world can take payments" }, 400);
    }

    const items = (body.items ?? []).map((i, position) => ({
      id: i.id, name: (i.name ?? "").trim().slice(0, 80), note: (i.note ?? "").trim().slice(0, 200),
      price_usdc: Math.round(Number(i.price_usdc) * 100) / 100, position,
    }));
    if (items.length > 30) return json({ error: "Up to 30 items" }, 400);
    if (items.some((i) => !i.name || !(i.price_usdc > 0 && i.price_usdc <= 1000))) {
      return json({ error: "Each item needs a name and a price between $0.01 and $1,000" }, 400);
    }

    if (items.length === 0) {
      await db.from("catalog_items").update({ active: false }).eq("agent_id", agent.id);
      await db.from("agents").update({ pricing: "free" }).eq("id", agent.id);
      return json({ pricing: "free", items: [] });
    }

    // Selling needs a verified human behind the shop. Until World ID is set up on the server,
    // shops open unverified (and show no badge).
    if (Deno.env.get("WORLD_CLIENT_ID")) {
      const { data: identity } = await db.from("world_identities").select("acr").eq("user_id", uid).maybeSingle();
      if (!identity) return json({ error: "Verify with World ID first", needs_verification: true }, 403);
    }

    const w = await wallet(db, "agent", agent.id);

    // Upsert what's listed; retire what isn't (orders keep their history).
    const keep: string[] = [];
    for (const i of items) {
      const row = { agent_id: agent.id, name: i.name, note: i.note, price_usdc: i.price_usdc, position: i.position, active: true };
      if (i.id) {
        const { data } = await db.from("catalog_items").update(row).eq("id", i.id).eq("agent_id", agent.id).select("id").maybeSingle();
        if (data) { keep.push(data.id); continue; }
      }
      const { data, error } = await db.from("catalog_items").insert(row).select("id").single();
      if (error) throw new Error(error.message);
      keep.push(data.id);
    }
    await db.from("catalog_items").update({ active: false }).eq("agent_id", agent.id).not("id", "in", `(${keep.join(",")})`);
    await db.from("agents").update({ pricing: "paid", wallet_address: w.accountId }).eq("id", agent.id);

    const { data: saved } = await db.from("catalog_items").select("id, name, note, price_usdc, position")
      .eq("agent_id", agent.id).eq("active", true).order("position");
    return json({ pricing: "paid", wallet_account: w.accountId, wallet_url: hashscanAccount(w.accountId), items: saved ?? [] });
  } catch (e) {
    console.error("merchant: error", String(e));
    return json({ error: String(e).slice(0, 200) }, 502);
  }
});
