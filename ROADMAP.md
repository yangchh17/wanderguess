# Wanderguess — Roadmap & Status

Source of truth for what's done and what's next. Update on each meaningful change.
(Day-to-day progress also lives in git history; this is the durable summary.)

Live: https://wanderguess.yangchh.workers.dev · Repo: yangchh17/wanderguess
Stack: static client (Cloudflare Workers assets) + Supabase (Postgres + Storage + Edge Functions).

---

## 🧭 Competitive landscape & positioning (researched 2026-06-13)
The "upload your own photos → friends guess where" concept is **not novel** — several
products exist. Honest read:
- **PhotoGuessr / loveguessr.com** (web) — the closest: own photos, pin location on a
  map, **+ guess the date** (TimeGuessr-style, 10k pts), share-by-link, free, no
  signup. Single-creator model (you upload, friends guess *your* memories).
- **Whereez** (iOS) — own photos, **blurred** for mystery, async/feed, distance+time
  scoring, social-network features (friends, profiles). New/small (few ratings).
- **GeoGuess.com** (web) — upload photos + multiplayer (details thin).
- Adjacent: **TimeGuessr / WhenTaken / WhereTaken** (curated photos, place+year, viral
  daily, single-player); **Photo Roulette / Buddies / Throwbacks** (own photos but
  guess *whose*, not *where* — big, established party apps); **GeoGuessr** (Street
  View, the giant).

**Where Wanderguess is differentiated (lean into this):**
- **Shared-pool party multiplayer** — *everyone in the room contributes photos to one
  pool and everyone guesses everyone's.* Competitors are single-creator (one uploader,
  others guess). The "group trip → combine everyone's photos → who actually knows where
  you all were" occasion is the genuine wedge.
- Rooms + presence + host-start + per-photo timer + rematch; accounts + history/stats;
  a real security/trust model; GeoGuessr-style zoom/pan inspection.

**Table-stakes we already have:** own photos, map pin, share link, no signup, free, web.
**Gaps worth considering:** date guessing (cheap depth, others have it); a mobile
app + push (Whereez/Photo Roulette have it); photo-blur as an alt reveal.

**Verdict:** Worth continuing — as a learning/portfolio project unequivocally, and as a
product *if* it commits to the group/party-pool angle rather than re-cloning the
single-creator memory game loveguessr already nails. Keep the committed plan, but frame
Stage 1 (library) and any social features around *groups*, not solo memories.

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

## 🎯 Committed plan (decided 2026-06-12)
Committed: Stages 0–2 (UI shell → personal library → scoped scoring). Each
stage ships on its own. Stage 3 (public pool) is NOT committed — re-evaluate
after Stage 2 ships and we see how the app feels; the design below is kept so
Stages 0–2 stay pool-compatible. Principle: tags are browse/filter labels
only; scoring scope is server-derived (reverse geocode) — player input never
touches the formula.

### Stage 0 — UI shell: bottom tab bar
- ✅ **Module split done** (2026-06-13): extracted `js/core.js` (shared `$`, `show`,
  `sb`, `ensureAuth`, `escapeHtml` — singleton via consistent `?v=1` specifier),
  `js/account.js` (account + stats/history), `js/feedback.js` (suggestion box),
  `js/ui.js` (toast, copy/share, steppers, time pills, score-pop, help). The inline
  module in `index.html` is now just the game core (lobby/upload/play) and imports
  from `core.js`. Verified end-to-end (create room, roster, leave, My-stats, back).
  Sign-in/out now do `location.reload()` for a clean re-init (no game-module coupling).
- ✅ ppp cap aligned to 5 in the create handler (was 10; UI already capped).
- ✅ **Bottom tab bar shipped** (2026-06-13): **Play · Profile** (Library arrives in
  Stage 1, Explore in Stage 3). `js/nav.js` switches surfaces; the active indicator
  auto-syncs to the visible `.screen` (a MutationObserver), so it stays correct even
  when the game module navigates on its own.
- ✅ **Home decluttered:** Play = just name → Create / Join (+ rejoin). The account
  card, stats/history, and suggestion box all moved into the **Profile** tab. This is
  the "simple & guided" win — Home is now 3 cards, not 6.
