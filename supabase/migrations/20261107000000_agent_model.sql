-- Which 0G router chat model an agent thinks with. Null = the server default (ZG_MODEL).
alter table public.agents
  add column if not exists model text check (model is null or length(model) <= 100);
