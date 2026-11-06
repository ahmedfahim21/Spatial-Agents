-- Paid public agents: a catalog, Hedera wallets, World ID verification, human checkpoints
-- (approvals) for large purchases, and settled orders.

-- Only public agents can sell.
alter table public.agents
  add constraint agents_paid_only_public check (pricing = 'free' or visibility = 'public');

-- What a shop agent sells. Written by the merchant function; anyone can read a public shop's items.
create table public.catalog_items (
  id         uuid primary key default gen_random_uuid(),
  agent_id   uuid not null references public.agents(id) on delete cascade,
  name       text not null check (char_length(name) between 1 and 80),
  note       text not null default '' check (char_length(note) <= 200),
  price_usdc numeric(10, 2) not null check (price_usdc > 0 and price_usdc <= 1000),
  position   int not null default 0,
  active     boolean not null default true,
  created_at timestamptz not null default now()
);
create index catalog_items_agent on public.catalog_items (agent_id, position);
alter table public.catalog_items enable row level security;
create policy "read public or own catalogs" on public.catalog_items
  for select to anon, authenticated
  using (exists (select 1 from public.agents a
                 where a.id = agent_id and (a.visibility = 'public' or a.owner_id = auth.uid())));

-- Custodial Hedera testnet accounts: one per paid agent (receives) and one per buyer (pays).
-- Keys are AES-GCM encrypted by the edge functions. No policies: server only.
create table public.wallets (
  id         uuid primary key default gen_random_uuid(),
  kind       text not null check (kind in ('agent', 'user')),
  owner      uuid not null,
  account_id text not null unique,
  enc_key    text not null,
  funded     boolean not null default false,
  created_at timestamptz not null default now(),
  unique (kind, owner)
);
alter table public.wallets enable row level security;

-- A user's World ID: pairwise subject from auth.world.org. Never exposed beyond its owner.
create table public.world_identities (
  user_id     uuid primary key references auth.users(id) on delete cascade,
  iss         text not null,
  sub         text not null,
  acr         text,
  verified_at timestamptz not null default now(),
  unique (iss, sub)
);
alter table public.world_identities enable row level security;
create policy "read own world identity" on public.world_identities
  for select to authenticated using (user_id = auth.uid());

-- In-flight World ID authentications (state, nonce, PKCE). Server only.
create table public.world_attempts (
  state       text primary key,
  user_id     uuid not null references auth.users(id) on delete cascade,
  purpose     text not null check (purpose in ('verify_shop', 'checkpoint')),
  approval_id uuid,
  nonce       text not null,
  verifier    text not null,
  status      text not null default 'pending' check (status in ('pending', 'ok', 'denied', 'failed')),
  created_at  timestamptz not null default now()
);
alter table public.world_attempts enable row level security;

-- Human checkpoints: a purchase above the buyer's limit waits here until a fresh World ID
-- authentication approves it. Used exactly once, within five minutes.
create table public.approvals (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references auth.users(id) on delete cascade,
  agent_id    uuid not null references public.agents(id) on delete cascade,
  item_id     uuid not null references public.catalog_items(id) on delete cascade,
  qty         int not null check (qty between 1 and 20),
  amount_usdc numeric(12, 2) not null check (amount_usdc > 0),
  status      text not null default 'pending'
              check (status in ('pending', 'approved', 'denied', 'expired', 'used')),
  expires_at  timestamptz not null default now() + interval '5 minutes',
  created_at  timestamptz not null default now()
);
alter table public.approvals enable row level security;
create policy "read own approvals" on public.approvals
  for select to authenticated using (user_id = auth.uid());

-- Settled x402 payments.
create table public.orders (
  id            uuid primary key default gen_random_uuid(),
  buyer_id      uuid references auth.users(id) on delete set null,
  agent_id      uuid not null references public.agents(id) on delete cascade,
  item_id       uuid references public.catalog_items(id) on delete set null,
  item_name     text not null,
  qty           int not null,
  amount_usdc   numeric(12, 2) not null,
  payer_account text not null,
  hedera_tx     text not null unique,
  checkpoint    boolean not null default false,
  created_at    timestamptz not null default now()
);
create index orders_buyer on public.orders (buyer_id, created_at desc);
alter table public.orders enable row level security;
create policy "buyers and shop owners read orders" on public.orders
  for select to authenticated
  using (buyer_id = auth.uid()
         or exists (select 1 from public.agents a where a.id = agent_id and a.owner_id = auth.uid()));

-- How much the buyer's wallet agent may spend without asking.
create table public.buyer_settings (
  user_id           uuid primary key references auth.users(id) on delete cascade,
  auto_limit_usdc   numeric(10, 2) not null default 5 check (auto_limit_usdc between 0 and 100),
  daily_budget_usdc numeric(10, 2) not null default 20 check (daily_budget_usdc between 0 and 500),
  updated_at        timestamptz not null default now()
);
alter table public.buyer_settings enable row level security;
create policy "manage own buyer settings" on public.buyer_settings
  for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());

-- Server-side key/value (e.g. the HCS audit topic id). Server only.
create table public.app_settings (
  key   text primary key,
  value text not null
);
alter table public.app_settings enable row level security;

-- Nearby agents now say whether their owner is a verified human (World ID). The return type
-- changes again, so recreate.
drop function if exists public.nearby_agents(double precision, double precision, double precision);

create function public.nearby_agents(p_lat double precision, p_lng double precision, p_km double precision default 5)
returns table (
  id uuid, name text, emoji text, color text, shape text, anchor text, voice_id text, greeting text,
  lat double precision, lng double precision, radius_m double precision,
  visibility text, pricing text, price_usd numeric, wallet_address text,
  is_mine boolean, distance_m double precision, verified boolean
)
language sql stable security definer set search_path = public as $$
  select a.id, a.name, a.emoji, a.color, a.shape, a.anchor, a.voice_id, a.greeting,
         a.lat, a.lng, a.radius_m, a.visibility, a.pricing, a.price_usd, a.wallet_address,
         a.owner_id = auth.uid(), d.m,
         exists (select 1 from public.world_identities w where w.user_id = a.owner_id)
  from public.agents a
  cross join lateral (
    select 6371000 * 2 * asin(sqrt(
      power(sin(radians(a.lat - p_lat) / 2), 2) +
      cos(radians(p_lat)) * cos(radians(a.lat)) * power(sin(radians(a.lng - p_lng) / 2), 2)
    )) as m
  ) d
  where a.anchor = 'geo'
    and (a.visibility = 'public' or a.owner_id = auth.uid())
    and a.lat between p_lat - least(p_km, 50) / 111.0 and p_lat + least(p_km, 50) / 111.0
    and d.m <= least(p_km, 50) * 1000
  order by d.m
  limit 100
$$;

revoke all on function public.nearby_agents(double precision, double precision, double precision) from public;
grant execute on function public.nearby_agents(double precision, double precision, double precision) to anon, authenticated;

-- What the verified badge shows: public facts only (never the World ID subject).
create function public.shop_profile(p_agent uuid)
returns table (
  verified boolean, acr text, verified_at timestamptz, wallet_account text, audit_topic text, pricing text
)
language sql stable security definer set search_path = public as $$
  select w.user_id is not null, w.acr, w.verified_at, a.wallet_address,
         (select value from public.app_settings where key = 'audit_topic'), a.pricing
  from public.agents a
  left join public.world_identities w on w.user_id = a.owner_id
  where a.id = p_agent and (a.visibility = 'public' or a.owner_id = auth.uid())
$$;

revoke all on function public.shop_profile(uuid) from public;
grant execute on function public.shop_profile(uuid) to anon, authenticated;
