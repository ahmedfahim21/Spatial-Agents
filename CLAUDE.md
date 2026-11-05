# Agentsphere — project brief

Hackathon project for **ETHGlobal Mumbai** (Nov 5–7, 2026). **Deadline: Saturday Nov 7, 09:00 IST.** Commit small and often.

**Current scope: Claude Code only.** No Web3, no other agents yet. Get this core working and feeling great first.

## One line

Your Claude Code sessions sit around your head. Face one to select it, talk to it, and hear it reply from where it sits. When one needs permission, it asks in your ear and you nod or shake.

## The problem

You run several Claude Code sessions, walk away, and one hits a permission prompt. It sits blocked until you're back at the keyboard. Agentsphere lets you handle it from anywhere with AirPods on.

## Gestures

| Gesture | Meaning |
|---|---|
| Turn toward an agent | Select it (soft tick from its direction) |
| Nod | Approve |
| Shake | Deny |
| ⌥Space push-to-talk | Send an instruction to the agent you're facing |

## What exists (v0.1)

SwiftUI macOS app, Swift Package, macOS 14+. Build with `./build.sh run` (wraps the binary in `build/Agentsphere.app` with `Support/Info.plist`, ad-hoc signed, so Motion / Mic / Speech permission prompts work). **Not compiled yet.**

- `HeadTracker.swift` — `CMHeadphoneMotionManager` yaw in degrees (+ = right), recenter, invert toggle.
- `SpatialAudio.swift` — `AVAudioEngine` + `AVAudioEnvironmentNode` (HRTFHQ, headphones). One player node per agent, positioned at `azimuth - headYaw` so voices stay fixed in the room. `AVSpeechSynthesizer.write` → converted to 44.1 kHz mono → scheduled on that agent's node. Distinct voice per agent. `ping()` tones.
- `AppState.swift` — sessions, focus (nearest agent within ±focus width of head yaw), push-to-talk, dispatch, log.
- `ClaudeRunner.swift` — each turn runs `claude -p "<text>" --output-format json [--resume <session_id>] --permission-mode acceptEdits` in the agent's folder. Resolves `claude` and PATH via `zsh -ilc`.
- `SpeechInput.swift` — on-device `SFSpeechRecognizer` push-to-talk.
- `AgentsphereApp.swift` — top-down room UI (drag agents around you, focus cone), control panel, log.

## Build order

1. **Build and run v0.1.** Fix compile errors. Verify: turning your head changes focus; replies come from the correct direction; ⌥Space round-trip to a real Claude session works and continues the same conversation.
2. **Nod / shake detection.** Add pitch to `HeadTracker`. Detect from angular velocity (nod = pitch down-up, shake = yaw left-right), with thresholds and debounce. Show the detected gesture in the UI. Don't use Apple's system head gestures.
3. **Permission requests in your ear.**
   - Add a small local HTTP server in the app (e.g. `127.0.0.1:7777`).
   - Install a Claude Code `PreToolUse` hook in each agent's folder (`.claude/settings.json`) that sends the pending tool call to the server and waits for the answer. Check the current Claude Code hooks docs for the exact JSON input/output and how to return allow/deny.
   - Agentsphere speaks a one-sentence summary from that agent's position ("Left: wants to run npm install"), waits for nod (allow) or shake (deny). Timeout = deny.
   - Read-only tools (Read, Grep, Glob) auto-allow so you aren't spammed.
   - Bind each approval to a hash of the exact tool name + arguments.
   - Once this works, drop `--permission-mode acceptEdits` so all approvals go through Agentsphere.
4. **Attach to existing sessions (stretch).** Let the user add a session by Claude session id / folder so it resumes what they already started, not just new headless ones.
5. **Ambient presence (polish).** Quiet per-agent sound while working, silence when idle, chime when done, so you can hear who's busy without anyone talking.
6. **Sweep to discover.** As the head passes an agent, it speaks its name and status.
7. **Demo hardening.** Two or three real sessions in different repos, a rehearsed script, a recorded fallback video.

## Demo (target)

1. "Who's come back from lunch to find Claude Code stuck on a permission prompt?"
2. Judge wears AirPods. Two agents: one on the left fixing a bug, one on the right writing tests.
3. Left agent asks to run a migration → judge turns left and nods → it continues.
4. Right agent asks to `git push --force` → judge shakes → denied, agent says it will stop.
5. Judge faces the right agent and says "write the tests for the login page instead" → it starts working.

## Later (not now)

Web3 layer for sponsor prizes: 0G private risk summaries and decision logs, x402 payments on Hedera with an HCS audit log, ENSv2 agent identities with revocable permissions, World ID for high-risk actions.

## Rules / constraints

- All project code written during the hackathon. Don't copy code from older projects; public libraries are fine.
- Document AI tool usage in the README.
- Public GitHub repo with an open-source license.
- Set the Mac's input to the built-in mic; using the AirPods mic drops them to call-quality audio and hurts spatial sound.
