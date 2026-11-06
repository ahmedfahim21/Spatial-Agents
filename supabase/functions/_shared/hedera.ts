// Hedera testnet: custodial wallets, USDC transfers, x402 payment signing and the HCS audit log.
// Supabase's runtime can't open native gRPC connections, so this uses the SDK's WebClient
// (gRPC-web over fetch). Signing is always local.
import {
  AccountCreateTransaction, AccountId, Hbar, PrivateKey, TokenAssociateTransaction, TokenId,
  TopicCreateTransaction, TopicMessageSubmitTransaction, TransactionId, TransferTransaction, WebClient,
} from "npm:@hiero-ledger/sdk@2.90.1";
import type { SupabaseClient } from "npm:@supabase/supabase-js@2";
import type { Requirements } from "./x402.ts";

export const NETWORK = "hedera:testnet";
export const USDC = Deno.env.get("HEDERA_USDC") ?? "0.0.429274";
const USDC_DECIMALS = 6;
/** What a new buyer wallet starts with. */
const STARTER_USDC = 10;
const MIRROR = "https://testnet.mirrornode.hedera.com/api/v1";

/** Dollars to the token's smallest unit, as the string x402 expects. */
export function usdcUnits(amount: number): string {
  return String(Math.round(amount * 10 ** USDC_DECIMALS));
}

/** `0.0.123@1700000000.000000001` → a HashScan link. */
export function hashscan(txId: string): string {
  const [acct, time] = txId.split("@");
  return `https://hashscan.io/testnet/transaction/${acct}-${(time ?? "").replace(".", "-")}`;
}

export function hashscanAccount(id: string): string {
  return `https://hashscan.io/testnet/account/${id}`;
}

function parseKey(s: string): PrivateKey {
  const t = s.trim().replace(/^0x/, "");
  return /^[0-9a-fA-F]{64}$/.test(t) ? PrivateKey.fromStringECDSA(t) : PrivateKey.fromStringDer(t);
}

let op: { client: WebClient; id: AccountId; key: PrivateKey } | null = null;

/** The operator account: creates wallets, hands out starter USDC, writes the audit log. */
function operator() {
  if (op) return op;
  const id = Deno.env.get("HEDERA_OPERATOR_ID"), key = Deno.env.get("HEDERA_OPERATOR_KEY");
  if (!id || !key) throw new Error("Hedera isn't configured on the server yet");
  const accountId = AccountId.fromString(id);
  const pk = parseKey(key);
  const client = WebClient.forTestnet();
  client.setOperator(accountId, pk);
  client.setRequestTimeout(30_000);
  op = { client, id: accountId, key: pk };
  return op;
}

// MARK: Wallet keys at rest (AES-GCM with WALLET_ENC_KEY, 32 bytes base64)

const b64 = (bytes: Uint8Array) => btoa(String.fromCharCode(...bytes));
const unb64 = (s: string) => Uint8Array.from(atob(s), (c) => c.charCodeAt(0));

async function aes(): Promise<CryptoKey> {
  const raw = Deno.env.get("WALLET_ENC_KEY");
  if (!raw) throw new Error("WALLET_ENC_KEY isn't set");
  const bytes = unb64(raw);
  if (bytes.length !== 32) throw new Error("WALLET_ENC_KEY must be 32 bytes, base64");
  return crypto.subtle.importKey("raw", bytes, "AES-GCM", false, ["encrypt", "decrypt"]);
}

async function seal(text: string): Promise<string> {
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const ct = new Uint8Array(await crypto.subtle.encrypt({ name: "AES-GCM", iv }, await aes(), new TextEncoder().encode(text)));
  const out = new Uint8Array(iv.length + ct.length);
  out.set(iv);
  out.set(ct, iv.length);
  return b64(out);
}

async function unseal(sealed: string): Promise<string> {
  const bytes = unb64(sealed);
  const pt = await crypto.subtle.decrypt({ name: "AES-GCM", iv: bytes.slice(0, 12) }, await aes(), bytes.slice(12));
  return new TextDecoder().decode(pt);
}

// MARK: Wallets

export type Wallet = { accountId: string; key: PrivateKey; funded: boolean };

/**
 * The custodial wallet of a paid agent (receives) or a user (pays), created on first use:
 * an ECDSA account associated with USDC so it can hold and receive it.
 */
export async function wallet(db: SupabaseClient, kind: "agent" | "user", owner: string): Promise<Wallet> {
  const existing = await loadWallet(db, kind, owner);
  if (existing) return existing;

  const { client } = operator();
  const key = PrivateKey.generateECDSA();
  const created = await new AccountCreateTransaction()
    .setKeyWithoutAlias(key.publicKey)
    .setInitialBalance(new Hbar(1))
    .setAccountMemo(`Agentsphere ${kind} wallet`)
    .execute(client);
  const accountId = (await created.getReceipt(client)).accountId!.toString();

  const assoc = await new TokenAssociateTransaction()
    .setAccountId(accountId)
    .setTokenIds([TokenId.fromString(USDC)])
    .freezeWith(client)
    .sign(key);
  await (await assoc.execute(client)).getReceipt(client);

  const { error } = await db.from("wallets").insert({
    kind, owner, account_id: accountId, enc_key: await seal(key.toStringRaw()),
  });
  if (error) {
    // Lost a race with another request creating the same wallet: use theirs.
    const theirs = await loadWallet(db, kind, owner);
    if (theirs) return theirs;
    throw new Error(error.message);
  }
  console.log(`hedera: created ${kind} wallet ${accountId}`);
  return { accountId, key, funded: false };
}

