import { ArrowUpRight, BadgeCheck, CheckCircle2, LoaderCircle, ShoppingBag } from "lucide-react";
import { useEffect, useRef, useState } from "react";
import { Bot } from "./Bot";
import { Phone } from "./Frames";
import { Activity, Bubble, InputBar, Speaking } from "./Screens";

const proof = "https://hashscan.io/testnet/transaction/0.0.9185802-1793968211-903481982";
const menu = [
  { name: "Cappuccino", price: 4.5 },
  { name: "Croissant", price: 3 },
  { name: "Coffee beans", price: 8 },
];
const perPurchase = 5;
const dailyBudget = 20;
const startBalance = 10;

// The x402 exchange, in order. `at` is how far the payment has got.
const wire = [
  ["POST /order", "Wallet agent asks to buy"],
  ["402 PAYMENT-REQUIRED", "The shop names its price and account"],
  ["PAYMENT-SIGNATURE", "Wallet agent signs a USDC transfer"],
  ["200 PAYMENT-RESPONSE", "Settled on Hedera, logged to HCS"],
] as const;

type Stage = "idle" | "checkpoint" | "approving" | "paying" | "paid";
const usd = (n: number) => `$${n.toFixed(2)}`;

function Wallet({ who, balance, bot }: { who: string; balance: number; bot: React.ReactNode }) {
  return (
    <div className="flex flex-col items-center gap-1.5 text-center">
      {bot}
      <p className="text-[13px] text-secondary">{who}</p>
      <p className="text-[20px] tabular-nums tracking-tight">{balance.toFixed(2)}</p>
      <p className="-mt-1.5 text-[11px] text-secondary">USDC</p>
    </div>
  );
}

function Meter({ label, used, of }: { label: string; used: number; of: number }) {
  const over = used > of;
  return (
    <div>
      <p className="flex justify-between text-[13px]">
        <span className="text-secondary">{label}</span>
        <span className="tabular-nums">{usd(used)} of {usd(of)}</span>
      </p>
      <div className="mt-1.5 h-1.5 overflow-hidden rounded-full bg-fill">
        <div className="h-full rounded-full transition-[width] duration-500" style={{ width: `${Math.min(100, (used / of) * 100)}%`, background: over ? "#ff9500" : "#000" }} />
      </div>
    </div>
  );
}

