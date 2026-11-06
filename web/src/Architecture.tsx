import { ArrowRight } from "lucide-react";
import { useEffect, useState } from "react";

type Node = { x: number; y: number; label: string; note: string; where: string };

const nodes = {
  airpods: { x: 90, y: 270, label: "AirPods", note: "Head pose from the motion sensors, and spatial audio back. Each agent is a sound source moved opposite your head, so it stays put.", where: "Shared/HeadTracker.swift, Shared/SpatialAudio.swift" },
  mac: { x: 300, y: 120, label: "Mac app", note: "Holds your Claude Code sessions around you and runs a local server that keeps each tool call open until you answer.", where: "Sources/Agentsphere" },
  iphone: { x: 300, y: 400, label: "iPhone app", note: "Personal and placed agents, the map, phone tools and your orders. Calendar, Health and the rest run here.", where: "iOS/App" },
  claude: { x: 540, y: 60, label: "Claude Code", note: "Each turn runs claude -p with --resume in the agent's folder, so the conversation continues.", where: "ClaudeRunner.swift" },
  chat: { x: 540, y: 180, label: "chat", note: "One conversational turn. Streams the reply, passes tool requests to the phone, and turns a hidden order line into a payment.", where: "supabase/functions/chat" },
  stt: { x: 540, y: 270, label: "stt", note: "Speech to text for what you say to an agent.", where: "supabase/functions/stt" },
  tts: { x: 540, y: 360, label: "tts", note: "Speaks a line in the agent's voice, so the app ships no key.", where: "supabase/functions/tts" },
  pay: { x: 540, y: 470, label: "pay", note: "Your custodial wallet agent. Pays within your limits, or creates an approval that a fresh World ID check must clear.", where: "supabase/functions/pay" },
  zerog: { x: 780, y: 225, label: "0G Router", note: "Chat models, chosen per agent, and Whisper Large v3 for speech.", where: "router-api.0g.ai" },
  eleven: { x: 780, y: 360, label: "ElevenLabs", note: "Streaming voices for each agent.", where: "supabase/functions/tts" },
  shop: { x: 780, y: 470, label: "shop", note: "The x402 seller. Answers 402 with the price, then verifies and settles the signed payment.", where: "supabase/functions/shop" },
  world: { x: 780, y: 560, label: "World ID", note: "The human checkpoint for purchases above your limit.", where: "supabase/functions/world" },
  hedera: { x: 1010, y: 470, label: "Hedera", note: "USDC settles here, and every payment is written to an HCS topic as an audit log.", where: "supabase/functions/_shared/hedera.ts" },
} satisfies Record<string, Node>;

type Id = keyof typeof nodes;
type Step = [from: Id, to: Id, text: string];

const flows: { name: string; steps: Step[] }[] = [
  {
    name: "Approve a tool call",
    steps: [
      ["claude", "mac", "A PreToolUse hook sends the pending tool call to the app and waits"],
      ["mac", "airpods", "It speaks a one-line summary from that agent's position"],
      ["airpods", "mac", "Your nod or shake, read from head motion"],
      ["mac", "claude", "Allow or deny, bound to a hash of that exact call"],
    ],
  },
  {
    name: "Talk to an agent",
    steps: [
      ["airpods", "iphone", "You look at an agent and nod, and it wakes"],
      ["iphone", "stt", "What you say goes to speech to text"],
      ["stt", "zerog", "Whisper Large v3 transcribes it"],
      ["iphone", "chat", "The words go to the agent"],
      ["chat", "zerog", "The agent's chosen model replies"],
      ["iphone", "tts", "The reply is sent for speaking"],
      ["tts", "eleven", "ElevenLabs voices it"],
      ["iphone", "airpods", "You hear it from where the agent sits"],
    ],
  },
  {
    name: "Use your phone",
    steps: [
      ["iphone", "chat", "You ask about your day"],
      ["chat", "zerog", "The model is offered only the tools you switched on"],
      ["chat", "iphone", "It asks for one, and the request is passed to the app"],
      ["iphone", "chat", "The app runs it on the phone and sends back only the result"],
    ],
  },
  {
    name: "Pay a shop",
    steps: [
      ["iphone", "chat", "\"I'll have a cappuccino\""],
      ["chat", "pay", "A hidden order line, never spoken, triggers the wallet agent"],
      ["pay", "world", "Above your limit, it waits for a World ID check"],
      ["pay", "shop", "POST the order"],
      ["shop", "pay", "402 with the price and the shop's account"],
      ["pay", "shop", "A signed USDC transfer"],
      ["shop", "hedera", "Settled through the facilitator, logged to HCS"],
    ],
  },
];

const columns: [number, string][] = [[90, "You"], [300, "Devices"], [540, "Agent and backend"], [780, "Services"], [1010, "Ledger"]];
const w = 150;
const h = 60;

/** Where a line between two nodes meets the edge of each box. */
function edge(from: Node, to: Node) {
  const clip = (a: Node, b: Node) => {
    const dx = b.x - a.x, dy = b.y - a.y;
    const t = Math.min(dx ? (w / 2 + 4) / Math.abs(dx) : 1, dy ? (h / 2 + 4) / Math.abs(dy) : 1);
    return [a.x + dx * t, a.y + dy * t];
  };
  const [x1, y1] = clip(from, to);
  const [x2, y2] = clip(to, from);
  return { x1, y1, x2, y2 };
}

