// A shop agent's x402 storefront. No Supabase sign-in: payment is the authorization.
//   GET  /shop/<agent>          the catalog and how to pay (discovery)
//   POST /shop/<agent>/order    {item_id, qty} → 402 with PAYMENT-REQUIRED, or, with a valid
//                               PAYMENT-SIGNATURE, settles on Hedera and returns the receipt.
import { admin, cors, json } from "../_shared/common.ts";
import { audit, hashscan, NETWORK, USDC, usdcUnits } from "../_shared/hedera.ts";
import {
  decodeHeader, encodeHeader, feePayer, HEADERS, type PaymentPayload, type PaymentRequired, type Requirements,
  sameTerms, settle, verify,
} from "../_shared/x402.ts";

const BASE = `${Deno.env.get("SUPABASE_URL")}/functions/v1/shop`;
const headers402 = {
  ...cors,
  "Access-Control-Allow-Headers": `${cors["Access-Control-Allow-Headers"]}, ${HEADERS.signature}`,
  "Access-Control-Expose-Headers": `${HEADERS.required}, ${HEADERS.response}`,
};

type Shop = { id: string; name: string; wallet_address: string | null; pricing: string; visibility: string };
type Item = { id: string; name: string; note: string; price_usdc: number };

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: headers402 });
  const parts = new URL(req.url).pathname.split("/").filter(Boolean);
  const at = parts.indexOf("shop");
  const agentId = parts[at + 1];
  const action = parts[at + 2];
  if (!agentId || !/^[0-9a-f-]{36}$/i.test(agentId)) return json({ error: "Use /shop/<agent id>" }, 404);

  const db = admin();
  const { data: shop } = await db.from("agents")
    .select("id, name, wallet_address, pricing, visibility").eq("id", agentId).maybeSingle<Shop>();
  if (!shop || shop.visibility !== "public" || shop.pricing !== "paid" || !shop.wallet_address) {
    return json({ error: "No shop here" }, 404);
  }

  if (req.method === "GET" && !action) {
    const { data: items } = await db.from("catalog_items")
      .select("id, name, note, price_usdc").eq("agent_id", agentId).eq("active", true).order("position");
    return json({
      shop: { id: shop.id, name: shop.name, pay_to: shop.wallet_address },
      items: items ?? [],
      payment: {
        protocol: "x402", version: 2, scheme: "exact", network: NETWORK, asset: USDC, currency: "USDC",
        order: { method: "POST", url: `${BASE}/${agentId}/order`, body: { item_id: "<uuid>", qty: 1 } },
      },
    });
  }
  if (req.method !== "POST" || action !== "order") return json({ error: "Not found" }, 404);

  let body: { item_id?: string; qty?: number };
  try {
    body = await req.json();
  } catch {
    return json({ error: "Invalid JSON" }, 400);
  }
  const qty = Math.floor(Number(body.qty ?? 1));
  if (!body.item_id || !(qty >= 1 && qty <= 20)) return json({ error: "item_id and qty (1-20) are required" }, 400);
  const { data: item } = await db.from("catalog_items")
    .select("id, name, note, price_usdc").eq("id", body.item_id).eq("agent_id", agentId).eq("active", true)
    .maybeSingle<Item>();
  if (!item) return json({ error: "That item isn't on the menu" }, 404);

  const amount = Math.round(Number(item.price_usdc) * qty * 100) / 100;
  let terms: Requirements;
  try {
    terms = {
      scheme: "exact", network: NETWORK, amount: usdcUnits(amount), asset: USDC, payTo: shop.wallet_address,
      maxTimeoutSeconds: 180, extra: { feePayer: await feePayer(NETWORK) },
    };
  } catch (e) {
    return json({ error: String(e) }, 503);
  }
  const resource = {
    url: `${BASE}/${agentId}/order`,
    description: `${qty} × ${item.name} from ${shop.name} ($${amount.toFixed(2)} USDC)`,
    mimeType: "application/json",
  };
  const ask = (error: string, status = 402) => {
    const required: PaymentRequired = { x402Version: 2, error, resource, accepts: [terms] };
    return new Response(JSON.stringify(required), {
      status,
      headers: { ...headers402, "Content-Type": "application/json", [HEADERS.required]: encodeHeader(required) },
    });
  };

  const signature = req.headers.get(HEADERS.signature);
  if (!signature) return ask(`${HEADERS.signature} header is required`);

  let payment: PaymentPayload;
  try {
    payment = decodeHeader<PaymentPayload>(signature);
  } catch {
    return ask("Couldn't read the payment", 400);
  }
  if (payment.x402Version !== 2 || !payment.accepted || !sameTerms(payment.accepted, terms) || !payment.payload?.transaction) {
    return ask("The payment doesn't match these terms");
  }

  try {
    const check = await verify(payment, terms);
    if (!check.isValid) return ask(`Payment rejected: ${check.invalidReason ?? "invalid"}`);
    const result = await settle(payment, terms);
    if (!result.success) return ask(`Payment failed: ${result.errorReason ?? "settlement failed"}`);

    // Whose wallet paid (if it's one of ours) for the buyer's order history.
    const payer = result.payer ?? check.payer ?? "";
    const { data: buyer } = await db.from("wallets").select("owner").eq("kind", "user").eq("account_id", payer).maybeSingle();
    const { data: order, error } = await db.from("orders").insert({
      buyer_id: buyer?.owner ?? null, agent_id: agentId, item_id: item.id, item_name: item.name, qty,
      amount_usdc: amount, payer_account: payer, hedera_tx: result.transaction,
    }).select("id").single();
    if (error) console.error("shop: order insert failed", error.message);

    const sequence = await audit(db, {
      type: "payment", shop: agentId, shop_account: shop.wallet_address, payer, item: item.name, qty,
      amount_usdc: amount, tx: result.transaction,
    });

    return new Response(JSON.stringify({
      order: {
        id: order?.id ?? null, item_name: item.name, qty, amount_usdc: amount, hedera_tx: result.transaction,
        hashscan_url: hashscan(result.transaction), payer, pay_to: shop.wallet_address, audit_sequence: sequence,
      },
    }), {
      status: 200,
      headers: { ...headers402, "Content-Type": "application/json", [HEADERS.response]: encodeHeader(result) },
    });
  } catch (e) {
    console.error("shop: settlement error", String(e));
    return json({ error: "The payment couldn't be settled right now." }, 502);
  }
});