- ✅ **Guided lobby shipped** (2026-06-13): reordered to the natural flow (invite →
  add photos → ready/start → players → leaderboard) with a **state-driven "next step"
  banner** (1 Add photos → 2 Ready → 3 Start / waiting / Game on) driven by
  `refreshLobby`. Verified the banner advances through each state.
- ✅ **Landing splash (2026-06-14):** a GeoGuessr-style `#s-landing` overlay (brand +
  tagline + big **Play** button + "How to play") shows on load unless you're resuming a
  room; Play reveals the tabbed app (home/lobby + tabs). Replaced the auto-popping help.
- ⬜ In-game badge on the Play tab while a round is active.
- Full-screen overlays (play/results/pin/help) unchanged; they render above the bar.

### Stage 1 — Personal library (fixes iOS for good)
**✅ Backend done (2026-06-13, RPC/edge-tested):** `library_photos` table (owner-only
RLS, truth locked, `library_public` view), `delete_library_photo` RPC, and
**process-photo v9** with a `target='library'` path (uid from JWT, `lib/{uid}/` srcPath
pinned, 15-photo cap, ownership-guarded). Verified: upload→process→ready, truth locked,
cross-user isolation, owner-only delete, cap.
**✅ Library tab done (2026-06-13):** 3rd tab (Play · Library · Profile); upload to your
library (reuses the decode/EXIF/pin pipeline with `target:'library'`), grid + delete +
`N / 15` count. Verified: navigate, empty state, upload→process→renders, delete.
**✅ Slice 2 done (2026-06-14) — Stage 1 COMPLETE:** `add_library_to_room(p_player_id,
p_lib_ids[])` copies chosen library photos into the room's `photos` (truth copied
server-side, `source_lib_id` link, dedup, capped at `photos_per_player`). The lobby's
"Your photos" now shows your **library grid** to pick from (no room file-picker); the
"Add a photo" button uploads to your library AND pre-selects it. Verified end-to-end:
empty-library prompt → seed → pick → Add to pool (copies, linked, pooled) → guess scores
5000 on a library-sourced photo. The library is now the primary upload path (iOS fix).
- (Old direct room-upload RPCs `set_pool`/`delete_photo` and `uploadOne` remain defined
  but unused by the new lobby; harmless — can be pruned later.)
- `library_photos`: owned by auth.uid(); truth columns locked exactly like
  `photos` (truth stays RPC-only everywhere); safe view without truth;
  display images under `display/lib/{uid}/`.
- `process-photo` learns a library target — same EXIF strip + truth extract,
  JWT-ownership-checked; originals still deleted after processing.
- **Library is the primary upload destination — not the lobby.** Players
  build their library on their own time before joining a game. No file
  picker in the lobby: it shows only a grid of your library photos to
  select from. This is the key UX win for iOS — users can do the
  Files trick without anyone waiting on them.
  (Note: all iOS browsers — Safari and Chrome alike — are WebKit and share
  the same GPS stripping behaviour; the fix applies to all of them.)
- Edge case: player joins a room with an empty library → lobby shows a
  clear "add photos to your library first" prompt with a link to the
  Library tab, not a dead end.
- Cap ~15 photos/user (free-tier storage). Guest libraries accrue under
  the anon uid and carry over on account upgrade (same as history).
- Max photos per player per game: 5 (matches library cap sanity; host
  stepper now capped at 5 in UI).
- Lobby keeps an "Add photo" button — uploads into the library AND selects
  it for the current room in one step. Same DB design, no second code path.
  The Library tab is for deliberate pre-game building; the lobby button
  keeps the spontaneous party flow alive.
- ⚠️ **NOT YET TESTED end-to-end on a real device.** The GPS extraction
  logic (Files path → HEIC with intact EXIF → exifr.js reads lat/lng →
  uploaded) is in the code and the `gps-check.html` diagnostic tests the
  client-side EXIF read. A full flow test on a real iPhone (Files trick →
  photo in library → added to room → truth stored correctly → revealed
  after guess) is required before relying on it.

