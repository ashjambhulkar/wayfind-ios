/**
 * Pure ranking + diversification for day-plan candidate pools (no I/O).
 * Used by itinerary-ai after Google Text Search retrieval.
 */

export type CandidatePlaceInput = {
  place_id: string;
  name: string;
  types: string[];
  rating: number | null;
  user_ratings_total: number | null;
  price_level: number | null;
  lat: number;
  lng: number;
  formatted_address?: string;
  open_now?: boolean | null;
  /**
   * How many distinct day-plan Text Search queries returned this place (cheap discovery signal).
   * Primary quality signal when Text Search is minimal (no rating / review count).
   */
  list_hit_count: number;
  /** From `city_places.thumbnail_url` when pool rows are DB-backed. */
  thumbnail_url?: string | null;
};

export type RankedCandidate = CandidatePlaceInput & {
  wayfind_category: string;
  rank_score: number;
  rank: number;
};

export type CandidateCluster = {
  label: string;
  centroid: { lat: number; lng: number };
  candidates: RankedCandidate[];
};

/** Max candidates per Wayfind bucket in the final shortlist (anti-repetition). */
const MAX_PER_WAYFIND_CATEGORY: Record<string, number> = {
  attraction: 9,
  restaurant: 6,
  nature: 5,
  shopping: 5,
  nightlife: 4,
  custom: 4,
  transport: 0,
};

const BANNED_TYPE_SUBSTRINGS = [
  "parking",
  "gas_station",
  "atm",
  "car_rental",
  "car_dealer",
  "subway_station",
  "bus_station",
  "transit_station",
  "train_station",
  "light_rail_station",
  "travel_agency",
  "tour_operator",
];

/** Interest id → Google type substrings (soft match). Mirrors planner interest IDs. */
const INTEREST_TYPE_FRAGMENTS: Record<string, string[]> = {
  museums_culture: ["museum", "cultural", "art_gallery", "library"],
  food_dining: ["restaurant", "food", "meal_", "bakery", "brunch"],
  nature_parks: ["park", "natural", "hiking", "campground", "garden", "botanical"],
  shopping: ["shopping", "store", "market", "mall", "boutique"],
  art_galleries: ["art_gallery", "museum", "cultural"],
  entertainment: ["movie", "theater", "performing", "concert", "stadium", "arena"],
  history_heritage: ["historical", "monument", "heritage", "cemetery", "castle"],
  beach_relaxation: ["beach", "marina", "waterfront", "resort_spa"],
  adventure_sports: ["sports", "gym", "stadium", "adventure", "amusement", "zoo", "aquarium"],
  cafes_local: ["cafe", "coffee", "bakery", "neighborhood"],
  nightlife: ["night_club", "bar", "pub", "casino"],
  wellness_spa: ["spa", "gym", "yoga", "wellness", "beauty"],
};

/** Substrings matched against `typesBlob(types)` for meal vs activity pool split in candidate pipeline. */
export const MEAL_TYPE_FRAGMENTS = [
  "restaurant",
  "cafe",
  "bakery",
  "meal_",
  "food",
  "brunch",
] as const;

const GENERIC_NAME_PATTERNS = [
  /^art\s*gallery$/i,
  /^restaurant$/i,
  /^cafe$/i,
  /^coffee\s*shop$/i,
  /^hotel$/i,
  /^bar$/i,
  /^park$/i,
  /^museum$/i,
  /^bakery$/i,
  /^pharmacy$/i,
  /^store$/i,
];

const TOUR_OPERATOR_PATTERNS = [
  /\btours?\b/i,
  /\btour\s*(company|operator|agency|guide)\b/i,
];

const MEANINGFUL_TYPE_EXCLUSIONS = new Set([
  "point_of_interest",
  "establishment",
]);

/** Drops generic names and type-only noise before ranking (Change 5). */
export function passesQualityFilter(name: string, types: string[]): boolean {
  const trimmed = name.trim();
  if (trimmed.length < 4) return false;

  for (const pat of GENERIC_NAME_PATTERNS) {
    if (pat.test(trimmed)) return false;
  }

  for (const pat of TOUR_OPERATOR_PATTERNS) {
    if (pat.test(trimmed)) return false;
  }

  const meaningfulTypes = types.filter(
    (t) => !MEANINGFUL_TYPE_EXCLUSIONS.has(t.trim().toLowerCase()),
  );
  if (meaningfulTypes.length === 0) return false;

  return true;
}

