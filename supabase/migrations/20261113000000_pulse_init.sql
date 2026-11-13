-- Pulse cloud schema (Phases 7-9).
--
-- What is stored here: daily summaries, sleep sessions and workouts. Nothing else.
-- Raw heartbeats and per-minute data never leave the phone (data minimization).
--
-- Security model:
--   * Row Level Security is ON for every table. A signed-in user can only see their own rows.
--   * The Claude connector signs in through OAuth and gets a token with a `client_id` claim.
--     Tokens with that claim can READ but never write (see the write policies below).
--   * Secrets (Strava tokens, usage counters) live in tables with RLS on and NO policies, so only
--     the server-side functions (service role) can touch them.
--   * `user_id` is filled in by the database from the signed-in user, never trusted from the app.

create table public.daily_summary (
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  day date not null,
  recovery_pct numeric,
  recovery_word text,
  day_strain numeric not null,
  sleep_minutes integer,
  sleep_need_minutes integer not null,
  resting_hr numeric,
  hrv_rmssd numeric,
  baseline_resting_hr numeric,
  baseline_hrv numeric,
  explanation text not null default '',
  source text not null check (source in ('history', 'live', 'manual', 'simulated')),
  algorithm_version integer not null,
  updated_at timestamptz not null default now(),
  primary key (user_id, day)
);

create table public.sleep_session (
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  id uuid not null,
  start_at timestamptz not null,
  end_at timestamptz not null,
  asleep_minutes integer not null,
  awake_minutes integer not null,
  disturbances integer not null,
  is_nap boolean not null default false,
  source text not null check (source in ('history', 'live', 'manual', 'simulated')),
  updated_at timestamptz not null default now(),
  primary key (user_id, id)
);

create table public.workout (
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  id uuid not null,
  start_at timestamptz not null,
  end_at timestamptz not null,
  kind text not null,
  avg_hr integer not null,
  max_hr integer not null,
  strain numeric not null,
  zone_seconds integer[] not null default '{}',
  source text not null check (source in ('history', 'live', 'manual', 'simulated')),
  updated_at timestamptz not null default now(),
  primary key (user_id, id)
);

create index sleep_session_user_end on public.sleep_session (user_id, end_at desc);
create index workout_user_start on public.workout (user_id, start_at desc);

alter table public.daily_summary enable row level security;
alter table public.sleep_session enable row level security;
alter table public.workout enable row level security;

-- Read: your own rows (the app, and the Claude connector acting for you).
create policy "read own days" on public.daily_summary
  for select to authenticated using (user_id = (select auth.uid()));
create policy "read own sleeps" on public.sleep_session
  for select to authenticated using (user_id = (select auth.uid()));
create policy "read own workouts" on public.workout
  for select to authenticated using (user_id = (select auth.uid()));

-- Write: your own rows, and only with a token from signing in to the app directly.
-- OAuth clients (the Claude connector) carry a `client_id` claim and are refused here, so
-- the connector is read-only at the database level, whatever the server code does.
create policy "app inserts own days" on public.daily_summary
  for insert to authenticated
  with check (user_id = (select auth.uid()) and (select auth.jwt() ->> 'client_id') is null);
create policy "app updates own days" on public.daily_summary
  for update to authenticated
  using (user_id = (select auth.uid()) and (select auth.jwt() ->> 'client_id') is null)
  with check (user_id = (select auth.uid()));
create policy "app deletes own days" on public.daily_summary
  for delete to authenticated
  using (user_id = (select auth.uid()) and (select auth.jwt() ->> 'client_id') is null);

create policy "app inserts own sleeps" on public.sleep_session
  for insert to authenticated
  with check (user_id = (select auth.uid()) and (select auth.jwt() ->> 'client_id') is null);
create policy "app updates own sleeps" on public.sleep_session
  for update to authenticated
  using (user_id = (select auth.uid()) and (select auth.jwt() ->> 'client_id') is null)
  with check (user_id = (select auth.uid()));
create policy "app deletes own sleeps" on public.sleep_session
  for delete to authenticated
  using (user_id = (select auth.uid()) and (select auth.jwt() ->> 'client_id') is null);

create policy "app inserts own workouts" on public.workout
  for insert to authenticated
  with check (user_id = (select auth.uid()) and (select auth.jwt() ->> 'client_id') is null);
create policy "app updates own workouts" on public.workout
  for update to authenticated
  using (user_id = (select auth.uid()) and (select auth.jwt() ->> 'client_id') is null)
  with check (user_id = (select auth.uid()));
create policy "app deletes own workouts" on public.workout
  for delete to authenticated
  using (user_id = (select auth.uid()) and (select auth.jwt() ->> 'client_id') is null);

-- People who are not signed in get nothing at all.
revoke all on public.daily_summary, public.sleep_session, public.workout from anon;

-- ---------------------------------------------------------------------------------------------
-- Server-only tables: RLS on, no policies, no grants. Only the edge functions (service role) use them.
-- ---------------------------------------------------------------------------------------------

-- Strava OAuth tokens (Phase 7). Never readable by the app or by the Claude connector.
create table public.strava_token (
  user_id uuid primary key references auth.users (id) on delete cascade,
  access_token text not null,
  refresh_token text not null,
  expires_at timestamptz not null,
  updated_at timestamptz not null default now()
);

-- One-time values that tie a Strava sign-in to the user who started it (CSRF protection).
create table public.strava_oauth_state (
  state text primary key,
  user_id uuid not null references auth.users (id) on delete cascade,
  created_at timestamptz not null default now()
);

-- How many coach questions a user asked per day (Phase 9), to cap the Anthropic API bill.
create table public.coach_usage (
  user_id uuid not null references auth.users (id) on delete cascade,
  day date not null,
  requests integer not null default 0,
  primary key (user_id, day)
);

alter table public.strava_token enable row level security;
alter table public.strava_oauth_state enable row level security;
alter table public.coach_usage enable row level security;
revoke all on public.strava_token, public.strava_oauth_state, public.coach_usage from anon, authenticated;

-- Adds one to today's coach counter and returns the new value, in one atomic statement.
create function public.bump_coach_usage(p_user uuid)
returns integer
language sql
security definer
set search_path = ''
as $$
  insert into public.coach_usage (user_id, day, requests)
  values (p_user, (now() at time zone 'utc')::date, 1)
  on conflict (user_id, day) do update set requests = public.coach_usage.requests + 1
  returning requests;
$$;
revoke all on function public.bump_coach_usage(uuid) from public, anon, authenticated;
