Google Maps Platform — API audit
All usage was $0.00 this period because every line stayed within its free-tier cap. The table below shows the Google cost that kicks in once each cap is breached, and whether the service is already replaced by a native Apple Maps equivalent.

Google Service	Free Cap	Cost After Cap (per 1,000)	Apple Maps
Routes: Compute Routes Essentials	10,000	$5.00	✅ MKDirections
Places API: Autocomplete Requests	10,000	$2.83	❌
Places API: Text Search Pro	5,000	$32.00	❌
Places API: Text Search Enterprise	1,000	$35.00	❌
Places API: Place Details Pro	5,000	$17.00	❌
Places API: Place Details Enterprise	1,000	$20.00	❌
Places API: Place Details Enterprise + Atmosphere	1,000	$25.00	❌
Places API: Place Details Essentials (IDs Only)	Unlimited	Free	❌
Places API: Place Details Photos	1,000	$7.00	❌
Geocoding	10,000	$5.00	✅ CLGeocoder
Legacy: Basic Data	Unlimited	Free	❌
Legacy: Atmosphere Data	1,000	$5.00	❌
Legacy: Contact Data	1,000	$3.00	❌
Legacy: Text Search	5,000	$32.00	❌
Legacy: Places Details	5,000	$17.00	❌
Legacy: Places Photo	1,000	$7.00	❌
Time Zone	10,000	$5.00	✅ CLPlacemark.timeZone
Distance Matrix	10,000	$5.00	✅ MKDirections
Cost at scale (projected)
Scale	Google Bill	After Full Apple Migration	Saving
1× (current)	$0	$0	$0
10×	~$600 / mo	~$15 / mo	~$585 / mo
50×	~$3,500 / mo	~$100 / mo	~$3,400 / mo
100×	~$8,800 / mo	~$350 / mo	~$8,450 / mo
Migration priority
The three ❌ rows with the highest post-cap rate are the most urgent to migrate:

Text Search Pro / Enterprise ($32–35 / 1,000) → replace with MKLocalSearch
Place Details Enterprise / Pro / Atmosphere ($17–25 / 1,000) → replace with MKMapItem from MKLocalSearch
Autocomplete ($2.83 / 1,000) → replace with MKLocalSearchCompleter
Services Apple Maps cannot replace: place photos, ratings, opening hours, price level, and persistent place IDs — keep Google or a third-party source for those fields only.

Pricing sourced from the Google Maps Platform official pricing page (April 2026). Figures will change as usage grows.

Search Orchestrator Strategy
Tackling the $32–35 per 1,000 cost of Google's Text Search and Autocomplete requires moving the entire top-of-the-funnel discovery flow over to Apple's ecosystem. For a travel planner like Wayfind, the vast majority of API calls happen while users are exploring — typing, deleting, panning the map. Those exploration costs can be driven to zero across both Next.js and Expo using the architecture below, while still preserving Google's premium "Atmosphere" data (reviews, ratings, photos) for moments where it actually matters.

1. Apple-First Autocomplete Engine — Cost: $0
Move all keystroke-level autocomplete to Apple.

