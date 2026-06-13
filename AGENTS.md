# AGENTS.md — context for AI agents (Codex, Claude, etc.)

**Wanderguess** is an async multiplayer photo location-guessing game: a static
client (`index.html`, vanilla JS + Leaflet + exifr + heic2any) on Cloudflare
Workers static assets, backed by Supabase (Postgres + Storage + Edge Functions).

## Start here
- **`HANDOFF.md` — READ FIRST if you are a Claude session.** Two Claude sessions
  edit this repo one at a time; HANDOFF.md is the running cross-session log (pull on
  arrival, append on finish). It also has the current module map.
- `ROADMAP.md` — status, what's next, and feature plans (the committed staged plan).
- `REVIEW.md` — the review request + shared findings thread. If asked to review,
  follow it and append to "Findings (Codex)".
- `db/schema.sql` — canonical DB (tables, RLS, views, RPCs).
- **Client (split into ES modules — no build step):**
  - `index.html` — markup, CSS, and the inline module = the **game core** (identity,
    home, lobby, upload, pin map, play, results, zoom, reveal).
  - `js/core.js` — singleton shared primitives (`$`, `show`, `sb`, `ensureAuth`,
    `escapeHtml`); every importer uses the same `core.js?v=1` specifier.
  - `js/account.js` (account + stats/history) · `js/feedback.js` (suggestion box) ·
    `js/ui.js` (toast, copy/share, steppers, time pills, help).
  - `shared/geo.js` (scoring) · `shared/media.js` (HEIC/downscale).
  - `solo.html` is an old single-player prototype.

## Conventions
- **Trust boundary (critical):** `photos.truth_lat/lng` must never reach a client
  before that client guesses. Clients use the `photos_public` view + RPCs; truth
  comes only from `submit_guess` after a guess is recorded. Don't weaken this.
- DB changes go in `db/schema.sql` AND are applied as Supabase migrations.
- No build step; the client is plain ES modules. Keep it dependency-light.
- Don't commit secrets. The publishable Supabase key in `config.js` is public by
  design; the service-role key lives only in Supabase (auto-injected to functions).
- Don't commit personal data (`photoset/` is gitignored) or local tooling
  (`.claude/`, `.codex/`).

## Verifying changes
- Schema/RPC logic: test via SQL/RPC against the live Supabase project.
- Client: serve statically and load `index.html`.
