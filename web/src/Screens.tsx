import { AudioLines, ShoppingBag as Bag } from "lucide-react";
import { AlarmClock, Calendar, CloudSun, Ellipsis, Heart, List, ListChecks, Map as MapIcon, Mic, Navigation, ScanLine, X } from "lucide-react";
import { useRef, useState, type ReactNode } from "react";
import { Bot, botColors, type BotColor, type BotShape } from "./Bot";
import { focusedAgent, Radar, useHeadYaw, type Placed } from "./Radar";

const withMe: Placed[] = [
  { name: "Juno", role: "Left", azimuth: -55, color: "violet", shape: "squircle" },
  { name: "Coach", role: "Right", azimuth: 55, color: "orange", shape: "hexagon" },
];
const stops = [-55, 55];

export function Title({ children, right }: { children: ReactNode; right?: ReactNode }) {
  return (
    <div className="flex items-center justify-between px-4 pb-2 pt-1">
      <h4 className="text-[26px] tracking-tight">{children}</h4>
      {right}
    </div>
  );
}

export function Group({ children }: { children: ReactNode }) {
  return <div className="mx-3 divide-y divide-separator/50 rounded-card bg-card">{children}</div>;
}

export function Bubble({ from, children }: { from: "you" | "agent"; children: ReactNode }) {
  return from === "you" ? (
    <p className="ml-auto max-w-[82%] rounded-[17px] bg-ink px-3 py-2 text-[13px] leading-[18px] text-white">{children}</p>
  ) : (
    <p className="mr-auto max-w-[82%] rounded-[17px] bg-fill px-3 py-2 text-[13px] leading-[18px]">{children}</p>
  );
}

export function Activity({ children }: { children: ReactNode }) {
  return <p className="mx-auto w-fit rounded-full bg-[#f2f2f7] px-2.5 py-1 text-[11px] text-secondary">{children}</p>;
}

export function InputBar() {
  return (
    <div className="flex items-center gap-2 px-3 pb-5 pt-2">
      <span className="flex h-9 flex-1 items-center rounded-full border border-separator px-3 text-[13px] text-secondary">Message</span>
      <span className="flex size-9 items-center justify-center rounded-full bg-ink text-white">
        <Mic size={16} />
      </span>
    </div>
  );
}

export function Speaking({ agent, label = "Speaking" }: { agent: { color: BotColor; shape: BotShape }; label?: string }) {
  return (
    <div className="flex flex-col items-center gap-1.5 pb-2">
      <Bot {...agent} mood="speaking" size={56} />
      <span className="flex items-center gap-1 text-[12px] text-secondary">
        <AudioLines size={13} /> {label}
      </span>
    </div>
  );
}

function Row({ agent, title, sub, end }: { agent: { color: BotColor; shape: BotShape }; title: string; sub: ReactNode; end?: ReactNode }) {
  return (
    <div className="flex items-center gap-2.5 px-3 py-2">
      <Bot {...agent} size={34} />
      <div className="min-w-0 flex-1">
        <p className="truncate text-[14px] leading-[18px]">{title}</p>
        <p className="flex items-center gap-1 text-[12px] leading-4 text-secondary">{sub}</p>
      </div>
      <span className="flex items-center gap-1 text-[13px] text-secondary">{end}</span>
    </div>
  );
}

/** With me: the live radar. It follows the pointer. */
export function WithMeScreen() {
  const center = useRef<HTMLDivElement>(null);
  const yaw = useHeadYaw(center, stops);
  const focused = focusedAgent(withMe, yaw);
  const facing = Math.round((yaw + 360) % 360);

  return (
    <div>
      <Title right={<ScanLine size={19} className="text-[#007aff]" />}>With me</Title>
      <div ref={center} className="flex justify-center">
        <Radar agents={withMe} yaw={yaw} radius={92} />
      </div>
      <div className="mt-1 text-center" aria-live="polite">
        <p className="text-[15px]">{focused ? `${focused.name} is listening for a nod` : "Look at an agent"}</p>
        <p className="mt-0.5 text-[11px] text-secondary">Facing {facing}° · AirPods head tracking</p>
      </div>
      <div className="mt-3">
        <Group>
          {withMe.map((a) => (
            <Row key={a.name} agent={a} title={a.name} sub={a.role} />
          ))}
        </Group>
      </div>
    </div>
  );
}

