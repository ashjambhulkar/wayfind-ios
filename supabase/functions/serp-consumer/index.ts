import 'jsr:@supabase/functions-js/edge-runtime.d.ts'
import { createClient } from 'npm:@supabase/supabase-js@2'

type QueueMessage = {
  msg_id: number
  read_ct: number
  enqueued_at: string
  vt: string
  message: {
    city_place_id: string
  }
}

type HoursEntry = Record<string, string>

type SerpApiImage = {
  title?: string
  thumbnail?: string
  serpapi_thumbnail?: string
  last_updated?: string
}

type PopularTimesDayEntry = {
  time?: string
  info?: string
  busyness_score?: number
}

type PopularTimes = {
  current_day?: string
  live_hash?: {
    time_spent?: string
    [key: string]: unknown
  }
  graph_results?: Record<string, PopularTimesDayEntry[]>
  [key: string]: unknown
}

type UserReviewSummary = {
  snippet?: string
  thumbnail?: string
}

type UserReviewImage = {
  thumbnail?: string
}

type UserReview = {
  username?: string
  rating?: number
  description?: string
  date?: string
  date_iso8601?: string
  images?: UserReviewImage[]
}

type UserReviews = {
  summary?: UserReviewSummary[]
  most_relevant?: UserReview[]
}

type RatingSummaryEntry = {
  stars?: number
  amount?: number
}

type PlaceResult = {
  title?: string
  place_id?: string
  data_id?: string
  rating?: number
  reviews?: number
  rating_summary?: RatingSummaryEntry[]
  price?: string
  phone?: string
  website?: string
  hours?: HoursEntry[]
  address?: string
  images?: SerpApiImage[]
  thumbnail?: string
  serpapi_thumbnail?: string
  type?: string[]
  type_ids?: string[]
  popular_times?: PopularTimes
  user_reviews?: UserReviews
}

type SerpApiResponse = {
  place_results?: PlaceResult
  error?: string
}

type ReviewsApiReview = {
  rating?: number
  date?: string
  date_iso8601?: string
  snippet?: string
  description?: string
  user?: { name?: string }
  reviewer?: { name?: string }
  username?: string
}

type ReviewsApiResponse = {
  reviews?: ReviewsApiReview[]
  error?: string
}

type ReviewsSummaryJson = {
  source: string
  fetched_at: string
  total_reviews: number | null
  average_rating: number | null
  rating_distribution: Record<string, number> | null
  top_themes: string[]
  review_tags: string[]
  review_highlights: {
    rating: number | null
    date: string | null
    author: string | null
    text: string
  }[]
}

const supabase = createClient(
  Deno.env.get('SUPABASE_URL')!,
  Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
  { auth: { persistSession: false, autoRefreshToken: false } }
)

const SERPAPI_API_KEY = Deno.env.get('SERPAPI_API_KEY')!

function parsePriceLevel(priceText: string | null): number | null {
  if (!priceText) return null
  const match = priceText.match(/[€$£¥]+/)
  return match ? match[0].length || null : null
}

function normalizeOpeningHours(hours: HoursEntry[] | null | undefined) {
  if (!hours || !Array.isArray(hours)) return null
  return hours
    .map((entry) => {
      const [day, value] = Object.entries(entry)[0] ?? []
      return day && value ? { day, hours: value } : null
    })
    .filter(Boolean)
}

