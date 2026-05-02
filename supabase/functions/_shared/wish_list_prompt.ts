/**
 * Change 9 Part 4: wish list LLM — indexed place lines (no place_ids), single JSON response.
 */

import type { CityPlaceDbRow } from "./city_places_pool.ts";
import { haversineKm } from "./day_plan_candidate_rank_core.ts";
import { openaiChatMaxOutputField } from "./openai_itinerary_models.ts";
import {
  V2B_INTEREST_PROMPTS,
  V2B_SCOPE_LABELS,
  V2B_TRAVEL_STYLE_PROMPTS,
  WISHLIST_ALLOWED_TOD,
  WISHLIST_MAX_POOL_LINES,
  WISHLIST_MAX_REASON_CHARS,
  WISHLIST_MAX_STORY_SUBTITLE_CHARS,
  WISHLIST_MAX_STORY_TITLE_CHARS,
  WISHLIST_MIN_PICKS,
  WISHLIST_MAX_PICKS,
  WISHLIST_OPENAI_MAX_OUTPUT_TOKENS,
  WISHLIST_OPENAI_TEMPERATURE,
  WISHLIST_SYSTEM_PROMPT,
} from "./v2b_ai_constants.ts";

const OPENAI_CHAT_COMPLETIONS_URL = "https://api.openai.com/v1/chat/completions";

export type WishListTod = (typeof WISHLIST_ALLOWED_TOD)[number];

export type WishListPick = {
  idx: number;
  importance: number;
  tod: WishListTod;
  /** Becomes `moment_line` on the client / itinerary ops. */
  reason: string;
};

export type WishListResponse = {
  picks: WishListPick[];
  story_title?: string;
  story_subtitle?: string;
};

export class WishListParseError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "WishListParseError";
  }
}

export type WishListTravelerInput = {
  /** e.g. couple, solo — key into V2B_TRAVEL_STYLE_PROMPTS or free text. */
  travel_style?: string;
  pace?: string;
  interest_ids?: string[];
};

/**
 * One-line traveler summary for the user block (style + pace + interests).
 */
export function buildTravelerSummaryLine(input: WishListTravelerInput): string {
  const styleKey = (input.travel_style ?? "").trim().toLowerCase();
  const stylePhrase =
    V2B_TRAVEL_STYLE_PROMPTS[styleKey] ??
    (styleKey.length > 0 ? styleKey : "general traveler");
  const pace = (input.pace ?? "balanced").trim() || "balanced";
  const ids = Array.isArray(input.interest_ids) ? input.interest_ids : [];
  const mapped = ids.map((id) => V2B_INTEREST_PROMPTS[id] ?? id);
  const interestText =
    mapped.length > 0 ? mapped.join(", ") : "a balanced mix of highlights";
  return `Traveler: ${stylePhrase}. Pace: ${pace}. Preferences: ${interestText}.`;
}

/**
 * Numbered pool lines with enrichment context when available.
 * Format: `1. Name | category | X.Xkm | 4.7 | "why go snippet" | ~2h`
 * The extra context lets the LLM write specific, warm moment_lines instead of generic descriptions.
 */
export function buildCompactPlaceListLines(
  indexedPool: CityPlaceDbRow[],
  center: { lat: number; lng: number },
  maxLines: number = WISHLIST_MAX_POOL_LINES,
): string[] {
  const cap = Math.min(maxLines, indexedPool.length);
  const lines: string[] = [];
  for (let i = 0; i < cap; i++) {
    const p = indexedPool[i]!;
    const distKm = haversineKm(center, { lat: p.lat, lng: p.lng });
    const distPart = `${distKm.toFixed(1)}km`;

    let line = `${i + 1}. ${p.name} | ${p.wayfind_category} | ${distPart}${ratingSuffix(p)}`;

    // Append a short "why go" snippet so the LLM can write specific moment_lines
    const whyGo = Array.isArray((p as any).ai_why_go) ? (p as any).ai_why_go as string[] : null;
    if (whyGo && whyGo.length > 0) {
      const snippet = whyGo[0]!.slice(0, 100);
      line += ` | "${snippet}"`;
    } else {
      const editorial = (p as any).ai_editorial_summary;
      if (typeof editorial === "string" && editorial.trim().length > 0) {
        line += ` | "${editorial.trim().slice(0, 100)}"`;
      }
    }

    // Append time-spent hint so the LLM can mention duration naturally
    const tsMin = p.time_spent_min;
    const tsMax = p.time_spent_max;
    if (tsMin != null && tsMax != null && tsMin > 0) {
      const avgH = ((tsMin + tsMax) / 2 / 60).toFixed(1);
      line += ` | ~${avgH}h`;
    }

    lines.push(line);
  }
  return lines;
}

export type WishListUserPromptInput = {
  travelerLine: string;
  cityLabel: string;
  explorationScope: string;
  excludeNames: string[];
  placeListLines: string[];
  /** When true, PLACE LIST already omits excluded venues — do not repeat a long exclude list. */
  placesPreFilteredFromExcludes?: boolean;
  /** Adaptive min picks for sparse areas. */
  adaptiveMinPicks?: number;
  /** Adaptive max picks for sparse areas. */
  adaptiveMaxPicks?: number;
};