function Marker({ x, y, name, color, shape }: { x: number; y: number; name: string; color: BotColor; shape: BotShape }) {
  return (
    <div className="absolute flex -translate-x-1/2 -translate-y-1/2 flex-col items-center" style={{ left: x, top: y }}>
      <Bot color={color} shape={shape} size={30} />
      <span className="mt-0.5 rounded bg-white/70 px-1 text-[9px]">{name}</span>
    </div>
  );
}

/** Explore: the map with a shop's menu, and what's nearby. */
export function ExploreScreen() {
  return (
    <div>
      <Title
        right={
          <span className="flex rounded-[10px] bg-fill p-0.5 text-secondary">
            <span className="flex h-6 w-8 items-center justify-center"><List size={14} /></span>
            <span className="flex h-6 w-8 items-center justify-center rounded-lg bg-card text-ink shadow-sm"><MapIcon size={14} /></span>
          </span>
        }
      >
        Explore
      </Title>
      <div className="relative mx-3 h-[236px] overflow-hidden rounded-card bg-[#efece4]">
        <svg className="absolute inset-0" width="100%" height="100%" viewBox="0 0 240 236" preserveAspectRatio="xMidYMid slice" aria-hidden>
          <path d="M150 -5 h100 v110 q-60 20 -82 -22 q-16 -36 -18 -88z" fill="#c9e7c0" />
          <path d="M-10 190 q70 -22 130 12 t130 -4 v50 h-260z" fill="#b5dcf5" />
          <g fill="none" stroke="#fff" strokeLinecap="round">
            <path d="M-5 70 L250 118" strokeWidth="9" />
            <path d="M62 -5 L100 240" strokeWidth="9" />
            <path d="M-5 150 L120 128" strokeWidth="5" />
            <path d="M170 110 L205 200" strokeWidth="5" />
          </g>
        </svg>
        <Marker x={148} y={132} name="Corner Café" color="orange" shape="drop" />
        <Marker x={196} y={186} name="Park Guide" color="green" shape="capsule" />
        <Marker x={42} y={44} name="Home" color="blue" shape="squircle" />
        <div className="absolute left-[92px] top-[16px] w-[122px] rounded-xl bg-card px-2.5 py-2 shadow-[0_3px_8px_rgba(0,0,0,0.14)]">
          <p className="flex items-center gap-1 text-[10px] text-secondary"><Bag size={10} /> Menu</p>
          {[["Cappuccino", "$4.50"], ["Croissant", "$3.00"], ["Coffee beans", "$8.00"]].map(([n, p]) => (
            <p key={n} className="mt-0.5 flex justify-between text-[11px]">{n}<span className="text-secondary">{p}</span></p>
          ))}
          <span className="absolute -bottom-1.5 left-[50px] size-3 rotate-45 bg-card" />
        </div>
        <div className="absolute left-[84px] top-[176px] size-0">
          <div className="absolute bottom-0 left-[-30px] h-[58px] w-[60px] bg-[#007aff]/25" style={{ clipPath: "polygon(50% 100%, 0 0, 100% 0)", transform: "rotate(38deg)", transformOrigin: "50% 100%" }} />
          <span className="absolute -left-[7px] -top-[7px] size-3.5 rounded-full border-2 border-white bg-[#007aff] shadow" />
        </div>
      </div>
      <p className="px-4 pb-1.5 pt-3 text-[15px]">Nearby</p>
      <Group>
        <Row agent={{ color: "orange", shape: "drop" }} title="Corner Café" sub={<><Bag size={10} /> Shop</>} end={<>40 m <Navigation size={10} fill="currentColor" className="rotate-12" /></>} />
        <Row agent={{ color: "green", shape: "capsule" }} title="Park Guide" sub="Free" end={<>120 m <Navigation size={10} fill="currentColor" className="rotate-45" /></>} />
      </Group>
    </div>
  );
}

/** Conversation with a personal agent that used the phone. */
export function ToolsScreen() {
  return (
    <div className="flex h-full flex-col bg-white">
      <div className="flex justify-end px-4 text-ink"><Ellipsis size={18} /></div>
      <Speaking agent={{ color: "violet", shape: "squircle" }} />
      <div className="flex flex-1 flex-col justify-end gap-2 overflow-hidden px-3">
        <Bubble from="you">What's my morning like? Move the gym if it's tight.</Bubble>
        <Activity>Checked your calendar</Activity>
        <Activity>Checked Apple Health</Activity>
        <Bubble from="agent">Two meetings before noon, and you slept under six hours. I'd skip the 7 am session.</Bubble>
        <Activity>Added a reminder</Activity>
        <Bubble from="agent">Done. I'll remind you to go after lunch instead.</Bubble>
      </div>
      <InputBar />
    </div>
  );
}

