/**
 * Clustered candidate pool string for GPT prompts (Change 6 §3b).
 * Lives in a small module so Vitest can import it without pulling Deno `https://` deps.
 */

import {
  type CandidateCluster,
  type RankedCandidate,
  haversineKm,
} from "./day_plan_candidate_rank_core.ts";

/** Meals within this distance (km) of the pool center are labeled "Near base area" for broader scopes. */
const NEAR_BASE_MEAL_RADIUS_KM = 3;

/**
 * Clustered ACTIVITY / MEAL sections for the model: per-cluster JSON lines,
 * optional transit note, and meal grouping for city_wide / spread_out.
 */
export function formatClusteredPoolForPrompt(
  activityClusters: CandidateCluster[],
  mealCandidates: RankedCandidate[],
  destinationLabel: string,
  center: { lat: number; lng: number },
  scope: string,
  transitNote: string | null,
): string {
  if (!activityClusters.length && !mealCandidates.length) return "";

  const formatLine = (c: RankedCandidate) => {
    const row: Record<string, unknown> = {
      rank: c.rank,
      place_id: c.place_id,
      name: c.name,
      lat: Math.round(c.lat * 1000) / 1000,
      lng: Math.round(c.lng * 1000) / 1000,
      dist_km:
        Math.round(haversineKm(center, { lat: c.lat, lng: c.lng }) * 10) / 10,
      wayfind_category: c.wayfind_category,
      types: c.types.slice(0, 8),
    };
    if (c.rating != null) row.rating = c.rating;
    if (c.user_ratings_total != null) row.rating_count = c.user_ratings_total;
    if (c.price_level != null) row.price_level = c.price_level;
    row.address = (c.formatted_address ?? "").slice(0, 200);
    row.rank_score = Math.round(c.rank_score * 1000) / 1000;
    return JSON.stringify(row);
  };

  const scopeLabel = String(scope).trim() || "city_wide";
  let out = `## ACTIVITY CANDIDATES (${destinationLabel.trim()} — ${scopeLabel} scope)\n`;
  out += `Candidates are grouped into geographic clusters. `;
  out += `Each day should draw from at most 2 adjacent clusters to avoid excessive travel.\n`;
  if (transitNote) {
    out += `Transit note: ${transitNote}\n`;
  }
  out += `\n`;

  const sortedClusters = [...activityClusters].sort((a, b) => {
    const dA = haversineKm(center, a.centroid);
    const dB = haversineKm(center, b.centroid);
    return dA - dB;
  });

  for (let i = 0; i < sortedClusters.length; i++) {
    const cl = sortedClusters[i]!;
    const clDist = Math.round(haversineKm(center, cl.centroid) * 10) / 10;
    out += `### Cluster ${String.fromCharCode(65 + i)}: ${cl.label} (~${clDist}km from base)\n`;
    out += cl.candidates.map(formatLine).join("\n") + "\n\n";
  }

  if (mealCandidates.length > 0) {
    out += `## MEAL CANDIDATES\n`;
    out +=
      `Pick meal stops from this section. Meals should bridge activity clusters geographically.\n`;

    if (scope === "walkable") {
      out += `All meals are near your base/stay area.\n`;
      out += mealCandidates.map(formatLine).join("\n") + "\n";
    } else {
      const baseMeals = mealCandidates.filter((m) => {
        const d = haversineKm(center, { lat: m.lat, lng: m.lng });
        return d <= NEAR_BASE_MEAL_RADIUS_KM;
      });
      const clusterMeals = mealCandidates.filter((m) => {
        const d = haversineKm(center, { lat: m.lat, lng: m.lng });
        return d > NEAR_BASE_MEAL_RADIUS_KM;
      });

      if (baseMeals.length > 0) {
        out += `\n### Near base area\n`;
        out += baseMeals.map(formatLine).join("\n") + "\n";
      }
      if (clusterMeals.length > 0) {
        out += `\n### Near activity clusters\n`;
        out += clusterMeals.map(formatLine).join("\n") + "\n";
      }
      if (baseMeals.length === 0 && clusterMeals.length === 0) {
        out += mealCandidates.map(formatLine).join("\n") + "\n";
      }

      out += `\nWhen activities are far from the base, prefer meals from "Near activity clusters" `;
      out += `so you don't waste time returning to base for lunch. `;
      out += `If no suitable meal candidate is near the chosen activity cluster, `;
      out += `note in the description that the traveler should find a local spot nearby.\n`;
    }
  }

  return out;
}

