import { User } from "lucide-react";
import { useRef, useState, type PointerEvent } from "react";
import { Bot, type BotColor, type BotShape } from "./Bot";

type Placed = { name: string; role: string; azimuth: number; color: BotColor; shape: BotShape };

const agents: Placed[] = [
  { name: "Atlas", role: "Fixing the login bug", azimuth: -75, color: "cyan", shape: "circle" },
  { name: "Juno", role: "Your day planner", azimuth: 0, color: "violet", shape: "squircle" },
  { name: "Pixel", role: "Writing the tests", azimuth: 75, color: "orange", shape: "hexagon" },
];

const focusWidth = 30;
const radius = 132;
const stage = radius * 2 + 80;

/** The With me radar: move the pointer to turn your head, and the agent you face lights up. */
export function Radar() {
  const [yaw, setYaw] = useState(-75);
  const box = useRef<HTMLDivElement>(null);

  const turn = (e: PointerEvent) => {
    const r = box.current!.getBoundingClientRect();
    const x = e.clientX - (r.left + r.width / 2);
    const y = e.clientY - (r.top + r.height / 2);
    const angle = (Math.atan2(x, -y) * 180) / Math.PI;
    setYaw(Math.max(-120, Math.min(120, angle)));
  };

  const focused = agents.find((a) => Math.abs(a.azimuth - yaw) <= focusWidth);

  return (
    <div className="flex flex-col items-center gap-5">
      <div
        ref={box}
        onPointerMove={turn}
        onPointerDown={turn}
        role="img"
        aria-label="Three agents placed around a person. The one the person faces lights up."
        className="relative max-w-full cursor-crosshair touch-none select-none"
        style={{ width: stage, height: stage }}
      >
        <div
          className="absolute rounded-full border border-separator/60"
          style={{ inset: 40 }}
        />
        <div
          className="absolute left-1/2 top-1/2 h-0 w-0"
          style={{ transform: `rotate(${yaw}deg)`, transition: "transform 180ms var(--ease-spring)" }}
        >
          <div
            className="absolute bg-ink/8"
            style={{
              width: radius * 1.1,
              height: radius * 1.15,
              left: (-radius * 1.1) / 2,
              top: -radius * 1.15,
              clipPath: "polygon(50% 100%, 0 0, 100% 0)",
              maskImage: "linear-gradient(to top, black, transparent)",
            }}
          />
        </div>
        <div className="absolute left-1/2 top-1/2 flex size-11 -translate-x-1/2 -translate-y-1/2 items-center justify-center rounded-full bg-card text-secondary shadow-[0_2px_6px_rgba(0,0,0,0.08)]">
          <User size={20} fill="currentColor" strokeWidth={0} />
        </div>
        {agents.map((a) => {
          const rad = (a.azimuth * Math.PI) / 180;
          const active = focused === a;
          return (
            <div
              key={a.name}
              className="absolute left-1/2 top-1/2"
              style={{ transform: `translate(calc(-50% + ${Math.sin(rad) * radius}px), calc(-50% + ${-Math.cos(rad) * radius}px))` }}
            >
              <div className="relative flex size-[66px] items-center justify-center">
                <svg className="absolute inset-0 -rotate-90" viewBox="0 0 66 66" aria-hidden>
                  <circle
                    cx="33"
                    cy="33"
                    r="31"
                    fill="none"
                    stroke="currentColor"
                    strokeWidth="3"
                    strokeLinecap="round"
                    pathLength="1"
                    strokeDasharray="1"
                    strokeDashoffset={active ? 0 : 1}
                    style={{ transition: `stroke-dashoffset ${active ? 280 : 180}ms ease-out` }}
                  />
                </svg>
                <Bot color={a.color} shape={a.shape} size={52} mood={active ? "awake" : "idle"} look={-Math.sin(rad)} />
              </div>
            </div>
          );
        })}
      </div>
      <p className="h-12 text-center text-[15px] leading-6 text-secondary" aria-live="polite">
        {focused ? (
          <>
            <span className="text-ink">{focused.name}</span>
            <br />
            {focused.role}
          </>
        ) : (
          <>
            Nobody here
            <br />
            Turn toward an agent
          </>
        )}
      </p>
    </div>
  );
}
