// x402 v2 over HTTP. The server answers 402 with a PAYMENT-REQUIRED header; the client retries
// with PAYMENT-SIGNATURE; the server returns PAYMENT-RESPONSE. Each carries base64 JSON.
// Verification and settlement go through a facilitator (x402.org by default), which also pays
// the Hedera network fee.

export const FACILITATOR = (Deno.env.get("X402_FACILITATOR") ?? "https://x402.org/facilitator").replace(/\/$/, "");

export type Requirements = {
  scheme: "exact";
  network: string;
  amount: string;
  asset: string;
  payTo: string;
  maxTimeoutSeconds: number;
  extra: { feePayer: string };
};

export type Resource = { url: string; description: string; mimeType: string };

export type PaymentRequired = {
  x402Version: 2;
  error?: string;
  resource: Resource;
  accepts: Requirements[];
};

export type PaymentPayload = {
  x402Version: 2;
  resource: Resource;
  accepted: Requirements;
  payload: { transaction: string };
};

export type Settlement = {
  success: boolean;
  errorReason?: string;
  payer?: string;
  transaction: string;
  network: string;
};

export const HEADERS = {
  required: "PAYMENT-REQUIRED",
  signature: "PAYMENT-SIGNATURE",
  response: "PAYMENT-RESPONSE",
} as const;

export function encodeHeader(value: unknown): string {
  const bytes = new TextEncoder().encode(JSON.stringify(value));
  return btoa(String.fromCharCode(...bytes));
}

export function decodeHeader<T>(header: string): T {
  const bytes = Uint8Array.from(atob(header), (c) => c.charCodeAt(0));
  return JSON.parse(new TextDecoder().decode(bytes)) as T;
}

let feePayerCache: { network: string; account: string; at: number } | null = null;

/** The facilitator's fee-paying account for a network, from its /supported list. */
export async function feePayer(network: string): Promise<string> {
  if (feePayerCache?.network === network && Date.now() - feePayerCache.at < 3_600_000) return feePayerCache.account;
  const r = await fetch(`${FACILITATOR}/supported`);
  if (!r.ok) throw new Error(`Facilitator /supported failed (${r.status})`);
  const body = await r.json();
  const kind = (body.kinds ?? []).find((k: { scheme: string; network: string }) => k.scheme === "exact" && k.network === network);
  const account = kind?.extra?.feePayer;
  if (typeof account !== "string") throw new Error(`Facilitator doesn't support ${network}`);
  feePayerCache = { network, account, at: Date.now() };
  return account;
}

async function call<T>(path: "verify" | "settle", payload: PaymentPayload, requirements: Requirements): Promise<T> {
  const r = await fetch(`${FACILITATOR}/${path}`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ x402Version: 2, paymentPayload: payload, paymentRequirements: requirements }),
  });
  const text = await r.text();
  try {
    return JSON.parse(text) as T;
  } catch {
    throw new Error(`Facilitator /${path} returned ${r.status}: ${text.slice(0, 200)}`);
  }
}

export function verify(payload: PaymentPayload, requirements: Requirements) {
  return call<{ isValid: boolean; invalidReason?: string; payer?: string }>("verify", payload, requirements);
}

export function settle(payload: PaymentPayload, requirements: Requirements) {
  return call<Settlement>("settle", payload, requirements);
}

/** The client's copy of the terms must be exactly what the server asked for. */
export function sameTerms(a: Requirements, b: Requirements): boolean {
  return a.scheme === b.scheme && a.network === b.network && a.amount === b.amount && a.asset === b.asset &&
    a.payTo === b.payTo && a.extra?.feePayer === b.extra?.feePayer;
}
