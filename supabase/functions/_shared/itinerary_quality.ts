import type { CityPlaceDbRow } from "./city_places_pool.ts";
import { haversineKm } from "./day_plan_candidate_rank_core.ts";
import { openaiChatMaxOutputField } from "./openai_itinerary_models.ts";
import type { TTDPTravelEndpoint } from "./travel_cache.ts";
import type { TTDPStop } from "./ttdp_optimizer.ts";
import { evaluateSequence } from "./ttdp_optimizer.ts";

const OPENAI_COMPLETIONS_URL = "https://api.openai.com/v1/chat/completions";

/**
 * Energy level per wayfind_category. Used to check that high-energy stops
 * alternate with rest periods — no 3+ consecutive "high" without a break.
 */
const ENERGY_LEVEL: Record<string, "high" | "medium" | "low"> = {
  attraction: "high",
  nature: "low",
  shopping: "medium",
  nightlife: "medium",
  restaurant: "low",
  cafe: "low",
};

function getEnergyLevel(category: string): "high" | "medium" | "low" {
  return ENERGY_LEVEL[category] ?? "medium";
}

// ── City Rules types ────────────────────────────────────────────────────────

export type CityRuleType =
  | "exhaustion_conflict"
  | "category_cap"
  | "neighborhood_cluster"
  | "best_time"
  | "season"
  | "highlights";

export type CityRuleRow = {
  id: string;
  city_profile_id: string | null;
  rule_type: CityRuleType;
  rule_data: Record<string, unknown>;
  weight: number;
  is_active: boolean;
  applies_when: {
    pace?: string[];
    trip_depth?: string[];
    min_trip_days?: number;
  } | null;
};

export type RuleContext = {
  pace: string;
  tripDepth: string;
  tripDays: number;
  month: number;
};

function ruleApplies(rule: CityRuleRow, ctx: RuleContext): boolean {
  if (!rule.is_active) return false;
  const cond = rule.applies_when;
  if (!cond) return true;
  if (cond.pace && !cond.pace.includes(ctx.pace)) return false;
  if (cond.trip_depth && !cond.trip_depth.includes(ctx.tripDepth)) return false;
  if (cond.min_trip_days != null && ctx.tripDays < cond.min_trip_days) return false;
  return true;
}

export type RuleViolation = {
  rule_id: string;
  rule_type: CityRuleType;
  would_penalize: boolean;
  reason: string;
  penalty: number;
};

/**
 * Evaluate city rules against a completed itinerary sequence.
 * Returns soft penalty violations (never blocks — only adjusts score).
 */
