# Wanderguess — Roadmap & Status

Source of truth for what's done and what's next. Update on each meaningful change.
(Day-to-day progress also lives in git history; this is the durable summary.)

Live: https://wanderguess.yangchh.workers.dev · Repo: yangchh17/wanderguess
Stack: static client (Cloudflare Workers assets) + Supabase (Postgres + Storage + Edge Functions).

---

## ✅ Done (deployed)
- Lobby: create / join by code; rejoin reuses identity (rename supported).
- Presence: heartbeat + server-computed `online` (roster view) — Safari-safe.
- Host-controlled start (host = earliest player); host-start gated on online-ready.
- Upload: client decode+downscale (HEIC via heic2any), hybrid location
  (auto EXIF where it survives, else map pin), non-blocking batch, dedup, delete,
  collapsible grid.
- Pool selection: each player adds up to N (host-set) photos; N is a max.
- Async play: per-photo timer (host-set, "No limit" option) with pause/resume;
  players enter on their own time (no auto-enter).
- Scoring: server-authoritative `submit_guess` (matches shared/geo.js); shared
  leaderboard; anti-cheat (guess photo is a CSS background, no save/right-click).
- End game: "See all locations" reveal map (photo + score per point, only photos
  you've guessed); host same-room rematch keeps uploaded photos (game_seq scopes
  guess-memory); scores reset per game.
- Interface redesign: glassy "explorer at night" theme, Copy/Share invite,
  segmented host setup (stepper + time pills), medal leaderboard — mobile-first.
- Play UX closer to GeoGuessr: photo **zoom & pan** to inspect signs/landmarks
  (pinch / wheel / double-click / drag, +/−/reset; still a non-saveable CSS
  background — anti-cheat intact); animated **round-result card** (distance +
  points count-up + 0–5000 score bar); **Enter/Space** to guess / advance.

## 🔒 Security (from Codex review — see REVIEW.md)
**Fixed (no auth needed):**
- ✅ Truth leak via `get_results` — RPC removed; reveal map built from truths the
  client cached from `submit_guess`.
- ✅ `set_pool` now enforces `photos_per_player` server-side.
- ✅ `process-photo` validates `srcPath` is under the room's prefix.
- Decision: `start_game` keeps host override (start with AFK/unready players) — by design.

**Auth-hardening slice — Supabase anonymous auth.** Impersonation closed; photo-row
overwrite closed (v8).
- ✅ **Stage 1 (roles + column lockdown):** clients sign in anonymously
  (`authenticated` role); `players.user_id` added (default `auth.uid()`, not
  spoofable); all policies/grants extended to `authenticated`; truth + `players.token`
  revoked from both roles. Client `ensureAuth()` falls back to anon gracefully.
- ✅ **Anonymous sign-ins enabled** in Supabase → Authentication → Sign In / Providers.
- ✅ **Stage 2 (ownership via auth.uid()):** every definer RPC now requires the caller
  to own the player (`and user_id = auth.uid()` on `submit_guess`, `set_ready`,
  `set_pool`, `set_name`, `start_game`, `reset_room`, `delete_photo`, `touch_player`);
  `players_insert` policy enforces `with check (user_id = auth.uid())`. `process-photo`
  runs with `verify_jwt`, derives the caller's uid from the JWT, verifies the caller
  owns the uploader player, and (v8) verifies the caller owns the target `photoId`
  before writing — with `srcPath` pinned to the exact `${roomId}/${photoId}.src` key.
  **Verified end-to-end**: cross-identity RPC spoof → "not your player"; cross-room
  photo overwrite → 403 "not your photo" (victim row unchanged). (Codex #1, #3, #6 and
  the whole player_id-spoof surface closed.)
- Later: anonymous → real account upgrade (email), unlocking history + photo archive.

**Other hardening:**
- Scope `photos_public` to the caller's own rooms (currently `using (true)` — every
  client can enumerate all rooms' photo metadata + display URLs). Defense-in-depth /
  privacy; no longer an overwrite vector after v8.
- Rate limiting / abuse (room + upload creation) on the free tier.
- Orphaned storage cleanup (display images from deleted photos/rooms).

---

## 🚧 In progress — Accounts, history & scoreboards
Builds on the anonymous-auth foundation. **Guest play stays forever.**
- Account = upgrade the existing anonymous identity to a permanent one
  (`auth.updateUser({email,password})`), so `auth.uid()` — and all accrued
  history — is preserved. Returning users `signInWithPassword`; sign-out drops
  back to a fresh anonymous guest.
- Durable history via a new `game_results` table (one row per finished game,
  per user): total points, photos guessed, best single-photo points, closest km.
  Written by a server-authoritative `record_game` RPC at finish (ownership-checked,
  no truth leak). Survives same-room rematches (which delete live `guesses`).
- `get_my_history()` (recent games) + `get_my_stats()` (lifetime aggregates) RPCs;
  a Profile/Stats screen in the client.
- Later: global all-time leaderboard (needs stable profile names), photo archive
  ("select from your stack"), friends.

---

## 🎯 Next big features (pick one)

### A. Sync mode (live "race the same photo on a clock")
Default stays async; sync is opt-in. The marquee competitive mode.

**S1 — Server round engine**
- Room mode: `rooms.mode text default 'async'` ('async' | 'sync').
- Round state on room (or a `rounds` table): `photo_order uuid[]` (shuffled pool),
  `round_idx int`, `round_started_at timestamptz`, `round_ends_at timestamptz`.
- `start_game` (sync): build shuffled order from the pool, set round 0,
  started_at=now(), ends_at=now()+seconds_per_photo, status='playing'.
- `advance_round(room, from_idx)` RPC, **guarded by from_idx** (idempotent — only
  advances if current round_idx == from_idx) so concurrent client calls are safe.
  Advances when `now() >= round_ends_at` OR all online players have guessed the
  current photo; sets next round timestamps, or status='finished' at the end.
- Verify: RPC-level tests (advance on timeout; advance when all guessed; no
  double-advance).

**S2 — Sync client**
- Lobby: host toggles room mode (sync/async). (Optional v2: per-player opt-in —
  players flag "sync", host start pulls in the sync-flagged ready players.)
- Play: render the current photo from round state; countdown derived from
  `round_ends_at` (server time → all clocks agree); submit guess; on round end,
  reveal that photo's truth to everyone, brief between-round summary, then the
  next photo appears for all simultaneously.
- A watchdog (poll ~1s during sync play) triggers `advance_round` when due.
- Final: shared scoreboard + reveal map.

**S3 — Realtime & polish**
- Supabase Realtime (postgres_changes on the room) for instant transitions
  instead of 1s polling; reconnection handling; late-join = spectate till next game.

### B. Accounts, history & photo archive (retention layer)
Build when there are returning players. Keep **guest play forever**.
- Supabase Auth (email magic-link / Google / Apple); `players.user_id` links a
  guest identity to an account.
- **Game history & lifetime stats** (query guesses/rooms by user_id).
- **Photo archive ("select from your stack")**: a user-owned library of
  previously uploaded (already EXIF-stripped, truth-bearing) photos, reusable in
  any new room without re-uploading. *(This is the user's "save to account" ask —
  download-to-device stays disabled for anti-cheat; archive lives server-side.)*
- Friends + friend leaderboards + invites (after the above).

---

## 🧊 Out of scope (for now)
- Saving photos to the device gallery (web can't; conflicts with anti-cheat).
- Native app (would enable reliable auto-locate + screenshot protection).
