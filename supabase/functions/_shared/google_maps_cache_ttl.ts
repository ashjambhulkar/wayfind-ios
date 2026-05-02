/**
 * Central TTL policy for **time-limited Redis** caches of Google Maps Platform responses.
 *
 * ## Google Maps Platform (GMP) bound
 * The [Maps Platform Service Specific Terms](https://cloud.google.com/maps-platform/terms/maps-service-terms)
 * allow **temporary** caching up to **30 consecutive calendar days** for several services we use, including:
 * - **Places API** §10.3 — latitude/longitude from Places
 * - **Geocoding API** §5.3 — latitude/longitude from Geocoding
 * - **Routes API** §15.3 — latitude/longitude from Routes
 *
 * Individual sections refer to lat/lng; we apply the same **30-day ceiling** to full Redis blobs
 * returned by our edge helpers (Place Details, Text Search, route legs) so TTLs are easy to audit
 * and stay within the common GMP caching window. **Place IDs** may be stored longer per GMP when
 * used as stable identifiers (see same terms, “Google ID values”); that is separate from these TTLs.
 *
 * ## Not governed here
 * - **Postgres `place_cache`** rows (no automatic expiry; refreshed on fetch).
 * - **Client in-memory** place-details dedupe (`placesService.ts`).
 * - **Autocomplete** — not Redis-cached (session-oriented; avoids stale suggestion lists).
 *
 * Adjust durations here only; do not scatter magic TTL numbers in callers.
 */
export const SECONDS_PER_DAY = 86_400;

/** Maximum Redis TTL aligned with GMP “30 consecutive calendar days” caching clauses. */
export const GMP_MAX_CACHE_DAYS = 30;
export const GMP_MAX_CACHE_SECONDS = GMP_MAX_CACHE_DAYS * SECONDS_PER_DAY;

// ── Places (New): Details + Text Search ─────────────────────────────────

/**
 * Redis `place_details:{placeId}` — minimal Place Details (id, name, address, location, types)
 * plus optional merged OpenAI editorial fields after a user-facing fetch.
 */
export const TTL_PLACE_DETAILS_SECONDS = GMP_MAX_CACHE_SECONDS;

/**
 * Redis `text_search:{hash}` — Places Text Search (New), location-biased queries only.
 * Previously 24h; low traffic benefits from reusing discovery results for weeks.
 */
export const TTL_TEXT_SEARCH_SECONDS = GMP_MAX_CACHE_SECONDS;

/** Redis `text_search_dayplan:{hash}` — day-plan discovery (light field mask, separate keyspace). */
export const TTL_TEXT_SEARCH_DAY_PLAN_SECONDS = GMP_MAX_CACHE_SECONDS;

// ── Routes / Geocoding / Timezone ───────────────────────────────────────

/**
 * Redis `directions:{hash}` — Routes API `computeRoutes` (polyline, duration, distance).
 * Traffic-sensitive; same 30-day GMP ceiling as other Maps caches for this stage (cost over freshness).
 */
export const TTL_ROUTES_DIRECTIONS_SECONDS = GMP_MAX_CACHE_SECONDS;

/** Redis `geocode:{hash}` — Geocoding API first result JSON. */
export const TTL_GEOCODE_SECONDS = GMP_MAX_CACHE_SECONDS;

/** Redis `timezone:{lat}_{lng}` — Timezone API IANA id (DST rules live in OS, not this string). */
export const TTL_TIMEZONE_SECONDS = GMP_MAX_CACHE_SECONDS;

// ── Places hero (metadata + stored URL pointer) ─────────────────────────

/**
 * Redis `place_hero_photo:{placeId}:w{width}` — JSON `{ v:2, storage_path, hero_attribution }`
 * after Places `id,photos` + media fetch + Storage upload. Clients receive a **signed** image URL
 * (same TTL window) because `trip-documents` is private and `expo-image` loads without auth headers.
 */
export const TTL_PLACE_HERO_METADATA_SECONDS = GMP_MAX_CACHE_SECONDS;



