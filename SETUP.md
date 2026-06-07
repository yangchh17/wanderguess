# Wanderguess multiplayer — setup (Steps 1–2)

No local tooling needed (no Docker/Node/CLI). Everything below is the Supabase
**web dashboard** + your existing static files served by python.

## 1. Create a Supabase project
1. Go to https://supabase.com → new project (free tier is fine). Pick a region near you.
2. When it's ready: **Project Settings → API Keys** → **Publishable and secret API keys** tab.
   Copy the **Publishable key** (`sb_publishable_…`). Your **Project URL** is on the
   project home page (e.g. `https://<ref>.supabase.co`).
   - (The Publishable key is the modern replacement for the old "anon" key; it maps to
     the `anon` role, so the RLS policies here apply.)

## 2. Wire the client
1. Edit `config.js`:
   - `url` = your Project URL
   - `anonKey` = your Publishable key (`sb_publishable_…`)

## 3. Create the database schema
1. Dashboard → **SQL Editor** → paste all of `db/schema.sql` → **Run**.

## 4. Create storage buckets
1. Dashboard → **Storage → Create bucket**:
   - `uploads` — **uncheck "Public"** (PRIVATE — originals contain GPS).
   - `display` — **check "Public"**.
2. SQL Editor → paste all of `db/storage.sql` → **Run**.

## 5. Deploy the Edge Function
**Dashboard way (no CLI):**
1. Dashboard → **Edge Functions → Create a function** → name it exactly `process-photo`.
2. Paste the contents of `supabase/functions/process-photo/index.ts` → **Deploy**.

**Secret:** nothing to set. Supabase **auto-injects** `SUPABASE_URL` and
`SUPABASE_SERVICE_ROLE_KEY` into deployed Edge Functions — the function reads them
from the environment automatically. (The service-role key never touches the client.)

## 6. Run the client
From the project folder:
```
python -m http.server 8780 --bind 0.0.0.0
```
On your phone (same Wi-Fi): `http://<your-computer-ip>:8780/app.html`

---

## ✅ CHECKPOINT — verify before building the game loop

Goal: **one photo from one phone flows end-to-end, and the coordinate lives in the
DB, not the client.**

1. On your phone, open `app.html`, enter a name, **Create a room**.
2. In the lobby, **Add photos** → pick one geotagged photo. Watch it go
   `uploading… → extracting location… → ✅ added to the pool`.
   (Pick a non-geotagged one too → it should show `❌ no location data — try another`.)
3. **Truth is in the DB:** Dashboard → **Table Editor → photos**. The row shows
   `status = ready` and real `truth_lat` / `truth_lng`.
4. **Truth is NOT on the client (the important check):**
   - In the phone browser devtools / network tab, confirm the only photo data the
     client fetched is the **display image URL** (public bucket) — no lat/lng.
   - Or run in the browser console:
     ```js
     await sb.from('photos').select('*')          // -> permission denied / empty (RLS)
     await sb.from('photos_public').select('*')   // -> rows WITHOUT truth columns
     ```
   The base `photos` table must be inaccessible; the view returns no coordinates.
5. **Originals are gone:** Storage → `uploads` should be empty for that photo
   (the function deletes originals after extracting the truth).

If all five hold, the trust boundary is real. **Stop here and tell me** — then I'll
build Step 3 (pooled guessing, client + server scoring, shared leaderboard).

---

## Files
- `app.html` — mobile-first client (lobby + upload). Steps 1–2.
- `shared/geo.js` — scoring/distance (reused unchanged; used in Step 3).
- `shared/media.js` — client HEIC→JPEG display-source prep.
- `db/schema.sql` — tables, safe view, RLS.
- `db/storage.sql` — bucket policies.
- `supabase/functions/process-photo/index.ts` — server-side EXIF + strip (trust boundary).
- `config.js` — your Supabase URL + anon key (you create this).
- `gps-check.html` — standalone iOS GPS-survival diagnostic (already used).
- `index.html` — the original single-player prototype (kept for reference).
