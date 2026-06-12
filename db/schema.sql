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
  seconds_per_photo int  default 90,                 -- per-photo time limit; NULL = no limit
  game_seq          int  not null default 0,         -- bumped on rematch (invalidates client guess-memory)
  created_at        timestamptz not null default now()
);

-- ---------- Players (no accounts; secret token held client-side) ----------
create table if not exists public.players (
  id         uuid primary key default gen_random_uuid(),
  room_id    uuid not null references public.rooms(id) on delete cascade,
  name       text not null,
  token      uuid not null default gen_random_uuid(),  -- secret identity
  ready      boolean not null default false,           -- ready-gate
  last_seen  timestamptz not null default now(),       -- presence (online/offline)
  user_id    uuid default auth.uid(),                  -- anon-auth identity (set via default; not spoofable)
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
declare v_room uuid; v_cap int; v_count int;
begin
  select room_id into v_room from players where id = p_player_id;
  if v_room is null then raise exception 'invalid player'; end if;
  select photos_per_player into v_cap from rooms where id = v_room;
  update photos set in_pool = false where uploader_id = p_player_id;
  update photos set in_pool = true where id in (             -- enforce per-player cap server-side
    select id from photos
    where id = any(p_photo_ids) and uploader_id = p_player_id and status = 'ready'
    order by created_at limit v_cap
  );
  select count(*) into v_count from photos where uploader_id = p_player_id and in_pool = true;
  return v_count;
end; $$;
revoke all on function public.set_pool(uuid, uuid[]) from public;
grant execute on function public.set_pool(uuid, uuid[]) to anon;

-- Uploader can delete their own photo (cascades its guesses).
create or replace function public.delete_photo(p_player_id uuid, p_photo_id uuid)
returns void language sql security definer set search_path = public as $$
  delete from public.photos where id = p_photo_id and uploader_id = p_player_id;
$$;
revoke all on function public.delete_photo(uuid, uuid) from public;
grant execute on function public.delete_photo(uuid, uuid) to anon;

-- Rename a player (e.g., rejoining with a different name).
create or replace function public.set_name(p_player_id uuid, p_name text)
returns void language sql security definer set search_path = public as $$
  update public.players set name = p_name where id = p_player_id and p_name <> '';
$$;
revoke all on function public.set_name(uuid, text) from public;
grant execute on function public.set_name(uuid, text) to anon;

-- Presence heartbeat (clients call periodically while in the room).
create or replace function public.touch_player(p_player_id uuid)
returns void language sql security definer set search_path = public as $$
  update public.players set last_seen = now() where id = p_player_id;
$$;
revoke all on function public.touch_player(uuid) from public;
grant execute on function public.touch_player(uuid) to anon;

-- Roster with server-computed presence (clients must NOT parse timestamps —
-- Safari mis-parses Postgres microsecond precision). Exposes no last_seen/token.
create or replace view public.roster
  with (security_invoker = on) as
  select id, room_id, name, ready, created_at,
         (now() - last_seen < interval '15 seconds') as online
  from public.players;
grant select on public.roster to anon;

-- Ready-gate: players toggle readiness; the HOST starts the game.
create or replace function public.set_ready(p_player_id uuid, p_ready boolean)
returns void language sql security definer set search_path = public as $$
  update public.players set ready = p_ready where id = p_player_id;
$$;
revoke all on function public.set_ready(uuid, boolean) from public;
grant execute on function public.set_ready(uuid, boolean) to anon;

-- NOTE: get_results RPC was removed (it could leak truth to a spoofed player_id).
-- The client builds the reveal map from truths it cached from submit_guess.

-- Host-only rematch: clear pool + guesses + ready, back to lobby (same room).
create or replace function public.reset_room(p_player_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_room uuid; v_host uuid;
begin
  select room_id into v_room from players where id = p_player_id;
  if v_room is null then raise exception 'invalid player'; end if;
  select id into v_host from players where room_id = v_room order by created_at, id limit 1;
  if v_host is distinct from p_player_id then raise exception 'only the host can start a new game'; end if;
  -- Rematch keeps uploaded photos; clears scores, un-pools, resets ready, bumps game_seq.
  delete from guesses where photo_id in (select id from photos where room_id = v_room);
  update photos  set in_pool = false where room_id = v_room;
  update players set ready = false   where room_id = v_room;
  update rooms   set status = 'lobby', game_seq = game_seq + 1 where id = v_room;
end; $$;
revoke all on function public.reset_room(uuid) from public;
grant execute on function public.reset_room(uuid) to anon;

-- ============================================================
--  Anonymous-auth hardening — STAGE 1 (roles + column lockdown)
--  Anon-auth clients use the 'authenticated' role. Allow it everywhere anon was
--  allowed, and keep truth/token columns out of reach of BOTH roles.
--  Requires "Anonymous sign-ins" enabled in Supabase Auth settings.
--  STAGE 2 (per-RPC ownership via auth.uid()) is pending — see ROADMAP/REVIEW.
-- ============================================================
alter policy rooms_insert   on public.rooms   to anon, authenticated;
alter policy rooms_select   on public.rooms   to anon, authenticated;
alter policy players_insert on public.players to anon, authenticated;
alter policy players_select on public.players to anon, authenticated;
alter policy photos_select  on public.photos  to anon, authenticated;
alter policy "anon upload to uploads" on storage.objects to anon, authenticated;

revoke all on public.photos from anon, authenticated;
grant select (id, room_id, uploader_id, status, display_url, error, in_pool, created_at)
  on public.photos to anon, authenticated;

revoke all on public.players from anon, authenticated;             -- hides `token`
grant select (id, room_id, name, ready, last_seen, created_at, user_id)
  on public.players to anon, authenticated;
grant insert (room_id, name) on public.players to anon, authenticated;  -- user_id comes from the default only

revoke all on public.guesses from anon, authenticated;             -- RPC-only
grant select, insert on public.rooms to anon, authenticated;
revoke update, delete on public.rooms from anon, authenticated;    -- status/game_seq change via RPC only
grant select on public.photos_public to anon, authenticated;
grant select on public.roster        to anon, authenticated;

grant execute on function public.submit_guess(uuid,uuid,double precision,double precision) to authenticated;
grant execute on function public.get_leaderboard(uuid)    to authenticated;
grant execute on function public.set_pool(uuid, uuid[])   to authenticated;
grant execute on function public.set_ready(uuid, boolean) to authenticated;
grant execute on function public.start_game(uuid)         to authenticated;
grant execute on function public.reset_room(uuid)         to authenticated;
grant execute on function public.delete_photo(uuid, uuid) to authenticated;
grant execute on function public.touch_player(uuid)       to authenticated;
grant execute on function public.set_name(uuid, text)     to authenticated;

-- Host = earliest player in the room; only the host can start.
create or replace function public.start_game(p_player_id uuid)
returns text language plpgsql security definer set search_path = public as $$
declare v_room uuid; v_host uuid; v_status text;
begin
  select room_id into v_room from players where id = p_player_id;
  if v_room is null then raise exception 'invalid player'; end if;
  select id into v_host from players where room_id = v_room order by created_at, id limit 1;
  if v_host is distinct from p_player_id then raise exception 'only the host can start the game'; end if;
  update rooms set status = 'playing' where id = v_room and status = 'lobby';
  select status into v_status from rooms where id = v_room;
  return v_status;
end; $$;
revoke all on function public.start_game(uuid) from public;
grant execute on function public.start_game(uuid) to anon;

-- ============================================================
--  SEAM FOR LATER (DO NOT BUILD NOW):
--  A synchronous "race the clock" mode will add:
--    create table public.rounds (
--      id uuid primary key, room_id uuid, photo_id uuid,
--      started_at timestamptz, ends_at timestamptz);
--    alter table public.guesses add column round_id uuid references public.rounds(id);
--  Nothing above needs restructuring for that — guesses already key on photo_id.
-- ============================================================


-- ============================================================
--  ANON-AUTH STAGE 2 — ownership guards (auth.uid())
--  Supersedes the RPC bodies above. Clients sign in (anonymously or with a real
--  account); every player row carries user_id = auth.uid() (set at insert, RLS-
--  enforced). Each definer RPC now requires the caller to OWN the player it acts
--  on, so a room participant can no longer spoof another player's id. Mutating
--  RPCs (submit_guess/set_pool/start_game/reset_room) raise on a mismatch; the
--  fire-and-forget ones (touch_player/set_ready/set_name/delete_photo) simply
--  affect zero rows. The process-photo Edge Function does the same via the JWT
--  (see supabase/functions/process-photo/index.ts, v7).
-- ============================================================

-- Players may only insert a row owned by their own auth identity.
drop policy if exists players_insert on public.players;
create policy players_insert on public.players
  for insert to anon, authenticated with check (user_id = auth.uid());

create or replace function public.touch_player(p_player_id uuid)
returns void language sql security definer set search_path = public as $$
  update public.players set last_seen = now() where id = p_player_id and user_id = auth.uid();
$$;

create or replace function public.set_ready(p_player_id uuid, p_ready boolean)
returns void language sql security definer set search_path = public as $$
  update public.players set ready = p_ready where id = p_player_id and user_id = auth.uid();
$$;

create or replace function public.set_name(p_player_id uuid, p_name text)
returns void language sql security definer set search_path = public as $$
  update public.players set name = p_name where id = p_player_id and user_id = auth.uid() and p_name <> '';
$$;

create or replace function public.set_pool(p_player_id uuid, p_photo_ids uuid[])
returns integer language plpgsql security definer set search_path = public as $$
declare v_room uuid; v_cap int; v_count int;
begin
  select room_id into v_room from players where id = p_player_id and user_id = auth.uid();
  if v_room is null then raise exception 'not your player'; end if;
  select photos_per_player into v_cap from rooms where id = v_room;
  update photos set in_pool = false where uploader_id = p_player_id;
  update photos set in_pool = true where id in (
    select id from photos where id = any(p_photo_ids) and uploader_id = p_player_id and status = 'ready'
    order by created_at limit v_cap);
  select count(*) into v_count from photos where uploader_id = p_player_id and in_pool = true;
  return v_count;
end; $$;

create or replace function public.delete_photo(p_player_id uuid, p_photo_id uuid)
returns void language sql security definer set search_path = public as $$
  delete from public.photos where id = p_photo_id and uploader_id = p_player_id
    and exists (select 1 from public.players where id = p_player_id and user_id = auth.uid());
$$;

create or replace function public.submit_guess(p_photo_id uuid, p_player_id uuid,
  p_guess_lat double precision, p_guess_lng double precision)
returns table(truth_lat double precision, truth_lng double precision, distance_km double precision, points integer)
language plpgsql security definer set search_path = public as $$
declare v_lat double precision; v_lng double precision; v_room uuid; v_dist double precision; v_pts integer;
begin
  select ph.truth_lat, ph.truth_lng, ph.room_id into v_lat, v_lng, v_room
  from photos ph where ph.id = p_photo_id and ph.status = 'ready';
  if v_lat is null then raise exception 'photo not available'; end if;
  if not exists (select 1 from players pl where pl.id = p_player_id and pl.room_id = v_room and pl.user_id = auth.uid()) then
    raise exception 'not your player for this room';
  end if;
  v_dist := 6371 * 2 * asin(sqrt(power(sin(radians(v_lat - p_guess_lat)/2),2)
            + cos(radians(p_guess_lat))*cos(radians(v_lat))*power(sin(radians(v_lng - p_guess_lng)/2),2)));
  v_pts := round(5000 * exp(-10 * v_dist / 14916.862));
  insert into guesses(photo_id, player_id, guess_lat, guess_lng, distance_km, points)
  values (p_photo_id, p_player_id, p_guess_lat, p_guess_lng, v_dist, v_pts)
  on conflict (photo_id, player_id) do nothing;
  select g.distance_km, g.points into v_dist, v_pts from guesses g where g.photo_id = p_photo_id and g.player_id = p_player_id;
  return query select v_lat, v_lng, v_dist, v_pts;
end; $$;

create or replace function public.start_game(p_player_id uuid)
returns text language plpgsql security definer set search_path = public as $$
declare v_room uuid; v_host uuid; v_status text;
begin
  select room_id into v_room from players where id = p_player_id and user_id = auth.uid();
  if v_room is null then raise exception 'not your player'; end if;
  select id into v_host from players where room_id = v_room order by created_at, id limit 1;
  if v_host is distinct from p_player_id then raise exception 'only the host can start the game'; end if;
  update rooms set status = 'playing' where id = v_room and status = 'lobby';
  select status into v_status from rooms where id = v_room;
  return v_status;
end; $$;

create or replace function public.reset_room(p_player_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_room uuid; v_host uuid;
begin
  select room_id into v_room from players where id = p_player_id and user_id = auth.uid();
  if v_room is null then raise exception 'not your player'; end if;
  select id into v_host from players where room_id = v_room order by created_at, id limit 1;
  if v_host is distinct from p_player_id then raise exception 'only the host can start a new game'; end if;
  delete from guesses where photo_id in (select id from photos where room_id = v_room);
  update photos  set in_pool = false where room_id = v_room;
  update players set ready = false   where room_id = v_room;
  update rooms   set status = 'lobby', game_seq = game_seq + 1 where id = v_room;
end; $$;


-- ============================================================
--  ACCOUNTS, HISTORY & SCOREBOARDS
--  Durable per-finished-game snapshot per user. Survives same-room rematches
--  (which delete live `guesses`) and room deletion (room_id -> null, code kept).
--  Accounts = upgrade the anonymous user in place (client: auth.updateUser),
--  so auth.uid() and all history are preserved. Guest play stays forever.
-- ============================================================
create table if not exists public.game_results (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null,
  room_id uuid references public.rooms(id) on delete set null,
  game_seq int not null default 0,
  room_code text,
  points int not null default 0,
  photos_guessed int not null default 0,
  best_points int not null default 0,
  closest_km double precision,
  finished_at timestamptz not null default now(),
  unique (user_id, room_id, game_seq)
);
alter table public.game_results enable row level security;
drop policy if exists gr_select on public.game_results;
create policy gr_select on public.game_results for select to anon, authenticated using (user_id = auth.uid());
revoke all on public.game_results from anon, authenticated;
grant select on public.game_results to anon, authenticated;   -- writes only via record_game (definer)

-- Snapshot the caller's own finished game (sum of their guesses for the current game).
create or replace function public.record_game(p_player_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_uid uuid; v_room uuid; v_seq int; v_code text;
        v_points int; v_count int; v_best int; v_closest double precision;
begin
  select user_id, room_id into v_uid, v_room from players where id = p_player_id and user_id = auth.uid();
  if v_uid is null then raise exception 'not your player'; end if;
  select game_seq, code into v_seq, v_code from rooms where id = v_room;
  select coalesce(sum(points),0), count(*), coalesce(max(points),0), min(distance_km)
    into v_points, v_count, v_best, v_closest
    from guesses where player_id = p_player_id;
  if v_count = 0 then return; end if;
  insert into game_results(user_id, room_id, game_seq, room_code, points, photos_guessed, best_points, closest_km, finished_at)
  values (v_uid, v_room, coalesce(v_seq,0), v_code, v_points, v_count, v_best, v_closest, now())
  on conflict (user_id, room_id, game_seq) do update
    set points = excluded.points, photos_guessed = excluded.photos_guessed,
        best_points = excluded.best_points, closest_km = excluded.closest_km, finished_at = now();
end; $$;
revoke all on function public.record_game(uuid) from public;
grant execute on function public.record_game(uuid) to anon, authenticated;

-- The caller's recent games (no truth coordinates — points/distance/counts only).
create or replace function public.get_my_history()
returns table(room_code text, game_seq int, points int, photos_guessed int,
              best_points int, closest_km double precision, finished_at timestamptz)
language sql security definer set search_path = public as $$
  select room_code, game_seq, points, photos_guessed, best_points, closest_km, finished_at
  from public.game_results where user_id = auth.uid()
  order by finished_at desc limit 50;
$$;
revoke all on function public.get_my_history() from public;
grant execute on function public.get_my_history() to anon, authenticated;

-- The caller's lifetime aggregates.
create or replace function public.get_my_stats()
returns table(games int, total_points bigint, avg_points int, best_game int,
              total_photos bigint, best_points int, closest_km double precision)
language sql security definer set search_path = public as $$
  select count(*)::int, coalesce(sum(points),0)::bigint, coalesce(round(avg(points)),0)::int,
         coalesce(max(points),0)::int, coalesce(sum(photos_guessed),0)::bigint,
         coalesce(max(best_points),0)::int, min(closest_km)
  from public.game_results where user_id = auth.uid();
$$;
revoke all on function public.get_my_stats() from public;
grant execute on function public.get_my_stats() to anon, authenticated;


-- ============================================================
--  PLAYER FEEDBACK (write-only suggestion box)
--  Clients can only INSERT, via the rate-limited RPC below — the table
--  itself is not readable or writable by anon/authenticated, so players
--  can never see each other's submissions. Read it in the Supabase
--  dashboard (service role bypasses RLS).
-- ============================================================
create table if not exists public.feedback (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null,                       -- auth.uid() of the sender (guest or account)
  body       text not null,
  created_at timestamptz not null default now()
);
create index if not exists feedback_user_time on public.feedback(user_id, created_at);
alter table public.feedback enable row level security;   -- RLS on, no policies = no direct access
revoke all on public.feedback from anon, authenticated;

create or replace function public.submit_feedback(p_body text)
returns void language plpgsql security definer set search_path = public as $$
declare v_body text := trim(coalesce(p_body, ''));
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  if length(v_body) < 3    then raise exception 'feedback is empty'; end if;
  if length(v_body) > 2000 then raise exception 'feedback too long (2000 chars max)'; end if;
  if (select count(*) from feedback
      where user_id = auth.uid() and created_at > now() - interval '1 hour') >= 5 then
    raise exception 'too many submissions — try again in a bit';
  end if;
  insert into feedback(user_id, body) values (auth.uid(), v_body);
end; $$;
revoke all on function public.submit_feedback(text) from public;
grant execute on function public.submit_feedback(text) to anon, authenticated;