export function evaluateCityRules(
  sequence: TTDPStop[],
  rules: CityRuleRow[],
  ctx: RuleContext,
): RuleViolation[] {
  const violations: RuleViolation[] = [];

  for (const rule of rules) {
    const active = rule.is_active;
    const applies = active && ruleApplies(rule, ctx);
    const shadowApplies = !active && ruleApplies({ ...rule, is_active: true }, ctx);

    if (!applies && !shadowApplies) continue;

    const data = rule.rule_data;
    let violated = false;
    let reason = "";

    switch (rule.rule_type) {
      case "exhaustion_conflict": {
        const cat = data.category as string | undefined;
        const minDur = (data.min_duration_threshold as number) ?? 90;
        const maxPerDay = (data.max_per_day as number) ?? 1;
        const matching = sequence.filter((s) => {
          if (cat && s.category !== cat) return false;
          return s.duration_minutes >= minDur;
        });
        if (matching.length > maxPerDay) {
          violated = true;
          reason = `${matching.length} stops with duration >= ${minDur}min in category "${cat}" (max ${maxPerDay})`;
        }
        break;
      }

      case "category_cap": {
        const caps = data as Record<string, number>;
        const counts: Record<string, number> = {};
        for (const s of sequence) {
          counts[s.category] = (counts[s.category] ?? 0) + 1;
        }
        for (const [capKey, maxCount] of Object.entries(caps)) {
          const catName = capKey.replace("max_", "").replace("_per_day", "");
          const actual = counts[catName] ?? 0;
          if (actual > maxCount) {
            violated = true;
            reason = `${actual} "${catName}" stops exceeds cap of ${maxCount}`;
            break;
          }
        }
        break;
      }

      case "neighborhood_cluster": {
        const clusters = (data.clusters ?? []) as {
          name: string;
          bounds: { sw: number[]; ne: number[] };
        }[];
        for (const cluster of clusters) {
          const inCluster = sequence.filter(
            (s) =>
              s.lat >= cluster.bounds.sw[0] &&
              s.lat <= cluster.bounds.ne[0] &&
              s.lng >= cluster.bounds.sw[1] &&
              s.lng <= cluster.bounds.ne[1],
          );
          if (inCluster.length >= 2) {
            const indices = inCluster.map((s) => sequence.indexOf(s));
            const consecutive = indices.every((idx, i) =>
              i === 0 || idx === indices[i - 1]! + 1 || idx === indices[i - 1]! + 2,
            );
            if (!consecutive) {
              violated = true;
              reason = `${inCluster.length} stops in "${cluster.name}" are not grouped consecutively`;
              break;
            }
          }
        }
        break;
      }

      case "best_time": {
        const prefs = (data.preferences ?? []) as {
          name: string;
          preferred: "morning" | "evening";
          match_by?: string;
        }[];
        for (const pref of prefs) {
          const stop = sequence.find((s) =>
            pref.match_by === "name_contains"
              ? s.name.toLowerCase().includes(pref.name.toLowerCase())
              : s.name.toLowerCase() === pref.name.toLowerCase(),
          );
          if (!stop) continue;
          const hour = stop.start_minutes / 60;
          if (pref.preferred === "morning" && hour >= 14) {
            violated = true;
            reason = `"${pref.name}" scheduled at ${Math.floor(hour)}:00 but best in morning`;
            break;
          }
          if (pref.preferred === "evening" && hour < 16) {
            violated = true;
            reason = `"${pref.name}" scheduled at ${Math.floor(hour)}:00 but best in evening`;
            break;
          }
        }
        break;
      }

      case "season": {
        const outdoorMonths = (data.outdoor_friendly_months ?? []) as number[];
        const isOutdoorMonth = outdoorMonths.length === 0 || outdoorMonths.includes(ctx.month);
        if (!isOutdoorMonth) {
          const OUTDOOR_CATEGORIES = new Set(["nature"]);
          const outdoorStops = sequence.filter((s) => OUTDOOR_CATEGORIES.has(s.category));
          if (outdoorStops.length > sequence.length * 0.4) {
            violated = true;
            reason = `${outdoorStops.length}/${sequence.length} stops are outdoor but month ${ctx.month} is not outdoor-friendly`;
          }
        }
        break;
      }

      default:
        break;
    }

    if (violated || shadowApplies) {
      const isActiveViolation = applies && violated;
      violations.push({
        rule_id: rule.id,
        rule_type: rule.rule_type,
        would_penalize: violated,
        reason: violated ? reason : "shadow: rule not active",
        penalty: isActiveViolation ? rule.weight * -0.15 : 0,
      });
    }
  }

  return violations;
}

// ── Itinerary Quality Scorer ────────────────────────────────────────────────

export type ItineraryQualityScore = {
  overall: number;
  temporal_feasibility: number;
  spatial_coherence: number;
  variety_and_energy: number;
  city_rules_compliance: number;
  practical_completeness: number;
  issues: string[];
  city_rules_violations: RuleViolation[];
};

/**
 * Compute a 0–1 quality score for a completed TTDP itinerary.
 * Layer 1 (algorithmic) + Layer 2 (city rules as soft penalties).
 * Only temporal feasibility is a hard pass/fail — everything else is scored.
 */
