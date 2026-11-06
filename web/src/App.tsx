import { ArrowUpRight, AudioLines, Check, Lock, MapPin, Mic, X } from "lucide-react";
import { useEffect, useRef, useState, type ReactNode } from "react";
import { AirPods } from "./AirPods";
import { Architecture } from "./Architecture";
import { Bot } from "./Bot";
import { Phone } from "./Frames";
import { MacDemo } from "./MacDemo";
import { Payments } from "./Payments";
import { CreateScreen, ExploreScreen, FindScreen, ToolsScreen, WithMeScreen } from "./Screens";

const repo = "https://github.com/ahmedfahim21/Spatial-Agents";

/** Fades its children in the first time they scroll into view. */
function Reveal({ children, className = "" }: { children: ReactNode; className?: string }) {
  const box = useRef<HTMLDivElement>(null);
  const [seen, setSeen] = useState(false);

  useEffect(() => {
    const watch = new IntersectionObserver(([e]) => {
      if (e.isIntersecting) {
        setSeen(true);
        watch.disconnect();
      }
    }, { rootMargin: "0px 0px -8% 0px" });
    watch.observe(box.current!);
    return () => watch.disconnect();
  }, []);

  return <div ref={box} className={`reveal ${seen ? "seen" : ""} ${className}`}>{children}</div>;
}

function Section({ id, tone, label, title, intro, children }: { id: string; tone: "white" | "grey"; label: string; title: string; intro: string; children: ReactNode }) {
  return (
    <section id={id} className={`tone-${tone} overflow-hidden px-4 py-24 sm:px-6 sm:py-36`}>
      <div className="mx-auto max-w-6xl">
        <Reveal className="mx-auto max-w-3xl text-center">
          <p className="text-[17px] text-secondary sm:text-[19px]">{label}</p>
          <h2 className="mt-2 text-[40px] leading-[1.07] tracking-[-0.022em] text-balance sm:text-[64px]">{title}</h2>
          <p className="mx-auto mt-5 max-w-2xl text-[19px] leading-[1.45] text-secondary text-pretty sm:text-[21px]">{intro}</p>
        </Reveal>
        <Reveal className="mt-14 sm:mt-20">{children}</Reveal>
      </div>
    </section>
  );
}

function Nav() {
  return (
    <header className="sticky top-0 z-20 bg-white/75 backdrop-blur-2xl backdrop-saturate-150">
      <nav className="mx-auto flex h-12 max-w-6xl items-center justify-between px-4 sm:px-6">
        <a href="#top" className="flex items-center gap-2 text-[15px]">
          <Bot color="cyan" shape="circle" size={20} />
          Agentsphere
        </a>
        <div className="flex items-center gap-6 text-[13px] text-ink/70">
          <a href="#airpods" className="hidden transition-colors hover:text-ink sm:block">AirPods</a>
          <a href="#gestures" className="hidden transition-colors hover:text-ink sm:block">Gestures</a>
          <a href="#mac" className="hidden transition-colors hover:text-ink sm:block">Mac</a>
          <a href="#iphone" className="hidden transition-colors hover:text-ink sm:block">iPhone</a>
          <a href="#shops" className="hidden transition-colors hover:text-ink sm:block">Shops</a>
          <a href="#built" className="hidden transition-colors hover:text-ink sm:block">How it's built</a>
          <a href={repo} className="pressable rounded-full bg-ink px-3 py-1 text-white">GitHub</a>
        </div>
      </nav>
    </header>
  );
}

