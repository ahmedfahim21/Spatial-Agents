import {
  AlarmClock,
  ArrowUpRight,
  Calendar,
  CloudSun,
  Ear,
  Heart,
  ListChecks,
  Map,
  MapPin,
  Mic,
  MoveHorizontal,
  MoveVertical,
  Rotate3d,
  ShieldCheck,
  UserRound,
  Wallet,
  type LucideIcon,
} from "lucide-react";
import type { ReactNode } from "react";
import { Approval } from "./Approval";
import { Bot, botColors, type BotColor, type BotShape } from "./Bot";
import { Radar } from "./Radar";

const repo = "https://github.com/ahmedfahim21/Spatial-Agents";
const proof = "https://hashscan.io/testnet/transaction/0.0.9185802-1793968211-903481982";

function SectionLabel({ children }: { children: ReactNode }) {
  return <p className="text-[13px] uppercase tracking-wide text-secondary">{children}</p>;
}

function Section({ id, label, title, intro, children }: { id: string; label: string; title: string; intro: string; children: ReactNode }) {
  return (
    <section id={id} className="mx-auto max-w-5xl px-4 py-16 sm:px-6 sm:py-24">
      <SectionLabel>{label}</SectionLabel>
      <h2 className="mt-3 max-w-2xl text-[34px] leading-[1.12] tracking-tight text-balance sm:text-[44px]">{title}</h2>
      <p className="mt-4 max-w-2xl text-[17px] leading-7 text-secondary">{intro}</p>
      <div className="mt-10">{children}</div>
    </section>
  );
}

function Card({ icon: Icon, title, children }: { icon: LucideIcon; title: string; children: ReactNode }) {
  return (
    <div className="rounded-card bg-card p-6">
      <Icon size={22} strokeWidth={1.75} aria-hidden />
      <h3 className="mt-4 text-[17px]">{title}</h3>
      <p className="mt-1.5 text-[15px] leading-6 text-secondary">{children}</p>
    </div>
  );
}

function Rows({ rows }: { rows: [string, string][] }) {
  return (
    <div className="divide-y divide-separator/60 rounded-card bg-card px-5">
      {rows.map(([title, detail]) => (
        <div key={title} className="py-3.5">
          <p className="text-[15px]">{title}</p>
          <p className="mt-0.5 text-[15px] leading-6 text-secondary">{detail}</p>
        </div>
      ))}
    </div>
  );
}

function Nav() {
  return (
    <header className="sticky top-0 z-10 border-b border-separator/40 bg-grouped/80 backdrop-blur-xl">
      <nav className="mx-auto flex h-14 max-w-5xl items-center justify-between px-4 sm:px-6">
        <a href="#top" className="flex items-center gap-2 text-[17px]">
          <Bot color="cyan" shape="circle" size={24} />
          Agentsphere
        </a>
        <div className="flex items-center gap-5 text-[15px] text-secondary">
          <a href="#gestures" className="hidden hover:text-ink sm:block">Gestures</a>
          <a href="#mac" className="hidden hover:text-ink sm:block">Mac</a>
          <a href="#iphone" className="hidden hover:text-ink sm:block">iPhone</a>
          <a href="#shops" className="hidden hover:text-ink sm:block">Shops</a>
          <a href={repo} className="hover:text-ink">GitHub</a>
        </div>
      </nav>
    </header>
  );
}

function Hero() {
  return (
    <section id="top" className="mx-auto grid max-w-5xl items-center gap-10 px-4 pb-10 pt-14 sm:px-6 sm:pt-20 lg:grid-cols-[1fr_auto]">
      <div>
        <h1 className="text-[44px] leading-[1.05] tracking-tight text-balance sm:text-[64px]">Your agents, in the space around you.</h1>
        <p className="mt-5 max-w-xl text-[19px] leading-8 text-secondary">
          Agentsphere gives every AI agent a place in the room. Put your AirPods in, look at one, nod, and talk. It answers from where it sits. No screen, no keyboard.
        </p>
        <div className="mt-8 flex flex-wrap gap-3">
          <a href={repo} className="pressable flex h-[50px] items-center gap-1.5 rounded-full bg-ink px-6 text-grouped">
            View on GitHub <ArrowUpRight size={18} aria-hidden />
          </a>
          <a href="#run" className="pressable flex h-[50px] items-center rounded-full bg-fill px-6">
            Run it yourself
          </a>
        </div>
      </div>
      <div className="flex flex-col items-center">
        <Radar />
        <p className="mt-2 text-[13px] text-secondary">Move your pointer to turn your head</p>
      </div>
    </section>
  );
}