/** Find: walking to a placed agent. */
export function FindScreen() {
  return (
    <div className="flex h-full flex-col bg-white px-4 pb-6">
      <div className="flex items-center justify-between">
        <span className="flex items-center gap-2 text-[15px]"><Bot color="orange" shape="drop" size={26} /> Corner Café</span>
        <span className="flex size-8 items-center justify-center rounded-full bg-fill"><X size={15} /></span>
      </div>
      <div className="relative flex flex-1 items-center justify-center">
        {[0, 0.8, 1.6].map((d) => (
          <span key={d} className="loop-pulse absolute size-40 rounded-full border border-ink/30" style={{ animationDelay: `${d}s` }} />
        ))}
        <Navigation size={72} fill="currentColor" strokeWidth={0} className="rotate-[20deg]" />
      </div>
      <p className="text-[52px] leading-none tracking-tight">42 m</p>
      <p className="mt-1.5 text-[19px]">ahead, slightly right</p>
      <p className="mt-3 text-[12px] leading-4 text-secondary">Pulses speed up as you get closer. With AirPods in, follow its beacon.</p>
    </div>
  );
}

const access = [
  ["Calendar", Calendar, "#ff3b30"],
  ["Reminders", ListChecks, "#ff9500"],
  ["Health", Heart, "#ff2d55"],
  ["Maps", MapIcon, "#34c759"],
  ["Weather", CloudSun, "#007aff"],
  ["Alarms and timers", AlarmClock, "#5856d6"],
] as const;

const shapes: BotShape[] = ["circle", "hexagon", "squircle", "capsule", "drop"];

/** Create: every control here works. */
export function CreateScreen() {
  const [color, setColor] = useState<BotColor>("cyan");
  const [shape, setShape] = useState<BotShape>("circle");
  const [off, setOff] = useState<string[]>(["Health"]);

  return (
    <div>
      <p className="pb-2 text-center text-[15px]">New agent</p>
      <div className="flex justify-center pb-2"><Bot color={color} shape={shape} size={60} mood="awake" /></div>
      <div className="mx-3 rounded-card bg-card p-2.5">
        <div className="flex justify-between">
          {(Object.keys(botColors) as BotColor[]).map((c) => (
            <button key={c} type="button" aria-label={c} aria-pressed={c === color} onClick={() => setColor(c)} className="pressable size-[23px] cursor-pointer rounded-full" style={{ background: botColors[c], boxShadow: c === color ? "0 0 0 2px white, 0 0 0 3.5px black" : undefined }} />
          ))}
        </div>
        <div className="mt-2.5 flex justify-between">
          {shapes.map((s) => (
            <button key={s} type="button" aria-label={s} aria-pressed={s === shape} onClick={() => setShape(s)} className={`pressable flex size-9 cursor-pointer items-center justify-center rounded-xl ${s === shape ? "bg-fill" : ""}`}>
              <Bot color={color} shape={s} size={24} />
            </button>
          ))}
        </div>
      </div>
      <p className="px-6 pb-1 pt-3 text-[10px] uppercase tracking-wide text-secondary">Access</p>
      <Group>
        {access.map(([name, Icon, tint]) => {
          const on = !off.includes(name);
          return (
            <button key={name} type="button" role="switch" aria-checked={on} onClick={() => setOff(on ? [...off, name] : off.filter((n) => n !== name))} className="flex w-full cursor-pointer items-center gap-2 px-3 py-[5px] text-left text-[13px]">
              <span className="flex size-[22px] items-center justify-center rounded-md text-white" style={{ background: tint }}><Icon size={13} /></span>
              <span className="flex-1">{name}</span>
              <span className={`flex h-[18px] w-[30px] items-center rounded-full p-0.5 transition-colors ${on ? "justify-end bg-[#34c759]" : "bg-fill"}`}>
                <span className="size-3.5 rounded-full bg-white shadow" />
              </span>
            </button>
          );
        })}
      </Group>
    </div>
  );
}

