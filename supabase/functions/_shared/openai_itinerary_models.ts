/**
 * OpenAI model IDs for **itinerary AI** (plan_day hybrid: wish list, optional LLM eval, etc.).
 *
 * Change the default here, or override per environment without code edits:
 *   `supabase secrets set OPENAI_ITINERARY_MODEL=gpt-4.1-mini`
 *
 * Other features (booking extraction, city place AI blurbs, Serp enricher) use their own constants.
 */
const DEFAULT_ITINERARY_MODEL = "gpt-5.4-mini";

export function openaiItineraryModel(): string {
  const fromEnv = Deno.env.get("OPENAI_ITINERARY_MODEL")?.trim();
  return fromEnv && fromEnv.length > 0 ? fromEnv : DEFAULT_ITINERARY_MODEL;
}

/**
 * Newer OpenAI chat models reject `max_tokens` and require `max_completion_tokens`.
 * Spread the return value into the chat/completions JSON body alongside `model`, `messages`, etc.
 */
export function openaiChatMaxOutputField(
  model: string,
  maxOutput: number,
): Record<string, number> {
  const m = model.trim().toLowerCase();
  if (
    m.startsWith("gpt-5") ||
    m.startsWith("o1") ||
    m.startsWith("o3") ||
    m.startsWith("o4")
  ) {
    return { max_completion_tokens: maxOutput };
  }
  return { max_tokens: maxOutput };
}