function Hero() {
  return (
    <section id="top" className="tone-white overflow-hidden px-4 pt-16 text-center sm:px-6 sm:pt-24">
      <Reveal>
        <h1 className="mx-auto max-w-4xl text-[52px] leading-[1.04] tracking-[-0.03em] text-balance sm:text-[96px]">Agents, all around you.</h1>
        <p className="mx-auto mt-6 max-w-2xl text-[21px] leading-[1.4] text-secondary text-pretty sm:text-[24px]">
          Put your AirPods in. Look at an agent, nod, and talk. It answers from where it sits.
        </p>
        <div className="mt-8 flex justify-center">
          <a href={repo} className="pressable flex h-12 items-center gap-1.5 rounded-full bg-ink px-6 text-[17px] text-white">
            View on GitHub <ArrowUpRight size={18} aria-hidden />
          </a>
        </div>
      </Reveal>
      <Reveal className="relative mx-auto mt-16 flex h-[560px] max-w-5xl items-start justify-center sm:h-[600px]">
        <div className="absolute right-1/2 top-16 mr-28 hidden -rotate-6 lg:block">
          <Phone tab="Explore"><ExploreScreen /></Phone>
        </div>
        <div className="absolute left-1/2 top-16 ml-28 hidden rotate-6 lg:block">
          <Phone background="#fff"><ToolsScreen /></Phone>
        </div>
        <div className="relative z-10">
          <Phone width={300} tab="With me"><WithMeScreen /></Phone>
        </div>
      </Reveal>
    </section>
  );
}

function Stage({ title, detail, children }: { title: string; detail: string; children: ReactNode }) {
  return (
    <div className="overflow-hidden rounded-[28px] bg-[var(--tile)]">
      <div className="flex h-52 items-center justify-center">{children}</div>
      <div className="px-6 pb-7">
        <h3 className="text-[21px] tracking-tight">{title}</h3>
        <p className="mt-1.5 text-[15px] leading-[1.45] text-secondary">{detail}</p>
      </div>
    </div>
  );
}

function Gestures() {
  return (
    <Section
      id="gestures"
      tone="white"
      label="Gestures"
      title="Your head is the interface."
      intro="AirPods already know which way you're facing. Agentsphere reads that motion directly, so four small movements replace the mouse, the keyboard and the screen."
    >
      <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
        <Stage title="Turn to select" detail="Face an agent and its ring draws closed, with a soft tick from its direction.">
          <div className="relative flex size-32 items-end justify-center">
            <div className="relative flex size-[66px] -translate-y-14 items-center justify-center">
              <svg className="absolute inset-0 -rotate-90" viewBox="0 0 66 66" aria-hidden>
                <circle className="loop-ring" cx="33" cy="33" r="31" fill="none" stroke="#000" strokeWidth="3" strokeLinecap="round" pathLength="1" strokeDasharray="1" />
              </svg>
              <Bot color="cyan" shape="circle" size={50} />
            </div>
            <div className="loop-turn absolute bottom-3 left-1/2 -ml-[34px] h-16 w-[68px] origin-bottom bg-ink/10" style={{ clipPath: "polygon(50% 100%, 0 0, 100% 0)" }} />
            <span className="absolute bottom-0 size-6 rounded-full bg-card shadow" />
          </div>
        </Stage>
        <Stage title="Nod to say yes" detail="Wake the agent you're looking at, or approve what it's asking for.">
          <div className="loop-nod"><Bot color="green" shape="squircle" size={76} mood="awake" /></div>
          <Check className="ml-4" size={26} aria-hidden />
        </Stage>
        <Stage title="Shake to say no" detail="Deny a request, or end the conversation and let the agent sleep.">
          <div className="loop-shake"><Bot color="pink" shape="hexagon" size={76} mood="ended" /></div>
          <X className="ml-4" size={26} aria-hidden />
        </Stage>
        <Stage title="Speak to instruct" detail="Talk to the agent you're facing. Its reply stays fixed in the room as you turn.">
          <Bot color="violet" shape="capsule" size={76} mood="speaking" />
          <div className="ml-4 flex h-12 items-center gap-1" aria-hidden>
            {[0, 0.15, 0.3, 0.1, 0.25].map((d, i) => (
              <span key={i} className="loop-wave h-full w-1 rounded-full bg-ink" style={{ animationDelay: `${d}s` }} />
            ))}
          </div>
        </Stage>
      </div>
    </Section>
  );
}