function parseTypicalSpend(
  text: string | null
): { time_spent_min: number | null; time_spent_max: number | null } {
  if (!text) return { time_spent_min: null, time_spent_max: null }

  const body = text
    .replace(/^People\s+(typically\s+)?spend\s*/i, '')
    .replace(/^Visitors\s+(typically\s+)?spend\s*/i, '')
    .replace(/\s*here\.?$/i, '')
    .trim()

  const toMinutes = (value: string): number | null => {
    const v = value.trim()
    const hrMatch = v.match(/(\d+(?:\.\d+)?)\s*(hr|hour|hours)\b/i)
    const minMatch = v.match(/(\d+(?:\.\d+)?)\s*(min|minute|minutes)\b/i)

    if (hrMatch) return Math.round(parseFloat(hrMatch[1]) * 60)
    if (minMatch) return Math.round(parseFloat(minMatch[1]))

    const bare = v.match(/^(\d+(?:\.\d+)?)\s*$/)
    if (bare) {
      const n = parseFloat(bare[1])
      if (n > 0 && n <= 12) return Math.round(n * 60)
      if (n > 12) return Math.round(n)
    }

    return null
  }

  const upperOnly = body.match(/^\s*(?:up\s+to|at\s+most)\s+(.+)$/i)
  if (upperOnly) {
    const maxM = toMinutes(upperOnly[1].trim())
    if (maxM != null && maxM > 0) {
      const minM = Math.max(1, Math.round(maxM / 2))
      return { time_spent_min: minM, time_spent_max: maxM }
    }
  }

  let parts: string[]
  if (/\s+to\s+/i.test(body)) {
    parts = body.split(/\s+to\s+/i).map((s) => s.trim())
  } else if (/[–-]/.test(body) && /hr|hour|min/i.test(body)) {
    parts = body.split(/\s*[–-]\s*/).map((s) => s.trim()).filter(Boolean)
  } else {
    parts = [body]
  }

  if (parts.length === 2) {
    return {
      time_spent_min: toMinutes(parts[0]),
      time_spent_max: toMinutes(parts[1]),
    }
  }

  const single = toMinutes(body)
  return { time_spent_min: single, time_spent_max: single }
}

const SPEND_HINT =
  /spend|typically|people\s+\w+\s+spend|visit\s+(?:duration|length)|\d+\s*(?:hr|hour|hours|min)/i

function walkPopularTimesForSpendStrings(
  obj: unknown,
  out: string[],
  depth: number
): void {
  if (depth > 14 || out.length >= 24) return
  if (typeof obj === 'string') {
    const s = obj.trim().replace(/\s+/g, ' ')
    if (s.length >= 8 && s.length <= 500 && SPEND_HINT.test(s)) out.push(s)
    return
  }
  if (Array.isArray(obj)) {
    obj.forEach((item) => walkPopularTimesForSpendStrings(item, out, depth + 1))
    return
  }
  if (obj && typeof obj === 'object') {
    for (const v of Object.values(obj as Record<string, unknown>)) {
      walkPopularTimesForSpendStrings(v, out, depth + 1)
    }
  }
}

function extractSpendText(place: PlaceResult | undefined): string | null {
  if (!place) return null

  const direct = place.popular_times?.live_hash?.time_spent
  if (typeof direct === 'string' && direct.trim()) return direct.trim()

  const raw = place as Record<string, unknown>
  for (const key of [
    'people_typically_spend',
    'people_usually_spend',
    'typical_time_spent',
    'visit_duration',
  ]) {
    const v = raw[key]
    if (typeof v === 'string' && v.trim()) return v.trim()
  }

  const alt: string[] = []
  if (place.popular_times && typeof place.popular_times === 'object') {
    walkPopularTimesForSpendStrings(place.popular_times, alt, 0)
    return alt[0] ?? null
  }

  return null
}

function extractImageUrls(images: SerpApiImage[] | null | undefined): string[] {
  if (!images || !Array.isArray(images)) return []
  return images
    .map((img) => img.thumbnail?.trim() || img.serpapi_thumbnail?.trim())
    .filter((url): url is string => Boolean(url))
}

function extractThumbnailUrl(place: PlaceResult): string | null {
  return (
    place.thumbnail?.trim() ||
    place.serpapi_thumbnail?.trim() ||
    extractImageUrls(place.images)[0] ||
    null
  )
}

function extractPhones(place: PlaceResult): {
  formatted: string | null
  international: string | null
} {
  const raw = place as Record<string, unknown>
  const formatted =
    (typeof place.phone === 'string' && place.phone.trim()) ||
    (typeof raw['formatted_phone_number'] === 'string' &&
      raw['formatted_phone_number'].trim()) ||
    null

  const international =
    (typeof raw['international_phone_number'] === 'string' &&
      raw['international_phone_number'].trim()) ||
    (typeof raw['international_phone'] === 'string' &&
      raw['international_phone'].trim()) ||
    formatted

  return { formatted: formatted || null, international: international || null }
}

