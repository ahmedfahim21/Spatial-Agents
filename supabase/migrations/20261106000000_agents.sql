-- Agents that live in the world (geo) or travel with their owner (body).
-- Coding agents (Claude Code) stay on the Mac and never live here.

create table public.agents (
  id             uuid primary key default gen_random_uuid(),
  owner_id       uuid not null default auth.uid() references auth.users (id) on delete cascade,
  kind           text not null check (kind in ('personal', 'public')),
  anchor         text not null check (anchor in ('body', 'geo')),
  visibility     text not null check (visibility in ('private', 'public')),
  name           text not null check (char_length(name) between 1 and 60),
  emoji          text check (char_length(emoji) <= 8),
  color          text check (char_length(color) <= 16),
  voice_id       text check (char_length(voice_id) <= 64),
  greeting       text not null default '' check (char_length(greeting) <= 500),
  context        text not null default '' check (char_length(context) <= 8000),
  lat            double precision check (lat between -90 and 90),
  lng            double precision check (lng between -180 and 180),
  radius_m       double precision not null default 25 check (radius_m between 3 and 2000),
  pricing        text not null default 'free' check (pricing in ('free', 'paid')),
  price_usd      numeric(10, 4) check (price_usd >= 0),
  wallet_address text check (char_length(wallet_address) <= 128),
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  -- Public agents are places you walk up to: always geo-anchored.
  constraint public_is_geo check (visibility = 'private' or anchor = 'geo'),
  constraint kind_matches_visibility check ((kind = 'public') = (visibility = 'public')),
  constraint geo_has_location check (anchor = 'body' or (lat is not null and lng is not null))
);

create index agents_owner_idx on public.agents (owner_id);
create index agents_geo_idx on public.agents (lat, lng) where anchor = 'geo';

alter table public.agents enable row level security;

-- Owners can do anything with their own agents. Nobody else reads the table directly:
-- public discovery goes through nearby_agents(), which never returns an agent's context.
create policy "owners manage their agents" on public.agents
  for all to authenticated
  using (owner_id = auth.uid())
  with check (owner_id = auth.uid());

create or replace function public.touch_updated_at() returns trigger
language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end $$;

create trigger agents_touch before update on public.agents
  for each row execute function public.touch_updated_at();

-- Public geo agents near a point, plus the caller's own private geo agents.
create or replace function public.nearby_agents(p_lat double precision, p_lng double precision, p_km double precision default 5)
returns table (
  id uuid, name text, emoji text, color text, voice_id text, greeting text,
  lat double precision, lng double precision, radius_m double precision,
  visibility text, pricing text, price_usd numeric, wallet_address text,
  is_mine boolean, distance_m double precision
)
language sql stable security definer set search_path = public as $$
  select a.id, a.name, a.emoji, a.color, a.voice_id, a.greeting,
         a.lat, a.lng, a.radius_m, a.visibility, a.pricing, a.price_usd, a.wallet_address,
         a.owner_id = auth.uid(), d.m
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
