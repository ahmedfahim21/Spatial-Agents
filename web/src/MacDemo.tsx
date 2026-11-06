import { useRef, useState } from "react";
import { MacWindow } from "./Frames";
import { Radar, useHeadYaw, type Placed } from "./Radar";

const sessions: Placed[] = [
  { name: "api", role: "Left", azimuth: -70, color: "cyan", shape: "circle" },
  { name: "web", role: "Right", azimuth: 70, color: "orange", shape: "hexagon" },
];
const stops = [-70, 70];

const asks = [
  { name: "api", summary: "wants to run npm run migrate", tool: "Bash", hash: "9f2c41d07ab3" },
  { name: "web", summary: "wants to run git push --force", tool: "Bash", hash: "e07b63ac15d2" },
  { name: "api", summary: "wants to edit LoginForm.tsx", tool: "Edit", hash: "41ca8e92f06b" },
];

type Line = { id: number; text: string };

/** The Mac app, with its approval panel. The buttons stand in for your head. */
export function MacDemo() {
  const center = useRef<HTMLDivElement>(null);
  const yaw = useHeadYaw(center, stops);
  const [index, setIndex] = useState(0);
  const [gesture, setGesture] = useState("None yet");
  const [log, setLog] = useState<Line[]>([{ id: -1, text: "api: Fixed the session expiry bug." }]);
  const ask = asks[index % asks.length];

  const answer = (allow: boolean) => {
    setGesture(allow ? "Nod" : "Shake");
    setLog([{ id: index, text: `${ask.name}: ${allow ? "Allowed" : "Denied"} ${ask.tool} ${ask.hash.slice(0, 6)}` }, ...log].slice(0, 3));
    setIndex(index + 1);
  };

  return (
    <MacWindow title="Agentsphere">
      <div className="grid md:grid-cols-[1fr_1.1fr]">
        <div className="flex flex-col items-center justify-center gap-1 bg-white p-5">
          <p className="text-[10px] tracking-widest text-secondary">FRONT</p>
          <div ref={center}><Radar agents={sessions} yaw={yaw} radius={104} size={48} /></div>
          <p className="font-mono text-[11px] text-secondary">Facing {Math.round(yaw)}°</p>
        </div>
        <div className="space-y-3 border-black/10 p-4 md:border-l">
          <div className="flex items-center justify-between">
            <p className="text-[20px]">Agentsphere</p>
            <span className="rounded-md bg-white px-2 py-0.5 text-[12px] shadow-[0_0_0_0.5px_rgba(0,0,0,0.2)]">Add Claude session…</span>
          </div>
          <div className="rounded-lg bg-black/[0.04] p-3">
            <p className="text-[11px] text-secondary">Permission</p>
            <p key={index} className="rise mt-1 text-[15px]">{ask.name} {ask.summary}</p>
            <p className="font-mono text-[11px] text-secondary">{ask.tool} · {ask.hash}</p>
            <div className="mt-2.5 flex items-center gap-2">
              <button type="button" onClick={() => answer(true)} className="pressable cursor-pointer rounded-md bg-ink px-3 py-1 text-[13px] text-white">Approve (nod)</button>
              <button type="button" onClick={() => answer(false)} className="pressable cursor-pointer rounded-md bg-white px-3 py-1 text-[13px] shadow-[0_0_0_0.5px_rgba(0,0,0,0.2)]">Deny (shake)</button>
              <span className="text-[11px] text-secondary">⌥Y / ⌥N</span>
            </div>
          </div>
          <div className="flex justify-between rounded-lg bg-black/[0.04] px-3 py-2 text-[13px]">
            <span className="text-secondary">Last gesture</span>{gesture}
          </div>
          <div className="h-[84px] overflow-hidden rounded-lg bg-black/[0.04] px-3 py-2 font-mono text-[11px] leading-5 text-secondary" aria-live="polite">
            {log.map((l) => <p key={l.id} className="rise truncate">{l.text}</p>)}
          </div>
        </div>
      </div>
    </MacWindow>
  );
}
