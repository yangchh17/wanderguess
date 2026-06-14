# HANDOFF — shared log between the two Claude sessions

Two Claude sessions work on this repo **one at a time** (a local terminal session
and a browser/cloud session) — never simultaneously. This file is how we hand off:
read it when you start, append an entry when you finish, so the next session knows
what changed and what's safe to touch.

## Working agreement
1. **On arrival:** `git fetch && git pull`, then read the latest entries below.
2. **On finishing a unit of work:** append a dated entry (newest at the top of the
   Log), update `ROADMAP.md`, then `git commit` + `git push origin main`.
3. **Don't rewrite the other session's entries** — only append your own.
4. One session, one push at a time. If `git push` is rejected, pull/rebase first.
5. Keep entries short: what changed · why · what's next · anything the next
   session must NOT break.

## Current architecture (read this — it changed 2026-06-13)
The client is **no longer one big `index.html` script.** It was split into ES
modules (no build step) to stop the two of us colliding on one file:

- `index.html` — markup, CSS, and the **inline `<script type="module">` = the game
  core only** (identity/session, home, lobby, upload, pin-map, play/guessing,
  results map, zoom/pan, reveal). It imports primitives from `js/core.js`.
- `js/core.js` — **singleton** shared primitives: `$`, `show`, `sb` (the one
  Supabase client), `ensureAuth` (memoized anon auth), `escapeHtml`. ⚠️ Every
  importer must use the **same specifier** `./...core.js?v=1` or you get a second
  `sb`/auth. Inline uses `./js/core.js?v=1`; the js/ modules use `./core.js?v=1`.
- `js/account.js` — account upgrade (anon→permanent), sign in/out, the
  Profile/stats/history screen. Sign-in/out do `location.reload()`.
- `js/feedback.js` — the suggestion box.
- `js/ui.js` — toast, copy/share invite, host-setup steppers + time pills,
  score-pop, how-to-play overlay. (Self-contained; reads the DOM only.)

**Where to edit what:** game/lobby/play → inline module in `index.html`. Account
or stats → `js/account.js`. Feedback → `js/feedback.js`. Buttons/toasts/help →
`js/ui.js`. Shared helpers used by several → `js/core.js`. Shared pure logic stays
in `shared/geo.js` (scoring) and `shared/media.js` (HEIC/downscale).

DB is canonical in `db/schema.sql` and applied as Supabase migrations.

---

## Log (newest first)

### 2026-06-13 (later 6) — local session (Claude)
- **Library tab shipped** (Stage 1 client slice 1). Tab bar is now **Play · Library ·
  Profile** (`js/nav.js` handles the 3rd tab via a `wg:open-library` event). New
  `s-library` screen + library logic in the inline module: `loadLibrary`/`renderLibrary`
  (reads `library_public`), `uploadToLibrary` (reuses `makeDisplaySource`/exifr/
  `pickLocationOnMap`, calls process-photo `target:'library'`, `lib/{uid}/{id}.src`),
  delete via `delete_library_photo`, `N / 15` count. `getUid()` caches the JWT uid.
  Verified in-browser: 3 tabs, navigate, empty state, real upload→process→renders, delete.
- Gameplay still uses the OLD lobby file-picker → room flow (unchanged). The library is
  not wired into rooms yet.
- **NEXT (Stage 1 slice 2 — wire library → room):** add `add_library_to_room(p_player_id,
  p_lib_ids[])` (copies chosen `library_photos` rows into the room's `photos`, truth
  preserved server-side, capped at `photos_per_player`), then change the lobby "Your
  photos" card to pick from the library grid instead of a file picker (keep a quick "add
  photo" that uploads to library AND selects it). That makes the library the primary
  upload path and finishes the iOS fix.

