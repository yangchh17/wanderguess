# Code Review — request & thread

A shared, async review log between the build agent (Claude) and the reviewer
(Codex). Codex: read the **Context** and **Please review** sections, then append
findings under **Findings (Codex)**. Claude responds under **Responses**.

---

## How to run a review (for the human)
In a terminal at the repo root:
```
codex
```
Then prompt, e.g.: *"Review this repo against REVIEW.md. Focus on the security and
correctness items. Append findings to the 'Findings (Codex)' section."*
(Codex also auto-reads `AGENTS.md` for project context.)

To review only recent changes: `git log --oneline -15` then ask Codex to review a
specific commit range or `git diff`.

---

## Context
- **What it is:** Wanderguess — async multiplayer photo location-guessing game.
- **Architecture:** static client `index.html` (vanilla JS, Leaflet, exifr,
  heic2any) talking to Supabase (Postgres + Storage + Edge Functions).
- **Key files:**
  - `index.html` — the whole client (lobby, upload, guessing, results).
  - `shared/geo.js` — scoring/distance (pure; mirrored server-side).
  - `shared/media.js` — client HEIC→JPEG decode + downscale.
  - `db/schema.sql` — tables, RLS, views, RPCs (the canonical DB definition).
  - `supabase/functions/process-photo/index.ts` — server-side image strip + truth store.
- **Status & plans:** see `ROADMAP.md`.
- **Trust model:** the true coordinate (`photos.truth_lat/lng`) must never reach a
  client until that client has guessed. Clients read the `photos_public` view
  (no truth columns) and the `submit_guess` RPC returns truth only after recording
  a guess. Display images are server-stripped of EXIF.

## Please review (priority order)
1. **Security / trust boundary** — can any client read a photo's truth before
   guessing it? Check RLS, column grants, the `photos_public` view, and every
   `security definer` RPC in `db/schema.sql`.
2. **Known gap (confirm severity):** RPCs accept a client-supplied `player_id`
   with no token check, and `players` ids are readable — so a player in a room
   can act as another (spoof ready/scores/start). Is the proposed fix (require
   `players.token`) sufficient? Any other spoofing vectors?
3. **Correctness** — scoring parity between `shared/geo.js` and the SQL in
   `submit_guess`; the rematch/`game_seq` guess-memory logic; presence/online.
4. **`security definer` functions** — search_path pinning, privilege scope,
   injection surface.
5. **Anything that would break a real multiplayer session.**

## Findings (Codex)
<!-- Codex: append findings here. Use: [severity] file:area — issue → suggestion -->
_(none yet)_

## Responses (Claude)
<!-- Claude addresses each finding here, with the commit that fixes it. -->
_(none yet)_
