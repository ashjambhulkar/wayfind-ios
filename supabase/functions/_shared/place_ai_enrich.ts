/**
 * AI enrichment for place detail screens.
 *
 * Generates editorial + quick-take + bullets from Google place **metadata** (no review text).
 * Persists to `place_cache`. Skipped when OPENAI_API_KEY is absent or row already enriched.
 */

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const OPENAI_API_KEY = Deno.env.get("OPENAI_API_KEY") ?? "";
const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const OPENAI_MODEL = "gpt-4.1-mini";

type SupabaseAdmin = ReturnType<typeof createClient>;

// ── Types ───────────────────────────────────────────────────────────────

export type PlaceAiContent = {
  editorialSummary: string;
  /**
   * Short AI angle on the place — NOT a summary of Google reviews (we do not fetch review bodies).
   * Stored in DB column `ai_review_summary` for backwards compatibility.
   */
  quickTake: string;
  whyGo: string[];
  knowBeforeYouGo: string[];
};

type PlaceContext = {
  placeId: string;
  name: string;
  address: string;
  types: string[];
  rating: number | null;
  priceLevel: number | null;
};

// ── Prompt ──────────────────────────────────────────────────────────────

function buildPrompt(ctx: PlaceContext): string {
  return `You are a travel content writer for Wayfind, a trip-planning app.

You do NOT have access to individual user reviews. You only have public place metadata (name, types, optional aggregate rating). Never claim to summarize "what reviewers said" or "guest reviews".

Generate four pieces of content for the following place. Output ONLY valid JSON matching the schema below — no markdown, no extra keys.

## Place details
Name: ${ctx.name}
Address: ${ctx.address}
Types: ${ctx.types.join(", ") || "unknown"}
Aggregate rating (if any): ${ctx.rating != null ? `${ctx.rating}/5 (not individual reviews)` : "not available"}
Price level: ${ctx.priceLevel != null ? `${ctx.priceLevel}/4` : "unknown"}

## Output schema
{
  "editorial_summary": "<2-3 engaging sentences describing what this place is and who it suits. Ground only in name, address, and types — no invented facts.>",
  "quick_take": "<2-3 sentences: editor-style 'why you might care' or 'what to expect' tone. Must NOT pretend to quote or synthesize Google reviews.>",
  "why_go": [
    "<Reason 1 — specific and compelling, ≤ 15 words>",
    "<Reason 2>",
    "<Reason 3>",
    "<Reason 4 (optional)>"
  ],
  "know_before_you_go": [
    "<Practical tip 1 — only safe generalities if unsure, ≤ 20 words>",
    "<Practical tip 2>",
    "<Practical tip 3>",
    "<Practical tip 4 (optional)>"
  ]
}

Rules:
- why_go: 3–4 items, each under 15 words, specific to this place.
- know_before_you_go: 3–4 items; never invent hours, prices, or booking rules.
- Write in English, warm and helpful tone.`;
}

// ── OpenAI call ─────────────────────────────────────────────────────────