### Stage 2 — Scoped scoring ✅ DONE (2026-06-14, RPC + UI verified)
- `rooms.scope` ('world'|'country'|'region'|'city'); host picks at create (segmented
  control). `submit_guess` derives the map-size km server-side from scope
  (world 14,917 · country 2,000 · region 400 · city 40) and scores with it — clients
  can't inflate. Same exponential, smaller km = closer guesses needed.
- Client: scope picker in the create card + a scope label in the lobby. All displayed
  points are already server-authoritative, so no client scoring change was needed.
- Verified: same 10 km guess → 4,967 pts at World vs 410 at City.
- ⬜ Later (deferred, not needed for scoring): reverse-geocode tags/labels
  (city/region/country) for library browsing + auto-suggesting the scope; map
  auto-zoom to the scope area.

### Stage 3 — Public pool (Explore) — STARTED, curated-first (owner decided 2026-06-14)
**✅ Backend done (v1 = curated, no UGC):** `public_photos` table (truth locked) +
`public_photos_safe` view + `guess_public(photo, lat, lng)` RPC (world scope, returns
the answer + score = solo reveal; stateless = no leaderboard yet). RPC + view verified
(scores, truth locked, safe view shows photo+label only). Owner curates via the Supabase
dashboard (insert display_url + truth_lat/lng + label).
**✅ Explore solo-play UI done (2026-06-14):** "Explore solo" on the landing + an
"Explore public photos solo" button on home → a solo run of up to 5 random public photos:
guess on the map → `guess_public` → timed (60s) reveal showing distance + the place label
→ next → finish with total. Reuses the play screen (own `explore.on` route). Empty-state
("pool is being curated") when no photos. Verified end-to-end (render, guess, reveal+label,
score, progression, finish, exit). The pool ships **empty** — owner seeds it.
- **Later (full UGC, deferred):** `library_photos.is_public` opt-in with consent warning
  (strangers see the photo + its exact location after guessing). Publishing requires a
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

## 🔄 Sync mode (live "race the same photo on a clock") — prioritized per owner
This is the closest match to **GeoGuess.com** (the owner's reference): user-photo party
rooms with live, server-clocked rounds + guess-markers appearing in real time. Default
stays async; sync is opt-in.

**✅ S1 — Server round engine (DONE 2026-06-13, fully RPC-tested)**
- `rooms.mode` ('async'|'sync') + round state on the room: `photo_order uuid[]`,
  `round_idx`, `round_phase` ('guessing'|'reveal'), `round_ends_at`.
- `start_game` (sync) shuffles the pool and opens round 0.
- `advance_round(room, from_idx, from_phase)` — idempotent (guarded by from_idx+phase);
  guessing→reveal on timeout OR when every **online** player (≥1) has guessed;
  reveal→next after a 5s window; last round→`finished`.
- `get_round_state` (current photo for all; truth ONLY at reveal) and
  `get_round_guesses` (others' markers, gated so you can't copy before guessing).
- `submit_guess` hardened for sync: only the current round's photo, only during the
  guessing window (blocks reveal-phase / wrong-photo cheats).
- Verified: holds on partial guesses, reveal on all-guessed, round progression, finish,
  truth gating, cheat rejections, no double-advance. (Async path unchanged.)

**✅ S2 — Sync client (DONE 2026-06-13, 2-player browser-tested end-to-end)**
- Host toggles **Relaxed / Live** at room creation (home create card; `#mode-seg`).
- Sync rooms **auto-enter** all players when the host starts (no "Start guessing" tap;
  driven by `refreshLobby` detecting `mode='sync' && status='playing'`).
- Play loop polls `get_round_state` (~1s): renders the current photo, **server-clocked
  countdown** from `round_ends_at`, map guess → `submit_guess` ("locked in"); on reveal
  shows the truth + **everyone's guess markers** (`get_round_guesses`); auto-advances to
  the next photo for all; final shared scoreboard (`record_game` + leaderboard).
- ~1s **watchdog** calls `advance_round` when the phase deadline passes (idempotent).
- Reuses the play DOM + helpers; async path untouched (routed by a `sync.on` flag).
  Verified: auto-enter, countdown, guess/lock-in, reveal card + markers, round
  progression, finish screen — and async play regression-checked (still uses its own
  per-photo timer). Later: Supabase Realtime instead of 1s polling.

**S1 design notes (implemented as above; kept for reference)**
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
