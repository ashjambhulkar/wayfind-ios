//
//  SupabaseManager.swift
//  wayfind
//

import CoreLocation
import Foundation
import Observation
import Supabase
import UIKit

/// Uses ``AuthSessionService/shared`` as the single `SupabaseClient` (session + PostgREST auth headers).
@Observable @MainActor
final class SupabaseManager {
    nonisolated init() {}

    private static let tripDocumentsBucket = "trip-documents"
    private static let avatarsBucket = "avatars"

    private var client: SupabaseClient? {
        AuthSessionService.shared.client
    }

    private func requireClientAndUserId() async throws -> (SupabaseClient, UUID) {
        guard let client else { throw SupabaseManagerError.notConfigured }
        let session = try await client.auth.session
        return (client, session.user.id)
    }

    // MARK: - Trips

    func fetchTrips() async throws -> [Trip] {
        let (client, _) = try await requireClientAndUserId()
        let rows: [TripRow] = try await client
            .from("trips")
            .select()
            .order("updated_at", ascending: false)
            .execute()
            .value
        return rows.map { Self.mapTripRow($0) }
    }

    // MARK: - Profile

    func fetchOwnProfileDetail() async throws -> UserProfileDetail? {
        let (client, userId) = try await requireClientAndUserId()
        let rows: [ProfileHeroRow] = try await client
            .from("profiles")
            .select("id,username,display_name,avatar_url,bio,created_at,preferred_airport,preferred_currency,venmo_username,paypal_username")
            .eq("id", value: userId.uuidString)
            .limit(1)
            .execute()
            .value
        return rows.first.map(\.userProfileDetail)
    }

    func updateProfileFields(
        displayName: String?,
        username: String,
        bio: String?,
        preferredAirport: String?,
        preferredCurrency: String?,
        avatarURL: String?,
        venmoUsername: String?,
        paypalUsername: String?
    ) async throws {
        let (client, userId) = try await requireClientAndUserId()
        let nowIso = ISO8601DateFormatter().string(from: Date())
        let payload = ProfileFieldsUpdate(
            display_name: displayName,
            username: username,
            bio: bio,
            preferred_airport: preferredAirport,
            preferred_currency: preferredCurrency,
            avatar_url: avatarURL,
            venmo_username: venmoUsername,
            paypal_username: paypalUsername,
            updated_at: nowIso
        )
        try await client
            .from("profiles")
            .update(payload)
            .eq("id", value: userId.uuidString)
            .execute()
    }

    /// Uploads avatar to Storage bucket `avatars` (same path pattern as Expo `profileService`).
    func uploadProfileAvatar(imageData: Data, contentType: String) async throws -> String {
        let (client, userId) = try await requireClientAndUserId()
        guard !imageData.isEmpty else { throw SupabaseManagerError.invalidCoverImageData }
        let lower = contentType.lowercased()
        let isPng = lower.contains("png")
        let ext = isPng ? "png" : "jpg"
        let mime = isPng ? "image/png" : "image/jpeg"
        let path = "\(userId.uuidString.lowercased())/avatar.\(ext)"
        try await client.storage
            .from(Self.avatarsBucket)
            .upload(path, data: imageData, options: FileOptions(contentType: mime, upsert: true))
        let publicURL = try client.storage.from(Self.avatarsBucket).getPublicURL(path: path)
        let bust = Int(Date().timeIntervalSince1970 * 1000)
        return "\(publicURL.absoluteString)?t=\(bust)"
    }

    func fetchProfileAggregateStats() async throws -> ProfileAggregateStats {
        let (client, userId) = try await requireClientAndUserId()

        async let tripsTask: [TripStatsRow] = client
            .from("trips")
            .select("id,start_date,end_date,status,is_active")
            .eq("user_id", value: userId.uuidString)
            .execute()
            .value

        async let importedCountTask = Self.fetchImportedBookingsCount(client: client, userId: userId)
        async let placeRowsTask: [ActivityPlaceIdRow] = client
            .from("trip_activities")
            .select("place_id")
            .eq("user_id", value: userId.uuidString)
            .execute()
            .value

        let (tripRows, importedCount, placeRows) = try await (tripsTask, importedCountTask, placeRowsTask)

        let inputs = tripRows.map(\.bucketInput)
        let tripCount = inputs.count
        let upcomingOrActive = ProfileTripBucketing.countUpcomingOrActiveTrips(inputs)
        let distinctPlaces = Self.countDistinctNonEmptyPlaceIds(placeRows)

        return ProfileAggregateStats(
            tripCount: tripCount,
            upcomingOrActiveCount: upcomingOrActive,
            distinctPlaceCount: distinctPlaces,
            importedBookingCount: importedCount
        )
    }

    @discardableResult
    func addTrip(_ trip: Trip) async throws -> Trip {
        let (client, userId) = try await requireClientAndUserId()
        let calendar = Calendar.current
        let startISO = SupabaseModelMapping.calendarDateOnlyString(from: trip.startDate, calendar: calendar)
        let endISO = SupabaseModelMapping.calendarDateOnlyString(from: trip.endDate, calendar: calendar)
        let dates = SupabaseModelMapping.enumerateCalendarDateOnlyStrings(from: trip.startDate, through: trip.endDate, calendar: calendar)
        guard !dates.isEmpty else { throw SupabaseManagerError.invalidDateRange }

        let status = SupabaseModelMapping.inferTripStatus(startDate: trip.startDate, endDate: trip.endDate, calendar: calendar)
        let isActive = SupabaseModelMapping.isTripActive(startDate: trip.startDate, endDate: trip.endDate, calendar: calendar)

        let insert = TripInsert(
            user_id: userId,
            name: trip.title,
            destination: trip.destination,
            destination_place_id: trip.destinationPlaceId,
            start_date: startISO,
            end_date: endISO,
            status: status,
            is_active: isActive,
            description: trip.notes,
            cover_image_url: trip.coverImageUrl,
            cover_attribution: trip.coverImageAttribution,
            privacy: "private",
            total_budget: trip.totalBudget.map(DecimalCodec.init),
            budget_currency: trip.budgetCurrencyCode,
            city_profile_id: trip.cityProfileId,
            lat: trip.lat,
            lng: trip.lng
        )

        let created: TripRow = try await client
            .from("trips")
            .insert(insert, returning: .representation)
            .select()
            .single()
            .execute()
            .value

        let ideasDate = SupabaseModelMapping.addCalendarDaysString(startISO, offsetDays: -1, calendar: calendar)
        let ideasRow = TripDayBatchInsert(
            trip_id: created.id,
            user_id: userId,
            date: ideasDate,
            day_number: 0,
            label: "Ideas",
            notes: nil,
            timezone: nil
        )
        let scheduledRows = dates.enumerated().map { index, date in
            TripDayBatchInsert(
                trip_id: created.id,
                user_id: userId,
                date: date,
                day_number: index + 1,
                label: nil,
                notes: nil,
                timezone: nil
            )
        }
        try await client.from("trip_days").insert([ideasRow] + scheduledRows).execute()
        return Self.mapTripRow(created)
    }

    func updateTrip(_ trip: Trip) async throws {
        let (client, userId) = try await requireClientAndUserId()
        let calendar = Calendar.current
        let startISO = SupabaseModelMapping.calendarDateOnlyString(from: trip.startDate, calendar: calendar)
        let endISO = SupabaseModelMapping.calendarDateOnlyString(from: trip.endDate, calendar: calendar)
        let desired = SupabaseModelMapping.enumerateCalendarDateOnlyStrings(from: trip.startDate, through: trip.endDate, calendar: calendar)
        guard !desired.isEmpty else { throw SupabaseManagerError.invalidDateRange }

        try await SupabaseTripDayCascade.cascadeTripDaysForNewRange(
            client: client,
            tripId: trip.id,
            userId: userId,
            startDate: trip.startDate,
            endDate: trip.endDate,
            calendar: calendar
        )

        let status = SupabaseModelMapping.inferTripStatus(startDate: trip.startDate, endDate: trip.endDate, calendar: calendar)
        let isActive = SupabaseModelMapping.isTripActive(startDate: trip.startDate, endDate: trip.endDate, calendar: calendar)
        let nowIso = ISO8601DateFormatter().string(from: Date())

        let payload = TripUpdate(
            name: trip.title,
            destination: trip.destination,
            destination_place_id: trip.destinationPlaceId,
            start_date: startISO,
            end_date: endISO,
            description: trip.notes,
            cover_image_url: trip.coverImageUrl,
            cover_attribution: trip.coverImageAttribution,
            status: status,
            is_active: isActive,
            updated_at: nowIso,
            city_profile_id: trip.cityProfileId,
            lat: trip.lat,
            lng: trip.lng
        )

        // NOTE: filter on `id` only. RLS already enforces who can update —
        // for the owner via `is_trip_owner`, and for accepted editors via
        // `can_edit_trip`. Filtering on `user_id` here would silently drop
        // edits made by editor-collaborators, since the trip row's
        // `user_id` is the owner's id, not the caller's.
        try await client
            .from("trips")
            .update(payload)
            .eq("id", value: trip.id.uuidString)
            .execute()
    }

    func deleteTrip(id: UUID) async throws {
        // Deleting a trip is owner-only; keep the explicit `user_id` filter
        // so editors can't accidentally trigger a destructive call. RLS on
        // `trips` would also block this for non-owners, but defense in depth
        // is cheap here.
        let (client, userId) = try await requireClientAndUserId()
        try await client
            .from("trips")
            .delete()
            .eq("id", value: id.uuidString)
            .eq("user_id", value: userId.uuidString)
            .execute()
    }

    func regenerateDays(for tripId: UUID, startDate: Date, endDate: Date) async throws {
        let (client, userId) = try await requireClientAndUserId()
        try await SupabaseTripDayCascade.cascadeTripDaysForNewRange(
            client: client,
            tripId: tripId,
            userId: userId,
            startDate: startDate,
            endDate: endDate
        )
    }

    // MARK: - Days & activities