export function scoreItineraryQuality(
  sequence: TTDPStop[],
  hotelCoords: { lat: number; lng: number },
  dayStartMin: number,
  dayEndMin: number,
  getTravelMin: (from: TTDPTravelEndpoint, to: TTDPTravelEndpoint) => number,
  cityRules: CityRuleRow[],
  ruleCtx: RuleContext,
): ItineraryQualityScore {
  const issues: string[] = [];

  // ── Temporal feasibility (0 or 1) ──────────────────────────────────────
  let temporalScore = 1.0;

  const evalResult = evaluateSequence(
    sequence, hotelCoords, dayStartMin, dayEndMin, getTravelMin,
  );
  if (!evalResult.feasible) {
    temporalScore = 0;
    issues.push("Sequence is temporally infeasible (opening hours or day budget violation)");
  }

  // Gap check: no 3+ hour gap before 15:00
  for (let i = 1; i < sequence.length; i++) {
    const prevEnd = sequence[i - 1]!.end_minutes;
    const curStart = sequence[i]!.start_minutes;
    const gap = curStart - prevEnd;
    if (gap >= 180 && prevEnd < 15 * 60) {
      temporalScore = 0;
      issues.push(
        `${Math.round(gap)}min gap before 15:00 (between "${sequence[i - 1]!.name}" and "${sequence[i]!.name}")`,
      );
    }
  }

  // Meal window check (soft — deducts but doesn't zero)
  const hasMealSlot = sequence.some((s) => s.category === "restaurant");
  const dayLength = dayEndMin - dayStartMin;
  if (!hasMealSlot && dayLength >= 360) {
    temporalScore = Math.max(0, temporalScore - 0.3);
    issues.push("No meal in a 6+ hour day");
  }
  if (hasMealSlot) {
    const lunchStop = sequence.find(
      (s) => s.category === "restaurant" && s.start_minutes >= 11.5 * 60 && s.start_minutes < 14 * 60,
    );
    const dinnerStop = sequence.find(
      (s) => s.category === "restaurant" && s.start_minutes >= 18 * 60 && s.start_minutes < 21 * 60,
    );
    if (!lunchStop && dayLength >= 360) {
      temporalScore = Math.max(0, temporalScore - 0.1);
      issues.push("No lunch scheduled between 11:30-14:00");
    }
    if (!dinnerStop && dayEndMin >= 20 * 60) {
      temporalScore = Math.max(0, temporalScore - 0.1);
      issues.push("No dinner scheduled between 18:00-21:00 for a late day");
    }
  }

  // ── Spatial coherence (0-1) ────────────────────────────────────────────
  let spatialScore = 1.0;

  if (sequence.length >= 3) {
    const legDistances: number[] = [];
    let prev: { lat: number; lng: number } = hotelCoords;
    for (const stop of sequence) {
      const km = haversineKm(prev, { lat: stop.lat, lng: stop.lng });
      legDistances.push(km);
      prev = { lat: stop.lat, lng: stop.lng };
    }
    legDistances.sort((a, b) => a - b);
    const medianLeg = legDistances[Math.floor(legDistances.length / 2)]!;
    const maxLeg = legDistances[legDistances.length - 1]!;

    if (medianLeg > 0.01) {
      const legRatio = maxLeg / medianLeg;
      if (legRatio > 5) {
        spatialScore = Math.max(0, spatialScore - 0.4);
        issues.push(`Spatial outlier: longest leg ${maxLeg.toFixed(1)}km is ${legRatio.toFixed(1)}x the median`);
      } else if (legRatio > 3) {
        spatialScore = Math.max(0, spatialScore - 0.2);
        issues.push(`Moderate spatial spread: max/median leg ratio ${legRatio.toFixed(1)}`);
      }
    }
  }

  // ── Variety and energy pacing (0-1) ────────────────────────────────────
  let varietyScore = 1.0;

  // Category variety
  const nonMealStops = sequence.filter((s) => s.category !== "restaurant");
  const uniqueCategories = new Set(nonMealStops.map((s) => s.category));
  if (nonMealStops.length >= 4 && uniqueCategories.size < 2) {
    varietyScore -= 0.3;
    issues.push(`Low variety: ${uniqueCategories.size} unique categories across ${nonMealStops.length} stops`);
  }

  // Consecutive same-category check
  let maxConsecutiveSame = 1;
  let currentRun = 1;
  for (let i = 1; i < nonMealStops.length; i++) {
    if (nonMealStops[i]!.category === nonMealStops[i - 1]!.category) {
      currentRun++;
      maxConsecutiveSame = Math.max(maxConsecutiveSame, currentRun);
    } else {
      currentRun = 1;
    }
  }
  if (maxConsecutiveSame >= 3) {
    varietyScore -= 0.3;
    issues.push(`${maxConsecutiveSame} consecutive stops in same category`);
  }

  // Energy pacing: no 3+ consecutive high-energy stops
  let highEnergyRun = 0;
  let maxHighEnergyRun = 0;
  for (const stop of sequence) {
    if (getEnergyLevel(stop.category) === "high") {
      highEnergyRun++;
      maxHighEnergyRun = Math.max(maxHighEnergyRun, highEnergyRun);
    } else {
      highEnergyRun = 0;
    }
  }
  if (maxHighEnergyRun >= 3) {
    varietyScore -= 0.25;
    issues.push(`${maxHighEnergyRun} consecutive high-energy stops without a break`);
  }

  varietyScore = Math.max(0, varietyScore);

  // ── City rules compliance (0-1) ────────────────────────────────────────
  const ruleViolations = evaluateCityRules(sequence, cityRules, ruleCtx);
  const activePenalties = ruleViolations.filter((v) => v.penalty < 0);
  const totalPenalty = activePenalties.reduce((sum, v) => sum + v.penalty, 0);
  const rulesScore = Math.max(0, 1.0 + totalPenalty);

  if (activePenalties.length > 0) {
    for (const v of activePenalties) {
      issues.push(`[${v.rule_type}] ${v.reason}`);
    }
  }

  // ── Practical completeness (0-1) ───────────────────────────────────────
  let practicalScore = 1.0;

  // Buffer check: at least 5min between stops (accounting for travel)
  for (let i = 1; i < sequence.length; i++) {
    const prevEnd = sequence[i - 1]!.end_minutes;
    const curStart = sequence[i]!.start_minutes;
    if (curStart - prevEnd < 5) {
      practicalScore -= 0.15;
      issues.push(`No buffer between "${sequence[i - 1]!.name}" and "${sequence[i]!.name}"`);
      break;
    }
  }
  practicalScore = Math.max(0, practicalScore);

  // ── Combined score ─────────────────────────────────────────────────────
  const overall =
    0.25 * temporalScore +
    0.25 * spatialScore +
    0.20 * varietyScore +
    0.20 * rulesScore +
    0.10 * practicalScore;

  return {
    overall,
    temporal_feasibility: temporalScore,
    spatial_coherence: spatialScore,
    variety_and_energy: varietyScore,
    city_rules_compliance: rulesScore,
    practical_completeness: practicalScore,
    issues,
    city_rules_violations: ruleViolations,
  };
}

