# Wanderguess

A mobile-first, async multiplayer location-guessing game built from **your own photos**.
A group joins a shared lobby, everyone uploads a couple of geotagged photos from their
phone, and players guess where each other's photos were taken — scored by distance.

No accounts. No native app (yet). Vanilla JS + Leaflet on the front end, Supabase
(Postgres + Storage + Edge Functions) on the back.

## How it works
- **Lobby** — a host creates a room and gets a short code; others join by typing it.
- **Upload** — each player adds 1–2 photos from their phone.
- **Trust boundary** — the true coordinate is stored server-side and **withheld from
  other players** until they submit a guess; the displayed image is downsized and
  **EXIF-stripped** so guessers can't read coordinates off the photo.
- **Scoring** — GeoGuessr-style exponential score (5000 max per round) via shared pure
  functions (`shared/geo.js`), run client-side for instant feedback and server-side as
  the authority.

## Project layout
| Path | What |
|------|------|
| `app.html` | Mobile-first multiplayer client (lobby + upload). |
| `index.html` | Original single-player prototype (reference). |
| `shared/geo.js` | Distance + scoring (pure, reusable). |
| `shared/media.js` | Client HEIC→JPEG display-source prep. |
| `db/schema.sql` | Tables, safe view, RLS, column grants. |
| `db/storage.sql` | Storage bucket policies. |
| `supabase/functions/process-photo/` | Edge Function: truth + EXIF-stripped display image. |
| `gps-check.html` | Standalone diagnostic for EXIF GPS survival on mobile. |
| `SETUP.md` | Full Supabase setup + checkpoint. |

## Setup
See [`SETUP.md`](./SETUP.md). In short: create a Supabase project, copy
`config.example.js` → `config.js` with your URL + publishable key, run `db/schema.sql`
and `db/storage.sql`, deploy the `process-photo` Edge Function, then serve the static
files (e.g. `python -m http.server`).

## Known issue (open)
Auto-locating photos from EXIF on **iOS Safari** is unreliable — iOS strips the GPS
block from photos handed to web pages (other EXIF survives), so the coordinate often
never reaches the browser or server. Reliable photo auto-location appears to require a
native/PWA path with Photos permission (the route apps like Instagram use). A manual
map-pin is the web fallback.

## Status
Lobby + upload + server-side processing + trust boundary are built and verified.
Pooled guessing, scoring, and the shared leaderboard are the next step.