function extractSubtypes(place: PlaceResult): string[] | null {
  const values = new Set<string>()
  for (const item of place.type ?? []) {
    const v = item?.trim()
    if (v) values.add(v)
  }
  for (const item of place.type_ids ?? []) {
    const v = item?.trim()
    if (v) values.add(v)
  }
  return values.size > 0 ? Array.from(values) : null
}

function normalizePopularTimes(
  popularTimes: PopularTimes | null | undefined
): Record<string, unknown> | null {
  if (!popularTimes || typeof popularTimes !== 'object') return null
  return popularTimes as Record<string, unknown>
}

function extractReviewTags(place: PlaceResult): string[] | null {
  const tags = new Set<string>()

  for (const type of place.type ?? []) {
    const clean = type?.trim().toLowerCase()
    if (clean) tags.add(clean)
  }

  const summaries = place.user_reviews?.summary ?? []
  for (const item of summaries) {
    const text = item.snippet?.trim()
    if (!text) continue

    const lc = text.toLowerCase()

    const keywordMap: [RegExp, string][] = [
      [/\bcoffee\b/, 'coffee'],
      [/\btea\b/, 'tea'],
      [/\bbrunch\b/, 'brunch'],
      [/\bbreakfast\b/, 'breakfast'],
      [/\blunch\b/, 'lunch'],
      [/\bdinner\b/, 'dinner'],
      [/\bdessert\b|\bcake\b|\bpastr(?:y|ies)\b/, 'desserts'],
      [/\bservice\b|\bstaff\b/, 'service'],
      [/\batmosphere\b|\bvibe\b|\bcozy\b|\bcasual\b|\btrendy\b/, 'atmosphere'],
      [/\bqueue\b|\bwait\b/, 'wait time'],
      [/\bportion\b|\bgenerous\b/, 'portion size'],
      [/\bdelicious\b|\btasty\b|\bincredible\b|\bgreat food\b/, 'food quality'],
    ]

    for (const [pattern, tag] of keywordMap) {
      if (pattern.test(lc)) tags.add(tag)
    }
  }

  return tags.size > 0 ? Array.from(tags).slice(0, 20) : null
}

function buildRatingDistribution(place: PlaceResult): Record<string, number> | null {
  const entries = place.rating_summary ?? []
  if (!entries.length) return null

  const distribution: Record<string, number> = {}
  for (const entry of entries) {
    if (
      typeof entry.stars === 'number' &&
      typeof entry.amount === 'number'
    ) {
      distribution[String(entry.stars)] = Math.round(entry.amount)
    }
  }

  return Object.keys(distribution).length > 0 ? distribution : null
}