// ── LLM Evaluator (Layer 3) ─────────────────────────────────────────────────

export type LLMEvalScore = {
  flow: number;
  local_feel: number;
  preference_fit: number;
  surprise: number;
  suggestion: string | null;
};

export async function evaluateItineraryWithLLM(
  sequence: TTDPStop[],
  cityLabel: string,
  month: number,
  dayOfWeek: number,
  travelStyle: string | undefined,
  pace: string | undefined,
  interests: string[] | undefined,
  apiKey: string,
  model: string,
): Promise<LLMEvalScore | null> {
  const dayNames = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"];
  const monthNames = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

  const itineraryLines = sequence.map((s, i) => {
    const h = Math.floor(s.start_minutes / 60);
    const m = s.start_minutes % 60;
    const time = `${h}:${m.toString().padStart(2, "0")}`;
    return `${i + 1}. ${time} - ${s.name} (${s.duration_minutes} min, ${s.category})`;
  }).join("\n");

  const userProfile = [
    travelStyle && `travel style: ${travelStyle}`,
    pace && `pace: ${pace}`,
    interests?.length && `interests: ${interests.join(", ")}`,
  ].filter(Boolean).join(", ");

  const prompt = `You are a travel expert evaluating a day itinerary for ${cityLabel}.
Month: ${monthNames[month - 1] ?? month}. Day: ${dayNames[dayOfWeek] ?? dayOfWeek}.

User profile: ${userProfile || "not specified"}

Itinerary:
${itineraryLines}

Score each dimension 1-5:
- FLOW: Does the day flow naturally? Good pacing between intense and relaxed?
- LOCAL_FEEL: Does this feel like a real local experience, not a tourist checklist?
- PREFERENCE_FIT: How well does this match the user's stated interests and pace?
- SURPRISE: Is there at least one unexpected or delightful stop?

If any score < 3, suggest ONE specific improvement as a concrete swap (e.g. "Replace stop 4 with [specific place] because [reason]").
Return ONLY valid JSON: {"flow": N, "local_feel": N, "preference_fit": N, "surprise": N, "suggestion": "..." or null}`;

  try {
    const res = await fetch(OPENAI_COMPLETIONS_URL, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${apiKey}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        model,
        temperature: 0.3,
        ...openaiChatMaxOutputField(model, 300),
        response_format: { type: "json_object" },
        messages: [
          { role: "user", content: prompt },
        ],
      }),
    });

    if (!res.ok) {
      console.warn(`[llm_eval] OpenAI error ${res.status}`);
      return null;
    }

    const data = (await res.json()) as {
      choices?: { message?: { content?: string } }[];
    };
    const raw = data.choices?.[0]?.message?.content;
    if (typeof raw !== "string") return null;

    const parsed = JSON.parse(raw) as Record<string, unknown>;
    return {
      flow: Number(parsed.flow) || 3,
      local_feel: Number(parsed.local_feel) || 3,
      preference_fit: Number(parsed.preference_fit) || 3,
      surprise: Number(parsed.surprise) || 3,
      suggestion: typeof parsed.suggestion === "string" ? parsed.suggestion : null,
    };
  } catch (err) {
    console.warn("[llm_eval] failed:", err);
    return null;
  }
}