function Gestures() {
  return (
    <Section
      id="gestures"
      label="Gestures"
      title="Your head is the interface."
      intro="AirPods already know which way you're facing. Agentsphere reads that motion directly, so four small movements replace the mouse, the keyboard and the screen."
    >
      <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
        <Card icon={Rotate3d} title="Turn to select">
          Face an agent and its ring draws closed. You hear a soft tick from its direction.
        </Card>
        <Card icon={MoveVertical} title="Nod to say yes">
          Wake the agent you're looking at, or approve what it's asking for.
        </Card>
        <Card icon={MoveHorizontal} title="Shake to say no">
          Deny a request, or end a conversation and let the agent go back to sleep.
        </Card>
        <Card icon={Mic} title="Speak to instruct">
          Talk to the agent you're facing. The reply is spatial, so voices stay fixed in the room as you turn.
        </Card>
      </div>
    </Section>
  );
}

function MacSection() {
  return (
    <Section
      id="mac"
      label="On your Mac"
      title="Never come back to a stuck Claude Code session."
      intro="You start several sessions, walk away, and one hits a permission prompt. It sits blocked until you're back at the keyboard. With Agentsphere, it asks in your ear from where it sits, and you answer with your head."
    >
      <div className="grid items-start gap-6 lg:grid-cols-2">
        <Approval />
        <Rows
          rows={[
            ["Bring the sessions you have", "Find live and recent Claude Code sessions on your Mac and resume them, or start a new one in any folder."],
            ["Only what matters reaches you", "Read-only tools like Read, Grep and Glob are allowed automatically, so you aren't spammed."],
            ["Silence is a no", "If you don't answer within 60 seconds, the request is denied."],
            ["A nod answers one exact call", "Each decision is bound to a SHA-256 hash of the tool name and arguments, so it can't approve anything else."],
          ]}
        />
      </div>
    </Section>
  );
}

const tools: [LucideIcon, string][] = [
  [Calendar, "Calendar"],
  [ListChecks, "Reminders"],
  [Heart, "Health"],
  [Map, "Maps"],
  [CloudSun, "Weather"],
  [AlarmClock, "Alarms and timers"],
];

const shapes: BotShape[] = ["circle", "hexagon", "squircle", "capsule", "drop"];

function IPhoneSection() {
  return (
    <Section
      id="iphone"
      label="On your iPhone"
      title="Agents that live with you, and agents that live in places."
      intro="The iPhone app takes the same idea out of the door. Keep personal agents at your side, or leave one at a spot in the real world for you or anyone nearby to find."
    >
      <div className="grid gap-4 md:grid-cols-3">
        <Card icon={UserRound} title="With me">
          Your personal agents travel with you, one on your left and one on your right. Look, nod, and talk hands-free.
        </Card>
        <Card icon={MapPin} title="Placed in the world">
          Pin an agent to a place. A private one is yours alone; a public one can be discovered by anyone nearby.
        </Card>
        <Card icon={Ear} title="Found by ear">
          Walk toward a placed agent with Find, then hear it in 3D audio once you arrive. Look at it and nod to start talking.
        </Card>
      </div>

      <div className="mt-4 grid gap-4 md:grid-cols-2">
        <div className="rounded-card bg-card p-6">
          <h3 className="text-[17px]">They can use your phone</h3>
          <p className="mt-1.5 text-[15px] leading-6 text-secondary">
            Personal agents can check your day and act on it. Tools run on the iPhone, you switch each one per agent, and Health is read only.
          </p>
          <ul className="mt-5 grid grid-cols-2 gap-x-4 gap-y-3">
            {tools.map(([Icon, name]) => (
              <li key={name} className="flex items-center gap-2.5 text-[15px]">
                <Icon size={18} strokeWidth={1.75} className="shrink-0 text-secondary" aria-hidden />
                {name}
              </li>
            ))}
          </ul>
        </div>
        <div className="rounded-card bg-card p-6">
          <h3 className="text-[17px]">Make one in a minute</h3>
          <p className="mt-1.5 text-[15px] leading-6 text-secondary">
            Start from a template like a planner, coach, tour guide or café. Pick its voice, its model, and a look from 8 colours and 5 shapes.
          </p>
          <div className="mt-5 flex flex-wrap gap-2.5">
            {(Object.keys(botColors) as BotColor[]).map((color, i) => (
              <Bot key={color} color={color} shape={shapes[i % shapes.length]} size={40} look={i % 2 ? 0.5 : -0.5} />
            ))}
          </div>
        </div>
      </div>
    </Section>
  );
}

