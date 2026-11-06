import { useId } from "react";

// The cast, ported from iOS/App/Design.swift and Bot.swift: 8 colours × 5 shapes.
export const botColors = {
  cyan: "#36D1DC",
  orange: "#FF8A5B",
  violet: "#A78BFA",
  green: "#4ADE80",
  pink: "#F472B6",
  yellow: "#FACC15",
  blue: "#60A5FA",
  red: "#F87171",
} as const;

export type BotColor = keyof typeof botColors;
export type BotShape = "circle" | "hexagon" | "squircle" | "capsule" | "drop";
export type BotMood = "idle" | "awake" | "speaking" | "ended";

const hexagon = Array.from({ length: 6 }, (_, i) => {
  const a = ((i * 60 - 90) * Math.PI) / 180;
  return `${50 + Math.cos(a) * 49},${50 + Math.sin(a) * 49}`;
}).join(" ");

function Body({ shape, fill }: { shape: BotShape; fill: string }) {
  switch (shape) {
    case "circle":
      return <circle cx="50" cy="50" r="50" fill={fill} />;
    case "squircle":
      return <rect x="4" y="4" width="92" height="92" rx="32" fill={fill} />;
    case "capsule":
      return <rect x="10" y="0" width="80" height="100" rx="40" fill={fill} />;
    case "hexagon":
      return <polygon points={hexagon} fill={fill} stroke={fill} strokeWidth="10" strokeLinejoin="round" transform="translate(5 5) scale(.9)" />;
    case "drop":
      return <path d="M75.7 28.4 A40 40 0 1 1 24.3 28.4 Q50 -27 75.7 28.4 Z" fill={fill} />;
  }
}

/** An agent's face: a flat body with a diagonal gradient and two ink eyes. */
export function Bot({
  color,
  shape,
  mood = "idle",
  size = 44,
  look = 0,
}: {
  color: BotColor;
  shape: BotShape;
  mood?: BotMood;
  size?: number;
  /** -1…1: where the eyes look. */
  look?: number;
}) {
  const id = useId();
  const base = botColors[color];
  const eyeY = shape === "drop" ? 60 : shape === "capsule" ? 45 : 47;
  const ink = "#1c1c1c";
  const dx = look * 6;

  return (
    <svg width={size} height={size} viewBox="0 0 100 100" aria-hidden className="overflow-visible">
      <defs>
        <linearGradient id={id} x1="0" y1="0" x2="1" y2="1">
          <stop offset="0" stopColor={`color-mix(in srgb, ${base} 70%, white)`} />
          <stop offset="1" stopColor={`color-mix(in srgb, ${base} 95%, black)`} />
        </linearGradient>
      </defs>
      <Body shape={shape} fill={`url(#${id})`} />
      {[-15, 15].map((x) =>
        mood === "awake" || mood === "ended" ? (
          <path
            key={x}
            d={mood === "awake" ? `M${42.5 + x} ${eyeY + 3} q7.5 -10 15 0` : `M${43 + x} ${eyeY - 2} q7 6 14 0`}
            fill="none"
            stroke={ink}
            strokeWidth="6"
            strokeLinecap="round"
          />
        ) : (
          <ellipse
            key={x}
            cx={50 + x + dx}
            cy={eyeY}
            rx="7"
            ry="11.5"
            fill={ink}
            transform={`rotate(-8 ${50 + x + dx} ${eyeY})`}
            style={{ transition: "cx 200ms ease-out" }}
          />
        ),
      )}
      {mood === "speaking" && <rect x="43.5" y={eyeY + 19} width="13" height="6" rx="3" fill={ink} />}
    </svg>
  );
}
