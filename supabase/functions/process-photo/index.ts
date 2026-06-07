// ============================================================
//  Edge Function: process-photo  (Deno)
//  THE TRUST BOUNDARY LIVES HERE.
//  - Reads EXIF GPS from the ORIGINAL (server-side authority).
//  - Writes the truth coordinate to the DB (never returned to client).
//  - Produces a downsized, EXIF-STRIPPED display image in the public bucket.
//  - Response NEVER contains coordinates.
//
//  Deploy via the Supabase dashboard (Edge Functions > new function),
//  or `supabase functions deploy process-photo`.
//  Required secret: SUPABASE_SERVICE_ROLE_KEY (SUPABASE_URL is auto-provided).
// ============================================================

import { createClient } from "jsr:@supabase/supabase-js@2";
import exifr from "npm:exifr@7.1.3";
import { Image } from "https://deno.land/x/imagescript@1.2.17/mod.ts";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...cors, "Content-Type": "application/json" },
  });

const MAX_DIM = 1280;
const NO_GPS_MSG = "no location data in this photo — try another";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "POST only" }, 405);

  try {
    const { roomId, uploaderId, photoId, originalPath, displaySrcPath } = await req.json();
    if (!roomId || !uploaderId || !photoId || !originalPath || !displaySrcPath) {
      return json({ error: "missing fields" }, 400);
    }

    const admin = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    );

    // Basic sanity: uploader belongs to the room.
    const { data: player } = await admin
      .from("players").select("id").eq("id", uploaderId).eq("room_id", roomId).maybeSingle();
    if (!player) return json({ error: "invalid uploader/room" }, 403);

    // 1) Download ORIGINAL and read the TRUTH (server-side; works on HEIC bytes).
    const orig = await admin.storage.from("uploads").download(originalPath);
    if (orig.error || !orig.data) return json({ error: "original not found" }, 404);
    const origBuf = new Uint8Array(await orig.data.arrayBuffer());

    let gps: { latitude?: number; longitude?: number } | undefined;
    try { gps = await exifr.gps(origBuf); } catch { /* treated as no-GPS */ }

    if (!gps || gps.latitude == null || gps.longitude == null) {
      await admin.from("photos").upsert({
        id: photoId, room_id: roomId, uploader_id: uploaderId,
        status: "rejected", error: NO_GPS_MSG,
      });
      await admin.storage.from("uploads").remove([originalPath, displaySrcPath]);
      return json({ status: "rejected", error: NO_GPS_MSG }, 200);
    }

    // 2) Produce downsized, EXIF-STRIPPED display image (re-encode drops metadata).
    const src = await admin.storage.from("uploads").download(displaySrcPath);
    if (src.error || !src.data) return json({ error: "display source not found" }, 404);
    const img = await Image.decode(new Uint8Array(await src.data.arrayBuffer()));
    if (Math.max(img.width, img.height) > MAX_DIM) {
      if (img.width >= img.height) img.resize(MAX_DIM, Image.RESIZE_AUTO);
      else img.resize(Image.RESIZE_AUTO, MAX_DIM);
    }
    const jpeg = await img.encodeJPEG(80);

    const displayKey = `${roomId}/${photoId}.jpg`;
    const up = await admin.storage.from("display")
      .upload(displayKey, jpeg, { contentType: "image/jpeg", upsert: true });
    if (up.error) return json({ error: up.error.message }, 500);
    const { data: pub } = admin.storage.from("display").getPublicUrl(displayKey);

    // 3) Persist truth + display URL; mark ready.
    const { error: upErr } = await admin.from("photos").upsert({
      id: photoId, room_id: roomId, uploader_id: uploaderId,
      status: "ready", display_url: pub.publicUrl,
      truth_lat: gps.latitude, truth_lng: gps.longitude, error: null,
    });
    if (upErr) return json({ error: upErr.message }, 500);

    // Originals contain GPS — remove them now that the truth is in the DB.
    await admin.storage.from("uploads").remove([originalPath, displaySrcPath]);

    // NOTE: no coordinates in the response.
    return json({ status: "ready", displayUrl: pub.publicUrl }, 200);
  } catch (e) {
    return json({ error: String(e) }, 500);
  }
});
