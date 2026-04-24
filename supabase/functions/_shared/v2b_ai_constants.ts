/**
 * V2b structured AI prompts — shared by itinerary-ai (Deno).
 * Mirrors app constants in `constants/v2bProductDecisions.ts` / canonical spec.
 */

export const V2B_INTEREST_PROMPTS: Record<string, string> = {
  museums_culture: "museums, cultural sites, galleries",
  food_dining: "restaurants, street food, local cuisine",
  nature_parks: "parks, gardens, nature walks, viewpoints",
  shopping: "markets, boutiques, shopping districts",
  art_galleries: "art galleries, street art, creative spaces",
  entertainment: "shows, performances, live music",
  history_heritage: "historical sites, monuments, heritage tours",
  beach_relaxation: "beaches, waterfront, relaxation spots",
  adventure_sports: "adventure activities, sports, outdoor thrills",
  cafes_local: "cafes, local neighborhoods, hidden gems",
  nightlife: "bars, clubs, rooftop lounges, night tours",
  wellness_spa: "spas, wellness centers, yoga, thermal baths",
};

export const ALLOWED_EXPLORATION_SCOPES = new Set([
  "walkable",
  "city_wide",
  "spread_out",
]);

export const V2B_DEFAULT_EXPLORATION_SCOPE = "city_wide";

export const V2B_SCOPE_PROMPT_HINTS: Record<string, string> = {
  walkable:
    "All stops should be walk-connected — under 20 minutes walking between consecutive stops. " +
    "Stay within the neighborhood. No transit hops unless absolutely necessary.",
  city_wide:
    "A mix of neighborhoods is fine. Short transit hops (subway, bus, taxi) between clusters are acceptable. " +
    "Keep the day geographically sensible — avoid crossing the entire city back and forth.",
  spread_out:
    "Longer distances between stops are expected. The traveler is driving or using significant transit. " +
    "Include practical transit notes (drive time, taxi, ferry) in activity descriptions. " +
    "Do not assume walkability between stops.",
};

export const V2B_SCOPE_LABELS: Record<string, string> = {
  walkable: "Walkable neighborhood",
  city_wide: "Explore the city",
  spread_out: "Spread out / driving",
};

export const V2B_TRAVEL_STYLE_PROMPTS: Record<string, string> = {
  backpacker:
    "budget-friendly venues, street food, local markets, hostels area, free attractions, off-the-beaten-path discoveries",
  family:
    "kid-friendly venues, parks and playgrounds, interactive museums, easy walking distances, family restaurants, rest breaks",
  couple:
    "romantic restaurants, scenic viewpoints, unique experiences, evening activities, wine bars, intimate venues",
  friends:
    "group-friendly venues, adventure activities, nightlife, social dining, rooftop bars, shared experiences",
  solo:
    "walkable neighborhoods, cafes for working, self-guided tours, local hidden gems, flexible timing, photography spots",
};

// ─── Change 9: wish list (single LLM call, indexed pool, no place_ids in prompt) ─

export const WISHLIST_MIN_PICKS = 12;
export const WISHLIST_MAX_PICKS = 15;
/** Absolute floor for sparse areas — a 4-stop day is still a valid itinerary. */
export const WISHLIST_MIN_PICKS_FLOOR = 4;
/**
 * Compute dynamic min/max picks based on actual activity pool size.
 * In dense areas (pool >= 12) → standard 12-15.
 * In sparse areas (pool 4-11) → scale down proportionally.
 * Below 4 → returns null (cannot build a viable day).
 */
export function computeAdaptivePickRange(
  activityPoolSize: number,
): { minPicks: number; maxPicks: number } | null {
  if (activityPoolSize >= WISHLIST_MIN_PICKS) {
    return { minPicks: WISHLIST_MIN_PICKS, maxPicks: WISHLIST_MAX_PICKS };
  }
  if (activityPoolSize < WISHLIST_MIN_PICKS_FLOOR) {
    return null;
  }
  const minPicks = Math.max(
    WISHLIST_MIN_PICKS_FLOOR,
    Math.floor(activityPoolSize * 0.6),
  );
  const maxPicks = Math.min(
    activityPoolSize,
    Math.max(minPicks + 2, Math.floor(activityPoolSize * 0.9)),
  );
  return { minPicks, maxPicks };
}
/** Max numbered lines sent in the user prompt (token budget). */
export const WISHLIST_MAX_POOL_LINES = 55;
export const WISHLIST_MAX_REASON_CHARS = 200;
export const WISHLIST_MAX_STORY_TITLE_CHARS = 72;
export const WISHLIST_MAX_STORY_SUBTITLE_CHARS = 140;
export const WISHLIST_OPENAI_MAX_OUTPUT_TOKENS = 2048;
export const WISHLIST_OPENAI_TEMPERATURE = 0.65;

export const WISHLIST_ALLOWED_TOD = [
  "morning",
  "midday",
  "afternoon",
  "evening",
] as const;

/**
 * System prompt for wish-list generation (~target 800 tokens when combined with schema text).
 * Model outputs JSON only; `reason` becomes `moment_line` on the server (no second LLM call).
 */
export const WISHLIST_SYSTEM_PROMPT =
  `You are a travel taste advisor for Wayfind. Given a traveler's preferences and a numbered list of available places, pick the set of stops they would most enjoy. The **user** message states the exact minimum and maximum number of picks for this request — follow that range.

Output ONLY valid JSON matching this schema:
{
  "picks": [
    { "idx": 3, "importance": 9, "tod": "morning", "reason": "Start with sweeping city views to set a romantic tone." }
  ],
  "story_title": "A romantic day of art, views, and riverside strolls",
  "story_subtitle": "Begin with city panoramas, enjoy modern art, pause for Italian lunch, and wind down at a waterfront park."
}

Rules:
- idx: the number from the PLACE LIST (1-based). Copy exactly; do not invent indices.
- importance: integer 1-10 (10 = must-see, 1 = nice filler).
- tod: one of "morning" | "midday" | "afternoon" | "evening" — soft time-of-day suggestion only.
- reason: one sentence (max ${WISHLIST_MAX_REASON_CHARS} characters) explaining WHY this place fits this traveler at this moment in the day's arc. This text becomes the itinerary moment_line — human, warm, specific; NOT a generic venue description or address dump. Use the quoted context from the PLACE LIST to write something a local friend would say — reference specific features, views, or experiences. NEVER repeat the place name or address. Example: "Start here for sweeping Thames views before the crowds arrive" not "Visit Westminster Abbey for its historic architecture."
- story_title: max ${WISHLIST_MAX_STORY_TITLE_CHARS} characters; calm, specific promise of the day.
- story_subtitle: one sentence, max ${WISHLIST_MAX_STORY_SUBTITLE_CHARS} characters; how the day flows.
- Pick the number of places specified in the user message. Vary categories; do not pick five stops of the same category in a row.
- Match traveler tone (e.g. romantic vs family vs solo) when choosing and phrasing reasons.
- Every idx MUST refer to the numbered PLACE LIST in the user message as given (1-based line number). When the user message says excluded names were already applied server-side, every line in PLACE LIST is eligible — still pick only from those lines.
- If an exclude list is provided in the user message with concrete names (not the "(none) — already applied server-side" case), never pick any excluded place (match by list line text / name).`;

/** Free-tier monthly caps enforced server-side (matches `constants/v2bProductDecisions.ts`). */
export const V2B_MONTHLY_LIMIT_AI_DAY_PLANNER = 7;



