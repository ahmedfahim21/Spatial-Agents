// The buyer's wallet agent. It pays shop agents over x402 from the signed-in user's custodial
// Hedera wallet: on its own within the user's limits, and only after a World ID human
// checkpoint above them.
//   GET  /pay                                   wallet, balance and limits
//   POST /pay {agent_id, item_id, qty}          pay, or ask for a checkpoint
//   POST /pay {agent_id, item_id, qty, approval_id}   pay a purchase the user approved
//   POST /pay/settings {auto_limit_usdc, daily_budget_usdc}
import { admin, caller, cors, json } from "../_shared/common.ts";
import { fundOnce, hashscanAccount, NETWORK, signPayment, usdcBalance, usdcUnits, wallet } from "../_shared/hedera.ts";
import { decodeHeader, encodeHeader, HEADERS, type PaymentPayload, type PaymentRequired } from "../_shared/x402.ts";

const SHOP = `${Deno.env.get("SUPABASE_URL")}/functions/v1/shop`;
const DEFAULTS = { auto_limit_usdc: 5, daily_budget_usdc: 20 };

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  const db = admin();
  const uid = await caller(req, db);
  if (!uid) return json({ error: "Sign in first" }, 401);
  const path = new URL(req.url).pathname;

  const { data: saved } = await db.from("buyer_settings").select("auto_limit_usdc, daily_budget_usdc").eq("user_id", uid).maybeSingle();
  const limits = { auto_limit_usdc: Number(saved?.auto_limit_usdc ?? DEFAULTS.auto_limit_usdc), daily_budget_usdc: Number(saved?.daily_budget_usdc ?? DEFAULTS.daily_budget_usdc) };

  try {
    if (req.method === "GET") {
      const { data: w } = await db.from("wallets").select("account_id").eq("kind", "user").eq("owner", uid).maybeSingle();
      return json({
        account_id: w?.account_id ?? null,
        account_url: w ? hashscanAccount(w.account_id) : null,
        usdc: w ? await usdcBalance(w.account_id) : null,
        spent_today_usdc: await spentToday(db, uid),
        ...limits,
      });
    }
    if (req.method !== "POST") return json({ error: "Not found" }, 404);
    const body = await req.json().catch(() => ({}));

    if (path.endsWith("/settings")) {
      const next = {
        user_id: uid,
        auto_limit_usdc: clamp(body.auto_limit_usdc ?? limits.auto_limit_usdc, 0, 100),
        daily_budget_usdc: clamp(body.daily_budget_usdc ?? limits.daily_budget_usdc, 0, 500),
        updated_at: new Date().toISOString(),
      };
      const { error } = await db.from("buyer_settings").upsert(next);
      if (error) return json({ error: error.message }, 400);
      return json(next);
    }

    return await purchase(db, uid, body, limits);
  } catch (e) {
    console.error("pay: error", String(e));
    return json({ status: "failed", error: friendly(String(e)) }, 502);
  }
});

type Body = { agent_id?: string; item_id?: string; qty?: number; approval_id?: string };