function buildReviewsSummaryJson(
  place: PlaceResult,
  reviewsApi: ReviewsApiResponse | null,
  reviewTags: string[] | null
): ReviewsSummaryJson | null {
  const fromApi = (reviewsApi?.reviews ?? []).map((r) => ({
    rating: typeof r.rating === 'number' ? r.rating : null,
    date: r.date_iso8601 ?? r.date ?? null,
    author: r.user?.name ?? r.reviewer?.name ?? r.username ?? null,
    text: (r.description ?? r.snippet ?? '').trim(),
  }))

  const fromPlace = (place.user_reviews?.most_relevant ?? []).map((r) => ({
    rating: typeof r.rating === 'number' ? r.rating : null,
    date: r.date_iso8601 ?? r.date ?? null,
    author: r.username ?? null,
    text: (r.description ?? '').trim(),
  }))

  const highlights = [...fromApi, ...fromPlace]
    .filter((r) => r.text)
    .slice(0, 5)

  const themeSourceTexts = [
    ...(reviewsApi?.reviews ?? []).map((r) => (r.description ?? r.snippet ?? '').trim()),
    ...(place.user_reviews?.summary ?? []).map((r) => (r.snippet ?? '').trim()),
    ...(place.user_reviews?.most_relevant ?? []).map((r) => (r.description ?? '').trim()),
  ]
    .filter(Boolean)
    .map((s) => s.toLowerCase())

  const themeCounts = new Map<string, number>()
  const themeMatchers: [RegExp, string][] = [
    [/\bservice\b|\bstaff\b/, 'service'],
    [/\batmosphere\b|\bvibe\b|\bcozy\b|\bcasual\b|\btrendy\b/, 'atmosphere'],
    [/\bfood\b|\btasty\b|\bdelicious\b|\bdish\b|\bmeal\b/, 'food quality'],
    [/\bportion\b|\bgenerous\b/, 'portion size'],
    [/\bqueue\b|\bwait\b|\bcrowded\b|\bbusy\b/, 'wait time'],
    [/\bcoffee\b/, 'coffee'],
    [/\btea\b/, 'tea'],
    [/\bbrunch\b/, 'brunch'],
    [/\bbreakfast\b/, 'breakfast'],
    [/\bdinner\b/, 'dinner'],
  ]

  for (const text of themeSourceTexts) {
    for (const [pattern, label] of themeMatchers) {
      if (pattern.test(text)) {
        themeCounts.set(label, (themeCounts.get(label) ?? 0) + 1)
      }
    }
  }

  const topThemes = Array.from(themeCounts.entries())
    .sort((a, b) => b[1] - a[1])
    .map(([label]) => label)
    .slice(0, 8)

  const totalReviews =
    typeof place.reviews === 'number'
      ? Math.round(place.reviews)
      : reviewsApi?.reviews?.length ?? null

  const averageRating =
    typeof place.rating === 'number' ? place.rating : null

  const ratingDistribution = buildRatingDistribution(place)

  if (
    !highlights.length &&
    !topThemes.length &&
    !reviewTags?.length &&
    totalReviews == null &&
    averageRating == null &&
    ratingDistribution == null
  ) {
    return null
  }

  return {
    source: reviewsApi ? 'serpapi_google_maps_reviews' : 'serpapi_google_maps_place',
    fetched_at: new Date().toISOString(),
    total_reviews: totalReviews,
    average_rating: averageRating,
    rating_distribution: ratingDistribution,
    top_themes: topThemes,
    review_tags: reviewTags ?? [],
    review_highlights: highlights,
  }
}

async function fetchSerpPlace(placeId: string): Promise<SerpApiResponse> {
  const url = new URL('https://serpapi.com/search.json')
  url.searchParams.set('engine', 'google_maps')
  url.searchParams.set('type', 'place')
  url.searchParams.set('place_id', placeId)
  url.searchParams.set('api_key', SERPAPI_API_KEY)

  const response = await fetch(url.toString(), {
    method: 'GET',
    headers: { Accept: 'application/json' },
  })

  if (!response.ok) {
    const text = await response.text()
    throw new Error(`SerpApi request failed: ${response.status} ${text}`)
  }

  return (await response.json()) as SerpApiResponse
}

async function fetchSerpReviews(dataId: string): Promise<ReviewsApiResponse | null> {
  const url = new URL('https://serpapi.com/search.json')
  url.searchParams.set('engine', 'google_maps_reviews')
  url.searchParams.set('data_id', dataId)
  url.searchParams.set('api_key', SERPAPI_API_KEY)
  url.searchParams.set('hl', 'en')

  const response = await fetch(url.toString(), {
    method: 'GET',
    headers: { Accept: 'application/json' },
  })

  if (!response.ok) {
    const text = await response.text()
    throw new Error(`SerpApi reviews request failed: ${response.status} ${text}`)
  }

  return (await response.json()) as ReviewsApiResponse
}