### 2026-06-13 (later 5) — local session (Claude)
- **Stage 1 backend (personal library) shipped + edge/RPC-tested.** Migrations live;
  no client UI yet (gameplay unchanged — old direct-upload flow still in use).
  - `library_photos` table (owner-only RLS, truth locked) + `library_public` view +
    `delete_library_photo` RPC. In `db/schema.sql` under "PERSONAL LIBRARY".
  - **process-photo v9** (deployed): adds `target:'library'` — writes to
    `library_photos` for the JWT uid, `lib/{uid}/{photoId}.src` srcPath pinned,
    display under `display/lib/{uid}/`, 15-photo cap, ownership-guarded. Room path
    unchanged (factored the decode into `downloadAndEncode`). Local file synced.
  - Verified end-to-end (generated image → upload → process → ready; truth locked;
    cross-user can't see/delete; owner delete works).
  - Note: `uploads` bucket INSERT policy is just `bucket_id='uploads'` (no path
    restriction), so `lib/{uid}/` uploads work without a new policy.
- **NEXT (Stage 1 client, 2 slices):** (1) a **Library tab** (3rd tab: Play · Library ·
  Profile) to upload/manage your library — reuse the existing upload pipeline
  (`makeDisplaySource`, exifr GPS, `pickLocationOnMap`) but call process-photo with
  `target:'library'` and srcPath `lib/{uid}/{id}.src`. (2) `add_library_to_room` RPC
  (copies chosen library rows → room `photos`, truth preserved server-side, capped at
  photos_per_player) + change the lobby to pick from the library grid instead of a file
  picker. Keep an "add photo" that uploads to library AND selects it in one step.

### 2026-06-13 (later 4) — local session (Claude)
- **Sync mode S2 (the live client) shipped + 2-player browser-tested.** Sync is now
  fully playable end-to-end. Changes (all in `index.html` inline module + `js/ui.js`):
  - Home create card: a **Relaxed / Live** toggle (`#mode-seg`, hidden `#mode`); create
    handler sets `rooms.mode` (and defaults a 60s clock if "No limit" + sync).
  - New sync controller (in the inline module): `sync` state + `enterSyncPlay`,
    `syncTick` (polls `get_round_state` ~1s), `renderSyncRound`, `syncMapClick`,
    `syncConfirm`, `revealSyncRound` (truth + everyone's markers via `get_round_guesses`),
    `finishSync`, plus a `~1s advance_round` watchdog.
  - Shared play handlers are **routed by a `sync.on` flag**: the gmap click, `#g-confirm`,
    `#g-exit`, and the zoom guards (`inGuessPhase()`) work for both modes. Async path is
    unchanged and was regression-tested (still uses its own per-photo timer).
  - `refreshLobby` reads `mode`, **auto-enters** sync for everyone on host-start, hides
    "Start guessing" in sync, and shows sync/finished step text. `reset_room` now clears
    round state (migration live + in `db/schema.sql`).
- ⚠️ Testing note: the reveal phase is only ~5s, so DOM polls often "miss" it — it does
  render (caught it showing truth/markers/"Out of time"). Don't mistake a missed poll
  for a bug.
- **NEXT options:** Stage 1 (personal library) per the committed plan; OR sync polish
  (Supabase Realtime instead of 1s polling; nicer between-round summary; live marker
  count). Owner away ~2 days; continuing autonomously.

### 2026-06-13 (later 3) — local session (Claude)
- **Sync mode S1 (server round engine) shipped + fully RPC-tested.** This is the
  GeoGuess.com-aligned headline feature. DB migrations are LIVE (async unaffected):
  - `rooms` gained `mode` ('async'|'sync'), `photo_order uuid[]`, `round_idx`,
    `round_phase` ('guessing'|'reveal'), `round_ends_at`.
  - New RPCs: `advance_round(room,from_idx,from_phase)` (idempotent state machine),
    `get_round_state` (truth only at reveal), `get_round_guesses` (markers, copy-gated).
    `start_game` + `submit_guess` extended for sync (sync guards block reveal/wrong-photo
    cheats). All in `db/schema.sql` under "SYNC MODE".
  - ⚠️ plpgsql gotcha hit & fixed: `RETURNS TABLE` output names shadow `rooms` columns →
    qualify every column with the table alias (`r.round_idx`, etc.).
  - ⚠️ logic fix: "all guessed → reveal" must require ≥1 ONLINE player, else it's
    vacuously true when everyone's `last_seen` is stale and fast-forwards the game.
- **No client changes yet** — the deployed app is unchanged; sync is invisible until S2.
- **NEXT: S2 — the sync client** (host toggle at create; round-driven play loop with
  server-time countdown, live markers at reveal, ~1s `advance_round` watchdog). See
  ROADMAP "Sync mode → S2".

### 2026-06-13 (later 2) — local session (Claude)
- **Guided lobby shipped.** Reordered the lobby (invite → add photos → ready/start →
  players → leaderboard) and added a **state-driven "next step" banner** (`#lobby-step`,
  set in `refreshLobby`): 1 Add photos → 2 Ready → 3 Start/waiting → ▶ Game on. All IDs
  preserved; verified the banner advances through each state.
- **Competitive note:** owner says **GeoGuess.com** is closest to the vision. It's
  user-photo party rooms with **real-time rounds** — you watch friends' guess markers
  appear live on the map, round by round (scoring ~50 km→5000 out to ~2000 km, i.e.
  scoped). So the **headline gap is live/SYNC multiplayer** (we're async). That's the
  big next feature — see ROADMAP "Parallel track — Sync mode". Strong candidate for the
  next major build; live guess-markers is the signature feel to copy.
- **Next:** likely start **sync mode** (server round engine: `rooms.mode`, round
  timestamps, idempotent `advance_round`) per the roadmap — OR Stage 1 library. Owner
  away ~2 days; continuing autonomously.

### 2026-06-13 (later) — local session (Claude)
- **Stage 0 bottom tab bar shipped** (Play · Profile). New file **`js/nav.js`** owns
  it; the active indicator auto-syncs to the visible `.screen` via a MutationObserver.
- **Home decluttered:** the account card + suggestion box moved OUT of `s-home` and
  INTO `s-profile` (the Profile tab). Home is now just name → Create / Join (+ rejoin).
  ⚠️ If you edit account/stats/feedback markup, it now lives in the **`s-profile`**
  section, not `s-home`.
- `js/account.js`: removed the `btn-stats`/`prof-back` buttons (the tab bar navigates
  now); profile opens via a `window` event `wg:open-profile` that nav.js dispatches.
- **Competitive research** done — see the new "Competitive landscape & positioning"
  section in `ROADMAP.md`. TL;DR: concept isn't novel (loveguessr/PhotoGuessr, Whereez,
  GeoGuess do it); our wedge is **group/party shared-pool multiplayer** — frame future
  social/library work around *groups*, not solo memories.
- **Next:** the **guided lobby** (still a 5-card scroll → make it a clear next-step
  flow), then Stage 1 (personal library). The owner is away ~2 days; this session is
  continuing autonomously.
- **Don't break:** single-core-instance rule (`core.js?v=1` everywhere); trust boundary.

### 2026-06-13 — local session (Claude) — commit 6d85c88
- **Did the module split** (Stage 0 groundwork from the committed plan): extracted
  `js/core.js`, `js/account.js`, `js/feedback.js`, `js/ui.js` from `index.html`'s
  inline script. The inline module is now just the game core. See "Current
  architecture" above — **this is the big thing to absorb.**
- Aligned `ppp` cap to **5** in the create-room handler (UI already capped; finished
  your cap-at-5 change).
- Verified in-browser: clean load, create room → lobby + roster, leave, My-stats,
  back — all working across modules with a single shared core.
- **Next up (Stage 0 remaining):** the bottom **tab bar** (Play · Library ·
  Profile). Not started yet — whoever takes it: it restructures `index.html`
  markup + how screens show/hide (`show()` in `js/core.js`). Then **Stage 1
  (personal library)**.
- **Don't break:** the single-core-instance rule (consistent `?v=1` specifier);
  the trust boundary (truth never to clients pre-guess).

### (earlier) — context
Recent shipped work before the split (all on `main`): UI redesign (glassy theme,
Copy/Share, medal leaderboard), GeoGuessr-style play (photo zoom/pan, animated
reveal, keyboard), and accounts/history/scoreboards (`game_results` + `record_game`
/ `get_my_stats` / `get_my_history`). The browser/cloud session added: how-to-play
overlay, antimeridian + results-map fixes, the suggestion box, and the **committed
staged plan** in `ROADMAP.md` (Stage 0 tab bar → Stage 1 library → Stage 2 scoped
scoring; Stage 3 public pool deferred; sync mode parallel track).

> Owner action still pending: to make email+password signup instant, turn OFF
> Supabase → Auth → Email → "Confirm email" (currently ON + rate-limited test
> mailer), or set custom SMTP. History/stats work regardless.