export function haversineKm(
  a: { lat: number; lng: number },
  b: { lat: number; lng: number },
): number {
  const R = 6371;
  const dLat = (b.lat - a.lat) * Math.PI / 180;
  const dLng = (b.lng - a.lng) * Math.PI / 180;
  const lat1 = a.lat * Math.PI / 180;
  const lat2 = b.lat * Math.PI / 180;
  const s =
    Math.sin(dLat / 2) ** 2 +
    Math.cos(lat1) * Math.cos(lat2) * Math.sin(dLng / 2) ** 2;
  return 2 * R * Math.asin(Math.min(1, Math.sqrt(s)));
}

export function typesBlob(types: string[]): string {
  return types.map((t) => t.toLowerCase()).join(" ");
}

export function passesPracticalFilter(types: string[]): boolean {
  const blob = typesBlob(types);
  for (const frag of BANNED_TYPE_SUBSTRINGS) {
    if (blob.includes(frag)) return false;
  }
  return true;
}

/**
 * Aligns with itinerary-ai `normalizePlanCategory` buckets (simplified).
 * Order matters: tourist_attraction / museum checked FIRST so that places like
 * "9/11 Memorial & Museum" (types: park + museum) are classified as attraction,
 * not nature. A venue's primary identity as a landmark/museum takes precedence
 * over secondary features like having a park or café component.
 */
export function inferWayfindCategory(types: string[]): string {
  const s = typesBlob(types);
  if (/(museum|tourist_attraction|art_gallery|historical|monument|church|temple|mosque|observation_deck|castle)/.test(s)) {
    return "attraction";
  }
  if (/(night_club|casino)/.test(s)) return "nightlife";
  if (/(restaurant|cafe|bakery|meal_|food)/.test(s) && !/(museum|tourist_attraction)/.test(s)) return "restaurant";
  if (/(bar|pub|cocktail_bar|lounge)/.test(s)) return "nightlife";
  if (/(park|natural|hiking|campground|garden|botanical|zoo|aquarium)/.test(s)) return "nature";
  if (/(shopping|store|market|mall|clothing|jewelry|book_store)/.test(s) && !/(museum)/.test(s)) return "shopping";
  if (/(airport|subway|bus_station|train_station|transit|taxi)/.test(s)) return "transport";
  return "custom";
}

function hasDetailsQualitySignals(hit: CandidatePlaceInput): boolean {
  return (
    hit.rating != null &&
    hit.rating > 0 &&
    hit.rating <= 5 &&
    hit.user_ratings_total != null &&
    hit.user_ratings_total >= 0
  );
}

/** Prefer rating + review volume only when present (legacy cache); else multi-query Text Search recall. */
function baseQualityScore(hit: CandidatePlaceInput, maxListHitCount: number): number {
  if (hasDetailsQualitySignals(hit)) {
    const r = hit.rating!;
    const n = hit.user_ratings_total!;
    const popularity = Math.min(1, Math.log1p(n) / Math.log1p(2500));
    const ratingNorm = Math.max(0, Math.min(1, (r - 3) / 2));
    return 0.5 * ratingNorm + 0.5 * popularity;
  }
  const maxH = Math.max(1, maxListHitCount);
  const c = Math.max(1, hit.list_hit_count);
  const recall = Math.min(1, c / maxH);
  return 0.2 + 0.8 * recall;
}

function interestSoftBoost(types: string[], interestIds: string[]): number {
  if (!interestIds.length) return 0;
  const blob = typesBlob(types);
  let sum = 0;
  for (const id of interestIds) {
    const frags = INTEREST_TYPE_FRAGMENTS[id];
    if (!frags?.length) continue;
    let matched = false;
    for (const f of frags) {
      if (blob.includes(f)) {
        matched = true;
        break;
      }
    }
    if (matched) sum += 0.09;
  }
  return Math.min(0.27, sum);
}

function mealRelevanceBoost(
  types: string[],
  includeMeals: boolean,
  lunchWindow: boolean,
  dinnerWindow: boolean,
): number {
  if (!includeMeals) return 0;
  const blob = typesBlob(types);
  const isMealVenue = MEAL_TYPE_FRAGMENTS.some((f) => blob.includes(f));
  if (!isMealVenue) return 0;
  let b = 0.06;
  if (lunchWindow || dinnerWindow) b += 0.04;
  return b;
}

