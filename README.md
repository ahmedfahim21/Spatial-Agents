# Agentsphere

Your AI agents sit in the space around you. Look at one, nod, and talk. It replies from where it sits, and when it needs permission it asks in your ear and you nod or shake.

There are three parts:

- **Mac app:** your Claude Code sessions around your head, with permission prompts answered by nodding or shaking.
- **iPhone app:** personal agents that travel with you, and agents placed in the real world for you or anyone nearby to find.
- **Landing page:** the site in `web/`.

## Gestures

| Gesture | Meaning |
|---|---|
| Turn toward an agent | Select it (its ring lights up, with a soft tick from its direction) |
| Nod | Wake it, or approve what it asked |
| Shake | Deny, or end the conversation |
| Speak | Talk to the agent you're facing (⌥Space push-to-talk on the Mac) |

## Mac app

Needs macOS 14+, Xcode command line tools, Claude Code (`claude`) installed and logged in, and AirPods Pro / Max / 3 / 4.

```bash
./build.sh run
```

Allow **Motion**, **Microphone** and **Speech Recognition** when asked.

1. Put your AirPods in, face the screen, press **Recenter**.
2. Add a Claude session: start one in a project folder, or pick a live or recent session to resume. Add a second one.
3. Drag each agent to a spot around you (default: first on your left, second on your right).
4. Turn your head toward one. Its ring lights up and you hear a soft tick from its direction.
5. Press **⌥Space**, say an instruction, press **⌥Space** again. It's sent to the agent you're facing.
6. The reply is spoken from that agent's position. The full text is in the log.
7. When an agent needs permission, it asks from its position ("Left: wants to run npm install"). Nod to allow, shake to deny.

If turning right selects the agent on your left, tick **Invert direction**.

Read-only tools (Read, Grep, Glob and similar) are allowed automatically. No answer within 60 seconds is a deny. Each decision is bound to a SHA-256 hash of the exact tool name and arguments.

| Piece | File | What it does |
|---|---|---|
| Head tracking | `Shared/HeadTracker.swift` | `CMHeadphoneMotionManager` pose from AirPods; nods and shakes from angular velocity |
| Spatial voices | `Shared/SpatialAudio.swift` | `AVAudioEnvironmentNode` + HRTF; each agent is a sound source, moved opposite your head so it stays put in the room |
| Focus | `AppState.swift` | Nearest agent within ±focus width of where you're facing |
| Talking back | `Shared/SpeechInput.swift` | On-device `SFSpeechRecognizer` push-to-talk |
| Claude sessions | `ClaudeRunner.swift` | Each turn runs `claude -p "<text>" --resume <session_id> --output-format json` in the agent's folder, so the conversation continues |
| Approvals | `PermissionServer.swift` | Local HTTP server; a `PreToolUse` hook in each agent's folder holds the tool call until you answer |
| Finding sessions | `SessionDiscovery.swift` | Lists live and recent Claude Code sessions from `~/.claude` |

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

## Known limits

- **Mic:** if your AirPods are also the mic, macOS switches them to call-quality audio and spatial sound suffers. Set the input to the MacBook mic (System Settings › Sound › Input).
- **Sessions are headless:** each turn runs `claude -p` and resumes the conversation by session id. It doesn't type into an open terminal.

## AI tools

Built with Claude Code.