/**
 * User message: traveler block + city/scope/exclude + PLACE LIST + short instruction.
 */
export function buildWishListUserPrompt(input: WishListUserPromptInput): string {
  const scopeKey = input.explorationScope.trim().toLowerCase() || "city_wide";
  const scopeLabel =
    V2B_SCOPE_LABELS[scopeKey] ??
    (input.explorationScope.trim() || "city_wide");
  const preFiltered = Boolean(input.placesPreFilteredFromExcludes);
  const exclude = preFiltered
    ? "(none) — already applied server-side"
    : input.excludeNames.length > 0
    ? input.excludeNames.join(", ")
    : "(none)";
  const list = input.placeListLines.join("\n");
  const eligibilityNote = preFiltered
    ? "\nOnly venues in the PLACE LIST below are eligible — pick idx from that list only (1-based line numbers).\n"
    : "";
  return (
    `${input.travelerLine}\n` +
    `City: ${input.cityLabel.trim()}\n` +
    `Scope: ${scopeKey} (${scopeLabel})\n` +
    `Exclude (by name; do not pick): ${exclude}\n` +
    eligibilityNote +
    `\nPLACE LIST:\n${list}\n\n` +
    `Pick ${input.adaptiveMinPicks ?? WISHLIST_MIN_PICKS}-${
      input.adaptiveMaxPicks ?? WISHLIST_MAX_PICKS
    } stops. Vary categories.`
  );
}

function isAllowedTod(x: string): x is WishListTod {
  return (WISHLIST_ALLOWED_TOD as readonly string[]).includes(x);
}

/**
 * Maps model paraphrases ("late afternoon", "night", "brunch") onto the strict
 * {@link WISHLIST_ALLOWED_TOD} set so GPT‑5.x / other models do not hard-fail hybrid plan_day.
 */
function normalizeWishListTod(raw: string): WishListTod | null {
  const s = raw.trim().toLowerCase().replace(/\s+/g, " ").replace(/-/g, " ");
  if (s.length === 0) return null;
  if (isAllowedTod(s)) return s;

  // Phrase-level (order: more specific before generic "night" → evening)
  if (/\b(late|early)\s+afternoon\b|\bmid\s*afternoon\b|\bpost[\s-]*lunch\b/.test(s)) {
    return "afternoon";
  }
  if (/\b(late|early)\s+morning\b|\bmid\s*morning\b|\bsunrise\b|\bdawn\b|\bbreakfast\b/.test(s)) {
    return "morning";
  }
  if (/\bbrunch\b|\bnoon\b|\blunch(time)?\b|\bmid[\s-]*day\b/.test(s)) {
    return "midday";
  }
  if (
    /\b(night|midnight|after\s*dark)\b|\b(late|early)\s+evening\b|\bsunset\b|\bdusk\b|\btwilight\b|\bgolden\s+hour\b|\baperitivo\b|\bpre[\s-]*dinner\b/.test(s)
  ) {
    return "evening";
  }

  // Single-keyword fallbacks
  if (s.includes("afternoon")) return "afternoon";
  if (s.includes("morning")) return "morning";
  if (s.includes("midday") || s.includes("noon")) return "midday";
  if (s.includes("evening") || s.includes("night")) return "evening";

  return null;
}

function ratingSuffix(place: CityPlaceDbRow): string {
  const r = (place as { rating?: number | null }).rating;
  if (typeof r === "number" && Number.isFinite(r)) {
    return ` | ${r.toFixed(1)}`;
  }
  return "";
}

function clampStr(s: string, max: number): string {
  const t = s.trim();
  if (t.length <= max) return t;
  return t.slice(0, max - 1) + "…";
}

/**
 * Parse and validate OpenAI JSON object into WishListResponse.
 */
