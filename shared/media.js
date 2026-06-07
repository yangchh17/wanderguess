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
 * Produce a downscaled, EXIF-stripped JPEG for upload.
 * Decodes (HEIC via heic2any, else native), draws to a canvas capped at `maxDim`,
 * and re-encodes to JPEG. Keeping it small on the client means the server never
 * has to decode a full 12MP image (which was OOM-ing the Edge Function), and
 * uploads are far faster on mobile. The canvas re-encode also drops all EXIF.
 */
export async function makeDisplaySource(file, maxDim = 1280, quality = 0.82) {
  let srcBlob = file;
  if (isHeic(file)) srcBlob = await heicToJpeg(file);

  const url = URL.createObjectURL(srcBlob);
  try {
    const img = await new Promise((res, rej) => {
      const im = new Image();
      im.onload = () => res(im);
      im.onerror = () => rej(new Error('image decode failed'));
      im.src = url;
    });
    let w = img.naturalWidth, h = img.naturalHeight;
    if (!w || !h) throw new Error('empty image');
    if (Math.max(w, h) > maxDim) {
      const s = maxDim / Math.max(w, h);
      w = Math.round(w * s); h = Math.round(h * s);
    }
    const canvas = document.createElement('canvas');
    canvas.width = w; canvas.height = h;
    canvas.getContext('2d').drawImage(img, 0, 0, w, h);
    const blob = await new Promise((res, rej) =>
      canvas.toBlob(b => b ? res(b) : rej(new Error('toBlob failed')), 'image/jpeg', quality));
    return { blob, contentType: 'image/jpeg', ext: 'jpg' };
  } finally {
    URL.revokeObjectURL(url);
  }
}