/**
 * Scope-aware geo-coherence score.
 * `normalizeKm` sets the distance at which the score drops to ~10%.
 * - walkable (5km): 4km-away place scores low
 * - city_wide (25km): 4km-away place scores high — normal transit distance
 * - spread_out (80km): even 20km is considered close
 * Defaults to 42km (legacy) when not provided.
 */
function geoCoherenceScore(
  hit: CandidatePlaceInput,
  anchor: { lat: number; lng: number },
  normalizeKm?: number,
): number {
  const d = haversineKm(anchor, { lat: hit.lat, lng: hit.lng });
  const norm = normalizeKm ?? 42;
  return Math.max(0, 1 - Math.min(1, d / norm) * 0.9);
}

export type ScoreParts = {
  base_quality: number;
  interest_boost: number;
  meal_boost: number;
  geo_fit: number;
};

export function scoreCandidateParts(
  hit: CandidatePlaceInput,
  opts: {
    interestIds: string[];
    includeMeals: boolean;
    /** True if plan window overlaps typical lunch (11:30–14:30). */
    lunchWindow: boolean;
    /** True if plan window overlaps typical dinner (17:00–21:30). */
    dinnerWindow: boolean;
    anchor: { lat: number; lng: number };
    maxListHitCount: number;
    /** Scope-aware geo normalizer (km). Pass distCapKm so the geo score spreads across the full scope range. */
    geoNormalizeKm?: number;
  },
): ScoreParts {
  return {
    base_quality: baseQualityScore(hit, opts.maxListHitCount),
    interest_boost: interestSoftBoost(hit.types, opts.interestIds),
    meal_boost: mealRelevanceBoost(hit.types, opts.includeMeals, opts.lunchWindow, opts.dinnerWindow),
    geo_fit: geoCoherenceScore(hit, opts.anchor, opts.geoNormalizeKm),
  };
}

function combineScore(parts: ScoreParts): number {
  return (
    0.44 * parts.base_quality +
    0.22 * parts.interest_boost +
    0.10 * parts.meal_boost +
    0.24 * parts.geo_fit
  );
}

/** Full scalar score (e.g. pre-rank before selective Place Details enrichment). */
export function computeCandidateRankScore(
  hit: CandidatePlaceInput,
  opts: {
    interestIds: string[];
    includeMeals: boolean;
    lunchWindow: boolean;
    dinnerWindow: boolean;
    anchor: { lat: number; lng: number };
    maxListHitCount: number;
    geoNormalizeKm?: number;
  },
): number {
  return combineScore(scoreCandidateParts(hit, opts));
}

/**
 * Dedupe by place_id, filter impractical types, score, sort, diversify caps, take `limit`.
 */
export function rankAndShortlistCandidates(
  raw: CandidatePlaceInput[],
  opts: {
    interestIds: string[];
    includeMeals: boolean;
    lunchWindow: boolean;
    dinnerWindow: boolean;
    anchor: { lat: number; lng: number };
    limit: number;
    /** Scope-aware geo normalizer (km). Pass distCapKm so distant places aren't unfairly penalized. */
    geoNormalizeKm?: number;
  },
): RankedCandidate[] {
  const seen = new Set<string>();
  const deduped: CandidatePlaceInput[] = [];
  for (const h of raw) {
    const id = h.place_id.trim();
    if (!id || seen.has(id)) continue;
    seen.add(id);
    if (!passesPracticalFilter(h.types)) continue;
    if (!passesQualityFilter(h.name, h.types)) continue;
    const wf = inferWayfindCategory(h.types);
    if (wf === "transport") continue;
    if (!opts.includeMeals && wf === "restaurant") continue;
    deduped.push(h);
  }

  const maxListHitCount = deduped.reduce((m, h) => Math.max(m, h.list_hit_count), 1);
  const scoreOpts = { ...opts, maxListHitCount };

  const scored = deduped.map((h) => {
    const parts = scoreCandidateParts(h, scoreOpts);
    const wayfind_category = inferWayfindCategory(h.types);
    return {
      ...h,
      wayfind_category,
      rank_score: combineScore(parts),
      rank: 0,
    };
  });

  scored.sort((a, b) => b.rank_score - a.rank_score);

  const out: RankedCandidate[] = [];
  const counts = new Map<string, number>();

  const maxFor = (wf: string) => MAX_PER_WAYFIND_CATEGORY[wf] ?? 5;

  for (const row of scored) {
    if (out.length >= opts.limit) break;
    const wf = row.wayfind_category;
    const cap = maxFor(wf);
    if (cap <= 0) continue;
    const c = counts.get(wf) ?? 0;
    if (c >= cap) continue;
    out.push(row);
    counts.set(wf, c + 1);
  }

  if (out.length < opts.limit) {
    for (const row of scored) {
      if (out.length >= opts.limit) break;
      if (out.some((x) => x.place_id === row.place_id)) continue;
      const wf = row.wayfind_category;
      const cap = maxFor(wf);
      if (cap <= 0) continue;
      const c = counts.get(wf) ?? 0;
      if (c >= cap) continue;
      out.push(row);
      counts.set(wf, c + 1);
    }
  }

  out.sort((a, b) => b.rank_score - a.rank_score);
  out.forEach((r, i) => {
    r.rank = i + 1;
  });
  return out.slice(0, opts.limit);
}

