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
  id                uuid primary key default gen_random_uuid(),
  code              text unique not null,
  status            text not null default 'lobby',   -- lobby | playing  (seam for sync mode)
  photos_per_player int  not null default 3,         -- host-set contribution per player
  created_at        timestamptz not null default now()
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
  in_pool     boolean not null default false,  -- staged on upload; player promotes N into the pool
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
  select id, room_id, uploader_id, status, display_url, error, in_pool, created_at
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
grant select (id, room_id, uploader_id, status, display_url, error, in_pool, created_at)
  on public.photos to anon;

-- Clients use the safe view (or the granted columns directly).
grant select on public.photos_public to anon;

-- ============================================================
--  Step 3: scoring (server authority) + leaderboard
--  submit_guess reveals the truth ONLY after recording a guess; the math
--  matches shared/geo.js exactly (haversine R=6371; 5000*e^(-10 d / 14916.862)).
-- ============================================================
create or replace function public.submit_guess(
  p_photo_id uuid, p_player_id uuid,
  p_guess_lat double precision, p_guess_lng double precision
) returns table(truth_lat double precision, truth_lng double precision,
                distance_km double precision, points integer)
language plpgsql security definer set search_path = public as $$
declare
  v_lat double precision; v_lng double precision; v_room uuid;
  v_dist double precision; v_pts integer;
begin
  select ph.truth_lat, ph.truth_lng, ph.room_id into v_lat, v_lng, v_room
  from photos ph where ph.id = p_photo_id and ph.status = 'ready';
  if v_lat is null then raise exception 'photo not available'; end if;
  if not exists (select 1 from players pl where pl.id = p_player_id and pl.room_id = v_room) then
    raise exception 'invalid player for room';
  end if;
  v_dist := 6371 * 2 * asin(sqrt(
    power(sin(radians(v_lat - p_guess_lat)/2), 2) +
    cos(radians(p_guess_lat)) * cos(radians(v_lat)) *
    power(sin(radians(v_lng - p_guess_lng)/2), 2)));
  v_pts := round(5000 * exp(-10 * v_dist / 14916.862));
  insert into guesses(photo_id, player_id, guess_lat, guess_lng, distance_km, points)
  values (p_photo_id, p_player_id, p_guess_lat, p_guess_lng, v_dist, v_pts)
  on conflict (photo_id, player_id) do nothing;            -- one guess per photo per player
  select g.distance_km, g.points into v_dist, v_pts
  from guesses g where g.photo_id = p_photo_id and g.player_id = p_player_id;
  return query select v_lat, v_lng, v_dist, v_pts;
end; $$;
revoke all on function public.submit_guess(uuid,uuid,double precision,double precision) from public;
grant execute on function public.submit_guess(uuid,uuid,double precision,double precision) to anon;

-- Leaderboard: aggregates only; reads guesses as definer so raw guesses stay private.
create or replace function public.get_leaderboard(p_room uuid)
returns table(player_id uuid, name text, total_points integer, rounds_played integer)
language sql security definer set search_path = public as $$
  select p.id, p.name, coalesce(sum(g.points),0)::int, count(g.id)::int
  from players p left join guesses g on g.player_id = p.id
  where p.room_id = p_room
  group by p.id, p.name
  order by coalesce(sum(g.points),0) desc;
$$;
revoke all on function public.get_leaderboard(uuid) from public;
grant execute on function public.get_leaderboard(uuid) to anon;

-- Player promotes a chosen set of their OWN ready photos into the pool
-- (replaces their current pooled set, so they can re-pick before playing starts).
create or replace function public.set_pool(p_player_id uuid, p_photo_ids uuid[])
returns int language plpgsql security definer set search_path = public as $$
declare v_count int;
begin
  if not exists (select 1 from players where id = p_player_id) then
    raise exception 'invalid player';
  end if;
  update photos set in_pool = false where uploader_id = p_player_id;
  update photos set in_pool = true
    where id = any(p_photo_ids) and uploader_id = p_player_id and status = 'ready';
  select count(*) into v_count from photos where uploader_id = p_player_id and in_pool = true;
  return v_count;
end; $$;
revoke all on function public.set_pool(uuid, uuid[]) from public;
grant execute on function public.set_pool(uuid, uuid[]) to anon;

-- ============================================================
--  SEAM FOR LATER (DO NOT BUILD NOW):
--  A synchronous "race the clock" mode will add:
--    create table public.rounds (
--      id uuid primary key, room_id uuid, photo_id uuid,
--      started_at timestamptz, ends_at timestamptz);
--    alter table public.guesses add column round_id uuid references public.rounds(id);
--  Nothing above needs restructuring for that — guesses already key on photo_id.
-- ============================================================
