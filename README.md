# Agentsphere

Your Claude Code sessions sit around your head. Face one to select it, talk to it, and hear its reply from where it sits.

## Run it

Needs macOS 14+, Xcode command line tools, Claude Code (`claude`) installed and logged in, and AirPods Pro / Max / 3 / 4.

```bash
cd agentsphere
chmod +x build.sh
./build.sh run
```

Allow **Motion**, **Microphone** and **Speech Recognition** when asked.

## Use it

1. Put your AirPods in, face the screen, press **Recenter**.
2. **Add Claude session…** and pick a project folder. Add a second one.
3. Drag each agent to a spot around you (default: first on your left, second on your right).
4. Turn your head toward one. Its ring lights up and you hear a soft tick from its direction.
5. Press **⌥Space**, say an instruction, press **⌥Space** again. It's sent to the agent you're facing.
6. The reply is spoken from that agent's position. The full text is in the log.

If turning right selects the agent on your left, tick **Invert direction**.

## How it works

| Piece | File | What it does |
|---|---|---|
| Head tracking | `HeadTracker.swift` | `CMHeadphoneMotionManager` yaw from AirPods |
| Spatial voices | `SpatialAudio.swift` | `AVAudioEnvironmentNode` + HRTF; each agent is a sound source, moved opposite your head so it stays put in the room |
| Focus | `AppState.swift` | Nearest agent within ±focus width of where you're facing |
| Talking back | `SpeechInput.swift` | On-device `SFSpeechRecognizer` push-to-talk |
| Claude sessions | `ClaudeRunner.swift` | Each turn runs `claude -p "<text>" --resume <session_id> --output-format json` in the agent's folder, so the conversation continues |

## Known limits (v0.1)

- **Mic:** if your AirPods are also the mic, macOS switches them to call-quality audio and spatial sound suffers. Set the input to the MacBook mic (System Settings › Sound › Input).
- **Permissions:** turns run headless with `--permission-mode acceptEdits`, so Claude can edit files but anything else that needs approval (e.g. shell commands) is refused. Approve-by-nod comes next.
- **Sessions are headless:** they are not your open terminal sessions; each agent keeps its own Claude conversation via `--resume`.

## Next

- Nod / shake detection from head pitch & yaw velocity.
- Approvals in your ear via Claude Code's `--permission-prompt-tool` (or a `PreToolUse` hook): Claude asks, you nod or shake.
- Ambient "working" sounds per agent.
- Web3 layer later (0G, Hedera x402, ENSv2).
