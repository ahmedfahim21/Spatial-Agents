import { User } from "lucide-react";
import { useEffect, useRef, useState } from "react";
import { Bot, type BotColor, type BotShape } from "./Bot";

export type Placed = { name: string; role: string; azimuth: number; color: BotColor; shape: BotShape };

const focusWidth = 34;

/** Turns with the pointer. Until the pointer moves, it sweeps between the agents on its own. */
export function useHeadYaw(center: React.RefObject<HTMLElement | null>, stops: number[]) {
  const [yaw, setYaw] = useState(stops[0]);
  const moved = useRef(false);

  useEffect(() => {
    const onMove = (e: PointerEvent) => {
      if (e.pointerType === "touch") return;
      const r = center.current?.getBoundingClientRect();
      if (!r || r.bottom < 0 || r.top > innerHeight) return;
      moved.current = true;
      const angle = (Math.atan2(e.clientX - (r.left + r.width / 2), r.top + r.height / 2 - e.clientY) * 180) / Math.PI;
      setYaw(Math.max(-130, Math.min(130, angle)));
    };
    let i = 0;
    const sweep = setInterval(() => {
      if (moved.current || matchMedia("(prefers-reduced-motion: reduce)").matches) return;
      i = (i + 1) % stops.length;
      setYaw(stops[i]);
    }, 2200);
    addEventListener("pointermove", onMove);
    return () => {
      clearInterval(sweep);
      removeEventListener("pointermove", onMove);
    };
  }, [center, stops]);

  return yaw;
}

export const focusedAgent = (agents: Placed[], yaw: number) => agents.find((a) => Math.abs(a.azimuth - yaw) <= focusWidth);

/** The radar: you in the middle, a cone for where you face, agents on the ring. */
export function Radar({ agents, yaw, radius, size = 46 }: { agents: Placed[]; yaw: number; radius: number; size?: number }) {
  const focused = focusedAgent(agents, yaw);
  const ring = size + 14;
  const stage = radius * 2 + ring + 8;

  return (
    <div className="relative" style={{ width: stage, height: stage }} role="img" aria-label="Agents placed around a person. The one the person faces lights up.">
      <div className="absolute rounded-full border border-separator/70" style={{ inset: ring / 2 + 4 }} />
      <div className="absolute left-1/2 top-1/2 h-0 w-0" style={{ transform: `rotate(${yaw}deg)`, transition: "transform 420ms var(--ease-spring)" }}>
        <div
          className="absolute bg-ink/10"
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
      <div className="absolute left-1/2 top-1/2 flex size-10 -translate-x-1/2 -translate-y-1/2 items-center justify-center rounded-full bg-card text-secondary shadow-[0_2px_6px_rgba(0,0,0,0.08)]">
        <User size={18} fill="currentColor" strokeWidth={0} />
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
            <div className="relative flex items-center justify-center" style={{ width: ring, height: ring }}>
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
              <Bot color={a.color} shape={a.shape} size={size} mood={active ? "awake" : "idle"} look={-Math.sin(rad)} />
            </div>
          </div>
        );
      })}
    </div>
  );
}
