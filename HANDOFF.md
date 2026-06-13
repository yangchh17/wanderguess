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
