import { useRef } from "react";
import { Bot, type BotColor, type BotShape } from "./Bot";
import { useHeadYaw } from "./Radar";

const stops = [-30, 30];

const orbit: { angle: number; ring: number; color: BotColor; shape: BotShape; size: number }[] = [
  { angle: -68, ring: 340, color: "cyan", shape: "circle", size: 56 },
  { angle: 48, ring: 330, color: "orange", shape: "drop", size: 64 },
  { angle: 108, ring: 340, color: "violet", shape: "squircle", size: 48 },
  { angle: -118, ring: 330, color: "green", shape: "hexagon", size: 52 },
];

/** One earbud, drawn for this page: a glossy shell, silicone tip and stem. */
function Pod({ flip = false, id }: { flip?: boolean; id: string }) {
  return (
    <svg viewBox="0 0 220 340" className="h-full w-auto overflow-visible" style={{ transform: flip ? "scaleX(-1)" : undefined }} aria-hidden>
      <defs>
        <linearGradient id={`${id}-stem`} x1="0" x2="1" y1="0" y2="0">
          <stop offset="0" stopColor="#ffffff" />
          <stop offset="0.45" stopColor="#f7f7f9" />
          <stop offset="0.8" stopColor="#dcdce2" />
          <stop offset="1" stopColor="#bfbfc7" />
        </linearGradient>
        <radialGradient id={`${id}-shell`} cx="0.4" cy="0.3" r="0.85">
          <stop offset="0" stopColor="#ffffff" />
          <stop offset="0.55" stopColor="#f4f4f7" />
          <stop offset="0.85" stopColor="#d9d9df" />
          <stop offset="1" stopColor="#b9b9c1" />
        </radialGradient>
        <radialGradient id={`${id}-tip`} cx="0.55" cy="0.4" r="0.7">
          <stop offset="0" stopColor="#f1f1f4" />
          <stop offset="1" stopColor="#c4c4cc" />
        </radialGradient>
      </defs>
      {/* Silicone tip */}
      <g transform="rotate(-24 62 82)">
        <ellipse cx="50" cy="84" rx="34" ry="44" fill={`url(#${id}-tip)`} />
        <ellipse cx="34" cy="84" rx="15" ry="26" fill="#8e8e96" />
        <ellipse cx="33" cy="84" rx="10" ry="19" fill="#55555c" />
      </g>
      {/* Stem, under the shell */}
      <path d="M128 110 C150 112 172 118 176 136 L186 300 C188 326 148 330 146 304 L128 170 Z" fill={`url(#${id}-stem)`} />
      {/* Shell */}
      <path d="M60 78 C66 30 118 8 158 26 C196 44 200 96 180 128 C162 156 118 168 86 150 C62 136 56 108 60 78 Z" fill={`url(#${id}-shell)`} />
      {/* Sensor mesh and stem details */}
      <ellipse cx="132" cy="56" rx="17" ry="8" fill="#3a3a40" transform="rotate(24 132 56)" />
      <ellipse cx="96" cy="122" rx="6" ry="4" fill="#6e6e76" />
      <rect x="150" y="176" width="9" height="62" rx="4.5" fill="#000" opacity="0.05" transform="rotate(-5 154 206)" />
      <ellipse cx="166" cy="310" rx="15" ry="6" fill="#9a9aa2" transform="rotate(-5 166 310)" />
    </svg>
  );
}

/** A pair of AirPods at the centre of the agents' orbit. They turn with the pointer. */
export function AirPods() {
  const center = useRef<HTMLDivElement>(null);
  const yaw = useHeadYaw(center, stops);
  const turn = Math.max(-30, Math.min(30, yaw / 3));

  return (
    <div className="relative overflow-hidden rounded-[28px] bg-[var(--tile)]">
      <div className="relative flex h-[440px] items-center justify-center sm:h-[640px]">
        {[170, 250, 330].map((r) => (
          <span key={r} className="absolute rounded-full border border-ink/[0.07]" style={{ width: r * 2, height: r * 2 }} />
        ))}
        {orbit.map((o) => {
          const a = (o.angle * Math.PI) / 180;
          return (
            <div
              key={o.color}
              className="absolute left-1/2 top-1/2 hidden sm:block"
              style={{ transform: `translate(calc(-50% + ${Math.sin(a) * o.ring}px), calc(-50% + ${-Math.cos(a) * o.ring * 0.82}px))` }}
            >
              <Bot color={o.color} shape={o.shape} size={o.size} look={-Math.sin(a)} />
            </div>
          );
        })}
        <div ref={center} className="flex h-[250px] items-center gap-4 sm:h-[330px] sm:gap-8" style={{ perspective: 900 }}>
          {[false, true].map((flip) => (
            <div
              key={String(flip)}
              className="h-full drop-shadow-[0_30px_30px_rgba(0,0,0,0.16)]"
              style={{ transform: `rotateY(${turn}deg) rotateZ(${flip ? 5 : -5}deg)`, transition: "transform 600ms var(--ease-spring)" }}
            >
              <Pod flip={flip} id={flip ? "right" : "left"} />
            </div>
          ))}
        </div>
      </div>
      <div className="grid gap-6 px-6 pb-8 text-center sm:grid-cols-3 sm:px-10">
        {[
          ["Head tracking", "Motion sensors read every turn, nod and shake."],
          ["Spatial audio", "Each agent's voice stays fixed at its own place."],
          ["Works with", "AirPods Pro, Max, 3 and 4."],
        ].map(([t, d]) => (
          <div key={t}>
            <p className="text-[17px] tracking-tight">{t}</p>
            <p className="mt-1 text-[15px] leading-[1.45] text-secondary">{d}</p>
          </div>
        ))}
      </div>
    </div>
  );
}