export function parseWishListResponse(
  rawJson: unknown,
  poolLineCount: number,
  options?: { minPicks?: number; maxPicks?: number },
): WishListResponse {
  if (!rawJson || typeof rawJson !== "object") {
    throw new WishListParseError("Wish list JSON must be an object");
  }
  const o = rawJson as Record<string, unknown>;
  if (!Array.isArray(o.picks)) {
    throw new WishListParseError("Missing picks array");
  }
  const picks: WishListPick[] = [];
  const seenIdx = new Set<number>();

  for (const item of o.picks) {
    if (!item || typeof item !== "object") continue;
    const row = item as Record<string, unknown>;
    const idx = typeof row.idx === "number" && Number.isInteger(row.idx)
      ? row.idx
      : typeof row.idx === "string"
      ? Number.parseInt(row.idx, 10)
      : NaN;
    if (!Number.isFinite(idx) || idx < 1 || idx > poolLineCount) {
      throw new WishListParseError(`Invalid idx ${String(row.idx)} for pool size ${poolLineCount}`);
    }
    if (seenIdx.has(idx)) {
      throw new WishListParseError(`Duplicate idx ${idx}`);
    }
    seenIdx.add(idx);

    const importanceRaw = typeof row.importance === "number"
      ? row.importance
      : Number(row.importance);
    if (!Number.isFinite(importanceRaw)) {
      throw new WishListParseError(`Invalid importance for idx ${idx}`);
    }
    const importance = Math.min(10, Math.max(1, Math.round(importanceRaw)));

    const todSource = String(row.tod ?? "").trim();
    const todNorm = normalizeWishListTod(todSource);
    if (!todNorm) {
      throw new WishListParseError(
        `Invalid tod for idx ${idx}: ${todSource} (expected one of: ${WISHLIST_ALLOWED_TOD.join(", ")})`,
      );
    }

    const reasonRaw = typeof row.reason === "string" ? row.reason.trim() : "";
    if (reasonRaw.length === 0) {
      throw new WishListParseError(`Empty reason for idx ${idx}`);
    }

    picks.push({
      idx,
      importance,
      tod: todNorm,
      reason: clampStr(reasonRaw, WISHLIST_MAX_REASON_CHARS),
    });
  }

  const effectiveMin = options?.minPicks ?? WISHLIST_MIN_PICKS;
  const effectiveMax = options?.maxPicks ?? WISHLIST_MAX_PICKS;
  if (picks.length < effectiveMin || picks.length > effectiveMax) {
    throw new WishListParseError(
      `Expected ${effectiveMin}-${effectiveMax} picks, got ${picks.length}`,
    );
  }

  let story_title: string | undefined;
  if (typeof o.story_title === "string" && o.story_title.trim().length > 0) {
    story_title = clampStr(o.story_title, WISHLIST_MAX_STORY_TITLE_CHARS);
  }
  let story_subtitle: string | undefined;
  if (typeof o.story_subtitle === "string" && o.story_subtitle.trim().length > 0) {
    story_subtitle = clampStr(
      o.story_subtitle,
      WISHLIST_MAX_STORY_SUBTITLE_CHARS,
    );
  }

  return { picks, story_title, story_subtitle };
}

export type FetchWishListArgs = {
  apiKey: string;
  model: string;
  indexedPool: CityPlaceDbRow[];
  center: { lat: number; lng: number };
  traveler: WishListTravelerInput;
  cityLabel: string;
  explorationScope: string;
  excludeNames: string[];
  /** Hybrid path: pool rows matching exclude_names were removed before numbering. */
  placesPreFilteredFromExcludes?: boolean;
  maxPoolLines?: number;
  /** Adaptive min picks for sparse areas (overrides WISHLIST_MIN_PICKS). */
  adaptiveMinPicks?: number;
  /** Adaptive max picks for sparse areas (overrides WISHLIST_MAX_PICKS). */
  adaptiveMaxPicks?: number;
};

/**
 * One chat completion: system wish-list prompt + user prompt with indexed PLACE LIST.
 */
export async function fetchWishListFromOpenAI(
  args: FetchWishListArgs,
): Promise<WishListResponse> {
  const poolCap = Math.min(
    args.maxPoolLines ?? WISHLIST_MAX_POOL_LINES,
    args.indexedPool.length,
  );
  const slice = args.indexedPool.slice(0, poolCap);
  if (slice.length === 0) {
    throw new WishListParseError("indexedPool is empty");
  }

  const placeListLines = buildCompactPlaceListLines(slice, args.center, poolCap);
  const userMessage = buildWishListUserPrompt({
    travelerLine: buildTravelerSummaryLine(args.traveler),
    cityLabel: args.cityLabel,
    explorationScope: args.explorationScope?.trim() || "city_wide",
    excludeNames: args.excludeNames,
    placeListLines,
    placesPreFilteredFromExcludes: args.placesPreFilteredFromExcludes,
    adaptiveMinPicks: args.adaptiveMinPicks,
    adaptiveMaxPicks: args.adaptiveMaxPicks,
  });

  const res = await fetch(OPENAI_CHAT_COMPLETIONS_URL, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${args.apiKey}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      model: args.model,
      temperature: WISHLIST_OPENAI_TEMPERATURE,
      ...openaiChatMaxOutputField(args.model, WISHLIST_OPENAI_MAX_OUTPUT_TOKENS),
      response_format: { type: "json_object" },
      messages: [
        { role: "system", content: WISHLIST_SYSTEM_PROMPT },
        { role: "user", content: userMessage },
      ],
    }),
  });

  if (!res.ok) {
    const t = await res.text();
    throw new Error(`OpenAI wish list error ${res.status}: ${t}`);
  }

  const data = (await res.json()) as {
    choices?: { message?: { content?: string } }[];
  };
  const raw = data.choices?.[0]?.message?.content;
  if (typeof raw !== "string") {
    throw new Error("OpenAI returned no content for wish list");
  }

  let parsed: unknown;
  try {
    parsed = JSON.parse(raw) as unknown;
  } catch (e) {
    throw new WishListParseError(
      `Invalid JSON from model: ${e instanceof Error ? e.message : String(e)}`,
    );
  }

  return parseWishListResponse(parsed, slice.length, {
    minPicks: args.adaptiveMinPicks,
    maxPicks: args.adaptiveMaxPicks,
  });
}