function MacSection() {
  return (
    <Section
      id="mac"
      tone="grey"
      label="Agentsphere for Mac"
      title="Never come back to a stuck Claude Code session."
      intro="You start several sessions, walk away, and one hits a permission prompt. With Agentsphere it asks in your ear from where it sits, and you answer with your head. Try it: the buttons stand in for a nod and a shake."
    >
      <MacDemo />
      <div className="mt-14 grid gap-x-10 gap-y-8 sm:grid-cols-2 lg:grid-cols-4">
        {[
          ["Your existing sessions", "Find live and recent Claude Code sessions and resume them, or start a new one."],
          ["Only what matters", "Read-only tools like Read, Grep and Glob are allowed automatically."],
          ["Silence is a no", "No answer within 60 seconds and the request is denied."],
          ["One nod, one call", "Each decision is bound to a SHA-256 hash of the tool name and arguments."],
        ].map(([t, d]) => (
          <div key={t}>
            <p className="text-[17px] tracking-tight">{t}</p>
            <p className="mt-1 text-[15px] leading-[1.45] text-secondary">{d}</p>
          </div>
        ))}
      </div>
    </Section>
  );
}

function Shot({ icon, title, detail, children }: { icon: ReactNode; title: string; detail: string; children: ReactNode }) {
  return (
    <figure className="w-[262px] shrink-0 snap-center">
      {children}
      <figcaption className="mt-5 px-1">
        <p className="flex items-center gap-1.5 text-[17px] tracking-tight">{icon} {title}</p>
        <p className="mt-1 text-[15px] leading-[1.45] text-secondary">{detail}</p>
      </figcaption>
    </figure>
  );
}

function IPhoneSection() {
  return (
    <Section
      id="iphone"
      tone="white"
      label="Agentsphere for iPhone"
      title="Agents that live with you, and agents that live in places."
      intro="The iPhone app takes the idea out of the door. Keep personal agents at your side, or leave one at a spot in the real world for you or anyone nearby to find."
    >
      <div className="shelf -mx-4 flex snap-x snap-mandatory gap-6 overflow-x-auto px-4 pb-14 pt-2 sm:-mx-6 sm:px-6 xl:justify-between xl:overflow-visible">
        <Shot icon={<MapPin size={15} aria-hidden />} title="Placed in the world" detail="Pin an agent to a place. Private ones are yours; public ones anyone nearby can discover.">
          <Phone tab="Explore"><ExploreScreen /></Phone>
        </Shot>
        <Shot icon={<AudioLines size={15} aria-hidden />} title="Found by ear" detail="Find points you there and its beacon guides you. Arrive, look at it, nod, and talk.">
          <Phone background="#fff"><FindScreen /></Phone>
        </Shot>
        <Shot icon={<Mic size={15} aria-hidden />} title="They can use your phone" detail="Personal agents check your calendar, health, reminders, maps and weather, on the iPhone itself.">
          <Phone background="#fff"><ToolsScreen /></Phone>
        </Shot>
        <Shot icon={<Lock size={15} aria-hidden />} title="Yours to shape" detail="Choose a look from 8 colours and 5 shapes, and what each agent may touch. Try the controls.">
          <Phone><CreateScreen /></Phone>
        </Shot>
      </div>
    </Section>
  );
}

export function App() {
  return (
    <>
      <Nav />
      <main>
        <Hero />
        <Section
          id="airpods"
          tone="grey"
          label="AirPods"
          title="The sensors are already in your ears."
          intro="Agentsphere needs no new hardware. AirPods know where your head is pointing and can place a voice anywhere around you. That's all it takes to put agents in the room."
        >
          <AirPods />
        </Section>
        <Gestures />
        <MacSection />
        <IPhoneSection />
        <Section
          id="shops"
          tone="grey"
          label="Agent shops"
          title="Order out loud. Your wallet agent pays."
          intro="A public agent can run a shop with its own Hedera wallet. Your wallet agent pays it in USDC over x402, and you only step in when the amount is large. Order something, then try the coffee beans."
        >
          <Payments />
        </Section>
        <Section
          id="built"
          tone="white"
          label="How it's built"
          title="Follow a request through the system."
          intro="Native Apple audio and motion on the device, with a thin backend for models, voices and payments. Pick a journey, step through it, or click any box."
        >
          <Architecture />
        </Section>
      </main>
      <footer className="mx-auto flex max-w-6xl flex-wrap justify-between gap-2 px-4 py-8 text-[12px] text-secondary sm:px-6">
        <p>Built at ETHGlobal Mumbai, 2026.</p>
        <a href={repo} className="hover:text-ink">Open source on GitHub</a>
      </footer>
    </>
  );
}
