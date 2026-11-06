import { LoaderCircle } from "lucide-react";
import { useEffect, useRef, useState } from "react";
import { Bot, type BotColor, type BotShape } from "./Bot";
import { useHeadYaw } from "./Radar";

const stops = [0, -45, 0, 45];
const frameCount = 25;
const frameSize = 800;

const orbit: { angle: number; ring: number; color: BotColor; shape: BotShape; size: number }[] = [
  { angle: -68, ring: 340, color: "cyan", shape: "circle", size: 56 },
  { angle: 48, ring: 330, color: "orange", shape: "drop", size: 64 },
  { angle: 108, ring: 340, color: "violet", shape: "squircle", size: 48 },
  { angle: -118, ring: 330, color: "green", shape: "hexagon", size: 52 },
];

/** Frames rendered from the model by scripts/render-airpods.swift, turning left to right. */
function useFrames() {
  const [frames, setFrames] = useState<HTMLImageElement[] | null>(null);

  useEffect(() => {
    let live = true;
    Promise.all(
      Array.from({ length: frameCount }, (_, i) => {
        const src = `/airpods/${String(i).padStart(2, "0")}.png`;
        return new Promise<HTMLImageElement>((resolve, reject) => {
          const image = new Image();
          image.onload = () => resolve(image);
          image.onerror = () => reject(new Error(`Couldn't load ${src}`));
          image.src = src;
        });
      }),
    ).then((loaded) => {
      if (live) setFrames(loaded);
    }, (error) => {
      console.error("AirPods frames failed to load", error);
    });
    return () => {
      live = false;
    };
  }, []);

  return frames;
}

/** The AirPods at the centre of the agents' orbit. They turn with the pointer. */
export function AirPods() {
  const center = useRef<HTMLDivElement>(null);
  const canvas = useRef<HTMLCanvasElement>(null);
  const yaw = useHeadYaw(center, stops);
  const target = useRef(0);
  target.current = Math.max(-1, Math.min(1, yaw / 60));
  const frames = useFrames();
  const [canAR, setCanAR] = useState(false);

  useEffect(() => setCanAR(document.createElement("a").relList.supports("ar")), []);

  // Eases toward where you're facing, so the steps between frames don't show.
  useEffect(() => {
    if (!frames) return;
    const context = canvas.current!.getContext("2d")!;
    let at = target.current;
    let shown = -1;
    let raf = 0;
    const draw = () => {
      at += (target.current - at) * 0.08;
      const index = Math.round(((at + 1) / 2) * (frameCount - 1));
      if (index !== shown) {
        shown = index;
        context.clearRect(0, 0, frameSize, frameSize);
        context.drawImage(frames[index], 0, 0);
      }
      raf = requestAnimationFrame(draw);
    };
    draw();
    return () => cancelAnimationFrame(raf);
  }, [frames]);

  return (
    <div className="relative overflow-hidden rounded-[28px] bg-[linear-gradient(180deg,#fafafb,#e9e9ee)]">
      <div className="relative flex h-[400px] items-center justify-center sm:h-[620px]">
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
        <div ref={center} className="relative size-[360px] sm:size-[580px]">
          {!frames && <LoaderCircle size={24} className="spinner absolute left-1/2 top-1/2 -ml-3 -mt-3 text-secondary" aria-label="Loading AirPods" />}
          <canvas
            ref={canvas}
            width={frameSize}
            height={frameSize}
            role="img"
            aria-label="AirPods Pro in their open charging case"
            className="size-full drop-shadow-[0_30px_30px_rgba(0,0,0,0.14)] transition-opacity duration-700"
            style={{ opacity: frames ? 1 : 0 }}
          />
        </div>
        {canAR && (
          <a rel="ar" href="/airpods_prod_3.usdz" className="pressable absolute bottom-4 flex h-9 items-center rounded-full bg-ink px-4 text-[14px] text-white">
            <img src="/apple-touch-icon.png" alt="" className="hidden" />
            View in AR
          </a>
        )}
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
