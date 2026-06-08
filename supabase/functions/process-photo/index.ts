// process-photo (v7 — anon-auth: verify caller owns the uploader player)
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

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "POST only" }, 405);
  try {
    const { roomId, uploaderId, photoId, srcPath, lat, lng } = await req.json();
    if (!roomId || !uploaderId || !photoId || !srcPath)
      return json({ error: "missing fields" }, 400);
    if (typeof srcPath !== "string" || !srcPath.startsWith(`${roomId}/`))
      return json({ error: "bad source path" }, 400);

    const nlat = Number(lat), nlng = Number(lng);
    if (!Number.isFinite(nlat) || !Number.isFinite(nlng) ||
        nlat < -90 || nlat > 90 || nlng < -180 || nlng > 180)
      return json({ error: "missing or invalid coordinate" }, 400);

    // Identify the caller from their JWT (anon-auth) and verify they own the uploader.
    const authHeader = req.headers.get("Authorization") || "";
    const userClient = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!,
      { global: { headers: { Authorization: authHeader } } });
    const { data: u } = await userClient.auth.getUser();
    const uid = u && u.user ? u.user.id : null;
    if (!uid) return json({ error: "not authenticated" }, 401);

    const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
    const { data: player } = await admin.from("players").select("id")
      .eq("id", uploaderId).eq("room_id", roomId).eq("user_id", uid).maybeSingle();
    if (!player) return json({ error: "not your player for this room" }, 403);

    const src = await admin.storage.from("uploads").download(srcPath);
    if (src.error || !src.data) return json({ error: "source not found" }, 404);
    let jpeg: Uint8Array;
    try {
      const img = await Image.decode(new Uint8Array(await src.data.arrayBuffer()));
      if (Math.max(img.width, img.height) > MAX_DIM) {
        if (img.width >= img.height) img.resize(MAX_DIM, Image.RESIZE_AUTO);
        else img.resize(Image.RESIZE_AUTO, MAX_DIM);
      }
      jpeg = await img.encodeJPEG(80);
    } catch (_e) {
      await admin.from("photos").upsert({ id: photoId, room_id: roomId, uploader_id: uploaderId, status: "rejected", error: "could not process image" });
      await admin.storage.from("uploads").remove([srcPath]);
      return json({ status: "rejected", error: "could not process this image" }, 200);
    }

    const displayKey = `${roomId}/${photoId}.jpg`;
    const up = await admin.storage.from("display").upload(displayKey, jpeg, { contentType: "image/jpeg", upsert: true });
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
