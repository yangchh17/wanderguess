-- ============================================================
--  Storage buckets + policies
--  Run AFTER creating the two buckets in the dashboard:
--    1. "uploads"  — PRIVATE  (originals + display sources; contain GPS!)
--    2. "display"  — PUBLIC   (downsized, EXIF-stripped images clients see)
--  Storage > Create bucket. Make sure "uploads" is NOT public.
-- ============================================================

-- Anon may UPLOAD to the private "uploads" bucket, but may NOT read/list it
-- (originals still contain GPS — only the server reads them).
drop policy if exists "anon upload to uploads" on storage.objects;
create policy "anon upload to uploads"
  on storage.objects for insert to anon
  with check (bucket_id = 'uploads');

-- (No SELECT policy for anon on "uploads" => they cannot download originals.)
-- The "display" bucket is PUBLIC, so its objects are world-readable by URL
-- without any policy. The Edge Function (service_role) writes to it.