    // MARK: - Bulk timeline fetch (mirrors web fetchTripTimelineEnriched)

    /// Fetches `trip_days` + `trip_activities` + `trip_bookings` in three
    /// parallel queries, then groups activities by their `day_id` and matches
    /// bookings to days by the calendar date of `starts_at`.
    ///
    /// This replaces the old N+1 pattern (one `fetchPlaces(for:)` call per day)
    /// and aligns with the web app's `fetchTripTimelineEnriched` + parallel
    /// `trip_bookings` fetch in `tripDetailStore`.
    func fetchTripTimeline(for tripId: UUID) async throws -> (days: [ItineraryDay], placesByDayId: [UUID: [Place]]) {
        let (client, _) = try await requireClientAndUserId()
        let tripIdString = tripId.uuidString.lowercased()

        async let daysTask: [TripDayRow] = client
            .from("trip_days")
            .select()
            .eq("trip_id", value: tripIdString)
            .order("day_number", ascending: true)
            .execute()
            .value

        async let activitiesTask: [TripActivityRow] = client
            .from("trip_activities")
            .select()
            .eq("trip_id", value: tripIdString)
            .order("sort_order", ascending: true)
            .execute()
            .value

        async let bookingsTask: [TripBookingRow] = client
            .from("trip_bookings")
            .select()
            .eq("trip_id", value: tripIdString)
            .order("sort_order", ascending: true)
            .execute()
            .value

        let (dayRows, activityRows, bookingRows) = try await (daysTask, activitiesTask, bookingsTask)

        // Once we have the activities, fan out one more parallel query to
        // `city_places` for the distinct Google place_ids referenced by the
        // trip. This is the canonical enrichment table (rating, price level,
        // hero thumbnail, AI summary, subtypes, suggested visit length…).
        // We intentionally do NOT use `place_cache` — it's deprecated.
        let placeIds = Self.distinctPlaceIds(from: activityRows)
        let enrichments = try await Self.fetchCityPlaceEnrichments(client: client, placeIds: placeIds)

        let days = dayRows.map { Self.mapDayRow($0, tripId: tripId) }
            .sorted { $0.dayNumber < $1.dayNumber }

        // Seed the map so every day has an entry even when it has no places yet.
        var placesByDayId: [UUID: [Place]] = Dictionary(
            uniqueKeysWithValues: days.map { ($0.id, [Place]()) }
        )

        // Bookings are rendered from `trip_bookings` below. Some backend
        // flows also create a linked `trip_activities` shadow row with
        // `booking_id`; rendering both makes the row flip between activity
        // and booking presentations as realtime refreshes race. Treat
        // `trip_bookings` as canonical and skip those shadows here.
        let canonicalBookingIds = Set(bookingRows.map(\.id))

        // Activities already carry their day_id directly.
        for row in activityRows {
            if let bookingId = row.booking_id, canonicalBookingIds.contains(bookingId) {
                continue
            }
            let enrichment = row.place_id.flatMap { enrichments[$0] }
            let place = Self.mapActivityRow(row, dayId: row.day_id, enrichment: enrichment)
            placesByDayId[row.day_id, default: []].append(place)
        }

        // Bookings have no day_id — match by calendar date of starts_at.
        // If a sync race ever lands two trip_days rows for the same date,
        // we keep the first day_id rather than crashing. Bookings will
        // resolve to that day deterministically.
        let calendar = Calendar.current
        let daysByDateKey: [String: UUID] = Dictionary(
            days.compactMap { day -> (String, UUID)? in
                guard let date = day.date else { return nil }
                let key = SupabaseModelMapping.calendarDateOnlyString(from: date, calendar: calendar)
                return (key, day.id)
            },
            uniquingKeysWith: { existing, _ in existing }
        )
        let fallbackBookingDayId = days.first(where: { !$0.isWishlist })?.id ?? days.first?.id
        for row in bookingRows {
            guard let dayId = Self.resolveDayId(
                for: row,
                daysByDateKey: daysByDateKey,
                fallbackDayId: fallbackBookingDayId,
                calendar: calendar
            ) else { continue }
            let place = Self.mapBookingRow(row, dayId: dayId)
            placesByDayId[dayId, default: []].append(place)
        }

        // Sort each day's merged list: scheduled first (by startTime), then
        // unscheduled (by sortOrder) — mirrors web buildDayTimelineEntries.
        for dayId in placesByDayId.keys {
            placesByDayId[dayId]?.sort { a, b in
                switch (a.startTime, b.startTime) {
                case let (l?, r?): return l < r
                case (nil, _?):    return false
                case (_?, nil):    return true
                case (nil, nil):   return a.sortOrder < b.sortOrder
                }
            }
        }

        return (days, placesByDayId)
    }

    // MARK: - city_places enrichment

    /// Subset of `city_places` columns we care about for timeline rendering
    /// and the rich Place Detail sheet.
    /// All optional — any single field can be null in the database depending
    /// on enrichment status.
    ///
    /// Phase D.1 of the places-cost plan extended this with website / phone /
    /// hours / ai_editorial_summary / ai_review_summary / ai_why_go /
    /// ai_know_before_you_go so the Place Detail sheet can render rich data
    /// fully from owned `city_places` rather than firing a Google Place
    /// Details (the legacy expensive SKU) at sheet-open time.
    struct CityPlaceEnrichmentRow: Decodable, Sendable {
        let place_id: String
        let rating: Double?
        let user_ratings_total: Int?
        let price_level: Int?
        let thumbnail_url: String?
        let ai_short_summary: String?
        let subtypes: [String]?
        let time_spent_min: Int?
        let time_spent_max: Int?

        // Phase D.1 — rich detail fields backing PlaceDetailSheet.
        let website: String?
        let formatted_phone_number: String?
        /// Google opening_hours-style payload. Decoded lazily as JSONValue
        /// so callers can pluck `weekday_text` / `open_now` without us
        /// committing to a schema here (the column is jsonb).
        let opening_hours: JSONValue?
        let ai_editorial_summary: String?
        let ai_review_summary: String?
        let ai_why_go: [String]?
        let ai_know_before_you_go: [String]?
        let details_enriched_at: String?
        let ai_enriched_at: String?

        // Phase H.1 — image provenance + refresh tracking. `image_source`
        // is one of 'google' | 'serpapi' | 'wikimedia' | 'user' | 'unknown';
        // PlaceDetailSheet uses it to badge user-uploaded photos and to
        // decide whether to surface a CC attribution caption.
        let image_source: String?
        let images_refreshed_at: String?
        let thumbnail_attribution: String?
        /// Gallery JSONB: array of URL strings and/or objects with url-like keys
        /// (`url`, `thumbnail`, …). Hero prefers `firstGalleryImageURL(from:)`.
        let images: JSONValue?
        /// Serp/Google-style popular times: `{ "current_day", "graph_results" }`.
        let popular_times: JSONValue?

        // Phase I.1 — per-field attribution payload (CC license + DSA
        // compliance). Shape: `{ "summary": { "sources": [...] }, ... }`.
        // Decoded as JSONValue so we don't have to lock down the schema
        // on the iOS side every time the ingest function evolves.
        let ai_source_attribution: JSONValue?
    }