async function loadWallet(db: SupabaseClient, kind: string, owner: string): Promise<Wallet | null> {
  const { data, error } = await db.from("wallets").select("account_id, enc_key, funded")
    .eq("kind", kind).eq("owner", owner).maybeSingle();
  if (error) throw new Error(error.message);
  if (!data) return null;
  return { accountId: data.account_id, key: PrivateKey.fromStringECDSA(await unseal(data.enc_key)), funded: data.funded };
}

/** Gives a new buyer wallet its starter USDC from the operator, once. */
export async function fundOnce(db: SupabaseClient, w: Wallet): Promise<void> {
  if (w.funded) return;
  const { client, id } = operator();
  const units = Number(usdcUnits(STARTER_USDC));
  const tx = await new TransferTransaction()
    .addTokenTransfer(TokenId.fromString(USDC), id, -units)
    .addTokenTransfer(TokenId.fromString(USDC), AccountId.fromString(w.accountId), units)
    .execute(client);
  await tx.getReceipt(client);
  await db.from("wallets").update({ funded: true }).eq("account_id", w.accountId);
  w.funded = true;
}

/** USDC balance in dollars, from the mirror node (a few seconds behind consensus). */
export async function usdcBalance(accountId: string): Promise<number | null> {
  try {
    const r = await fetch(`${MIRROR}/accounts/${accountId}/tokens?token.id=${USDC}`);
    if (!r.ok) return null;
    const body = await r.json();
    const units = body.tokens?.[0]?.balance;
    return typeof units === "number" ? units / 10 ** USDC_DECIMALS : 0;
  } catch {
    return null;
  }
}

// MARK: x402

/**
 * The "exact" scheme payment for Hedera, as the reference client builds it: a transfer from
 * the payer to payTo, with the facilitator as the transaction's fee payer, signed by the payer
 * only. The facilitator adds its signature and submits.
 */
export async function signPayment(req: Requirements, w: Wallet): Promise<string> {
  const amount = Number(req.amount);
  const token = TokenId.fromString(req.asset);
  const tx = new TransferTransaction()
    .addTokenTransfer(token, AccountId.fromString(w.accountId), -amount)
    .addTokenTransfer(token, AccountId.fromString(req.payTo), amount)
    .setTransactionId(TransactionId.generate(AccountId.fromString(req.extra.feePayer)));
  // A client without an operator: freezing only picks nodes, it must not add our signature.
  tx.freezeWith(WebClient.forTestnet());
  const signed = await tx.sign(w.key);
  return b64(signed.toBytes());
}

// MARK: Audit log (HCS)

/** The spending log topic, created the first time it's needed. */
export async function auditTopic(db: SupabaseClient): Promise<string> {
  const { data } = await db.from("app_settings").select("value").eq("key", "audit_topic").maybeSingle();
  if (data?.value) return data.value;
  const { client, key } = operator();
  const tx = await new TopicCreateTransaction()
    .setTopicMemo("Agentsphere: agent spending audit log")
    .setSubmitKey(key.publicKey)
    .execute(client);
  const topic = (await tx.getReceipt(client)).topicId!.toString();
  await db.from("app_settings").upsert({ key: "audit_topic", value: topic });
  console.log(`hedera: audit topic ${topic}`);
  return topic;
}

/** Appends one record to the audit log. Never fails the caller. */
export async function audit(db: SupabaseClient, record: Record<string, unknown>): Promise<number | null> {
  try {
    const { client } = operator();
    const topic = await auditTopic(db);
    const tx = await new TopicMessageSubmitTransaction()
      .setTopicId(topic)
      .setMessage(JSON.stringify({ v: 1, at: new Date().toISOString(), ...record }))
      .execute(client);
    const receipt = await tx.getReceipt(client);
    return receipt.topicSequenceNumber ? Number(receipt.topicSequenceNumber) : null;
  } catch (e) {
    console.error("hedera: audit log failed", String(e));
    return null;
  }
}

/** One-time readiness: the operator holds USDC (associated) and the audit topic exists. */
export async function setup(db: SupabaseClient): Promise<Record<string, unknown>> {
  const { client, id } = operator();
  const out: Record<string, unknown> = { operator: id.toString() };
  try {
    const tx = await new TokenAssociateTransaction().setAccountId(id).setTokenIds([TokenId.fromString(USDC)]).execute(client);
    await tx.getReceipt(client);
    out.usdc = "associated";
  } catch (e) {
    out.usdc = String(e).includes("TOKEN_ALREADY_ASSOCIATED") ? "already associated" : `error: ${String(e).slice(0, 200)}`;
  }
  out.audit_topic = await auditTopic(db);
  out.operator_usdc = await usdcBalance(id.toString());
  return out;
}
