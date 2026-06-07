// ============================================================
//  Client-side media helpers (display-source production).
//  The TRUTH is read server-side from the original; these only
//  prepare a displayable JPEG so the server never decodes HEIC.
// ============================================================

export function isHeic(file) {
  return /heic|heif/i.test(file.type) || /\.(heic|heif)$/i.test(file.name);
}

let _heic2any = null;
function loadHeic2any() {
  if (_heic2any) return Promise.resolve(_heic2any);
  return new Promise((res, rej) => {
    const s = document.createElement('script');
    s.src = 'vendor/heic2any.js';
    s.onload = () => { _heic2any = window.heic2any; res(_heic2any); };
    s.onerror = rej;
    document.head.appendChild(s);
  });
}

/** Decode a HEIC File to a JPEG Blob (browser can't render HEIC natively). */
export async function heicToJpeg(file, quality = 0.85) {
  const h2a = await loadHeic2any();
  return h2a({ blob: file, toType: 'image/jpeg', quality });
}

/**
 * Produce a display-source file for upload:
 *  - HEIC  -> decoded JPEG Blob (so the server can process it)
 *  - other -> the original file unchanged (server re-encodes/strips it)
 * The server downsizes + strips EXIF regardless, so this is just "make it JPEG".
 */
export async function makeDisplaySource(file) {
  if (isHeic(file)) {
    const blob = await heicToJpeg(file);
    return { blob, contentType: 'image/jpeg', ext: 'jpg' };
  }
  return { blob: file, contentType: file.type || 'application/octet-stream', ext: 'bin' };
}
