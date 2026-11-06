import { Check, X } from "lucide-react";
import { useState } from "react";
import { Bot, type BotColor, type BotShape } from "./Bot";

type Ask = { side: string; request: string; color: BotColor; shape: BotShape };

const asks: Ask[] = [
  { side: "Left", request: "wants to run npm run migrate", color: "cyan", shape: "circle" },
  { side: "Right", request: "wants to run git push --force", color: "orange", shape: "hexagon" },
  { side: "Left", request: "wants to edit LoginForm.tsx", color: "cyan", shape: "circle" },
];

type Answer = "nod" | "shake";

/** A permission request as you'd hear it. Nod or shake with the buttons to answer it. */
export function Approval() {
  const [index, setIndex] = useState(0);
  const [answer, setAnswer] = useState<Answer | null>(null);
  const ask = asks[index % asks.length];

  return (
    <div className="rounded-card bg-card p-6">
      <div className="flex items-center gap-4">
        <div key={`${index}-${answer}`} className={answer ? `animate-${answer}` : undefined}>
          <Bot
            color={ask.color}
            shape={ask.shape}
            size={56}
            mood={answer === "nod" ? "awake" : answer === "shake" ? "ended" : "speaking"}
          />
        </div>
        <p className="min-w-0 text-[17px] leading-6" aria-live="polite">
          {ask.side}: <span className="break-words font-mono text-[15px]">{ask.request}</span>
        </p>
      </div>

      <p className="mt-5 flex h-6 items-center gap-2 text-[15px] text-secondary">
        {answer === "nod" && <><Check size={16} /> Allowed. It carries on.</>}
        {answer === "shake" && <><X size={16} /> Denied. It stops and tells you.</>}
        {!answer && "Waiting for you. No answer means no."}
      </p>

      <div className="mt-5 flex gap-3">
        {answer ? (
          <button
            type="button"
            onClick={() => {
              setAnswer(null);
              setIndex(index + 1);
            }}
            className="pressable h-[50px] flex-1 cursor-pointer rounded-full bg-fill"
          >
            Next request
          </button>
        ) : (
          <>
            <button type="button" onClick={() => setAnswer("nod")} className="pressable h-[50px] flex-1 cursor-pointer rounded-full bg-ink text-grouped">
              Nod
            </button>
            <button type="button" onClick={() => setAnswer("shake")} className="pressable h-[50px] flex-1 cursor-pointer rounded-full bg-fill">
              Shake
            </button>
          </>
        )}
      </div>
    </div>
  );
}
