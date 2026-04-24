import 'jsr:@supabase/functions-js/edge-runtime.d.ts'
import { createClient } from 'npm:@supabase/supabase-js@2'
import OpenAI from 'npm:openai@4'

type QueueMessage = {
  msg_id: number
  read_ct: number
  enqueued_at: string
  vt: string
  message: {
    city_place_id: string
  }
}

type CityPlaceRow = {
  id: string
  name: string
  formatted_address: string | null
  wayfind_category: string | null
  subtypes: string[] | null
  rating: number | null
  user_ratings_total: number | null
  price_level: number | null
  opening_hours: { day: string; hours: string }[] | null
  formatted_phone_number: string | null
  website: string | null
  time_spent_min: number | null
  time_spent_max: number | null
  popular_times: Record<string, unknown> | null
  reviews_tags: string[] | null
  ai_short_summary: string | null
  ai_editorial_summary: string | null
  ai_review_summary: string | null
  ai_why_go: string[] | null
  ai_know_before_you_go: string[] | null
  ai_enriched_at: string | null
  details_enriched_at: string | null
  status: string | null
}

type AiOutput = {
  ai_short_summary: string
  ai_editorial_summary: string
  ai_review_summary: string
  ai_why_go: string[]
  ai_know_before_you_go: string[]
}

const supabase = createClient(
  Deno.env.get('SUPABASE_URL')!,
  Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
  {
    auth: { persistSession: false, autoRefreshToken: false },
  }
)

const openai = new OpenAI({
  apiKey: Deno.env.get('OPENAI_API_KEY')!,
})

function compactPopularTimes(
  popularTimes: Record<string, unknown> | null
): Record<string, unknown> | null {
  if (!popularTimes) return null

  const liveHash =
    typeof popularTimes.live_hash === 'object' && popularTimes.live_hash
      ? popularTimes.live_hash
      : null

  const graphResults =
    typeof popularTimes.graph_results === 'object' && popularTimes.graph_results
      ? popularTimes.graph_results
      : null

  return {
    current_day: popularTimes.current_day ?? null,
    live_hash: liveHash,
    graph_results: graphResults,
  }
}

function buildPlaceContext(row: CityPlaceRow) {
  return {
    name: row.name,
    formatted_address: row.formatted_address,
    wayfind_category: row.wayfind_category,
    subtypes: row.subtypes ?? [],
    rating: row.rating,
    user_ratings_total: row.user_ratings_total,
    price_level: row.price_level,
    opening_hours: row.opening_hours,
    formatted_phone_number: row.formatted_phone_number,
    website: row.website,
    time_spent_min: row.time_spent_min,
    time_spent_max: row.time_spent_max,
    popular_times: compactPopularTimes(row.popular_times),
    reviews_tags: row.reviews_tags ?? [],
  }
}

function sanitizeAiOutput(raw: unknown): AiOutput {
  const obj = (raw ?? {}) as Record<string, unknown>

  const shortSummaryRaw =
    typeof obj.ai_short_summary === 'string' ? obj.ai_short_summary.trim() : ''
  const shortSummary = shortSummaryRaw.slice(0, 280)

  const editorial =
    typeof obj.ai_editorial_summary === 'string'
      ? obj.ai_editorial_summary.trim()
      : ''

  const reviewSummary =
    typeof obj.ai_review_summary === 'string'
      ? obj.ai_review_summary.trim()
      : ''

  const whyGo = Array.isArray(obj.ai_why_go)
    ? obj.ai_why_go
        .filter((x): x is string => typeof x === 'string')
        .map((s) => s.trim())
        .filter(Boolean)
        .slice(0, 6)
    : []

  const knowBefore = Array.isArray(obj.ai_know_before_you_go)
    ? obj.ai_know_before_you_go
        .filter((x): x is string => typeof x === 'string')
        .map((s) => s.trim())
        .filter(Boolean)
        .slice(0, 6)
    : []

  if (!shortSummary || !editorial || !reviewSummary) {
    throw new Error('Model returned incomplete AI fields')
  }

  return {
    ai_short_summary: shortSummary,
    ai_editorial_summary: editorial,
    ai_review_summary: reviewSummary,
    ai_why_go: whyGo,
    ai_know_before_you_go: knowBefore,
  }
}

