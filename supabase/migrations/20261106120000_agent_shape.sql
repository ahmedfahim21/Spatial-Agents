-- Each agent's body shape, chosen when it's created.
alter table public.agents
  add column if not exists shape text not null default 'circle'
  check (shape in ('circle', 'hexagon', 'squircle', 'capsule', 'drop'));

-- Return the shape (and anchor) with nearby agents. The return type changes, so recreate.
drop function if exists public.nearby_agents(double precision, double precision, double precision);

create function public.nearby_agents(p_lat double precision, p_lng double precision, p_km double precision default 5)
returns table (
  id uuid, name text, emoji text, color text, shape text, anchor text, voice_id text, greeting text,
  lat double precision, lng double precision, radius_m double precision,
  visibility text, pricing text, price_usd numeric, wallet_address text,
  is_mine boolean, distance_m double precision
)
language sql stable security definer set search_path = public as $$
  select a.id, a.name, a.emoji, a.color, a.shape, a.anchor, a.voice_id, a.greeting,
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
