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

## ✅ Accounts, history & scoreboards (shipped — guest play stays forever)
- **Durable history**: new `game_results` table (one row per finished game, per
  user — total points, photos guessed, best single-photo points, closest km).
  Written by the server-authoritative `record_game(p_player_id)` RPC at finish
  (ownership-checked via `auth.uid()`, no truth leak). Survives same-room rematches
  (which delete live `guesses`) and room deletion (`room_id → null`, code kept).
- **Stats & history screen** ("My stats" on Home): lifetime tiles (games, total /
  avg / best-game points, photos, best photo, closest-ever guess) + recent games,
  via `get_my_stats()` / `get_my_history()`. Works for guests too (accrues under
  the anonymous uid).
- **Accounts**: Home account card. "Save progress" upgrades the anonymous user in
  place (`auth.updateUser({email,password})`) — same `auth.uid()`, so all history
  carries over. "Sign in" (`signInWithPassword`) for returning users; "Sign out"
  drops back to a fresh anonymous guest.
- ⚠️ **Owner action for smooth signup:** email **Confirm email** is currently ON
  and uses Supabase's built-in (rate-limited, test-only) mailer. For instant
  email+password accounts, turn **Authentication → Sign In/Providers → Email →
  "Confirm email" OFF**, or configure custom SMTP. (Alternatively add Google OAuth
  — needs owner-created credentials.) History/stats work regardless.
- Later: global all-time leaderboard (needs stable profile names), photo archive
  ("select from your stack"), friends.

---

## 🎯 Committed plan — pool-ready app (decided 2026-06-12)
Order: UI shell → personal library → scoped scoring → public pool. Each stage
ships on its own. Principle: tags are browse/filter labels only; scoring scope
is server-derived (reverse geocode) — player input never touches the formula.

### Stage 0 — UI shell: bottom tab bar
- Tabs: **Play · Library · Profile** (Explore appears in Stage 3).
- Play = home (create/join/rejoin) + lobby once in a room; in-game badge.
- Profile absorbs the account card, stats/history, suggestion box.
- Full-screen overlays (play/results/pin/help) unchanged; they render above.
- Recommended: split index.html's module script into js/*.js ES modules
  (no build step needed) — 1,500+ lines is merge-conflict bait with two
  active sessions.

### Stage 1 — Personal library (fixes iOS for good)
- `library_photos`: owned by auth.uid(); truth columns locked exactly like
  `photos` (truth stays RPC-only everywhere); safe view without truth;
  display images under `display/lib/{uid}/`.
- `process-photo` learns a library target — same EXIF strip + truth extract,
  JWT-ownership-checked; originals still deleted after processing.
- Room uploads auto-save to the uploader's library. "Add from library"
  copies display object + truth into the room's photos via an ownership-
  checked RPC (storage COPY, not shared reference — room deletes stay safe).
- Library tab: grid + tags + delete + upload outside any room — iPhone
  users (Safari AND Chrome: all iOS browsers are WebKit, same GPS
  stripping) do the Files trick once, keep GPS forever.
- Cap ~100 photos/user (free-tier storage). Guest libraries accrue under
  the anon uid and carry over on account upgrade (same as history).

### Stage 2 — Scoped scoring (tags + reverse geocode)
- `process-photo` reverse-geocodes truth → city/region/country stored on
  the photo (locked columns; never rendered during guessing).
- Same formula, parameterized map size (already a param in shared/geo.js):
  world 14,917 km · country ~2,000 · region ~400 · city ~40. Fixed
  constants first; per-country bounding boxes later if wanted.
- `rooms.scope` ('world'|'country'|'region'|'city') + `scope_km`; host
  picks at create; `submit_guess` reads scope_km (server stays authority).
- Tags shown ONLY in library/pool browsing and as the game's scope label —
  equal info for everyone, no per-photo leak during play.

### Stage 3 — Public pool (Explore tab)
- `library_photos.is_public` opt-in with consent warning (strangers see
  the photo + its exact location after guessing). Publishing requires a
  real (non-anon) account → ban handle + abuse friction.
- Ratings: photo quality + "location accurate?" as separate signals.
  Auto-retire needs a minimum vote count (Wilson-style) first; soft-delete
  / quarantine, never hard-delete; optional retire-after-N-plays
  (anti-memorization keeps the pool fresh).
- Reports auto-hide at a threshold; owner reviews in the dashboard.
- Explore tab: browse by tag, solo run (5 random from a filter), daily
  challenge (seeded daily selection + global leaderboard — needs the
  stable profile names from accounts).
- Later: friends, friend leaderboards, invites.

---

## 🔄 Parallel track — Sync mode (live "race the same photo on a clock")
Default stays async; sync is opt-in. The marquee competitive mode.
Orthogonal to the staged plan above — can land between any stages.

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

*(The former "B. Accounts, history & photo archive" item: accounts + history
shipped — see above; the photo archive is now Stage 1 of the committed plan;
friends/leaderboards moved into Stage 3's "later" line.)*

---

## 🧊 Out of scope (for now)
- Saving photos to the device gallery (web can't; conflicts with anti-cheat).
- Native app (would enable reliable auto-locate + screenshot protection).