async function generateAiFields(row: CityPlaceRow): Promise<AiOutput> {
  const place = buildPlaceContext(row)

  const response = await openai.chat.completions.create({
    model: 'gpt-4o-mini',
    response_format: {
      type: 'json_schema',
      json_schema: {
        name: 'city_place_ai_enrichment',
        strict: true,
        schema: {
          type: 'object',
          additionalProperties: false,
          properties: {
            ai_short_summary: {
              type: 'string',
              minLength: 12,
              maxLength: 240,
              description:
                'One tight sentence capturing what this place is and who it suits. Grounded only in supplied data.',
            },
            ai_editorial_summary: {
              type: 'string',
              description:
                'Concise editorial description for travelers. 2-4 sentences. No invented facts.',
            },
            ai_review_summary: {
              type: 'string',
              description:
                'Grounded summary of what reviews seem to say based only on provided signals.',
            },
            ai_why_go: {
              type: 'array',
              items: { type: 'string' },
              minItems: 3,
              maxItems: 6,
            },
            ai_know_before_you_go: {
              type: 'array',
              items: { type: 'string' },
              minItems: 3,
              maxItems: 6,
            },
          },
          required: [
            'ai_short_summary',
            'ai_editorial_summary',
            'ai_review_summary',
            'ai_why_go',
            'ai_know_before_you_go',
          ],
        },
      },
    },
    messages: [
      {
        role: 'developer',
        content: [
          {
            type: 'text',
            text:
              'You generate travel-place copy for a production app. Use only the supplied place data. Do not invent facts, ticketing rules, reservation rules, accessibility claims, dress codes, or opening-hour exceptions unless directly supported by the input. Keep language natural, clear, and useful. Prefer concrete, grounded guidance over generic marketing language.',
          },
        ],
      },
      {
        role: 'user',
        content: [
          {
            type: 'text',
            text: `Generate AI enrichment for this place.\n\nPLACE JSON:\n${JSON.stringify(
              place,
              null,
              2
            )}`,
          },
        ],
      },
    ],
  })

  const content = response.choices[0]?.message?.content
  if (!content) {
    throw new Error('No model content returned')
  }

  return sanitizeAiOutput(JSON.parse(content))
}

async function processMessage(message: QueueMessage) {
  const cityPlaceId = message.message.city_place_id
  const nowIso = new Date().toISOString()

  const { data: row, error: rowError } = await supabase
    .from('city_places')
    .select(`
      id,
      name,
      formatted_address,
      wayfind_category,
      subtypes,
      rating,
      user_ratings_total,
      price_level,
      opening_hours,
      formatted_phone_number,
      website,
      time_spent_min,
      time_spent_max,
      popular_times,
      reviews_tags,
      ai_short_summary,
      ai_editorial_summary,
      ai_review_summary,
      ai_why_go,
      ai_know_before_you_go,
      ai_enriched_at,
      details_enriched_at,
      status
    `)
    .eq('id', cityPlaceId)
    .maybeSingle()

  if (rowError) {
    throw new Error(`fetch city_place failed: ${rowError.message}`)
  }

  if (!row) {
    return { skip: true, reason: 'row_not_found' }
  }

  if (!['active', 'reported'].includes(row.status ?? '')) {
    return { skip: true, reason: 'inactive_status' }
  }

  if (!row.details_enriched_at) {
    return { skip: true, reason: 'details_not_ready' }
  }

  if (row.ai_enriched_at) {
    return { skip: true, reason: 'already_ai_enriched' }
  }

  const ai = await generateAiFields(row as CityPlaceRow)

  const { error: updateError } = await supabase
    .from('city_places')
    .update({
      ai_short_summary: ai.ai_short_summary,
      ai_editorial_summary: ai.ai_editorial_summary,
      ai_review_summary: ai.ai_review_summary,
      ai_why_go: ai.ai_why_go,
      ai_know_before_you_go: ai.ai_know_before_you_go,
      ai_enriched_at: nowIso,
    })
    .eq('id', cityPlaceId)

  if (updateError) {
    throw new Error(`update city_place failed: ${updateError.message}`)
  }

  return {
    ok: true,
    name: row.name,
    city_place_id: cityPlaceId,
    why_go_count: ai.ai_why_go.length,
    know_before_count: ai.ai_know_before_you_go.length,
  }
}

Deno.serve(async (_req) => {
  try {
    const { data: messages, error } = await supabase
      .schema('pgmq_public')
      .rpc('read', {
        queue_name: 'city_places_ai',
        sleep_seconds: 30,
        n: 3,
      })

    if (error) {
      throw new Error(`queue read failed: ${error.message}`)
    }

    const batch = (messages ?? []) as QueueMessage[]

    if (batch.length === 0) {
      return new Response(JSON.stringify({ ok: true, processed: 0 }), {
        headers: { 'content-type': 'application/json' },
      })
    }

    let processed = 0
    let failed = 0

    for (const message of batch) {
      try {
        const result = await processMessage(message)

        const { error: deleteError } = await supabase
          .schema('pgmq_public')
          .rpc('delete', {
            queue_name: 'city_places_ai',
            message_id: message.msg_id,
          })

        if (deleteError) {
          throw new Error(`delete message failed: ${deleteError.message}`)
        }

        processed++
        console.log('[ai-consumer] processed', {
          msg_id: message.msg_id,
          city_place_id: message.message.city_place_id,
          result,
        })
      } catch (error) {
        failed++
        console.error('[ai-consumer] failed', {
          msg_id: message.msg_id,
          city_place_id: message.message.city_place_id,
          error: String(error),
        })
      }
    }

    return new Response(
      JSON.stringify({
        ok: true,
        processed,
        failed,
        received: batch.length,
      }),
      { headers: { 'content-type': 'application/json' } }
    )
  } catch (error) {
    return new Response(
      JSON.stringify({ ok: false, error: String(error) }),
      {
        status: 500,
        headers: { 'content-type': 'application/json' },
      }
    )
  }
})