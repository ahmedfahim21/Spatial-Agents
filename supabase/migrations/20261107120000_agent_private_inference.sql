-- An agent can run on 0G's private tier: sealed inference inside a TEE, on the smaller set of
-- TeeML models. Off by default, so an agent keeps the full catalogue unless its owner opts in.
alter table public.agents
  add column if not exists private_inference boolean not null default false;