    /// Type-erased JSON value used by `CityPlaceEnrichmentRow.opening_hours`.
    /// Keeps the schema flexible: Google's `opening_hours` payload changes
    /// shape between Place Details API versions and we don't want to break
    /// decode the moment a new field appears.
    enum JSONValue: Decodable, Sendable {
        case string(String)
        case number(Double)
        case bool(Bool)
        case array([JSONValue])
        case object([String: JSONValue])
        case null

        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if c.decodeNil() { self = .null; return }
            if let v = try? c.decode(Bool.self) { self = .bool(v); return }
            if let v = try? c.decode(Double.self) { self = .number(v); return }
            if let v = try? c.decode(String.self) { self = .string(v); return }
            if let v = try? c.decode([JSONValue].self) { self = .array(v); return }
            if let v = try? c.decode([String: JSONValue].self) { self = .object(v); return }
            self = .null
        }
    }

    // MARK: - city_places.images (hero gallery)

    /// Keys aligned with `IMAGE_OBJECT_URL_KEYS` in `city_places_pool.ts`.
    private static let cityPlaceImageObjectURLKeys: [String] = [
        "url", "thumbnail", "serpapi_thumbnail", "photo_uri", "photoUri", "link", "src",
    ]

    /// First usable gallery URL from `city_places.images` JSONB (not `thumbnail_url`).
    /// Mirrors `firstImageUrlFromImagesJson` in `city_places_pool.ts`.
    static func firstGalleryImageURL(from images: JSONValue?) -> String? {
        guard let images else { return nil }
        switch images {
        case .null:
            return nil
        case .string(let s):
            return firstGalleryImageURLFromEncodedString(s)
        case .array(let arr):
            return firstGalleryImageURLFromJSONArray(arr)
        default:
            return nil
        }
    }

    private static func firstGalleryImageURLFromEncodedString(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return nil }
        if t.hasPrefix("[") || t.hasPrefix("{") {
            guard let data = t.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) else { return nil }
            return firstGalleryImageURLFromJSONSerialization(obj)
        }
        return trimHTTPURLString(t)
    }

    private static func firstGalleryImageURLFromJSONArray(_ arr: [JSONValue]) -> String? {
        for item in arr {
            switch item {
            case .string(let s):
                if let u = trimHTTPURLString(s) { return u }
                let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.hasPrefix("[") || trimmed.hasPrefix("{"),
                   let nested = firstGalleryImageURLFromEncodedString(s) {
                    return nested
                }
            case .object(let o):
                if let u = firstURLFromImageObjectJSONValue(o) { return u }
            default:
                break
            }
        }
        return nil
    }

    private static func firstGalleryImageURLFromJSONSerialization(_ any: Any) -> String? {
        guard let arr = any as? [Any] else { return nil }
        for item in arr {
            if let s = item as? String, let u = trimHTTPURLString(s) { return u }
            if let dict = item as? [String: Any], let u = firstURLFromImageObjectDict(dict) { return u }
        }
        return nil
    }

    private static func firstURLFromImageObjectJSONValue(_ o: [String: JSONValue]) -> String? {
        for k in cityPlaceImageObjectURLKeys {
            guard let v = o[k], case .string(let s) = v else { continue }
            if let u = trimHTTPURLString(s) { return u }
        }
        return nil
    }

    private static func firstURLFromImageObjectDict(_ o: [String: Any]) -> String? {
        for k in cityPlaceImageObjectURLKeys {
            guard let s = o[k] as? String else { continue }
            if let u = trimHTTPURLString(s) { return u }
        }
        return nil
    }

    private static func trimHTTPURLString(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return nil }
        let lower = t.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") { return t }
        return nil
    }

    /// Pulls distinct, non-empty Google `place_id`s from the activity rows so
    /// we can do one bulk `IN (…)` query instead of N round-trips.
    private static func distinctPlaceIds(from rows: [TripActivityRow]) -> [String] {
        var seen = Set<String>()
        for row in rows {
            let id = row.place_id?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !id.isEmpty { seen.insert(id) }
        }
        return Array(seen)
    }

    /// Fetches the city_places rows for the given place_ids and returns a
    /// `[place_id: row]` lookup. Returns an empty map when `placeIds` is empty
    /// (skips the round-trip entirely) or when the query errors — enrichment
    /// is best-effort and must never block timeline rendering.
    private static func fetchCityPlaceEnrichments(
        client: SupabaseClient,
        placeIds: [String]
    ) async throws -> [String: CityPlaceEnrichmentRow] {
        guard !placeIds.isEmpty else { return [:] }
        do {
            let rows: [CityPlaceEnrichmentRow] = try await client
                .from("city_places")
                .select(
                    """
                    place_id,rating,user_ratings_total,price_level,thumbnail_url,\
                    ai_short_summary,subtypes,time_spent_min,time_spent_max,\
                    website,formatted_phone_number,opening_hours,\
                    ai_editorial_summary,ai_review_summary,ai_why_go,ai_know_before_you_go,\
                    details_enriched_at,ai_enriched_at,\
                    image_source,images_refreshed_at,thumbnail_attribution,images,\
                    popular_times,\
                    ai_source_attribution
                    """
                )
                .in("place_id", values: placeIds)
                .execute()
                .value
            // city_places has no unique index on place_id (the same Google
            // place can be cached under multiple city profiles, and seeding
            // bugs can produce intra-city dupes), so we MUST resolve
            // collisions instead of using `uniqueKeysWithValues:` which
            // hard-traps in production. We keep the first row encountered;
            // per-row debug logging is intentionally avoided because this
            // enrichment runs during timeline refreshes and console spam can
            // make open SwiftUI menus appear to flicker.
            return Dictionary(rows.map { ($0.place_id, $0) }, uniquingKeysWith: { existing, _ in
                return existing
            })
        } catch is CancellationError {
            // Task was cancelled (tab switch, sheet dismissed, view torn down).
            // Enrichment is non-essential; return no enrichment rather than
            // surfacing a debug fatal while the timeline itself can still render.
            return [:]
        } catch {
            // Enrichment is non-essential — print in DEBUG so the data-quality
            // issue stays visible, but never trap. The timeline must still
            // render if city_places RLS / schema / network breaks this query.
            #if DEBUG
            print("[city_places] enrichment failed: \(error)")
            #endif
            return [:]
        }
    }

    /// Fetches a single `city_places` enrichment row by Google `place_id`.
    /// Returns `nil` if no row exists yet — the caller should consider that a
    /// "not enriched" state and may want to call
    /// `requestCityPlaceEnrichment(forGooglePlaceId:)` to enqueue one.
    /// Phase J.6 — Resolve a Google `place_id` (the trip's
    /// destination_place_id) to its `city_profiles.id`. The profile row itself
    /// does not store a Google place id; resolve through `city_places`, which
    /// carries both the Google `place_id` and owning `city_profile_id`.
    ///
    /// Fetches the geographic center of a city_profiles row by primary key.
    /// Used after first-time async resolution to persist lat/lng back to the
    /// trips row so future sessions read it directly. Returns nil on miss.
    func fetchCityProfileCenterCoords(id: UUID) async -> (lat: Double, lng: Double)? {
        guard let client = AuthSessionService.shared.client else { return nil }
        struct Row: Decodable { let center_lat: Double; let center_lng: Double }
        do {
            let rows: [Row] = try await client
                .from("city_profiles")
                .select("center_lat,center_lng")
                .eq("id", value: id.uuidString.lowercased())
                .limit(1)
                .execute()
                .value
            guard let r = rows.first else { return nil }
            return (r.center_lat, r.center_lng)
        } catch {
            return nil
        }
    }

    /// NOTE: This only matches when the destination's place_id is itself a
    /// row in `city_places` (i.e. the destination is a known POI inside an
    /// already-seeded city). For city / locality place_ids — which is the
    /// common case — this returns `nil`. Use
    /// `resolveCityProfileId(forTrip:)` instead for any new caller.
    func fetchCityProfileId(forGooglePlaceId googlePlaceId: String) async -> UUID? {
        do {
            let (client, _) = try await requireClientAndUserId()

            struct CityPlaceRow: Decodable { let city_profile_id: UUID? }
            let cityPlaceRows: [CityPlaceRow] = try await client
                .from("city_places")
                .select("city_profile_id")
                .eq("place_id", value: googlePlaceId)
                .limit(1)
                .execute()
                .value
            if let id = cityPlaceRows.first?.city_profile_id {
                return id
            }
            return nil
        } catch {
            #if DEBUG
            print("[city_profiles] resolve failed: \(error)")
            #endif
            return nil
        }
    }

    /// Robust 3-tier `city_profile_id` resolver for a trip.
    ///
    /// Mirrors the server-side `matchCityProfile` ladder used by
    /// itinerary-ai, but runs entirely against owned data (no Google
    /// hops). Order matters — cheapest/most-likely first:
    ///
    ///   1. **Slug match** — `toSlug(trip.destination.firstSegment)`
    ///      against `city_profiles.city_slug`. Single round-trip; this
    ///      covers every city we (or auto-seed) ever populated.
    ///   2. **Geo proximity** — bbox query on `city_profiles.center_*`
    ///      around `trip.lat/lng`, then haversine to pick the nearest
    ///      profile within its own `match_radius_km`. Catches the case
    ///      where the trip label slug doesn't match (e.g. "Le Marais,
    ///      Paris" vs slug `paris`) but coordinates clearly do.
    ///   3. **Legacy `place_id` lookup** — re-uses
    ///      `fetchCityProfileId(forGooglePlaceId:)` so trips whose
    ///      destination *is* a seeded POI still resolve.
    ///
    /// Returns `nil` only when none of the three tiers match. Never
    /// throws — search fan-out should never fail because of us.
    func resolveCityProfileId(forTrip trip: Trip) async -> UUID? {
        guard let client = AuthSessionService.shared.client else { return nil }

        struct ProfileRow: Decodable {
            let id: UUID
            let center_lat: Double
            let center_lng: Double
            let match_radius_km: Double?
        }

        // Tier 1: slug match.
        let firstSegment = trip.destination
            .split(separator: ",", maxSplits: 1, omittingEmptySubsequences: true)
            .first
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            ?? trip.destination.trimmingCharacters(in: .whitespacesAndNewlines)
        let slug = Self.cityProfileSlug(firstSegment)
        if !slug.isEmpty {
            do {
                let rows: [ProfileRow] = try await client
                    .from("city_profiles")
                    .select("id,center_lat,center_lng,match_radius_km")
                    .eq("city_slug", value: slug)
                    .limit(1)
                    .execute()
                    .value
                if let id = rows.first?.id {
                    return id
                }
            } catch {
                #if DEBUG
                print("[city_profiles] slug resolve failed: \(error)")
                #endif
            }
        }

        // Tier 2: geo proximity. Needs trip coordinates.
        if let lat = trip.lat, let lng = trip.lng {
            // 0.5° ≈ 55 km in latitude — wide enough to catch any
            // profile whose `match_radius_km` (default 50) covers us.
            // Longitude span is widened by 1/cos(lat) so the bbox stays
            // proportional outside the equator.
            let latDelta = 0.55
            let cosLat = max(0.05, cos(lat * .pi / 180))
            let lngDelta = 0.55 / cosLat
            do {
                let rows: [ProfileRow] = try await client
                    .from("city_profiles")
                    .select("id,center_lat,center_lng,match_radius_km")
                    .gte("center_lat", value: lat - latDelta)
                    .lte("center_lat", value: lat + latDelta)
                    .gte("center_lng", value: lng - lngDelta)
                    .lte("center_lng", value: lng + lngDelta)
                    .limit(20)
                    .execute()
                    .value
                let tripCoord = CLLocationCoordinate2D(latitude: lat, longitude: lng)
                var best: (id: UUID, distKm: Double)?
                for row in rows {
                    let distKm = HaversineDistance.distance(
                        from: tripCoord,
                        to: CLLocationCoordinate2D(latitude: row.center_lat, longitude: row.center_lng)
                    )
                    let radius = row.match_radius_km ?? 50
                    if distKm <= radius {
                        if best == nil || distKm < best!.distKm {
                            best = (row.id, distKm)
                        }
                    }
                }
                if let best {
                    return best.id
                }
            } catch {
                #if DEBUG
                print("[city_profiles] geo resolve failed: \(error)")
                #endif
            }
        }

        // Tier 3: legacy place_id lookup (cheap when destination is a
        // seeded POI; harmless miss otherwise).
        if let placeId = trip.destinationPlaceId {
            return await fetchCityProfileId(forGooglePlaceId: placeId)
        }

        return nil
    }

    /// Slug derivation that mirrors the server-side `toSlug` in
    /// `city_profile_lookup.ts` so iOS lookups land on the same row the
    /// auto-seeder created. Strips diacritics, lowercases, collapses
    /// non-alphanumerics into a single hyphen, and trims edge hyphens.
    static func cityProfileSlug(_ raw: String) -> String {
        let folded = raw.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: .current)
        let lowered = folded.lowercased()
        var slug = ""
        slug.reserveCapacity(lowered.count)
        var lastWasHyphen = true // suppress leading hyphen
        for ch in lowered {
            if ch.isLetter || ch.isNumber {
                slug.append(ch)
                lastWasHyphen = false
            } else if !lastWasHyphen {
                slug.append("-")
                lastWasHyphen = true
            }
        }
        if slug.hasSuffix("-") { slug.removeLast() }
        return slug
    }

    func fetchCityPlaceEnrichment(googlePlaceId: String) async throws -> CityPlaceEnrichmentRow? {
        let (client, _) = try await requireClientAndUserId()
        let rows: [CityPlaceEnrichmentRow] = try await client
            .from("city_places")
            .select(
                """
                place_id,rating,user_ratings_total,price_level,thumbnail_url,\
                ai_short_summary,subtypes,time_spent_min,time_spent_max,\
                website,formatted_phone_number,opening_hours,\
                ai_editorial_summary,ai_review_summary,ai_why_go,ai_know_before_you_go,\
                details_enriched_at,ai_enriched_at,\
                image_source,images_refreshed_at,thumbnail_attribution,images,\
                popular_times,\
                ai_source_attribution
                """
            )
            .eq("place_id", value: googlePlaceId)
            .limit(1)
            .execute()
            .value
        return rows.first
    }

    // MARK: - Phase F (user photos)

    private static let placePhotosQuarantineBucket = "place-photos-quarantine"

    /// Pre-flight gate. Returns the structured verdict the upload UI uses
    /// to render the right error copy. Server enforces; this is for UX,
    /// not security.
    func checkPhotoUploadQuota(cityPlaceId: UUID) async -> DataService.PhotoUploadQuotaVerdict {
        do {
            let (client, _) = try await requireClientAndUserId()
            // Phase F.4 — `nonisolated` because Swift 6 strict
            // concurrency demands the Encodable conformance on RPC
            // params be sendable; declaring the struct inside a
            // `@MainActor` method otherwise marks the conformance
            // as MainActor-isolated.
            nonisolated struct Body: Encodable, Sendable { let p_city_place_id: String }
            struct Row: Decodable {
                let allowed: Bool
                let reason: String
                let remaining: Int
            }
            let rows: [Row] = try await client
                .rpc("check_photo_upload_quota",
                     params: Body(p_city_place_id: cityPlaceId.uuidString.lowercased()))
                .execute()
                .value
            if let r = rows.first {
                return .init(allowed: r.allowed, reason: r.reason, remaining: r.remaining)
            }
            return .init(allowed: false, reason: "unknown", remaining: 0)
        } catch {
            #if DEBUG
            print("[place_user_photos] quota check failed: \(error)")
            #endif
            return .init(allowed: false, reason: "unknown", remaining: 0)
        }
    }

    /// Uploads JPEG bytes to the quarantine bucket and inserts a
    /// `pending_moderation` row in `place_user_photos`. The path is
    /// namespaced by the uploader's auth UID to satisfy the storage RLS
    /// policy from migration `20260601160000_place_user_photos.sql`.
    func uploadQuarantinedPlacePhoto(
        cityPlaceId: UUID,
        imageData: Data,
        exifLat: Double?,
        exifLng: Double?,
        progress: @escaping @Sendable (Double) -> Void
    ) async -> Result<DataService.UploadedPhotoStub, PlacePhotoUploadError> {
        do {
            let (client, userId) = try await requireClientAndUserId()
            guard !imageData.isEmpty else { return .failure(.couldNotReadImage) }

            let photoId = UUID()
            let storagePath =
                "\(userId.uuidString.lowercased())/\(photoId.uuidString.lowercased()).jpg"

            // Supabase-swift's `upload` doesn't expose progress directly;
            // we report two synthetic checkpoints so the UI moves rather
            // than spinning silently. Phase G.4 will replace with real
            // background-URLSession progress.
            progress(0.1)
            try await client.storage
                .from(Self.placePhotosQuarantineBucket)
                .upload(
                    storagePath,
                    data: imageData,
                    options: FileOptions(contentType: "image/jpeg", upsert: false)
                )
            progress(0.85)

            // Decode the image once for width/height/bytes, best-effort.
            let (w, h) = Self.imageDimensions(from: imageData)

            struct Insert: Encodable {
                let id: String
                let city_place_id: String
                let uploader_user_id: String
                let storage_path: String
                let exif_lat: Double?
                let exif_lng: Double?
                let width: Int?
                let height: Int?
                let bytes: Int?
            }
            try await client
                .from("place_user_photos")
                .insert(Insert(
                    id: photoId.uuidString.lowercased(),
                    city_place_id: cityPlaceId.uuidString.lowercased(),
                    uploader_user_id: userId.uuidString.lowercased(),
                    storage_path: storagePath,
                    exif_lat: exifLat,
                    exif_lng: exifLng,
                    width: w,
                    height: h,
                    bytes: imageData.count
                ))
                .execute()
            progress(1.0)
            return .success(.init(photoId: photoId, storagePath: storagePath))
        } catch {
            return .failure(.uploadFailed(error.localizedDescription))
        }
    }

    /// Calls the `moderate-place-photo` Edge Function. Returns the
    /// resolved client-side outcome — server-side state has already been
    /// written by the time this returns.
    ///
    /// Uses raw URLRequest rather than the SDK's `client.functions.invoke`
    /// to mirror `ItineraryAIService.invoke()`'s 401-refresh retry shape
    /// and to keep the JSON parsing under our control (the function
    /// returns flexible status payloads).
    func invokeModeratePlacePhoto(photoId: UUID) async -> DataService.ModerationOutcome {
        do {
            let (_, _) = try await requireClientAndUserId()
            guard let token = try await sessionAccessToken() else {
                return .failure("Sign in to upload photos.")
            }
            let url = URL(string: "\(AppConfig.supabaseURL)/functions/v1/moderate-place-photo")!
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue(AppConfig.supabaseAnonKey, forHTTPHeaderField: "apikey")
            request.timeoutInterval = 90
            struct Body: Encodable { let photo_id: String }
            request.httpBody = try JSONEncoder().encode(
                Body(photo_id: photoId.uuidString.lowercased())
            )
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode >= 500 {
                return .failure("Moderation service is unavailable.")
            }
            struct R: Decodable {
                let ok: Bool?
                let status: String?
                let public_url: String?
                let reason: String?
                let detail: String?
                let error: String?
            }
            guard let parsed = try? JSONDecoder().decode(R.self, from: data) else {
                return .failure("Moderation didn't return a usable response.")
            }
            if let err = parsed.error {
                return .failure(err)
            }
            switch parsed.status {
            case "approved":
                if let s = parsed.public_url, let url = URL(string: s) {
                    return .approved(url)
                }
                return .pendingReview(nil)
            case "pending_review", "pending_moderation":
                return .pendingReview(parsed.reason)
            case "rejected":
                return .rejected(parsed.reason ?? "rejected", parsed.detail)
            default:
                return .failure("Unexpected moderation status.")
            }
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    // MARK: - Phase F.7 (lifecycle events + DSA appeals)

    /// Pulls all unacknowledged `place_user_photo_events` rows for the
    /// signed-in user. Sorted oldest-first so badges show the most
    /// recent verdict on top once reversed for display.
    func fetchUnacknowledgedPhotoEvents() async throws -> [PhotoLifecycleEvent] {
        guard let client = AuthSessionService.shared.client else { return [] }
        struct Row: Decodable {
            let id: Int64
            let photo_id: String
            let status: String
            let reason: String?
            let detail: String?
            let created_at: String
        }
        let rows: [Row] = try await client
            .from("place_user_photo_events")
            .select("id, photo_id, status, reason, detail, created_at")
            .filter("acknowledged_at", operator: "is", value: "null")
            .order("created_at", ascending: true)
            .limit(50)
            .execute()
            .value
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fallback = ISO8601DateFormatter()
        fallback.formatOptions = [.withInternetDateTime]
        return rows.compactMap { row -> PhotoLifecycleEvent? in
            guard let photoId = UUID(uuidString: row.photo_id) else { return nil }
            let date = formatter.date(from: row.created_at)
                ?? fallback.date(from: row.created_at)
                ?? Date()
            return PhotoLifecycleEvent(
                id: row.id,
                photoId: photoId,
                status: row.status,
                reason: row.reason,
                detail: row.detail,
                createdAt: date
            )
        }
    }

    /// Marks an event as acknowledged. Failures are silent — the badge
    /// will simply re-appear on the next fetch.
    func acknowledgePhotoEvent(id: Int64) async {
        guard let client = AuthSessionService.shared.client else { return }
        nonisolated struct Args: Encodable, Sendable { let p_event_id: Int64 }
        do {
            try await client
                .rpc("acknowledge_photo_event", params: Args(p_event_id: id))
                .execute()
        } catch {
            #if DEBUG
            print("acknowledgePhotoEvent failed: \(error)")
            #endif
        }
    }

    /// Files a DSA Article 20 internal complaint against a moderation
    /// decision. RLS + the RPC body itself enforces uploader-only
    /// access. Returns `true` when the row was inserted.
    func submitDsaAppeal(photoId: UUID, appealText: String) async -> Bool {
        guard let client = AuthSessionService.shared.client else { return false }
        nonisolated struct Args: Encodable, Sendable {
            let p_photo_id: String
            let p_appeal_text: String
        }
        do {
            try await client
                .rpc("submit_dsa_appeal", params: Args(
                    p_photo_id: photoId.uuidString.lowercased(),
                    p_appeal_text: appealText
                ))
                .execute()
            return true
        } catch {
            #if DEBUG
            print("submitDsaAppeal failed: \(error)")
            #endif
            return false
        }
    }

    // MARK: - Phase F.8 (per-photo community reports)

    /// Calls `report_user_photo`. Maps known SQL error codes back into
    /// human-readable messages so the report sheet can show inline
    /// guidance instead of a generic failure.
    func reportUserPhoto(
        photoId: UUID,
        reason: String,
        details: String?
    ) async -> DataService.PhotoReportOutcome {
        guard let client = AuthSessionService.shared.client else {
            return .failure(message: "Sign in to report photos.")
        }
        nonisolated struct Args: Encodable, Sendable {
            let p_photo_id: String
            let p_reason: String
            let p_details: String?
        }
        struct Row: Decodable {
            let report_count: Int
            let escalated: Bool
        }
        do {
            let rows: [Row] = try await client
                .rpc("report_user_photo", params: Args(
                    p_photo_id: photoId.uuidString.lowercased(),
                    p_reason: reason,
                    p_details: details?.isEmpty == true ? nil : details
                ))
                .execute()
                .value
            return .success(escalated: rows.first?.escalated ?? false)
        } catch {
            let message = Self.userFacingPhotoReportError(error)
            #if DEBUG
            print("reportUserPhoto failed: \(error)")
            #endif
            return .failure(message: message)
        }
    }

    private static func userFacingPhotoReportError(_ error: Error) -> String {
        let s = String(describing: error)
        if s.contains("cannot_report_own_photo") {
            return "You can't report your own photo."
        }
        if s.contains("photo_not_found") {
            return "This photo no longer exists."
        }
        if s.contains("invalid_reason") {
            return "Please choose a valid reason."
        }
        if s.contains("unauthenticated") {
            return "Sign in to report photos."
        }
        return "Couldn't send your report. Try again in a moment."
    }

    /// Returns the current Supabase session access token, refreshing
    /// once on expiry. Returns nil if the user is signed out.
    private func sessionAccessToken() async throws -> String? {
        guard let client = AuthSessionService.shared.client else { return nil }
        let session = try await client.auth.session
        return session.accessToken
    }

    // MARK: - Wave 0 — commit-attachment + pro_gate analytics

    /// Calls the `commit-attachment` Edge Function. Returns the row id +
    /// signed upload URL the caller streams bytes to. See
    /// `BackgroundUploader` for the full pipeline.
    func commitAttachment(descriptor: AttachmentUploadDescriptor) async throws -> AttachmentCommitResult {
        guard let token = try await sessionAccessToken() else {
            throw BackgroundUploaderError.notSignedIn
        }
        let url = URL(string: "\(AppConfig.supabaseURL)/functions/v1/commit-attachment")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(AppConfig.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.timeoutInterval = 30

        struct Body: Encodable {
            let kind: String
            let trip_id: String
            let parent_id: String
            let file_name: String
            let mime_type: String
            let byte_size: Int
            let attachment_type: String?
            let is_cover: Bool?
            let title: String?
            let category: String?
        }
        let body = Body(
            kind: descriptor.surface.rawValue,
            trip_id: descriptor.tripId.uuidString.lowercased(),
            parent_id: descriptor.parentId.uuidString.lowercased(),
            file_name: descriptor.fileName,
            mime_type: descriptor.mimeType,
            byte_size: descriptor.bytes.count,
            attachment_type: descriptor.attachmentType,
            is_cover: descriptor.isCover,
            title: descriptor.title,
            category: descriptor.category
        )
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        if status >= 400 {
            let detail = String(data: data, encoding: .utf8) ?? "HTTP \(status)"
            throw BackgroundUploaderError.serverError(detail)
        }

        struct Response: Decodable {
            let row_id: String
            let bucket: String
            let storage_path: String
            let signed_upload_url: String
        }
        let parsed = try JSONDecoder().decode(Response.self, from: data)
        guard let rowId = UUID(uuidString: parsed.row_id),
              let signed = URL(string: parsed.signed_upload_url) else {
            throw BackgroundUploaderError.serverError("Server returned an unparseable response.")
        }
        return AttachmentCommitResult(
            rowId: rowId,
            storagePath: parsed.storage_path,
            bucket: parsed.bucket,
            signedUploadURL: signed
        )
    }

    /// Calls the `record_pro_gate_attempt` Postgres RPC. Throws on RLS /
    /// network failure; callers fire-and-forget via `try?`.
    func recordProGateAttempt(
        gateName: String,
        surface: String?,
        metadata: [String: String]
    ) async throws {
        let (client, _) = try await requireClientAndUserId()
        // Swift 6 — declare the Encodable params struct as `nonisolated`
        // so the synthesised conformance isn't @MainActor-locked. Same
        // pattern as `checkPhotoUploadQuota` above.
        nonisolated struct Params: Encodable, Sendable {
            let p_gate_name: String
            let p_surface: String?
            let p_metadata: [String: String]
        }
        try await client
            .rpc(
                "record_pro_gate_attempt",
                params: Params(
                    p_gate_name: gateName,
                    p_surface: surface,
                    p_metadata: metadata
                )
            )
            .execute()
    }

    private static func imageDimensions(from data: Data) -> (Int?, Int?) {
        if let img = UIImage(data: data) {
            return (Int(img.size.width), Int(img.size.height))
        }
        return (nil, nil)
    }

    /// Phase E.2 — submit a user report against a `city_places` row by its
    /// Google `place_id`. Idempotent per (place, user, reason) on the
    /// server. Returns `true` once at least one row was reported (i.e. the
    /// place exists in our pool). Failures are logged in DEBUG and surfaced
    /// as `false`.
    ///
    /// `reason` must be one of: `closed`, `incorrect`, `inappropriate`,
    /// `other` (matches the CHECK constraint on `city_place_reports`).
    func reportCityPlace(
        forGooglePlaceId placeId: String,
        reason: String,
        details: String? = nil
    ) async -> Bool {
        guard !placeId.isEmpty else { return false }
        do {
            let (client, _) = try await requireClientAndUserId()
            struct IdRow: Decodable { let id: UUID }
            let rows: [IdRow] = try await client
                .from("city_places")
                .select("id")
                .eq("place_id", value: placeId)
                .execute()
                .value
            if rows.isEmpty { return false }
            for r in rows {
                nonisolated struct Body: Encodable, Sendable {
                    let p_city_place_id: String
                    let p_reason: String
                    let p_details: String?
                }
                _ = try? await client
                    .rpc(
                        "report_city_place",
                        params: Body(
                            p_city_place_id: r.id.uuidString.lowercased(),
                            p_reason: reason,
                            p_details: details
                        )
                    )
                    .execute()
            }
            return true
        } catch {
            #if DEBUG
            print("[city_places] reportCityPlace failed: \(error)")
            #endif
            return false
        }
    }

    /// Phase H.3 — TTL-driven lazy refresh. Calls
    /// `refresh_city_place_if_stale` server-side, which reads the data &
    /// image TTL flags and enqueues focused enrichment jobs. Returns the
    /// number of jobs enqueued (0, 1, or 2). Best-effort, never throws.
    @discardableResult
    func refreshCityPlaceIfStale(
        forGooglePlaceId placeId: String,
        priority: String = "background"
    ) async -> Int {
        guard !placeId.isEmpty else { return 0 }
        do {
            let (client, _) = try await requireClientAndUserId()
            struct IdRow: Decodable { let id: UUID }
            let rows: [IdRow] = try await client
                .from("city_places")
                .select("id")
                .eq("place_id", value: placeId)
                .execute()
                .value
            if rows.isEmpty { return 0 }
            var totalEnqueued = 0
            for r in rows {
                nonisolated struct Body: Encodable, Sendable {
                    let p_city_place_id: String
                    let p_priority: String
                }
                let response = try? await client
                    .rpc(
                        "refresh_city_place_if_stale",
                        params: Body(
                            p_city_place_id: r.id.uuidString.lowercased(),
                            p_priority: priority
                        )
                    )
                    .execute()
                if let data = response?.data,
                   let n = (try? JSONDecoder().decode(Int.self, from: data)) {
                    totalEnqueued += n
                }
            }
            return totalEnqueued
        } catch {
            #if DEBUG
            print("[city_places] refreshIfStale failed: \(error)")
            #endif
            return 0
        }
    }

    /// Phase D.2 — enqueue a foreground enrichment job for a `city_places`
    /// row identified by its Google `place_id`. Stampede-deduped server-side
    /// (`request_city_place_enrichment` RPC). Best-effort, never throws —
    /// enrichment is opportunistic and the sheet must still render without
    /// it.
    @discardableResult
    func requestCityPlaceEnrichment(
        forGooglePlaceId placeId: String,
        priority: String = "foreground"
    ) async -> Bool {
        guard !placeId.isEmpty else { return false }
        do {
            let (client, _) = try await requireClientAndUserId()
            // Look up the city_places row(s) — there may be multiple
            // (one per city profile) so we enqueue all of them.
            struct IdRow: Decodable { let id: UUID }
            let rows: [IdRow] = try await client
                .from("city_places")
                .select("id")
                .eq("place_id", value: placeId)
                .execute()
                .value
            if rows.isEmpty { return false }
            for r in rows {
                nonisolated struct RPCBody: Encodable, Sendable {
                    let p_city_place_id: String
                    let p_priority: String
                }
                _ = try? await client
                    .rpc(
                        "request_city_place_enrichment",
                        params: RPCBody(
                            p_city_place_id: r.id.uuidString.lowercased(),
                            p_priority: priority
                        )
                    )
                    .execute()
            }
            return true
        } catch {
            #if DEBUG
            print("[city_places] requestEnrichment failed: \(error)")
            #endif
            return false
        }
    }

    func fetchDays(for tripId: UUID) async throws -> [ItineraryDay] {
        let (client, _) = try await requireClientAndUserId()
        let rows: [TripDayRow] = try await client
            .from("trip_days")
            .select()
            .eq("trip_id", value: tripId.uuidString)
            .order("day_number", ascending: true)
            .execute()
            .value
        return rows.map { Self.mapDayRow($0, tripId: tripId) }
    }

    func fetchPlaces(for dayId: UUID) async throws -> [Place] {
        let (client, _) = try await requireClientAndUserId()
        let rows: [TripActivityRow] = try await client
            .from("trip_activities")
            .select()
            .eq("day_id", value: dayId.uuidString)
            .order("sort_order", ascending: true)
            .execute()
            .value
        return rows.map { Self.mapActivityRow($0, dayId: dayId) }
    }

    func addPlace(_ place: Place) async throws {
        let (client, userId) = try await requireClientAndUserId()
        let tripId = try await requireTripIdForDay(client: client, dayId: place.itineraryDayId)
        let row = Self.buildActivityInsert(place: place, tripId: tripId, userId: userId)
        try await client.from("trip_activities").insert(row).execute()
    }

    func updatePlace(_ place: Place) async throws {
        let (client, userId) = try await requireClientAndUserId()
        let tripId = try await requireTripIdForDay(client: client, dayId: place.itineraryDayId)
        let nowIso = ISO8601DateFormatter().string(from: Date())
        let payload = Self.buildActivityUpdate(place: place, tripId: tripId, userId: userId, updatedAt: nowIso)
        try await client
            .from("trip_activities")
            .update(payload)
            .eq("id", value: place.id.uuidString)
            .execute()
    }

    func deletePlace(id: UUID) async throws {
        let (client, _) = try await requireClientAndUserId()
        try await client
            .from("trip_activities")
            .delete()
            .eq("id", value: id.uuidString)
            .execute()
    }

    func movePlace(placeId: UUID, toDayId: UUID) async throws {
        let (client, _) = try await requireClientAndUserId()
        let nowIso = ISO8601DateFormatter().string(from: Date())
        struct MovePayload: Encodable, Sendable {
            let day_id: UUID
            let updated_at: String
        }
        try await client
            .from("trip_activities")
            .update(MovePayload(day_id: toDayId, updated_at: nowIso))
            .eq("id", value: placeId.uuidString)
            .execute()
    }

    func fetchParsedBookings(for tripId: UUID) async throws -> [ParsedBooking] {
        _ = tripId
        return [ParsedBooking]()
    }

    /// Uploads JPEG bytes to Storage (path matches Expo: `{userId}/trip-covers/{tripId}/cover.jpg`).
    func uploadCoverPhoto(data: Data, tripId: UUID) async throws -> String {
        let (client, userId) = try await requireClientAndUserId()
        guard !data.isEmpty else { throw SupabaseManagerError.invalidCoverImageData }

        let path =
            "\(userId.uuidString.lowercased())/trip-covers/\(tripId.uuidString.lowercased())/cover.jpg"

        try await client.storage
            .from(Self.tripDocumentsBucket)
            .upload(
                path,
                data: data,
                options: FileOptions(contentType: "image/jpeg", upsert: true)
            )

        let publicURL = try client.storage
            .from(Self.tripDocumentsBucket)
            .getPublicURL(path: path)
        return publicURL.absoluteString
    }

    // MARK: - Notes & checklists (trip hero pills + screens)

    func ensureTripChecklistTemplates(tripId: UUID) async throws {
        let (client, _) = try await requireClientAndUserId()
        let rpcParams: [String: String] = ["p_trip_id": tripId.uuidString]
        try await client
            .rpc("ensure_trip_checklist_templates", params: rpcParams)
            .execute()
    }

    func fetchTripNoteCount(tripId: UUID) async throws -> Int {
        let (client, _) = try await requireClientAndUserId()
        struct IdRow: Decodable, Sendable {
            let id: UUID
        }
        let rows: [IdRow] = try await client
            .from("trip_notes")
            .select("id")
            .eq("trip_id", value: tripId.uuidString)
            .execute()
            .value
        return rows.count
    }

    func fetchTripChecklistProgress(tripId: UUID) async throws -> (done: Int, total: Int) {
        let (client, _) = try await requireClientAndUserId()
        struct ChecklistIdRow: Decodable, Sendable {
            let id: UUID
            let template_key: String?
        }
        let lists: [ChecklistIdRow] = try await client
            .from("trip_checklists")
            .select("id, template_key")
            .eq("trip_id", value: tripId.uuidString)
            .execute()
            .value
        let ids = lists.filter { $0.template_key != nil }.map(\.id)
        guard !ids.isEmpty else { return (0, 0) }

        struct DoneRow: Decodable, Sendable {
            let is_done: Bool
        }
        let items: [DoneRow] = try await client
            .from("checklist_items")
            .select("is_done")
            .in("checklist_id", values: ids)
            .execute()
            .value
        let total = items.count
        let done = items.filter(\.is_done).count
        return (done, total)
    }

    func listTripNotes(tripId: UUID) async throws -> [TripNote] {
        let (client, _) = try await requireClientAndUserId()
        let rows: [TripNoteRow] = try await client
            .from("trip_notes")
            .select("id, trip_id, user_id, title, body, created_at, updated_at")
            .eq("trip_id", value: tripId.uuidString)
            .order("updated_at", ascending: false)
            .execute()
            .value
        return rows.map(Self.mapTripNoteRow)
    }

    func createTripNote(tripId: UUID) async throws -> TripNote {
        let (client, userId) = try await requireClientAndUserId()
        let row: TripNoteRow = try await client
            .from("trip_notes")
            .insert(
                TripNoteInsert(trip_id: tripId, user_id: userId, title: "", body: ""),
                returning: .representation
            )
            .select()
            .single()
            .execute()
            .value
        return Self.mapTripNoteRow(row)
    }

    func updateTripNote(noteId: UUID, title: String, body: String) async throws {
        let (client, _) = try await requireClientAndUserId()
        let nowIso = ISO8601DateFormatter().string(from: Date())
        let payload = TripNoteUpdate(title: title, body: body, updated_at: nowIso)
        try await client
            .from("trip_notes")
            .update(payload)
            .eq("id", value: noteId.uuidString)
            .execute()
    }

    func deleteTripNote(noteId: UUID) async throws {
        let (client, _) = try await requireClientAndUserId()
        try await client
            .from("trip_notes")
            .delete()
            .eq("id", value: noteId.uuidString)
            .execute()
    }

    func listTemplateTripChecklistsWithItems(tripId: UUID) async throws -> [TripChecklistWithItems] {
        let (client, _) = try await requireClientAndUserId()
        let templateKeys = TripChecklistTemplateKey.allCases.map(\.rawValue)
        let rows: [TripChecklistNestedRow] = try await client
            .from("trip_checklists")
            .select("id, trip_id, template_key, title, sort_order, checklist_items(id, checklist_id, title, is_done, sort_order)")
            .eq("trip_id", value: tripId.uuidString)
            .in("template_key", values: templateKeys)
            .order("sort_order", ascending: true)
            .execute()
            .value
        return rows.map(Self.mapTripChecklistNested).sorted { a, b in
            TripChecklistTemplateKey.sortIndex(forTemplateKey: a.templateKey)
                < TripChecklistTemplateKey.sortIndex(forTemplateKey: b.templateKey)
        }
    }

    func setChecklistItemDone(itemId: UUID, isDone: Bool) async throws {
        let (client, _) = try await requireClientAndUserId()
        let nowIso = ISO8601DateFormatter().string(from: Date())
        struct Payload: Encodable, Sendable {
            let is_done: Bool
            let updated_at: String
        }
        try await client
            .from("checklist_items")
            .update(Payload(is_done: isDone, updated_at: nowIso))
            .eq("id", value: itemId.uuidString)
            .execute()
    }

    func addChecklistItem(checklistId: UUID, tripId: UUID, title: String, sortOrder: Int) async throws -> TripChecklistItem {
        let (client, userId) = try await requireClientAndUserId()
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        struct Insert: Encodable, Sendable {
            let checklist_id: UUID
            let trip_id: UUID
            let user_id: UUID
            let title: String
            let is_done: Bool
            let sort_order: Int
        }
        let row: ChecklistItemNestedRow = try await client
            .from("checklist_items")
            .insert(
                Insert(
                    checklist_id: checklistId,
                    trip_id: tripId,
                    user_id: userId,
                    title: trimmed,
                    is_done: false,
                    sort_order: sortOrder
                ),
                returning: .representation
            )
            .select()
            .single()
            .execute()
            .value
        return TripChecklistItem(
            id: row.id,
            checklistId: row.checklist_id,
            title: row.title,
            isDone: row.is_done,
            sortOrder: row.sort_order
        )
    }

    func deleteChecklistItem(itemId: UUID) async throws {
        let (client, _) = try await requireClientAndUserId()
        try await client
            .from("checklist_items")
            .delete()
            .eq("id", value: itemId.uuidString)
            .execute()
    }

    private struct TripNoteRow: Decodable, Sendable {
        let id: UUID
        let trip_id: UUID
        let user_id: UUID
        let title: String
        let body: String
        let created_at: String?
        let updated_at: String?
    }

    private struct TripNoteInsert: Encodable, Sendable {
        let trip_id: UUID
        let user_id: UUID
        let title: String
        let body: String
    }

    private struct TripNoteUpdate: Encodable, Sendable {
        let title: String
        let body: String
        let updated_at: String
    }

    private struct TripChecklistNestedRow: Decodable, Sendable {
        let id: UUID
        let trip_id: UUID
        let template_key: String?
        let title: String
        let sort_order: Int
        let checklist_items: [ChecklistItemNestedRow]?
    }

    private struct ChecklistItemNestedRow: Decodable, Sendable {
        let id: UUID
        let checklist_id: UUID
        let title: String
        let is_done: Bool
        let sort_order: Int
    }

    private static func mapTripNoteRow(_ row: TripNoteRow) -> TripNote {
        let created = SupabaseModelMapping.parsePostgresTimestamp(row.created_at) ?? Date()
        let updated = SupabaseModelMapping.parsePostgresTimestamp(row.updated_at) ?? created
        return TripNote(
            id: row.id,
            tripId: row.trip_id,
            userId: row.user_id,
            title: row.title,
            body: row.body,
            createdAt: created,
            updatedAt: updated
        )
    }

    private static func mapTripChecklistNested(_ row: TripChecklistNestedRow) -> TripChecklistWithItems {
        let sortedItems = (row.checklist_items ?? []).sorted { $0.sort_order < $1.sort_order }.map { item in
            TripChecklistItem(
                id: item.id,
                checklistId: item.checklist_id,
                title: item.title,
                isDone: item.is_done,
                sortOrder: item.sort_order
            )
        }
        return TripChecklistWithItems(
            id: row.id,
            tripId: row.trip_id,
            templateKey: row.template_key,
            title: row.title,
            sortOrder: row.sort_order,
            items: sortedItems
        )
    }

    // MARK: - Mapping

    private struct TripStatsRow: Decodable, Sendable {
        let id: UUID
        let start_date: String?
        let end_date: String?
        let status: String
        let is_active: Bool

        var bucketInput: ProfileTripBucketInput {
            ProfileTripBucketInput(
                id: id,
                startDateISO: start_date,
                endDateISO: end_date,
                status: status,
                isActive: is_active
            )
        }
    }

    private struct ActivityPlaceIdRow: Decodable, Sendable {
        let place_id: String?
    }

    private static func countDistinctNonEmptyPlaceIds(_ rows: [ActivityPlaceIdRow]) -> Int {
        var seen = Set<String>()
        for row in rows {
            let trimmed = row.place_id?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty { seen.insert(trimmed) }
        }
        return seen.count
    }

    private static func fetchImportedBookingsCount(client: SupabaseClient, userId: UUID) async throws -> Int {
        let response = try await client
            .from("trip_bookings")
            .select("id", head: true, count: .exact)
            .eq("user_id", value: userId.uuidString)
            .in("source", values: ["upload", "email"])
            .execute()
        return response.count ?? 0
    }

    private struct ProfileFieldsUpdate: Encodable, Sendable {
        let display_name: String?
        let username: String
        let bio: String?
        let preferred_airport: String?
        let preferred_currency: String?
        let avatar_url: String?
        let venmo_username: String?
        let paypal_username: String?
        let updated_at: String
    }

    private struct ProfileHeroRow: Decodable, Sendable {
        let id: UUID
        let username: String
        let display_name: String?
        let avatar_url: String?
        let bio: String?
        let created_at: String?
        let preferred_airport: String?
        let preferred_currency: String?
        let venmo_username: String?
        let paypal_username: String?

        var userProfileDetail: UserProfileDetail {
            UserProfileDetail(
                id: id,
                username: username,
                displayName: display_name,
                avatarURLString: avatar_url,
                bio: bio,
                preferredAirport: preferred_airport,
                preferredCurrency: preferred_currency,
                createdAt: SupabaseModelMapping.parsePostgresTimestamp(created_at),
                venmoUsername: venmo_username,
                paypalUsername: paypal_username
            )
        }
    }

    private struct TripRow: Decodable, Sendable {
        let id: UUID
        let user_id: UUID
        let name: String
        let description: String?
        let destination: String
        let destination_place_id: String?
        let start_date: String?
        let end_date: String?
        let cover_image_url: String?
        let cover_attribution: String?
        let created_at: String?
        let updated_at: String?
        let status: String
        let is_active: Bool
        // Phase 1 of collaborative budget: trip-level planned spend, optional
        // (NULL = not set). Decoded via DecimalCodec to preserve precision.
        let total_budget: DecimalCodec?
        let budget_currency: String?
        // City profile linkage (migration 20260426150000). NULL for trips
        // that haven't been backfilled or resolved yet.
        let city_profile_id: UUID?
        let lat: Double?
        let lng: Double?
    }

    private struct TripInsert: Encodable, Sendable {
        let user_id: UUID
        let name: String
        let destination: String
        let destination_place_id: String?
        let start_date: String
        let end_date: String
        let status: String
        let is_active: Bool
        let description: String?
        let cover_image_url: String?
        let cover_attribution: String?
        let privacy: String
        let total_budget: DecimalCodec?
        let budget_currency: String
        let city_profile_id: UUID?
        let lat: Double?
        let lng: Double?
    }

    private struct TripUpdate: Encodable, Sendable {
        let name: String
        let destination: String
        let destination_place_id: String?
        let start_date: String
        let end_date: String
        let description: String?
        let cover_image_url: String?
        let cover_attribution: String?
        let status: String
        let is_active: Bool
        let updated_at: String
        let city_profile_id: UUID?
        let lat: Double?
        let lng: Double?
    }

    /// Lightweight PATCH that only writes city_profile_id / lat / lng.
    /// Called by TripMapView after the first async resolution so all
    /// subsequent map opens skip the 3-tier resolver entirely.
    func patchTripCityProfile(
        tripId: UUID,
        cityProfileId: UUID,
        lat: Double,
        lng: Double
    ) async {
        guard let client = AuthSessionService.shared.client else { return }
        struct Patch: Encodable {
            let city_profile_id: UUID
            let lat: Double
            let lng: Double
        }
        do {
            try await client
                .from("trips")
                .update(Patch(city_profile_id: cityProfileId, lat: lat, lng: lng))
                .eq("id", value: tripId.uuidString.lowercased())
                .execute()
        } catch {
            #if DEBUG
            print("[trips] patchTripCityProfile failed: \(error)")
            #endif
        }
    }

    private struct TripDayRow: Decodable, Sendable {
        let id: UUID
        let trip_id: UUID
        let day_number: Int
        let date: String
        let timezone: String?
    }

    private struct TripDayBatchInsert: Encodable, Sendable {
        let trip_id: UUID
        let user_id: UUID
        let date: String
        let day_number: Int
        let label: String?
        let notes: String?
        let timezone: String?
    }

    private struct TripActivityRow: Decodable, Sendable {
        let id: UUID
        let day_id: UUID
        let trip_id: UUID
        let name: String
        let description: String?
        let category: String?
        let starts_at: String?
        let duration_minutes: Int?
        let latitude: Double?
        let longitude: Double?
        let address: String?
        let place_id: String?
        let rating: Double?
        let price_level: Int?
        let sort_order: Int
        let booking_id: UUID?
        let travel_from_previous_minutes: Int?
        let travel_mode: String?
        let hero_image_url: String?
    }

    // Partial decode of trip_bookings.details_json — only the fields we need
    // for building a `BookingDetailUnion`. Extra keys are silently ignored.
    private struct BookingJSONDetails: Decodable, Sendable {
        let party_size: Int?
        let airline: String?
        let flight_number: String?
        let terminal: String?
        let seat: String?
        let room_type: String?
        let car_type: String?
    }

    private struct TripBookingRow: Decodable, Sendable {
        let id: UUID
        let trip_id: UUID
        let user_id: UUID
        let kind: String
        let title: String
        let confirmation_code: String?
        let provider: String?
        let starts_at: String?
        let ends_at: String?
        let start_location: String?
        let end_location: String?
        let start_lat: Double?
        let start_lng: Double?
        let sort_order: Int
        let details_json: BookingJSONDetails?
        // Phase 1 of collaborative budget: optional booking total + ISO 4217
        // currency. The DB trigger reads these to mirror the booking into
        // `trip_expenses` automatically.
        let amount: DecimalCodec?
        let currency: String?
    }

    private struct TripActivityInsert: Encodable, Sendable {
        let trip_id: UUID
        let day_id: UUID
        let user_id: UUID
        let name: String
        let description: String?
        let category: String
        let starts_at: String?
        let duration_minutes: Int
        let latitude: Double?
        let longitude: Double?
        let address: String?
        let place_id: String?
        let rating: Int?
        let price_level: Int?
        let estimated_cost: Double?
        let currency: String?
        let booking_id: UUID?
        let source: String
        let sort_order: Int
        let travel_from_previous_minutes: Int?
        let directions_url: String?
        let travel_mode: String
    }

    private struct TripActivityUpdate: Encodable, Sendable {
        let day_id: UUID
        let trip_id: UUID
        let user_id: UUID
        let name: String
        let description: String?
        let category: String
        let starts_at: String?
        let duration_minutes: Int
        let latitude: Double?
        let longitude: Double?
        let address: String?
        let place_id: String?
        let sort_order: Int
        let updated_at: String
    }

    private static func mapTripRow(_ row: TripRow) -> Trip {
        let start = SupabaseModelMapping.parseDateOnly(row.start_date) ?? Date()
        let end = SupabaseModelMapping.parseDateOnly(row.end_date) ?? start
        let created = SupabaseModelMapping.parsePostgresTimestamp(row.created_at) ?? Date()
        let updated = SupabaseModelMapping.parsePostgresTimestamp(row.updated_at) ?? created
        return Trip(
            id: row.id,
            userId: row.user_id,
            title: row.name,
            destination: row.destination,
            destinationPlaceId: row.destination_place_id,
            cityProfileId: row.city_profile_id,
            lat: row.lat,
            lng: row.lng,
            startDate: start,
            endDate: end,
            coverImageUrl: row.cover_image_url,
            coverImageAttribution: row.cover_attribution,
            notes: row.description,
            createdAt: created,
            updatedAt: updated,
            databaseStatus: row.status,
            isMarkedActiveOnServer: row.is_active,
            totalBudget: row.total_budget?.value,
            budgetCurrencyCode: row.budget_currency ?? "USD"
        )
    }

    private static func mapDayRow(_ row: TripDayRow, tripId: UUID) -> ItineraryDay {
        let tz = row.timezone?.trimmingCharacters(in: .whitespacesAndNewlines)
        return ItineraryDay(
            id: row.id,
            tripId: tripId,
            dayNumber: row.day_number,
            date: SupabaseModelMapping.parseDateOnly(row.date),
            timeZoneIdentifier: (tz?.isEmpty == false) ? tz : nil
        )
    }

    /// Maps a single `trip_activities` row → `Place`, folding in any
    /// `city_places` enrichment we have for the same Google `place_id`.
    /// Activity-row fields take precedence (the user's plan); city_places
    /// fills in NULL gaps (rating, price level, hero thumbnail, subtypes…).
    /// `enrichment` may be `nil` when the activity has no `place_id` or the
    /// enrichment row hasn't been written yet — both are graceful no-ops.
    private static func mapActivityRow(
        _ row: TripActivityRow,
        dayId: UUID,
        enrichment: CityPlaceEnrichmentRow? = nil
    ) -> Place {
        let isBooking = row.booking_id != nil
        let start = row.starts_at.flatMap { SupabaseModelMapping.parsePostgresTimestamp($0) }

        // Prefer the activity's own duration; fall back to city_places'
        // editorial "time_spent_min" so we still have *something* to show in
        // the subtitle / accessibility for places the user hasn't sized.
        let mergedDurationMinutes = row.duration_minutes ?? enrichment?.time_spent_min

        let end: Date? = {
            guard let s = start, let dur = mergedDurationMinutes, dur > 0 else { return nil }
            return s.addingTimeInterval(Double(dur) * 60)
        }()

        return Place(
            id: row.id,
            itineraryDayId: dayId,
            name: row.name,
            address: row.address,
            lat: row.latitude,
            lng: row.longitude,
            category: row.category,
            notes: row.description,
            sortOrder: row.sort_order,
            startTime: start,
            endTime: end,
            isBooking: isBooking,
            bookingType: isBooking ? "activity" : nil,
            confirmationNumber: nil,
            bookingDetails: nil,
            googlePlaceId: row.place_id,
            heroImageUrl: row.hero_image_url ?? enrichment?.mergedHeroImageURL,
            rating: row.rating ?? enrichment?.rating,
            userRatingsTotal: enrichment?.user_ratings_total,
            priceLevel: row.price_level ?? enrichment?.price_level,
            aiShortSummary: enrichment?.ai_short_summary,
            durationMinutes: mergedDurationMinutes,
            subtypes: enrichment?.subtypes,
            travelFromPreviousMinutes: row.travel_from_previous_minutes,
            travelMode: row.travel_mode
        )
    }

    // MARK: - Booking row mapping

    private static func mapBookingRow(_ row: TripBookingRow, dayId: UUID) -> Place {
        let category = bookingKindToCategory(row.kind)
        let start = row.starts_at.flatMap { SupabaseModelMapping.parsePostgresTimestamp($0) }
        let end   = row.ends_at.flatMap   { SupabaseModelMapping.parsePostgresTimestamp($0) }
        let details = buildBookingDetails(row: row, category: category, start: start, end: end)
        return Place(
            id: row.id,
            itineraryDayId: dayId,
            name: row.title,
            address: row.start_location,
            lat: row.start_lat,
            lng: row.start_lng,
            category: category.map(\.rawValue) ?? row.kind,
            notes: nil,
            sortOrder: row.sort_order,
            startTime: start,
            endTime: end,
            isBooking: true,
            bookingType: category?.rawValue ?? row.kind,
            confirmationNumber: row.confirmation_code,
            bookingDetails: details,
            googlePlaceId: nil,
            bookingAmount: row.amount?.value,
            bookingCurrencyCode: row.currency
        )
    }

    private static func bookingKindToCategory(_ kind: String) -> BookingCategory? {
        switch kind.lowercased() {
        case "flight":                        return .flight
        case "lodging", "hotel":              return .hotel
        case "restaurant":                    return .restaurant
        case "car_rental", "car":             return .carRental
        case "activity", "tour", "ticket":    return .activity
        case "transport", "train", "bus",
             "ferry", "transit":              return .transport
        default:                              return nil
        }
    }

    private static func buildBookingDetails(
        row: TripBookingRow,
        category: BookingCategory?,
        start: Date?,
        end: Date?
    ) -> BookingDetailUnion? {
        let json = row.details_json
        switch category {
        case .flight:
            return .flight(FlightDetails(
                airline: json?.airline ?? row.provider ?? "",
                flightNumber: json?.flight_number ?? "",
                departureAirport: row.start_location ?? "",
                arrivalAirport: row.end_location ?? "",
                departureTime: start,
                arrivalTime: end,
                terminal: json?.terminal ?? "",
                gate: "",
                seat: json?.seat ?? ""
            ))
        case .hotel:
            let nights: Int? = {
                guard let s = start, let e = end else { return nil }
                return Calendar.current.dateComponents([.day], from: s, to: e).day
            }()
            return .hotel(HotelDetails(
                checkInDate: start,
                checkInTime: nil,
                checkOutDate: end,
                checkOutTime: nil,
                roomType: json?.room_type ?? "",
                nights: nights
            ))
        case .restaurant:
            return .restaurant(RestaurantDetails(
                reservationTime: start,
                partySize: json?.party_size
            ))
        case .carRental:
            return .carRental(CarRentalDetails(
                company: row.provider ?? "",
                pickupLocation: row.start_location ?? "",
                dropoffLocation: row.end_location ?? "",
                pickupTime: start,
                dropoffTime: end,
                carType: json?.car_type ?? ""
            ))
        case .activity:
            return .activity(ActivityDetails(
                provider: row.provider ?? "",
                duration: nil,
                ticketNumber: row.confirmation_code ?? ""
            ))
        case .transport:
            return .transport(TransportDetails(
                operatorName: row.provider ?? "",
                serviceNumber: "",
                departureStation: row.start_location ?? "",
                arrivalStation: row.end_location ?? "",
                departureTime: start,
                arrivalTime: end,
                seat: json?.seat ?? ""
            ))
        case nil:
            return nil
        }
    }

    /// Finds which day a booking belongs to by matching the calendar-date of
    /// `starts_at` (or `ends_at` when start is absent) against `trip_days.date`.
    /// Falls back to the first scheduled day deterministically; using
    /// `Dictionary.values.first` here made date-less bookings jump between
    /// sections on repeated refreshes.
    private static func resolveDayId(
        for booking: TripBookingRow,
        daysByDateKey: [String: UUID],
        fallbackDayId: UUID?,
        calendar: Calendar
    ) -> UUID? {
        let rawDate = booking.starts_at ?? booking.ends_at
        guard let rawDate,
              let date = SupabaseModelMapping.parsePostgresTimestamp(rawDate) else {
            return fallbackDayId
        }
        let key = SupabaseModelMapping.calendarDateOnlyString(from: date, calendar: calendar)
        return daysByDateKey[key] ?? fallbackDayId
    }

    private static func activityCategory(for place: Place) -> String {
        switch place.categoryEnum {
        case .hotel:
            return "custom"
        default:
            return place.categoryEnum.rawValue
        }
    }

    private static func durationMinutes(for place: Place) -> Int {
        if let start = place.startTime, let end = place.endTime {
            let minutes = Int(end.timeIntervalSince(start) / 60)
            return max(15, minutes)
        }
        return 60
    }

    private static func startsAtISO(for place: Place) -> String? {
        guard let start = place.startTime else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: start)
    }

    private func requireTripIdForDay(client: SupabaseClient, dayId: UUID) async throws -> UUID {
        struct DayTripId: Decodable, Sendable {
            let trip_id: UUID
        }
        let row: DayTripId = try await client
            .from("trip_days")
            .select("trip_id")
            .eq("id", value: dayId.uuidString)
            .single()
            .execute()
            .value
        return row.trip_id
    }

    private static func buildActivityInsert(place: Place, tripId: UUID, userId: UUID) -> TripActivityInsert {
        TripActivityInsert(
            trip_id: tripId,
            day_id: place.itineraryDayId,
            user_id: userId,
            name: place.name,
            description: place.notes,
            category: activityCategory(for: place),
            starts_at: startsAtISO(for: place),
            duration_minutes: durationMinutes(for: place),
            latitude: place.lat,
            longitude: place.lng,
            address: place.address,
            place_id: place.googlePlaceId,
            rating: nil,
            price_level: nil,
            estimated_cost: nil,
            currency: nil,
            booking_id: nil,
            source: "manual",
            sort_order: place.sortOrder,
            travel_from_previous_minutes: nil,
            directions_url: nil,
            travel_mode: "walking"
        )
    }

    private static func buildActivityUpdate(place: Place, tripId: UUID, userId: UUID, updatedAt: String) -> TripActivityUpdate {
        TripActivityUpdate(
            day_id: place.itineraryDayId,
            trip_id: tripId,
            user_id: userId,
            name: place.name,
            description: place.notes,
            category: activityCategory(for: place),
            starts_at: startsAtISO(for: place),
            duration_minutes: durationMinutes(for: place),
            latitude: place.lat,
            longitude: place.lng,
            address: place.address,
            place_id: place.googlePlaceId,
            sort_order: place.sortOrder,
            updated_at: updatedAt
        )
    }
}

extension SupabaseManager.CityPlaceEnrichmentRow {
    /// Activity hero merge: first `images` gallery URL, else non-empty `thumbnail_url`.
    var mergedHeroImageURL: String? {
        SupabaseManager.firstGalleryImageURL(from: images) ?? thumbnailHeroFallback
    }

    private var thumbnailHeroFallback: String? {
        guard let t = thumbnail_url?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }
}

#if DEBUG
extension SupabaseManager.CityPlaceEnrichmentRow {
    /// Canvas / previews: only `place_id` and columns you set; everything else nil.
    init(previewPlaceId place_id: String, popular_times: SupabaseManager.JSONValue?) {
        self.place_id = place_id
        self.rating = nil
        self.user_ratings_total = nil
        self.price_level = nil
        self.thumbnail_url = nil
        self.ai_short_summary = nil
        self.subtypes = nil
        self.time_spent_min = nil
        self.time_spent_max = nil
        self.website = nil
        self.formatted_phone_number = nil
        self.opening_hours = nil
        self.ai_editorial_summary = nil
        self.ai_review_summary = nil
        self.ai_why_go = nil
        self.ai_know_before_you_go = nil
        self.details_enriched_at = nil
        self.ai_enriched_at = nil
        self.image_source = nil
        self.images_refreshed_at = nil
        self.thumbnail_attribution = nil
        self.images = nil
        self.popular_times = popular_times
        self.ai_source_attribution = nil
    }
}
#endif

// =============================================================================