/** Pick a journey and watch it run, or click anything to read about it. */
export function Architecture() {
  const [flow, setFlow] = useState(0);
  const [step, setStep] = useState(0);
  const [playing, setPlaying] = useState(true);
  const [picked, setPicked] = useState<Id | null>(null);
  const { steps } = flows[flow];

  useEffect(() => {
    if (!playing || matchMedia("(prefers-reduced-motion: reduce)").matches) return;
    const t = setInterval(() => setStep((s) => (s + 1) % steps.length), 2000);
    return () => clearInterval(t);
  }, [playing, steps]);

  const [from, to] = steps[step];
  const inFlow = new Set(steps.flatMap(([a, b]) => [a, b]));
  const line = edge(nodes[from], nodes[to]);
  const info = nodes[picked ?? to];

  return (
    <div className="rounded-[28px] bg-[var(--tile)] p-4 sm:p-6">
      <div className="flex flex-wrap gap-2" role="tablist">
        {flows.map((f, i) => (
          <button
            key={f.name}
            type="button"
            role="tab"
            aria-selected={i === flow}
            onClick={() => { setFlow(i); setStep(0); setPlaying(true); setPicked(null); }}
            className={`pressable h-9 cursor-pointer rounded-full px-4 text-[14px] ${i === flow ? "bg-ink text-white" : "bg-white"}`}
          >
            {f.name}
          </button>
        ))}
      </div>

      <div className="mt-4 grid items-start gap-4 lg:grid-cols-[1.65fr_1fr]">
      <div className="flex items-center justify-center gap-2 rounded-2xl bg-white p-4 text-[15px] md:hidden">
        <span className="rounded-xl bg-ink px-3 py-2 text-white">{nodes[from].label}</span>
        <ArrowRight size={18} aria-hidden />
        <span className="rounded-xl bg-ink px-3 py-2 text-white">{nodes[to].label}</span>
      </div>
      <div className="hidden md:block">
        <svg viewBox="0 0 1100 610" className="w-full" role="group" aria-label={`Diagram: ${flows[flow].name}`}>
          <defs>
            <marker id="tip" viewBox="0 0 10 10" refX="8" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse">
              <path d="M0 0 L10 5 L0 10z" fill="#000" />
            </marker>
          </defs>
          {columns.map(([x, name]) => (
            <text key={name} x={x} y="16" textAnchor="middle" fontSize="17" fill="#6e6e73">{name}</text>
          ))}
          {steps.map(([a, b], i) => {
            const l = edge(nodes[a], nodes[b]);
            return <line key={i} {...l} stroke="#c6c6c8" strokeWidth="1.5" strokeDasharray="4 5" />;
          })}
          <line {...line} stroke="#000" strokeWidth="2.5" markerEnd="url(#tip)" />
          <circle key={`${flow}-${step}`} r="6" fill="#36D1DC">
            <animateMotion dur="0.9s" fill="freeze" path={`M${line.x1} ${line.y1} L${line.x2} ${line.y2}`} />
          </circle>
          {(Object.entries(nodes) as [Id, Node][]).map(([id, n]) => {
            const live = id === from || id === to;
            return (
              <g
                key={id}
                role="button"
                tabIndex={0}
                aria-label={n.label}
                onClick={() => { setPicked(id); setPlaying(false); }}
                onKeyDown={(e) => { if (e.key === "Enter") { setPicked(id); setPlaying(false); } }}
                className="cursor-pointer outline-none"
                style={{ opacity: inFlow.has(id) ? 1 : 0.3, transition: "opacity 300ms" }}
              >
                <rect
                  x={n.x - w / 2}
                  y={n.y - h / 2}
                  width={w}
                  height={h}
                  rx="14"
                  fill={live ? "#000" : "#fff"}
                  stroke={picked === id ? "#36D1DC" : "none"}
                  strokeWidth="3"
                  style={{ transition: "fill 200ms" }}
                />
                <text x={n.x} y={n.y + 7} textAnchor="middle" fontSize="21" fill={live ? "#fff" : "#000"} style={{ transition: "fill 200ms" }}>{n.label}</text>
              </g>
            );
          })}
        </svg>
      </div>

      <div className="min-w-0 space-y-3">
        <ol className="space-y-0.5">
          {steps.map(([, , text], i) => (
            <li key={text + i}>
              <button
                type="button"
                onClick={() => { setStep(i); setPlaying(false); setPicked(null); }}
                className={`flex w-full cursor-pointer gap-2.5 rounded-lg px-2 py-1.5 text-left text-[14px] leading-5 transition-colors ${i === step ? "bg-white text-ink" : "text-secondary"}`}
              >
                <span className="tabular-nums">{i + 1}</span>
                {text}
              </button>
            </li>
          ))}
        </ol>
        <div className="rounded-2xl bg-white p-4">
          <p className="text-[17px]">{info.label}</p>
          <p className="mt-1 text-[14px] leading-5 text-secondary">{info.note}</p>
          <p className="mt-2 break-words font-mono text-[12px] text-secondary">{info.where}</p>
        </div>
      </div>
      </div>
    </div>
  );
}