/**
 * Groups candidates into geographic clusters using nearest-centroid assignment.
 *
 * Algorithm:
 * 1. Sort candidates by distance from center (closest first) — so the first
 *    cluster seed is near the base, and clusters grow outward.
 * 2. For each candidate, find the NEAREST existing cluster within clusterRadiusKm.
 *    If multiple clusters are within radius, pick the closest one (not the first).
 * 3. If no cluster is within radius, start a new cluster.
 * 4. After assignment, recalculate the cluster centroid.
 * 5. Label each cluster by the top-ranked member's neighborhood (from address).
 */
type MutableCluster = {
  members: RankedCandidate[];
  centroidLat: number;
  centroidLng: number;
};

export function clusterCandidates(
  candidates: RankedCandidate[],
  clusterRadiusKm: number,
  center?: { lat: number; lng: number },
): CandidateCluster[] {
  if (candidates.length === 0) return [];

  const sorted = center
    ? [...candidates].sort(
        (a, b) =>
          haversineKm(center, { lat: a.lat, lng: a.lng }) -
          haversineKm(center, { lat: b.lat, lng: b.lng }),
      )
    : [...candidates].sort((a, b) => a.lat - b.lat);

  const clusters: MutableCluster[] = [];

  for (const c of sorted) {
    let bestCluster: MutableCluster | null = null;
    let bestDist = Infinity;

    for (const cluster of clusters) {
      const d = haversineKm(
        { lat: cluster.centroidLat, lng: cluster.centroidLng },
        { lat: c.lat, lng: c.lng },
      );
      if (d <= clusterRadiusKm && d < bestDist) {
        bestCluster = cluster;
        bestDist = d;
      }
    }

    if (bestCluster) {
      bestCluster.members.push(c);
      const n = bestCluster.members.length;
      bestCluster.centroidLat =
        bestCluster.members.reduce((s, m) => s + m.lat, 0) / n;
      bestCluster.centroidLng =
        bestCluster.members.reduce((s, m) => s + m.lng, 0) / n;
    } else {
      clusters.push({
        members: [c],
        centroidLat: c.lat,
        centroidLng: c.lng,
      });
    }
  }

  return clusters.map((cl) => {
    const rankedMembers = [...cl.members].sort((a, b) => a.rank - b.rank);
    const topPlace = rankedMembers[0];
    const addr = topPlace?.formatted_address?.trim();
    const fromAddress = addr
      ? addr.split(",").map((s) => s.trim()).filter(Boolean).slice(0, 2).join(", ")
      : "";
    const areaName = fromAddress || topPlace?.name || "Area";

    return {
      label: areaName,
      centroid: { lat: cl.centroidLat, lng: cl.centroidLng },
      candidates: rankedMembers,
    };
  });
}

export function parsePlanDayWindowFlags(
  timeStart: string,
  timeEnd: string,
): { lunchWindow: boolean; dinnerWindow: boolean } {
  const parse = (s: string): number | null => {
    const m = /^(\d{1,2}):(\d{2})$/.exec(s.trim());
    if (!m) return null;
    const h = parseInt(m[1]!, 10);
    const min = parseInt(m[2]!, 10);
    if (h > 23 || min > 59) return null;
    return h * 60 + min;
  };
  const a = parse(timeStart);
  const b = parse(timeEnd);
  if (a == null || b == null || b <= a) {
    return { lunchWindow: true, dinnerWindow: true };
  }
  const overlaps = (x0: number, x1: number) => a < x1 && b > x0;
  return {
    lunchWindow: overlaps(11 * 60 + 30, 14 * 60 + 30),
    dinnerWindow: overlaps(17 * 60, 21 * 60 + 30),
  };
}



