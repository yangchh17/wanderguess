-- ============================================================
--  GeoGuessur multiplayer — schema (Steps 1–2)
--  Run this in the Supabase dashboard SQL editor.
--  Trust boundary: truth_lat/truth_lng live ONLY here and are
--  never exposed to clients (no anon access to photos base table;
--  clients read the photos_public view which omits truth columns).
-- ============================================================

create extension if not exists pgcrypto;

-- ---------- Rooms ----------
create table if not exists public.rooms (
  id         uuid primary key default gen_random_uuid(),
  code       text unique not null,
  status     text not null default 'lobby',   -- lobby | playing  (seam for sync mode)
  created_at timestamptz not null default now()
);

-- ---------- Players (no accounts; secret token held client-side) ----------
create table if not exists public.players (
  id         uuid primary key default gen_random_uuid(),
  room_id    uuid not null references public.rooms(id) on delete cascade,
  name       text not null,
  token      uuid not null default gen_random_uuid(),  -- secret identity
  created_at timestamptz not null default now()
);

-- ---------- Photo pool (truth columns are PRIVATE) ----------
create table if not exists public.photos (
  id          uuid primary key default gen_random_uuid(),
  room_id     uuid not null references public.rooms(id) on delete cascade,
  uploader_id uuid not null references public.players(id) on delete cascade,
  status      text not null default 'pending', -- pending | ready | rejected
  display_url text,
  truth_lat   double precision,                -- PRIVATE — never sent to clients
  truth_lng   double precision,                -- PRIVATE
  error       text,
  created_at  timestamptz not null default now()
);

-- ---------- Guesses (scoring table; defined now so it's stable for step 3) ----------
create table if not exists public.guesses (
  id          uuid primary key default gen_random_uuid(),
  photo_id    uuid not null references public.photos(id) on delete cascade,
  player_id   uuid not null references public.players(id) on delete cascade,
  guess_lat   double precision not null,
  guess_lng   double precision not null,
  distance_km double precision not null,
  points      integer not null,
  created_at  timestamptz not null default now(),
  unique (photo_id, player_id)               -- one guess per photo per player
);

-- ---------- Safe public projection of photos (NO truth columns) ----------
-- Uses column-level grants (below) + a security_invoker view so truth_lat/lng
-- can never be selected by anon, even via `select *`. (Avoids the
-- security-definer-view footgun the Supabase linter flags.)
drop view if exists public.photos_public;
create view public.photos_public
  with (security_invoker = on) as
  select id, room_id, uploader_id, status, display_url, error, created_at
  from public.photos;

-- ============================================================
--  Row Level Security
-- ============================================================
alter table public.rooms   enable row level security;
alter table public.players enable row level security;
alter table public.photos  enable row level security;
alter table public.guesses enable row level security;

-- rooms: anyone can create and look up by code
drop policy if exists rooms_insert on public.rooms;
drop policy if exists rooms_select on public.rooms;
create policy rooms_insert on public.rooms for insert to anon with check (true);
create policy rooms_select on public.rooms for select to anon using (true);

-- players: anyone can join and see the roster
drop policy if exists players_insert on public.players;
drop policy if exists players_select on public.players;
create policy players_insert on public.players for insert to anon with check (true);
create policy players_select on public.players for select to anon using (true);

-- guesses: NO anon policies => RLS denies all anon access (RPC-only in step 3).
-- The Edge Function uses the service_role key and bypasses RLS.
revoke all on public.guesses from anon;

-- photos: anon may SELECT rows, but ONLY the safe columns (truth is never granted).
revoke all on public.photos from anon;
create policy photos_select on public.photos for select to anon using (true);
grant select (id, room_id, uploader_id, status, display_url, error, created_at)
  on public.photos to anon;

-- Clients use the safe view (or the granted columns directly).
grant select on public.photos_public to anon;

-- ============================================================
--  SEAM FOR LATER (DO NOT BUILD NOW):
--  A synchronous "race the clock" mode will add:
--    create table public.rounds (
--      id uuid primary key, room_id uuid, photo_id uuid,
--      started_at timestamptz, ends_at timestamptz);
--    alter table public.guesses add column round_id uuid references public.rounds(id);
--  Nothing above needs restructuring for that — guesses already key on photo_id.
-- ============================================================
