# Agentsphere

Your AI agents sit in the space around you. Look at one, nod, and talk. It replies from where it sits.

There are two parts:

- **iPhone app:** personal agents that travel with you, and agents placed in the real world for you or anyone nearby to find.
- **Landing page:** the site in `web/`.

## Gestures

| Gesture | Meaning |
|---|---|
| Turn toward an agent | Select it (its ring lights up) |
| Nod | Wake it |
| Shake | End the conversation |
| Speak | Talk to the agent you've woken |

## iPhone app

Needs iOS 26, Xcode and AirPods with head tracking. Open `iOS/AgentsphereMobile.xcodeproj` and run the **Agentsphere** scheme on a device. `iOS/project.yml` is the XcodeGen source.

- **With me:** personal agents travel with you, one on your left and one on your right. Look at one, nod to wake it, and talk hands-free. Shake to end.
- **Placed agents:** pin an agent to a place. Private ones are yours alone; public ones can be discovered by anyone nearby. Find guides you there, then you hear it in 3D audio.
- **Phone tools:** personal agents can use Calendar, Reminders, Health (read only), Maps, Weather, and alarms and timers. Tools run on the iPhone and are switched per agent.
- **Create:** start from a template, then choose a voice, a model, and a look from 8 colours and 5 shapes.

The backend is in `supabase/functions`: `chat` (0G Compute Router), `stt` (Whisper Large v3 on 0G) and `tts` (ElevenLabs).

## Landing page

Vite, React and Tailwind, styled from the iPhone app's design language (`iOS/App/Design.swift`).

```bash
cd web
pnpm install
pnpm dev
```

`pnpm build` typechecks and builds to `web/dist`.

The turning AirPods are frames in `web/public/airpods/`, rendered from a USDZ model that isn't in this repo:

```bash
swift scripts/render-airpods.swift <model.usdz> web/public/airpods 25 800
```

Those frames are derived from an Apple Inc. model and aren't covered by this repo's MIT license.

## Paying shop agents: x402 on Hedera

Public agents placed in the world can run a shop. Their owner adds a menu in Create; the agent gets
its own Hedera wallet. A visitor walks up, nods, and says "I'll have a cappuccino". The agent
confirms out loud, and the visitor's **wallet agent** pays it in USDC over **x402** with no human
approving. Above the visitor's limit ($5 a purchase, $20 a day by default) the purchase waits for a
**World ID** human checkpoint instead. Every payment is also written to an **HCS topic** as an audit log.

```
 iPhone (voice)          chat (edge fn)            pay (buyer's wallet agent)        shop (x402 seller)          facilitator
 "one cappuccino" ───▶  0G router (Claude) ──▶  checks limits / budget ──POST──▶  402 PAYMENT-REQUIRED
                        hidden [[order]] line    signs USDC transfer ─────POST──▶  PAYMENT-SIGNATURE ──verify/settle──▶ Hedera
 order card + voice ◀── {order: paid, tx} ◀──── receipt ◀─────────────────────── 200 PAYMENT-RESPONSE      HCS audit log
```

| Piece | File | What it does |
|---|---|---|
| x402 seller | `supabase/functions/shop` | `POST /shop/<agent>/order` answers `402` with `PAYMENT-REQUIRED` (`exact`, `hedera:testnet`, USDC `0.0.429274`, `payTo` = the shop's account); with `PAYMENT-SIGNATURE` it verifies and settles through the facilitator, records the order and logs it to HCS |
| Wallet agent | `supabase/functions/pay` | The visitor's custodial wallet. Builds and signs the payment transfer (fee paid by the facilitator), pays within limits, otherwise creates a 5-minute approval that a fresh World ID check must approve; an approval is used once |
| Shops | `supabase/functions/merchant` | Saves the menu and creates the shop's wallet (ECDSA account, associated with USDC) |
| Ordering by voice | `supabase/functions/chat` | Puts the menu in the agent's prompt; a hidden `[[order item=n qty=q]]` line is never spoken and triggers `pay` |
| Hedera | `supabase/functions/_shared/hedera.ts` | Hiero SDK over gRPC-web (`WebClient`, since native gRPC can't connect from Supabase's runtime); wallet keys are AES-GCM encrypted at rest |
| x402 | `supabase/functions/_shared/x402.ts` | v2 headers (base64 JSON) and facilitator `/supported`, `/verify`, `/settle` (default `https://x402.org/facilitator`) |

**Proof it works (Hedera testnet):**

- Settled payment, 0.50 USDC, buyer `0.0.11339254` → shop `0.0.11339213`:
  `0.0.9185802@1793968211.903481982` ([HashScan](https://hashscan.io/testnet/transaction/0.0.9185802-1793968211-903481982))
- Ordered by voice through chat: `0.0.9185802@1793968264.064547811` ([HashScan](https://hashscan.io/testnet/transaction/0.0.9185802-1793968264-064547811))
- Spending audit log: HCS topic [`0.0.11339212`](https://hashscan.io/testnet/topic/0.0.11339212)
- An $8 order over the $5 limit came back as `checkpoint` and nothing was paid; retrying with the
  unapproved approval was refused ("wasn't approved (pending). Nothing was paid.").

**Set up your own:**

1. A Hedera testnet ECDSA account from [portal.hedera.com](https://portal.hedera.com).
2. `npx supabase secrets set HEDERA_OPERATOR_ID=0.0.x HEDERA_OPERATOR_KEY=0x… WALLET_ENC_KEY=$(openssl rand -base64 32)`
   (optional: `X402_FACILITATOR`; World ID: `WORLD_ISSUER`, `WORLD_CLIENT_ID`, `WORLD_CLIENT_SECRET`).
3. `npx supabase db push --remote` and deploy the functions (`shop`, `pay`, `merchant`, `world`, `chat`).
4. Call `POST /functions/v1/merchant/setup` once (signed in): associates the operator with USDC and creates the audit topic.
5. Send test USDC to the operator from [faucet.circle.com](https://faucet.circle.com) (Hedera Testnet). New buyer wallets start with 10 USDC from it.

## AI tools

Built with Claude Code.