async function callOpenAI(prompt: string): Promise<PlaceAiContent | null> {
  if (!OPENAI_API_KEY) return null;
  try {
    const res = await fetch("https://api.openai.com/v1/chat/completions", {
      method: "POST",
      headers: {
        Authorization: `Bearer ${OPENAI_API_KEY}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        model: OPENAI_MODEL,
        temperature: 0.5,
        max_tokens: 1024,
        response_format: { type: "json_object" },
        messages: [{ role: "user", content: prompt }],
      }),
    });
    if (!res.ok) {
      console.error("[place_ai_enrich] OpenAI HTTP", res.status);
      return null;
    }
    const data = await res.json() as {
      choices: Array<{ message: { content: string } }>;
    };
    const raw = data.choices?.[0]?.message?.content ?? "";
    const parsed = JSON.parse(raw) as Record<string, unknown>;

    const editorial = typeof parsed.editorial_summary === "string"
      ? parsed.editorial_summary.trim()
      : "";
    const quickTakeRaw = typeof parsed.quick_take === "string"
      ? parsed.quick_take.trim()
      : "";
    const legacyReview = typeof parsed.review_summary === "string"
      ? parsed.review_summary.trim()
      : "";
    const quickTake = quickTakeRaw || legacyReview;
    const whyGo = Array.isArray(parsed.why_go)
      ? (parsed.why_go as unknown[])
          .filter((x): x is string => typeof x === "string" && x.trim().length > 0)
          .slice(0, 4)
      : [];
    const knowBefore = Array.isArray(parsed.know_before_you_go)
      ? (parsed.know_before_you_go as unknown[])
          .filter((x): x is string => typeof x === "string" && x.trim().length > 0)
          .slice(0, 4)
      : [];

    if (!editorial || whyGo.length < 2 || knowBefore.length < 2) return null;

    return {
      editorialSummary: editorial,
      quickTake: quickTake || editorial,
      whyGo,
      knowBeforeYouGo: knowBefore,
    };
  } catch (e) {
    console.error("[place_ai_enrich] parse error", e);
    return null;
  }
}

// ── DB persistence ──────────────────────────────────────────────────────

async function saveEnrichment(
  admin: SupabaseAdmin,
  placeId: string,
  content: PlaceAiContent
): Promise<void> {
  const { error } = await admin.from("place_cache").upsert(
    {
      place_id: placeId,
      ai_editorial_summary: content.editorialSummary,
      ai_review_summary: content.quickTake,
      ai_why_go: content.whyGo,
      ai_know_before_you_go: content.knowBeforeYouGo,
      ai_enriched_at: new Date().toISOString(),
    },
    { onConflict: "place_id" }
  );
  if (error) {
    console.error("[place_ai_enrich] upsert failed", error.message);
  }
}

// ── Check if already enriched ────────────────────────────────────────────

async function isAlreadyEnriched(
  admin: SupabaseAdmin,
  placeId: string
): Promise<boolean> {
  const { data } = await admin
    .from("place_cache")
    .select("ai_enriched_at")
    .eq("place_id", placeId)
    .maybeSingle();
  return data?.ai_enriched_at != null;
}

// ── Public entry point ───────────────────────────────────────────────────

/**
 * Enriches a place with AI-generated content and returns the generated content.
 *
 * Returns null when:
 *  - OPENAI_API_KEY is not set
 *  - place is already enriched (ai_enriched_at is not null)
 *  - generation fails (partial/invalid response from model)
 *
 * The caller decides whether to await (blocking — first-load experience) or
 * fire-and-forget (.catch(...)). When awaited the returned content can be
 * merged directly into the response payload so the client receives AI fields
 * on the very first fetch.
 */
export async function enrichPlaceWithAI(
  placeDetails: Record<string, unknown>
): Promise<PlaceAiContent | null> {
  if (!OPENAI_API_KEY) return null;
  if (!SUPABASE_URL || !SUPABASE_SERVICE_ROLE_KEY) return null;

  const placeId = typeof placeDetails.place_id === "string"
    ? placeDetails.place_id.trim()
    : "";
  if (!placeId) return null;

  const name = typeof placeDetails.name === "string" ? placeDetails.name : "";
  const address =
    typeof placeDetails.formatted_address === "string"
      ? placeDetails.formatted_address
      : "";
  if (!name) return null;

  const admin = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);

  if (await isAlreadyEnriched(admin, placeId)) return null;

  const types = Array.isArray(placeDetails.types)
    ? (placeDetails.types as unknown[]).filter(
        (t): t is string => typeof t === "string"
      )
    : [];

  const rating =
    typeof placeDetails.rating === "number" ? placeDetails.rating : null;
  const priceLevel =
    typeof placeDetails.price_level === "number"
      ? placeDetails.price_level
      : null;

  const ctx: PlaceContext = {
    placeId,
    name,
    address,
    types,
    rating,
    priceLevel,
  };

  const content = await callOpenAI(buildPrompt(ctx));
  if (!content) return null;

  await saveEnrichment(admin, placeId, content);
  return content;
}



