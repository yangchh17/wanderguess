// ============================================================
//  Shared pure-logic module — reused on client AND server.
//  These are the ORIGINAL functions from the single-player
//  prototype, lifted out unchanged. Do not rewrite the math.
// ============================================================

export const MAP_SIZE_KM = 14916.862; // GeoGuessr standard world map diagonal

/** Haversine distance in km between two {lat,lng}. */
export function haversineKm(a, b) {
  const R = 6371, toRad = d => d * Math.PI / 180;
  const dLat = toRad(b.lat - a.lat), dLng = toRad(b.lng - a.lng);
  const h = Math.sin(dLat / 2) ** 2 +
            Math.cos(toRad(a.lat)) * Math.cos(toRad(b.lat)) * Math.sin(dLng / 2) ** 2;
  return R * 2 * Math.asin(Math.sqrt(h));
}

/** GeoGuessr exponential score from a distance (km). Max 5000. */
export function pointsFromDistance(distanceKm, mapSizeKm = MAP_SIZE_KM) {
  return Math.round(5000 * Math.exp(-10 * distanceKm / mapSizeKm));
}

/** Score a guess against truth. Returns {distanceKm, points}. */
export function scoreGuess(truth, guess) {
  const distanceKm = haversineKm(truth, guess);
  return { distanceKm, points: pointsFromDistance(distanceKm) };
}

/** Human-friendly distance formatting. */
export function formatKm(km) {
  if (km < 1) return `${Math.round(km * 1000)} m`;
  if (km < 100) return `${km.toFixed(1)} km`;
  return `${Math.round(km).toLocaleString()} km`;
}