/** The whole purchase, played out: tap something on the menu to order it. */
export function Payments() {
  const [item, setItem] = useState(menu[0]);
  const [stage, setStage] = useState<Stage>("idle");
  const [at, setAt] = useState(-1);
  const [run, setRun] = useState(0);
  const approved = useRef(false);
  const box = useRef<HTMLDivElement>(null);

  const order = (next: (typeof menu)[number]) => {
    approved.current = false;
    setItem(next);
    setAt(-1);
    setStage(next.price > perPurchase ? "checkpoint" : "paying");
    setRun((r) => r + 1);
  };

  // Plays the first order once the section is on screen.
  useEffect(() => {
    const seen = new IntersectionObserver(([e]) => {
      if (e.isIntersecting) {
        order(menu[0]);
        seen.disconnect();
      }
    }, { threshold: 0.3 });
    seen.observe(box.current!);
    return () => seen.disconnect();
  }, []);

  useEffect(() => {
    if (stage === "approving") {
      const t = setTimeout(() => setStage("paying"), 1100);
      return () => clearTimeout(t);
    }
    if (stage !== "paying") return;
    const timers = wire.map((_, i) => setTimeout(() => setAt(i), 200 + i * 750));
    timers.push(setTimeout(() => setStage("paid"), 200 + wire.length * 750));
    return () => timers.forEach(clearTimeout);
  }, [stage, run]);

  const paid = stage === "paid";
  const buyer = paid ? startBalance - item.price : startBalance;
  const shop = paid ? 42.5 + item.price : 42.5;
  const moving = stage === "paying" && at >= 2;

  return (
    <div ref={box} className="grid items-center justify-items-center gap-6 lg:grid-cols-[auto_1fr] lg:justify-items-stretch">
      <Phone width={236} background="#fff">
        <div className="flex h-full flex-col">
          <Speaking agent={{ color: "orange", shape: "drop" }} label="Corner Café" />
          <div className="flex flex-1 flex-col justify-end gap-2 overflow-hidden px-3">
            <Bubble from="agent">Hi! What can I get you?</Bubble>
            <Bubble from="you">I'll have the {item.name.toLowerCase()}.</Bubble>
            <div key={run} className="rise rounded-card bg-[#f2f2f7] p-3">
              <div className="flex items-baseline justify-between gap-2">
                <div>
                  <p className="text-[15px]">{item.name}</p>
                  <p className="text-[12px]" style={{ color: paid ? "#248a3d" : stage === "checkpoint" ? "#c93400" : "#6c6c70" }}>
                    {paid ? (approved.current ? "Paid · approved with World ID" : "Paid in USDC") : stage === "checkpoint" ? "Needs your approval" : stage === "approving" ? "Approving…" : "Paying…"}
                  </p>
                </div>
                <p className="text-[18px] tabular-nums">{usd(item.price)}</p>
              </div>
              {(stage === "paying" || stage === "approving") && (
                <p className="mt-2 flex items-center gap-1.5 text-[11px] text-secondary">
                  <LoaderCircle size={13} className="spinner" />
                  {stage === "approving" ? "Waiting for World ID…" : "Paying with your wallet on Hedera…"}
                </p>
              )}
              {paid && (
                <a href={proof} className="mt-2 flex items-center gap-1 text-[11px]">
                  <CheckCircle2 size={14} fill="#34c759" color="#fff" /> View receipt on HashScan <ArrowUpRight size={11} />
                </a>
              )}
              {stage === "checkpoint" && (
                <>
                  <button type="button" onClick={() => { approved.current = true; setStage("approving"); }} className="pressable mt-2.5 flex h-10 w-full cursor-pointer items-center justify-center gap-1.5 rounded-full bg-ink text-[13px] text-white">
                    <BadgeCheck size={15} /> Approve with World ID
                  </button>
                  <p className="mt-1.5 text-[10px] leading-[13px] text-secondary">Large purchases need a quick check that it's really you. Nothing is paid until then.</p>
                </>
              )}
            </div>
            {paid && <Activity>Your wallet agent paid {usd(item.price)}</Activity>}
          </div>
          <InputBar />
        </div>
      </Phone>

      <div className="grid w-full min-w-0 gap-3 md:grid-cols-2 xl:grid-cols-3">
        <div className="rounded-[28px] bg-[var(--tile)] p-5">
          <p className="flex items-center gap-1.5 text-[13px] text-secondary"><ShoppingBag size={13} /> Menu. Tap to order.</p>
          <div className="mt-2 divide-y divide-separator/50">
            {menu.map((m) => (
              <button key={m.name} type="button" onClick={() => order(m)} className="pressable flex w-full cursor-pointer items-center justify-between py-2 text-[15px]">
                <span className="flex items-center gap-2">
                  {m.name}
                  {m === item && <span className="size-1.5 rounded-full bg-ink" />}
                </span>
                <span className="tabular-nums text-secondary">{usd(m.price)}</span>
              </button>
            ))}
          </div>
        </div>

        <div className="space-y-4 rounded-[28px] bg-[var(--tile)] p-5">
          <p className="text-[13px] text-secondary">Your limits</p>
          <Meter label="This purchase" used={item.price} of={perPurchase} />
          <Meter label="Today" used={paid ? item.price : 0} of={dailyBudget} />
          <p className="text-[13px] leading-5 text-secondary">
            {item.price > perPurchase ? "Over the limit, so it waits for a World ID check. Approvals last 5 minutes and work once." : "Within your limits, so it goes through on its own."}
          </p>
        </div>

        <div className="rounded-[28px] bg-[var(--tile)] p-5 md:col-span-2 xl:col-span-3 xl:order-last">
          <div className="grid grid-cols-[auto_1fr_auto] items-center gap-4">
            <Wallet who="Wallet agent" balance={buyer} bot={<span className="flex size-11 items-center justify-center rounded-full bg-ink text-[15px] text-white">$</span>} />
            <div className="relative h-px bg-separator">
              <span
                className="absolute -top-3.5 flex size-7 items-center justify-center rounded-full bg-[#2775ca] text-[11px] text-white"
                style={{ left: moving || paid ? "calc(100% - 28px)" : "0", opacity: moving ? 1 : 0, transition: "left 1200ms var(--ease-spring), opacity 200ms" }}
              >
                $
              </span>
            </div>
            <Wallet who="Corner Café" balance={shop} bot={<Bot color="orange" shape="drop" size={44} mood={paid ? "awake" : "idle"} />} />
          </div>
          <ol className="mt-4 grid gap-2 sm:grid-cols-2 xl:grid-cols-4">
            {wire.map(([code, what], i) => (
              <li key={code} className={`rounded-2xl p-3 transition-colors duration-300 ${at >= i ? "bg-ink text-white" : "bg-[#f5f5f7] text-secondary"}`}>
                <p className="break-words font-mono text-[11px] leading-4">{code}</p>
                <p className={`mt-1 text-[12px] leading-4 ${at >= i ? "text-white/70" : ""}`}>{what}</p>
              </li>
            ))}
          </ol>
        </div>

        <div className="rounded-[28px] bg-[var(--tile)] p-5 md:col-span-2 xl:col-span-1">
          <p className="text-[13px] text-secondary">Corner Café's sales</p>
          <div className="mt-1 divide-y divide-separator/50">
            {paid && (
              <div key={run} className="rise flex items-center justify-between py-2">
                <div>
                  <p className="text-[15px]">{item.name}</p>
                  <p className="flex items-center gap-1 text-[12px] text-secondary">
                    Just now
                    {approved.current && <> · <BadgeCheck size={13} fill="#007aff" color="#fff" /> approved</>}
                  </p>
                </div>
                <span className="tabular-nums">{usd(item.price)}</span>
              </div>
            )}
            <div className="flex items-center justify-between py-2">
              <div>
                <p className="text-[15px]">2 × Croissant</p>
                <p className="text-[12px] text-secondary">Yesterday</p>
              </div>
              <span className="tabular-nums">$6.00</span>
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}
