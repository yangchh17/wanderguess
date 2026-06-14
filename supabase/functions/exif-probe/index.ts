// exif-probe (experiment) — fetch an image URL server-side and read its EXIF GPS.
// This bypasses the iOS Photos-picker stripping entirely (the phone is never involved).
// Returns the geotag if the *host* preserved EXIF (file-storage links usually do;
// image CDNs / social usually strip). verify_jwt = true (authed callers only).
// NOTE: server-side fetch of arbitrary URLs is an SSRF surface — we block local/private
// hosts here; tighten further (DNS-rebind, redirects to private IPs) before shipping.
import exifr from "https://esm.sh/exifr@7.1.3";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (b: unknown, s = 200) =>
  new Response(JSON.stringify(b), { status: s, headers: { ...cors, "Content-Type": "application/json" } });

const MAX_BYTES = 25 * 1024 * 1024;

function blockedHost(host: string): boolean {
  host = host.toLowerCase();
  if (host === "localhost" || host.endsWith(".local") || host.endsWith(".internal")) return true;
  // IPv4 private / loopback / link-local ranges
  if (/^127\./.test(host) || /^10\./.test(host) || /^192\.168\./.test(host)) return true;
  if (/^169\.254\./.test(host)) return true;
  if (/^172\.(1[6-9]|2\d|3[01])\./.test(host)) return true;
  if (host === "0.0.0.0" || host === "::1" || host.startsWith("[")) return true;
  return false;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "POST only" }, 405);
  try {
    const { url } = await req.json();
    if (typeof url !== "string") return json({ error: "missing url" }, 400);
    let u: URL;
    try { u = new URL(url); } catch { return json({ error: "invalid url" }, 400); }
    if (u.protocol !== "http:" && u.protocol !== "https:") return json({ error: "http(s) only" }, 400);
    if (blockedHost(u.hostname)) return json({ error: "blocked host" }, 400);

    const ctrl = new AbortController();
    const timer = setTimeout(() => ctrl.abort(), 12000);
    let r: Response;
    try { r = await fetch(u.toString(), { redirect: "follow", signal: ctrl.signal }); }
    finally { clearTimeout(timer); }
    if (!r.ok) return json({ error: `fetch failed (${r.status})` }, 400);

    const len = Number(r.headers.get("content-length") || 0);
    if (len && len > MAX_BYTES) return json({ error: "file too large" }, 400);
    const buf = new Uint8Array(await r.arrayBuffer());
    if (buf.length > MAX_BYTES) return json({ error: "file too large" }, 400);

    let gps: { latitude?: number; longitude?: number } | undefined;
    try { gps = await exifr.gps(buf); } catch (_e) { gps = undefined; }
    const has = !!(gps && gps.latitude != null && gps.longitude != null);

    return json({
      ok: true,
      finalUrl: r.url,
      contentType: r.headers.get("content-type"),
      bytes: buf.length,
      hasGps: has,
      lat: has ? gps!.latitude : null,
      lng: has ? gps!.longitude : null,
    });
  } catch (e) {
    return json({ error: String(e) }, 500);
  }
});