Mobile (Expo / React Native): MKLocalSearchCompleter natively handles typo tolerance, localized ranking, and region constraints with no billing dashboard.
Web (Next.js): MapKit JS ships with a free quota of 25,000 service calls + 250,000 map views per day per Apple Developer Program membership (verified from Apple's official docs). This is more than enough to handle web-based itinerary planning before requesting a limit increase.
⚠️ Caveat: When MapKit JS exceeds 25k/day, Apple returns HTTP 429 (TooManyRequests) rather than auto-overage billing. This is great for cost predictability but means traffic spikes can hard-fail. Wrap requests with graceful error handling and a Google fallback for spike protection.

2. POI Resolution Layer — Cost: $0
When a user taps an autocomplete suggestion, do not send the text string to Google. Instead, hand the selected MKLocalSearchCompletion (or PlaceLookup on web) to MKLocalSearch. The returned MKMapItem instantly provides:

Precise CLLocationCoordinate2D
Formatted address
Business name
Apple's native MKPointOfInterestCategory
Phone number and website URL
Following the KISS principle, this is enough to render destination cards and plot map markers immediately — no loading spinners, no upstream billable call.

3. The Google Bridge — Targeted ID Matching
You still need Google for Atmosphere data (reviews, ratings) and Photos. The trick is to bridge from Apple data to a Google place_id only when user intent is confirmed (e.g., they tap "View Reviews" or commit a stop to their itinerary).

Because you already have the exact name and coordinates from Apple, you can avoid Google's most expensive Text Search Pro tier:

Use Google Text Search Essentials ($5 / 1,000 after a 10,000 free cap) — far cheaper than Pro/Enterprise
Apply Field Masks to request only the id field on the response
The Place Details Essentials (IDs Only) SKU is in the Unlimited / free tier, so any subsequent ID-refresh call costs nothing
⚠️ Caveat: The first-time discovery query that resolves name + coord → place_id still triggers a Text Search Essentials call ($5 / 1,000 post-cap). The "free IDs Only" SKU only applies when you already hold a place_id and need to validate it. Plan for ~$5 per 1,000 new place bridges, not per existing place lookup.

4. Asynchronous Data Hydration
Once a Google place_id is stored in Supabase next to your Apple-sourced MKMapItem data, you control the cost curve completely:

Render the UI immediately using free Apple data
Trigger Google Place Details Photos / Atmosphere ($7–25 / 1,000) only on demand — when the user expands a destination card to research it
Cache aggressively — Google's Terms of Service permit:
place_id cached indefinitely (with periodic validity refresh)
Atmosphere data cached for up to 30 days before requiring a refetch
Subsequent users viewing the same Parisian café pull cached reviews from Supabase, not Google's API
Net cost impact
Layer	Before	After
Keystroke autocomplete	$2.83 / 1,000 (Google)	$0 (MapKit)
Text search resolution	$32–35 / 1,000 (Google Pro/Ent)	$0 (MapKit) → optional $5 / 1,000 for Google bridge
Initial place details (name/coord/address/phone)	$17–25 / 1,000 (Google)	$0 (MKMapItem)
Photos / reviews / hours	$7–25 / 1,000 (Google)	Same — but called only on intent + cached 30 days
Google place_id refresh	—	$0 (IDs Only SKU)
This shifts Google from being the discovery engine (called on every keystroke) to a deep-research bridge (called only when a user commits to a place), reducing API spend by an estimated 85–95% at scale while keeping the premium content layer available.

Spike Protection Playbook — Handling the MapKit JS 25k/day Ceiling
When MapKit JS exceeds its daily quota, Apple returns HTTP 429 (TooManyRequests) with no auto-overage billing — requests just fail. The strategies below, applied together, can realistically push effective capacity from 25k/day → 200k–500k+/day on the free tier without ever hitting a hard failure.

1. Request a Capacity Increase from Apple — Free, Official Path
Submit the MapKit JS Increase Request form from your Apple Developer account. Increases to 100k–500k+ service calls/day are commonly granted within days for legitimate production traffic. There is no cost — Apple's MapKit JS remains free even at elevated quotas.

Trigger this when sustained daily usage crosses ~60% of your current cap. Don't wait until you're already getting 429s.

2. Multi-Layer Caching — Biggest ROI
Most autocomplete traffic is redundant ("Pari" → "Paris" → "Paris, Fra" all in seconds). Aggressive caching cuts API calls 70%+ before they ever hit MapKit:

[Browser memory / IndexedDB] → [CDN edge cache] → [Server cache (Redis)] → MapKit JS
Layer	Tool	TTL	Purpose
Browser	react-query, IndexedDB	10 min	Per-session deduplication
Edge	Vercel Edge Config, Cloudflare KV	24 h	Popular global queries (Paris, Tokyo, NYC)
Server	Upstash Redis	30 days	Resolved place data keyed by lat,lng,name
Apple's ToS permits caching place data, similar to Google's policy.

3. Debouncing + Minimum Query Length
Single biggest client-side optimization — typically cuts request volume 50–70%:

const debouncedQuery = useDebounce(query, 300); // wait 300ms after last keystroke
const MIN_LENGTH = 3;                            // don't fire until 3 chars

useEffect(() => {
  if (debouncedQuery.length >= MIN_LENGTH) {
    runSearch(debouncedQuery);
  }
}, [debouncedQuery]);
Apply the same pattern in the Expo app via useDeferredValue or a debounce hook.

4. Circuit Breaker with Google Fallback
Auto-failover to Google when Apple starts rejecting:

class SearchOrchestrator {
  private appleCircuitOpen = false;
  private circuitResetAt = 0;

  async search(query: string) {
    const now = Date.now();
    if (this.appleCircuitOpen && now < this.circuitResetAt) {
      return this.googleSearch(query);
    }

    try {
      return await this.appleSearch(query);
    } catch (err) {
      if (err.status === 429 || err.code === 'TooManyRequests') {
        this.appleCircuitOpen = true;
        this.circuitResetAt = now + 60 * 60 * 1000;  // open 1 hour
        return this.googleSearch(query);
      }
      throw err;
    }
  }
}
Google cost is paid only during the fallback window — cheap insurance against hard failure.

5. Real-Time Quota Telemetry + Soft-Limit Throttling
Don't wait for the 429. Track usage live and back off before the cliff:

const todayCount = await redis.incr(`mapkit:calls:${today}`);
await redis.expire(`mapkit:calls:${today}`, 86400);

const QUOTA = 25_000;
const SOFT_LIMIT = 22_000;  // 88% of quota

if (todayCount > SOFT_LIMIT) {
  return Math.random() < 0.5 ? appleSearch(q) : googleSearch(q);
}
Smooths the cliff into a ramp — no users see hard failures, and the Google bill stays predictable.

6. Server-Side Proxy with Smart Routing
Route all MapKit JS calls through a Next.js API route or Edge Function rather than directly from the browser:

Browser → Next.js API route → MapKit JS / Google / Cache
Benefits:

Accurate centralized usage counter (no browser-side estimation)
Per-user rate limits to stop bots/scripts from burning quota (e.g., 100 searches/user/day)
A/B routing logic when usage is high
Maps token never exposed to the client (security win)
7. Pre-warm Popular Destination Queries
For a travel app, ~20% of queries cover ~80% of destinations. Run a weekly cron to pre-resolve the top 1,000 destinations and store the MKMapItem-equivalent JSON in Supabase / Edge Config:

Sub-50ms responses, served entirely from cache
Zero quota usage for these queries
Absorbs 30–50% of total search traffic for a typical travel app
8. Multiple Apple Developer Program Memberships
The 25k/day quota is per Apple Developer Program membership, not per app. Multi-brand portfolios can route different products to different memberships for additional headroom. For a single product this is harder to justify, but it's a legitimate scaling lever for larger orgs.

9. Last Resort: Web/Native Split
If web traffic genuinely cannot stay under quota even with the above:

Native iOS → 100% MapKit (no web quota concern, on-device APIs)
Web → Google with strict cost controls + cached layer
Backend → store coordinates as the universal key so both clients write to the same Supabase rows
You'd still eliminate Google cost on mobile (likely your majority traffic).

Recommended Production Stack for Wayfind
1. Debouncing + min-length on client       ← cuts traffic 50%
2. Server-side proxy + Redis cache          ← cuts traffic another 60%
3. Circuit breaker → Google fallback        ← spike insurance
4. Quota telemetry + soft-limit throttling  ← prevents hard failures
5. Apple capacity increase request          ← raises ceiling 4–20×
With these five layers in place, 200k–500k effective daily searches become serviceable on the free MapKit tier, with Google as a $5/1,000 insurance policy for the rare overflow.