const steps: [string, string][] = [
  ["Order out loud", "Walk up to a shop agent, nod, and say \"I'll have a cappuccino\". It confirms what you asked for."],
  ["Your wallet agent pays", "It checks your limits, then pays the shop in USDC over x402 on Hedera. You don't touch your phone."],
  ["Every payment is on record", "The order settles on Hedera and is written to an HCS topic as an audit log."],
];

function Shops() {
  return (
    <Section
      id="shops"
      label="Agent shops"
      title="Agents that can sell, and agents that can pay."
      intro="A public agent can run a shop with its own Hedera wallet and a menu. A visitor's wallet agent pays it directly, and a person only steps in when the amount is large."
    >
      <ol className="grid gap-4 md:grid-cols-3">
        {steps.map(([title, detail], i) => (
          <li key={title} className="rounded-card bg-card p-6">
            <span className="flex size-8 items-center justify-center rounded-full bg-fill text-[15px]">{i + 1}</span>
            <h3 className="mt-4 text-[17px]">{title}</h3>
            <p className="mt-1.5 text-[15px] leading-6 text-secondary">{detail}</p>
          </li>
        ))}
      </ol>
      <div className="mt-4 grid gap-4 md:grid-cols-2">
        <Card icon={Wallet} title="Limits you control">
          By default, up to $5 a purchase and $20 a day go through on their own.
        </Card>
        <Card icon={ShieldCheck} title="A human checkpoint above that">
          Anything over the limit waits for a fresh World ID check. Each approval lasts 5 minutes and works once.
        </Card>
      </div>
      <a href={proof} className="mt-6 inline-flex items-center gap-1 text-[15px] text-secondary hover:text-ink">
        See a settled testnet payment on HashScan <ArrowUpRight size={16} aria-hidden />
      </a>
    </Section>
  );
}

function Stack() {
  return (
    <Section
      id="stack"
      label="Under the hood"
      title="How it's built."
      intro="Native Apple audio and motion on the device, with a thin backend for models, voices and payments."
    >
      <Rows
        rows={[
          ["Head tracking", "CMHeadphoneMotionManager, with nods and shakes detected from angular velocity. Apple's system head gestures aren't used."],
          ["Spatial voices", "AVAudioEngine with HRTF rendering. Each agent is a sound source moved opposite your head, so it stays put."],
          ["Claude Code", "Each turn runs claude -p with --resume in the agent's folder. A PreToolUse hook sends tool calls to a local server in the app."],
          ["Models and speech", "Chat through the 0G Compute Router, with a model per agent. Whisper Large v3 on 0G for speech, ElevenLabs for voices."],
          ["Payments", "x402 on Hedera, an HCS audit log and World ID checkpoints, running on Supabase Edge Functions."],
        ]}
      />
    </Section>
  );
}

function Code({ children }: { children: string }) {
  return <pre className="mt-3 overflow-x-auto rounded-xl bg-fill px-4 py-3 font-mono text-[14px] leading-6">{children}</pre>;
}

function Run() {
  return (
    <Section
      id="run"
      label="Run it"
      title="Put your AirPods in."
      intro="Agentsphere is open source. You need AirPods with head tracking: Pro, Max, 3 or 4."
    >
      <div className="grid gap-4 md:grid-cols-2">
        <div className="min-w-0 rounded-card bg-card p-6">
          <h3 className="text-[17px]">Mac</h3>
          <p className="mt-1.5 text-[15px] leading-6 text-secondary">macOS 14+, Xcode command line tools, and Claude Code logged in.</p>
          <Code>./build.sh run</Code>
        </div>
        <div className="min-w-0 rounded-card bg-card p-6">
          <h3 className="text-[17px]">iPhone</h3>
          <p className="mt-1.5 text-[15px] leading-6 text-secondary">iOS 26 and Xcode. Run the Agentsphere scheme on your device.</p>
          <Code>open iOS/AgentsphereMobile.xcodeproj</Code>
        </div>
      </div>
    </Section>
  );
}

export function App() {
  return (
    <>
      <Nav />
      <main>
        <Hero />
        <Gestures />
        <MacSection />
        <IPhoneSection />
        <Shops />
        <Stack />
        <Run />
      </main>
      <footer className="mx-auto flex max-w-5xl flex-wrap justify-between gap-2 border-t border-separator/40 px-4 py-8 text-[13px] text-secondary sm:px-6">
        <p>Built at ETHGlobal Mumbai, 2026.</p>
        <a href={repo} className="hover:text-ink">Open source on GitHub</a>
      </footer>
    </>
  );
}