async function processMessage(message: QueueMessage) {
  const cityPlaceId = message.message.city_place_id
  const nowIso = new Date().toISOString()

  const { data: row, error: rowError } = await supabase
    .from('city_places')
    .select('id, place_id, name, details_enriched_at, status')
    .eq('id', cityPlaceId)
    .maybeSingle()

  if (rowError) throw new Error(`fetch city_place failed: ${rowError.message}`)
  if (!row) return { skip: true, reason: 'row_not_found' }
  if (row.details_enriched_at) return { skip: true, reason: 'already_enriched' }
  if (!['active', 'reported'].includes(row.status ?? '')) {
    return { skip: true, reason: 'inactive_status' }
  }

  const placeId = row.place_id as string
  const data = await fetchSerpPlace(placeId)
  if (data.error) throw new Error(`SerpApi error: ${data.error}`)

  const place = data.place_results
  if (!place) {
    const { error } = await supabase
      .from('city_places')
      .update({
        details_enriched_at: nowIso,
        time_spent_enriched_at: nowIso,
        reviews_summary_enriched_at: nowIso,
      })
      .eq('id', cityPlaceId)
    if (error) throw new Error(`update city_place failed: ${error.message}`)
    return { ok: true, placeId, name: row.name, queuedAi: false }
  }

  let reviewsApi: ReviewsApiResponse | null = null
  if (place.data_id) {
    try {
      reviewsApi = await fetchSerpReviews(place.data_id)
    } catch (error) {
      console.warn(`[serp-consumer] reviews fetch failed for ${placeId}: ${String(error)}`)
    }
  }

  const spendText = extractSpendText(place)
  const { time_spent_min, time_spent_max } = parseTypicalSpend(spendText)
  const imageUrls = extractImageUrls(place.images)
  const phones = extractPhones(place)
  const thumbnailUrl = extractThumbnailUrl(place)
  const subtypes = extractSubtypes(place)
  const reviewTags = extractReviewTags(place)
  const popularTimesPayload = normalizePopularTimes(place.popular_times)
  const reviewsSummaryJson = buildReviewsSummaryJson(place, reviewsApi, reviewTags)

  const payload = {
    rating: place.rating ?? null,
    user_ratings_total:
      typeof place.reviews === 'number' ? Math.round(place.reviews) : null,
    price_level: parsePriceLevel(place.price ?? null),
    opening_hours: normalizeOpeningHours(place.hours ?? null),
    formatted_phone_number: phones.formatted,
    international_phone_number: phones.international,
    website: place.website?.trim() || null,
    images: imageUrls.length > 0 ? imageUrls : null,
    thumbnail_url: thumbnailUrl,
    popular_times: popularTimesPayload,
    subtypes,
    reviews_tags: reviewTags,
    reviews_summary_json: reviewsSummaryJson,
    reviews_summary_enriched_at: nowIso,
    time_spent_min,
    time_spent_max,
    details_enriched_at: nowIso,
    time_spent_enriched_at: nowIso,
  }

  const { error: updateError } = await supabase
    .from('city_places')
    .update(payload)
    .eq('id', cityPlaceId)

  if (updateError) throw new Error(`update city_place failed: ${updateError.message}`)

    const { error: aiQueueError } = await supabase
    .schema('pgmq_public')
    .rpc('send', {
      queue_name: 'city_places_ai',
      message: { city_place_id: cityPlaceId },
      sleep_seconds: 0,
    })

  if (aiQueueError) throw new Error(`enqueue AI failed: ${aiQueueError.message}`)

  return { ok: true, placeId, name: row.name, queuedAi: true }
}

Deno.serve(async (_req) => {
  try {
    const { data: messages, error } = await supabase
  .schema('pgmq_public')
  .rpc('read', {
    queue_name: 'city_places_serpapi',
    sleep_seconds: 30,
    // Large batch: backlog often includes duplicate msgs per place (later ones skip without SerpAPI).
    // If most rows in a batch need full enrich, watch Serp hourly limits and Edge Function timeouts.
    n: 60,
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
    queue_name: 'city_places_serpapi',
    message_id: message.msg_id,
  })

if (deleteError) {
  throw new Error(`delete message failed: ${deleteError.message}`)
}

        processed++
        console.log('[serp-consumer] processed', {
          msg_id: message.msg_id,
          city_place_id: message.message.city_place_id,
          result,
        })
      } catch (error) {
        failed++
        console.error('[serp-consumer] failed', {
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