// process-photo (v9 — room photos OR personal library; truth stays server-side)
// target='room'    : strip+store into photos for a room (caller owns the player + photoId).
// target='library' : strip+store into the caller's personal library_photos (uid from JWT).
import { createClient } from "jsr:@supabase/supabase-js@2";
import { Image } from "https://deno.land/x/imagescript@1.2.17/mod.ts";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

const MAX_DIM = 1280;
const LIBRARY_CAP = 15;

// deno-lint-ignore no-explicit-any
async function downloadAndEncode(admin: any, srcPath: string): Promise<{ jpeg?: Uint8Array; err?: string; rejected?: boolean }> {
  const src = await admin.storage.from("uploads").download(srcPath);
  if (src.error || !src.data) return { err: "source not found" };
  try {
    const img = await Image.decode(new Uint8Array(await src.data.arrayBuffer()));
    if (Math.max(img.width, img.height) > MAX_DIM) {
      if (img.width >= img.height) img.resize(MAX_DIM, Image.RESIZE_AUTO);
      else img.resize(Image.RESIZE_AUTO, MAX_DIM);
    }
    return { jpeg: await img.encodeJPEG(80) };
  } catch (_e) {
    return { rejected: true };
  }
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "POST only" }, 405);
  try {
    const body = await req.json();
    const target = body.target === "library" ? "library" : "room";
    const { photoId, srcPath, lat, lng } = body;
    if (!photoId || !srcPath) return json({ error: "missing fields" }, 400);

    const nlat = Number(lat), nlng = Number(lng);
    if (!Number.isFinite(nlat) || !Number.isFinite(nlng) ||
        nlat < -90 || nlat > 90 || nlng < -180 || nlng > 180)
      return json({ error: "missing or invalid coordinate" }, 400);

    // Identify the caller from their JWT (anon-auth).
    const authHeader = req.headers.get("Authorization") || "";
    const userClient = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!,
      { global: { headers: { Authorization: authHeader } } });
    const { data: u } = await userClient.auth.getUser();
    const uid = u && u.user ? u.user.id : null;
    if (!uid) return json({ error: "not authenticated" }, 401);

    const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

    // ───────────── Personal library ─────────────
    if (target === "library") {
      if (typeof srcPath !== "string" || srcPath !== `lib/${uid}/${photoId}.src`)
        return json({ error: "bad source path" }, 400);
      const { data: existing } = await admin.from("library_photos").select("user_id").eq("id", photoId).maybeSingle();
      if (existing && existing.user_id !== uid) return json({ error: "not your photo" }, 403);
      if (!existing) {
        const { count } = await admin.from("library_photos").select("id", { count: "exact", head: true }).eq("user_id", uid);
        if ((count ?? 0) >= LIBRARY_CAP) return json({ error: `library is full (${LIBRARY_CAP} max)` }, 403);
      }

      const enc = await downloadAndEncode(admin, srcPath);
      if (enc.err) return json({ error: enc.err }, 404);
      if (enc.rejected) {
        await admin.from("library_photos").upsert({ id: photoId, user_id: uid, status: "rejected", error: "could not process image" });
        await admin.storage.from("uploads").remove([srcPath]);
        return json({ status: "rejected", error: "could not process this image" }, 200);
      }

      const displayKey = `lib/${uid}/${photoId}.jpg`;
      const up = await admin.storage.from("display").upload(displayKey, enc.jpeg!, { contentType: "image/jpeg", upsert: true });
      if (up.error) return json({ error: up.error.message }, 500);
      const { data: pub } = admin.storage.from("display").getPublicUrl(displayKey);

      const { error: upErr } = await admin.from("library_photos").upsert({
        id: photoId, user_id: uid, status: "ready", display_url: pub.publicUrl,
        truth_lat: nlat, truth_lng: nlng, error: null,
      });
      if (upErr) return json({ error: upErr.message }, 500);
      await admin.storage.from("uploads").remove([srcPath]);
      return json({ status: "ready", displayUrl: pub.publicUrl }, 200);
    }

    // ───────────── Room photo (v8 behaviour) ─────────────
    const { roomId, uploaderId } = body;
    if (!roomId || !uploaderId) return json({ error: "missing fields" }, 400);
    if (typeof srcPath !== "string" || srcPath !== `${roomId}/${photoId}.src`)
      return json({ error: "bad source path" }, 400);

    const { data: player } = await admin.from("players").select("id")
      .eq("id", uploaderId).eq("room_id", roomId).eq("user_id", uid).maybeSingle();
    if (!player) return json({ error: "not your player for this room" }, 403);

    const { data: existing } = await admin.from("photos")
      .select("uploader_id, room_id").eq("id", photoId).maybeSingle();
    if (existing && (existing.uploader_id !== uploaderId || existing.room_id !== roomId))
      return json({ error: "not your photo" }, 403);

    const enc = await downloadAndEncode(admin, srcPath);
    if (enc.err) return json({ error: enc.err }, 404);
    if (enc.rejected) {
      await admin.from("photos").upsert({ id: photoId, room_id: roomId, uploader_id: uploaderId, status: "rejected", error: "could not process image" });
      await admin.storage.from("uploads").remove([srcPath]);
      return json({ status: "rejected", error: "could not process this image" }, 200);
    }

    const displayKey = `${roomId}/${photoId}.jpg`;
    const up = await admin.storage.from("display").upload(displayKey, enc.jpeg!, { contentType: "image/jpeg", upsert: true });
    if (up.error) return json({ error: up.error.message }, 500);
    const { data: pub } = admin.storage.from("display").getPublicUrl(displayKey);

    const { error: upErr } = await admin.from("photos").upsert({
      id: photoId, room_id: roomId, uploader_id: uploaderId,
      status: "ready", display_url: pub.publicUrl, truth_lat: nlat, truth_lng: nlng, error: null,
    });
    if (upErr) return json({ error: upErr.message }, 500);
    await admin.storage.from("uploads").remove([srcPath]);
    return json({ status: "ready", displayUrl: pub.publicUrl }, 200);
  } catch (e) {
    return json({ error: String(e) }, 500);
  }
});