async function purchase(db: ReturnType<typeof admin>, uid: string, body: Body, limits: typeof DEFAULTS) {
  const qty = Math.floor(Number(body.qty ?? 1));
  if (!body.agent_id || !body.item_id || !(qty >= 1 && qty <= 20)) {
    return json({ status: "failed", error: "agent_id, item_id and qty (1-20) are required" }, 400);
  }
  const { data: item } = await db.from("catalog_items").select("id, name, price_usdc")
    .eq("id", body.item_id).eq("agent_id", body.agent_id).eq("active", true).maybeSingle();
  if (!item) return json({ status: "failed", error: "That item isn't on the menu" }, 404);
  const amount = Math.round(Number(item.price_usdc) * qty * 100) / 100;

  // Ask the shop for its terms. A real x402 round trip, as any client would do it.
  const orderUrl = `${SHOP}/${body.agent_id}/order`;
  const first = await fetch(orderUrl, {
    method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ item_id: item.id, qty }),
  });
  const requiredHeader = first.headers.get(HEADERS.required);
  if (first.status !== 402 || !requiredHeader) {
    return json({ status: "failed", error: `The shop didn't ask for payment (${first.status})` }, 502);
  }
  const required = decodeHeader<PaymentRequired>(requiredHeader);
  const terms = required.accepts.find((t) => t.scheme === "exact" && t.network === NETWORK);
  if (!terms) return json({ status: "failed", error: "The shop doesn't accept Hedera payments" }, 502);
  // Our wallet agent pays the catalog price, never whatever a shop happens to quote.
  if (terms.amount !== usdcUnits(amount)) {
    return json({ status: "failed", error: "The shop quoted a different price than its menu" }, 409);
  }

  // Spending rules: within the limit and today's budget, pay without asking. Otherwise a
  // person has to approve it with a fresh World ID check first.
  let checkpoint = false;
  if (body.approval_id) {
    const { data: claimed } = await db.from("approvals").update({ status: "used" })
      .eq("id", body.approval_id).eq("user_id", uid).eq("status", "approved")
      .eq("agent_id", body.agent_id).eq("item_id", item.id).eq("qty", qty).eq("amount_usdc", amount)
      .gt("expires_at", new Date().toISOString())
      .select("id");
    if (!claimed?.length) {
      const { data: a } = await db.from("approvals").select("status, expires_at").eq("id", body.approval_id).eq("user_id", uid).maybeSingle();
      const why = !a ? "not found" : a.status === "approved" ? "expired" : a.status;
      return json({ status: "denied", error: `This purchase wasn't approved (${why}). Nothing was paid.` }, 403);
    }
    checkpoint = true;
  } else {
    const spent = await spentToday(db, uid);
    const overLimit = amount > limits.auto_limit_usdc;
    const overBudget = spent + amount > limits.daily_budget_usdc;
    if (overLimit || overBudget) {
      const { data: approval, error } = await db.from("approvals").insert({
        user_id: uid, agent_id: body.agent_id, item_id: item.id, qty, amount_usdc: amount,
      }).select("id, expires_at").single();
      if (error) throw new Error(error.message);
      return json({
        status: "checkpoint",
        approval: {
          id: approval.id, agent_id: body.agent_id, item_id: item.id, item_name: item.name, qty, amount_usdc: amount,
          expires_at: approval.expires_at,
          reason: overLimit ? `Over your $${limits.auto_limit_usdc.toFixed(2)} limit` : `Over today's $${limits.daily_budget_usdc.toFixed(2)} budget`,
        },
      });
    }
  }

  // Pay: the user's wallet signs the transfer; the shop settles it through the facilitator.
  const w = await wallet(db, "user", uid);
  await fundOnce(db, w);
  const payment: PaymentPayload = {
    x402Version: 2, resource: required.resource, accepted: terms, payload: { transaction: await signPayment(terms, w) },
  };
  const paid = await fetch(orderUrl, {
    method: "POST",
    headers: { "Content-Type": "application/json", [HEADERS.signature]: encodeHeader(payment) },
    body: JSON.stringify({ item_id: item.id, qty }),
  });
  const result = await paid.json().catch(() => ({}));
  if (paid.status !== 200 || !result.order) {
    const reason = result.error ?? (paid.headers.get(HEADERS.required) ? decodeHeader<PaymentRequired>(paid.headers.get(HEADERS.required)!).error : null);
    return json({ status: "failed", error: friendly(reason ?? `The shop answered ${paid.status}`) }, 502);
  }
  if (checkpoint) await db.from("orders").update({ checkpoint: true }).eq("hedera_tx", result.order.hedera_tx);
  return json({ status: "paid", order: { ...result.order, checkpoint } });
}

async function spentToday(db: ReturnType<typeof admin>, uid: string): Promise<number> {
  const since = new Date(Date.now() - 24 * 3600 * 1000).toISOString();
  const { data } = await db.from("orders").select("amount_usdc").eq("buyer_id", uid).gte("created_at", since);
  return (data ?? []).reduce((sum, o) => sum + Number(o.amount_usdc), 0);
}

function clamp(v: unknown, lo: number, hi: number): number {
  const n = Number(v);
  return Number.isFinite(n) ? Math.min(hi, Math.max(lo, Math.round(n * 100) / 100)) : lo;
}

function friendly(reason: string): string {
  if (/insufficient|INSUFFICIENT_TOKEN_BALANCE/i.test(reason)) return "Not enough USDC in your wallet.";
  if (/not configured/i.test(reason)) return "Payments aren't set up on the server yet.";
  return reason.length > 160 ? reason.slice(0, 160) + "…" : reason;
}