// ── Crowd-aware busyness lookup ─────────────────────────────────────────────

const DAY_NAMES = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"];

/**
 * Pre-extract busyness scores for a specific day-of-week from the popular_times
 * JSONB into a lightweight lookup. Call this BEFORE solveTTDP, not inside it.
 */
export function extractBusynessForDay(
  pool: CityPlaceDbRow[],
  dayOfWeek: number,
): Map<string, number[]> {
  const lookup = new Map<string, number[]>();
  const dayName = DAY_NAMES[dayOfWeek] ?? "monday";

  for (const place of pool) {
    if (!place.popular_times) continue;
    const dayData = place.popular_times.graph_results[dayName];
    if (!Array.isArray(dayData)) continue;

    const hourly = new Array<number>(24).fill(0);
    for (const entry of dayData) {
      const hourMatch = entry.time?.match(/(\d+)\s*(AM|PM)/i);
      if (!hourMatch) continue;
      let hour = parseInt(hourMatch[1], 10);
      if (hourMatch[2].toUpperCase() === "PM" && hour !== 12) hour += 12;
      if (hourMatch[2].toUpperCase() === "AM" && hour === 12) hour = 0;
      if (hour >= 0 && hour < 24) {
        hourly[hour] = entry.busyness_score ?? 0;
      }
    }
    lookup.set(place.place_id, hourly);
  }

  return lookup;
}




