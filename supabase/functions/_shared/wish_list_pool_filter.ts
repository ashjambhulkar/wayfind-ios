/**
 * Hybrid wish list: exclude client/trip place names from the indexed pool before the LLM
 * (Layer A) and the same matching rules for post-parse skips (Layer B).
 */

import type { CityPlaceDbRow } from "./city_places_pool.ts";

/** Substring / containment alias tier only when the exclude token is this long (avoids "Park" → false positives). */
const WISHLIST_EXCLUDE_ALIAS_MIN_CHARS = 6;

/**
 * Normalize a venue label for comparison: trim, lowercase, collapse internal whitespace.
 */
export function normalizeWishListPlaceName(raw: string): string {
  return String(raw ?? "")
    .trim()
    .toLowerCase()
    .replace(/\s+/g, " ");
}

function nameMatchesExcludeNormalized(
  placeNorm: string,
  excludeNorm: string,
): boolean {
  if (placeNorm.length === 0 || excludeNorm.length === 0) return false;
  if (placeNorm === excludeNorm) return true;
  if (excludeNorm.length < WISHLIST_EXCLUDE_ALIAS_MIN_CHARS) return false;
  if (placeNorm.includes(excludeNorm)) return true;
  if (placeNorm.length < WISHLIST_EXCLUDE_ALIAS_MIN_CHARS) return false;
  if (excludeNorm.includes(placeNorm)) return true;
  return false;
}

/**
 * True if this pool row should be treated as excluded ("already on trip / other day" names).
 */
export function isPlaceExcludedFromWishList(
  place: CityPlaceDbRow,
  excludeNames: string[],
): boolean {
  const pid = String(place.place_id ?? "").trim();
  const pname = String(place.name ?? "").trim();
  const placeNorm = normalizeWishListPlaceName(pname);

  for (const raw of excludeNames) {
    const ex = String(raw ?? "").trim();
    if (!ex) continue;
    if (pid.length > 0 && ex === pid) return true;
    const excludeNorm = normalizeWishListPlaceName(ex);
    if (excludeNorm.length === 0) continue;
    if (nameMatchesExcludeNormalized(placeNorm, excludeNorm)) return true;
  }
  return false;
}

/**
 * Returns a stable subsequence of `pool` omitting rows excluded by name/place_id match.
 */
export function filterIndexedPoolForWishList(
  pool: CityPlaceDbRow[],
  excludeNames: string[],
): CityPlaceDbRow[] {
  if (excludeNames.length === 0) return [...pool];
  return pool.filter((row) => !isPlaceExcludedFromWishList(row, excludeNames));
}



