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
        let cityProfile = await resolvedCityProfileForTripCover(trip)

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
            city_profile_id: cityProfile.id,
            lat: cityProfile.lat,
            lng: cityProfile.lng
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

        var mapped = Self.mapTripRow(created)
        if mapped.coverImageUrl == nil, let cityProfileId = cityProfile.id {
            if let cover = await pickCachedCityCover(
                cityProfileId: cityProfileId,
                tripId: created.id
            ) {
                let didPatch = await patchTripCover(
                    client: client,
                    tripId: created.id,
                    cover: cover
                )
                if didPatch {
                    mapped.coverImageUrl = cover.imageUrl
                    mapped.coverImageAttribution = cover.attribution
                }
            }
        }
        return mapped
    }

    private func resolvedCityProfileForTripCover(_ trip: Trip) async -> (id: UUID?, lat: Double?, lng: Double?) {
        if let id = trip.cityProfileId {
            if let lat = trip.lat, let lng = trip.lng {
                return (id, lat, lng)
            }
            if let coords = await fetchCityProfileCenterCoords(id: id) {
                return (id, coords.lat, coords.lng)
            }
            return (id, trip.lat, trip.lng)
        }

        guard let id = await resolveCityProfileId(forTrip: trip) else {
            return (nil, trip.lat, trip.lng)
        }
        if let coords = await fetchCityProfileCenterCoords(id: id) {
            return (id, coords.lat, coords.lng)
        }
        return (id, trip.lat, trip.lng)
    }

    private struct CityProfileCoverSelection: Sendable {
        let imageUrl: String
        let attribution: String?
    }

    private func pickCachedCityCover(
        cityProfileId: UUID,
        tripId: UUID
    ) async -> CityProfileCoverSelection? {
        guard let client = AuthSessionService.shared.client else { return nil }

        nonisolated struct Params: Encodable, Sendable {
            let p_city_profile_id: String
            let p_trip_id: String
        }
        struct Row: Decodable {
            let image_url: String
            let cover_attribution: String?
        }

        do {
            let rows: [Row] = try await client
                .rpc(
                    "pick_city_profile_cover_image",
                    params: Params(
                        p_city_profile_id: cityProfileId.uuidString.lowercased(),
                        p_trip_id: tripId.uuidString.lowercased()
                    )
                )
                .execute()
                .value
            guard let row = rows.first, !row.image_url.isEmpty else { return nil }
            return CityProfileCoverSelection(
                imageUrl: row.image_url,
                attribution: row.cover_attribution
            )
        } catch {
            #if DEBUG
            print("[city_profile_covers] pick failed: \(error)")
            #endif
            return nil
        }
    }

    private func patchTripCover(
        client: SupabaseClient,
        tripId: UUID,
        cover: CityProfileCoverSelection
    ) async -> Bool {
        nonisolated struct Patch: Encodable, Sendable {
            let cover_image_url: String
            let cover_attribution: String?
        }

        do {
            try await client
                .from("trips")
                .update(Patch(
                    cover_image_url: cover.imageUrl,
                    cover_attribution: cover.attribution
                ))
                .eq("id", value: tripId.uuidString.lowercased())
                .execute()
            return true
        } catch {
            #if DEBUG
            print("[city_profile_covers] trip cover patch failed: \(error)")
            #endif
            return false
        }
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

        async let tripTzTask: String? = Self.fetchTripDisplayTimezone(client: client, tripIdString: tripIdString)

        let (dayRows, activityRows, bookingRows, tripDisplayTz) = try await (daysTask, activitiesTask, bookingsTask, tripTzTask)

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
        // Use the trip's destination timezone (from day rows) so that a flight
        // departing late UTC lands on the correct local calendar day.
        // IMPORTANT: build the day-key lookup from the RAW `trip_days.date`
        // string (already `yyyy-MM-dd`), not from a re-parsed Date — parsing
        // the day date in device TZ and re-formatting in trip TZ shifts the
        // value by one day whenever those TZs straddle midnight for the
        // implied absolute instant.
        let tripTimeZone = Self.resolveTripTimeZone(days: days, tripDisplayTimezone: tripDisplayTz)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = tripTimeZone

        // Exclude wishlist days (`day_number = 0`) — they carry a placeholder
        // date (usually the day before the trip starts) which would otherwise
        // attract bookings via either exact date match or the closest-day
        // fallback inside `resolveDayId`.
        let daysByDateKey: [String: UUID] = Dictionary(
            dayRows.compactMap { row -> (String, UUID)? in
                guard row.day_number != 0 else { return nil }
                return (String(row.date.prefix(10)), row.id)
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

        // Sort each day's merged list by the same spine instant the UI shows
        // (`startTime`, else booking-type fallbacks), then `sortOrder`.
        for dayId in placesByDayId.keys {
            placesByDayId[dayId]?.sort { a, b in
                switch (a.timelineSpineSortInstant(hotelTimelineRole: nil), b.timelineSpineSortInstant(hotelTimelineRole: nil)) {
                case let (l?, r?): return l < r
                case (nil, _?): return false
                case (_?, nil): return true
                case (nil, nil): return a.sortOrder < b.sortOrder
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
            // Propagate cancellation so callers see a clean failure instead
            // of silently receiving an empty enrichment map. Swallowing it
            // previously let `fetchTripTimeline` return Place structs stripped
            // of subtypes/rating/thumbnails, which the view model committed —
            // causing the timeline subtitle and spine icon to shuffle between
            // enriched and unenriched values on every debounce cancellation.
            throw CancellationError()
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
        let tripId = try await requireTripIdForDay(client: client, dayId: dayId)
        let dayRow: TripDayRow = try await client
            .from("trip_days")
            .select("id, trip_id, day_number, date, timezone")
            .eq("id", value: dayId.uuidString)
            .single()
            .execute()
            .value

        async let activitiesTask: [TripActivityRow] = client
            .from("trip_activities")
            .select()
            .eq("day_id", value: dayId.uuidString)
            .order("sort_order", ascending: true)
            .execute()
            .value

        async let bookingsTask: [TripBookingRow] = client
            .from("trip_bookings")
            .select()
            .eq("trip_id", value: tripId.uuidString)
            .order("sort_order", ascending: true)
            .execute()
            .value

        async let tripTzTask: String? = Self.fetchTripDisplayTimezone(client: client, tripIdString: tripId.uuidString.lowercased())

        let (activityRows, bookingRows, tripDisplayTz) = try await (activitiesTask, bookingsTask, tripTzTask)
        let canonicalBookingIds = Set(bookingRows.map(\.id))
        var places = activityRows
            .filter { row in
                guard let bookingId = row.booking_id else { return true }
                return !canonicalBookingIds.contains(bookingId)
            }
            .map { Self.mapActivityRow($0, dayId: dayId) }

        // Prefer the day's own timezone, then the trip's display_timezone, then
        // device TZ. This keeps booking-day resolution consistent with how the
        // trip detail and bookings list views show times.
        let tripTimeZone: TimeZone = {
            if let tz = dayRow.timezone?.trimmingCharacters(in: .whitespacesAndNewlines), !tz.isEmpty,
               let zone = TimeZone(identifier: tz) {
                return zone
            }
            if let tz = tripDisplayTz?.trimmingCharacters(in: .whitespacesAndNewlines), !tz.isEmpty,
               let zone = TimeZone(identifier: tz) {
                return zone
            }
            return .current
        }()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = tripTimeZone

        let daysByDateKey: [String: UUID] = [String(dayRow.date.prefix(10)): dayId]
        places.append(contentsOf: bookingRows.compactMap { booking -> Place? in
            guard Self.resolveDayId(
                for: booking,
                daysByDateKey: daysByDateKey,
                fallbackDayId: nil,
                calendar: calendar
            ) == dayId else { return nil }
            return Self.mapBookingRow(booking, dayId: dayId)
        })

        return places.sorted { lhs, rhs in
            if lhs.sortOrder != rhs.sortOrder { return lhs.sortOrder < rhs.sortOrder }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    func fetchBookings(for tripId: UUID) async throws -> [Place] {
        let (client, _) = try await requireClientAndUserId()
        let tripIdString = tripId.uuidString.lowercased()

        async let daysTask: [TripDayRow] = client
            .from("trip_days")
            .select("id, trip_id, day_number, date, timezone")
            .eq("trip_id", value: tripIdString)
            .order("day_number", ascending: true)
            .execute()
            .value

        async let bookingsTask: [TripBookingRow] = client
            .from("trip_bookings")
            .select()
            .eq("trip_id", value: tripIdString)
            .order("starts_at", ascending: true)
            .execute()
            .value

        async let tripTzTask: String? = Self.fetchTripDisplayTimezone(client: client, tripIdString: tripIdString)

        let (dayRows, bookingRows, tripDisplayTz) = try await (daysTask, bookingsTask, tripTzTask)
        let days = dayRows.map { Self.mapDayRow($0, tripId: tripId) }
            .sorted { $0.dayNumber < $1.dayNumber }

        let tripTimeZone = Self.resolveTripTimeZone(days: days, tripDisplayTimezone: tripDisplayTz)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = tripTimeZone

        // Wishlist days (`day_number = 0`) carry a placeholder date and must
        // not attract bookings via exact-match or closest-day fallback.
        let daysByDateKey: [String: UUID] = Dictionary(
            dayRows.compactMap { row -> (String, UUID)? in
                guard row.day_number != 0 else { return nil }
                return (String(row.date.prefix(10)), row.id)
            },
            uniquingKeysWith: { existing, _ in existing }
        )
        let fallbackDayId = days.first(where: { !$0.isWishlist })?.id ?? days.first?.id

        return bookingRows.compactMap { row in
            guard let dayId = Self.resolveDayId(
                for: row,
                daysByDateKey: daysByDateKey,
                fallbackDayId: fallbackDayId,
                calendar: calendar
            ) else { return nil }
            return Self.mapBookingRow(row, dayId: dayId)
        }
    }

    func addPlace(_ place: Place) async throws {
        let (client, userId) = try await requireClientAndUserId()
        let tripId = try await requireTripIdForDay(client: client, dayId: place.itineraryDayId)
        if place.isBooking {
            if try await tripBookingRowExists(client: client, id: place.id) {
                let nowIso = ISO8601DateFormatter().string(from: Date())
                let row = try Self.buildBookingUpdate(
                    place: place,
                    tripId: tripId,
                    userId: userId,
                    updatedAt: nowIso
                )
                try await client
                    .from("trip_bookings")
                    .update(row)
                    .eq("id", value: place.id.uuidString)
                    .execute()
            } else {
                let row = try Self.buildBookingInsert(place: place, tripId: tripId, userId: userId)
                try await client.from("trip_bookings").insert(row).execute()
            }
            return
        }
        let row = Self.buildActivityInsert(place: place, tripId: tripId, userId: userId)
        try await client.from("trip_activities").insert(row).execute()
    }

    func updatePlace(_ place: Place) async throws {
        let (client, userId) = try await requireClientAndUserId()
        let tripId = try await requireTripIdForDay(client: client, dayId: place.itineraryDayId)
        let nowIso = ISO8601DateFormatter().string(from: Date())
        if place.isBooking {
            let payload = try Self.buildBookingUpdate(place: place, tripId: tripId, userId: userId, updatedAt: nowIso)
            try await client
                .from("trip_bookings")
                .update(payload)
                .eq("id", value: place.id.uuidString)
                .execute()
            return
        }
        let payload = Self.buildActivityUpdate(place: place, tripId: tripId, userId: userId, updatedAt: nowIso)
        try await client
            .from("trip_activities")
            .update(payload)
            .eq("id", value: place.id.uuidString)
            .execute()
    }

    func deletePlace(id: UUID) async throws {
        let (client, _) = try await requireClientAndUserId()
        do {
            try await client
                .from("trip_bookings")
                .delete()
                .eq("id", value: id.uuidString)
                .execute()
        } catch {
            #if DEBUG
            print("[bookings] delete fallback to activity: \(error)")
            #endif
        }
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

    func fetchForwardingEmailAddress(for tripId: UUID) async throws -> String {
        let (client, userId) = try await requireClientAndUserId()
        let rows: [ForwardingAddressRow] = try await client
            .from("user_forwarding_addresses")
            .select("id,address_token,is_active")
            .eq("user_id", value: userId.uuidString)
            .eq("trip_id", value: tripId.uuidString)
            .limit(1)
            .execute()
            .value

        if let existing = rows.first {
            if !existing.is_active {
                try await client
                    .from("user_forwarding_addresses")
                    .update(ForwardingAddressUpdate(is_active: true))
                    .eq("id", value: existing.id.uuidString)
                    .execute()
            }
            return Self.forwardingEmailAddress(from: existing.address_token)
        }

        let token = Self.makeForwardingAddressToken()
        let inserted: ForwardingAddressRow = try await client
            .from("user_forwarding_addresses")
            .insert(
                ForwardingAddressInsert(
                    user_id: userId,
                    trip_id: tripId,
                    address_token: token,
                    is_active: true
                ),
                returning: .representation
            )
            .select("id,address_token,is_active")
            .single()
            .execute()
            .value
        return Self.forwardingEmailAddress(from: inserted.address_token)
    }

    func fetchForwardedBookingSummary(for tripId: UUID) async throws -> ForwardedBookingSummary {
        let (client, _) = try await requireClientAndUserId()
        let rows: [EmailForwardingStatusRow] = try await client
            .from("email_forwarding_queue")
            .select("status")
            .eq("trip_id", value: tripId.uuidString)
            .execute()
            .value

        return ForwardedBookingSummary(
            pendingCount: rows.filter { Self.isForwardingPendingStatus($0.status) }.count,
            needsReviewCount: rows.filter { Self.isForwardingReviewStatus($0.status) }.count,
            importedCount: rows.filter { $0.status == "processed" }.count
        )
    }

    func fetchParsedBookings(for tripId: UUID) async throws -> [ParsedBooking] {
        let (client, _) = try await requireClientAndUserId()
        let rows: [EmailForwardingQueueRow] = try await client
            .from("email_forwarding_queue")
            .select("id,user_id,trip_id,status,subject,error_message,extracted_bookings,created_at")
            .eq("trip_id", value: tripId.uuidString)
            .order("created_at", ascending: false)
            .limit(50)
            .execute()
            .value

        return rows.compactMap(Self.mapEmailForwardingQueueRow)
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

    private struct ForwardingAddressRow: Decodable, Sendable {
        let id: UUID
        let address_token: String
        let is_active: Bool
    }

    private struct ForwardingAddressInsert: Encodable, Sendable {
        let user_id: UUID
        let trip_id: UUID
        let address_token: String
        let is_active: Bool
    }

    private struct ForwardingAddressUpdate: Encodable, Sendable {
        let is_active: Bool
    }

    private struct EmailForwardingStatusRow: Decodable, Sendable {
        let status: String
    }

    private struct EmailForwardingQueueRow: Decodable, Sendable {
        let id: UUID
        let user_id: UUID?
        let trip_id: UUID?
        let status: String
        let subject: String?
        let error_message: String?
        let extracted_bookings: JSONValue?
        let created_at: String?
    }

    private static func makeForwardingAddressToken() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    private static func forwardingEmailAddress(from token: String) -> String {
        "trips+\(token)@\(AppConfig.bookingForwardingDomain)"
    }

    private static func isForwardingPendingStatus(_ status: String) -> Bool {
        ["received", "pending", "processing"].contains(status)
    }

    private static func isForwardingReviewStatus(_ status: String) -> Bool {
        ["failed", "no_user", "needs_assignment"].contains(status)
    }

    private static func mapEmailForwardingQueueRow(_ row: EmailForwardingQueueRow) -> ParsedBooking? {
        guard let userId = row.user_id, let tripId = row.trip_id else { return nil }
        let status: ParsedBookingStatus
        if isForwardingPendingStatus(row.status) {
            status = .pending
        } else if row.status == "processed" {
            status = .confirmed
        } else {
            status = .failed
        }

        return ParsedBooking(
            id: row.id,
            userId: userId,
            tripId: tripId,
            status: status,
            parsedData: forwardingParsedData(from: row),
            createdAt: SupabaseModelMapping.parsePostgresTimestamp(row.created_at) ?? Date()
        )
    }

    private static func forwardingParsedData(from row: EmailForwardingQueueRow) -> [String: String]? {
        var data: [String: String] = [:]
        if let subject = row.subject?.trimmingCharacters(in: .whitespacesAndNewlines), !subject.isEmpty {
            data["Subject"] = subject
        }
        if let error = row.error_message?.trimmingCharacters(in: .whitespacesAndNewlines), !error.isEmpty {
            data["Issue"] = error
        }
        if let booking = firstForwardedBookingObject(from: row.extracted_bookings) {
            for (sourceKey, displayKey) in forwardedBookingDisplayKeys {
                if let value = booking[sourceKey].flatMap(forwardingDisplayString) {
                    data[displayKey] = value
                }
            }
        }
        return data.isEmpty ? nil : data
    }

    private static let forwardedBookingDisplayKeys: [(String, String)] = [
        ("title", "Title"),
        ("kind", "Type"),
        ("provider", "Provider"),
        ("confirmation_code", "Confirmation"),
        ("starts_at", "Starts"),
        ("start_location", "From"),
        ("end_location", "To"),
        ("total_price", "Total"),
        ("currency", "Currency"),
    ]

    private static func firstForwardedBookingObject(from value: JSONValue?) -> [String: JSONValue]? {
        switch value {
        case .array(let items):
            for item in items {
                if case .object(let object) = item { return object }
            }
        case .object(let object):
            return object
        default:
            break
        }
        return nil
    }

    private static func forwardingDisplayString(from value: JSONValue) -> String? {
        switch value {
        case .string(let string):
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case .number(let number):
            return number.formatted()
        case .bool(let bool):
            return bool ? "Yes" : "No"
        default:
            return nil
        }
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
        let carrier_iata: String?
        let carrierIATA: String?
        let flight_number: String?
        let origin_airport_iata: String?
        let destination_airport_iata: String?
        let lookup_verified: Bool?
        let lookup_status: String?
        let terminal: String?
        let terminal_destination: String?
        let seat: String?
        let gate: String?
        let gate_destination: String?
        let baggage_claim: String?
        let room_type: String?
        let car_type: String?
        let address: String?
        let service_number: String?
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

    private struct TripBookingDetailsPayload: Encodable, Sendable {
        let airline: String?
        let carrier_iata: String?
        let flight_number: String?
        let origin_airport_iata: String?
        let destination_airport_iata: String?
        let lookup_verified: Bool?
        let lookup_status: String?
        let terminal: String?
        let terminal_destination: String?
        let gate: String?
        let gate_destination: String?
        let seat: String?
        let baggage_claim: String?
        let room_type: String?
        let party_size: Int?
        let car_type: String?
        let duration: String?
        let ticket_number: String?
        let service_number: String?
        let address: String?
    }

    private struct TripBookingInsert: Encodable, Sendable {
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
        let end_lat: Double?
        let end_lng: Double?
        let details_json: TripBookingDetailsPayload
        let amount: DecimalCodec?
        let currency: String
        let source: String
        let sort_order: Int
    }

    private struct TripBookingUpdate: Encodable, Sendable {
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
        let end_lat: Double?
        let end_lng: Double?
        let details_json: TripBookingDetailsPayload
        let amount: DecimalCodec?
        let currency: String
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
            travelMode: row.travel_mode,
            thumbnailUrl: enrichment?.nonEmptyThumbnailURL
        )
    }

    // MARK: - Booking row mapping

    /// Resolves `Place.address` from `trip_bookings.start_location`, with a fallback on
    /// `details_json.address` for hotel and restaurant when `start_location` was never populated.
    private static func bookingDisplayAddress(
        category: BookingCategory?,
        startLocation: String?,
        detailsJSON: BookingJSONDetails?
    ) -> String? {
        if let line = trimmedOrNil(startLocation) { return line }
        guard category == .hotel || category == .restaurant else { return nil }
        return trimmedOrNil(detailsJSON?.address)
    }

    private static func mapBookingRow(_ row: TripBookingRow, dayId: UUID) -> Place {
        let category = bookingKindToCategory(row.kind)
        let start = row.starts_at.flatMap { SupabaseModelMapping.parsePostgresTimestamp($0) }
        let end   = row.ends_at.flatMap   { SupabaseModelMapping.parsePostgresTimestamp($0) }
        let details = buildBookingDetails(row: row, category: category, start: start, end: end)
        let bookingAddress = bookingDisplayAddress(
            category: category,
            startLocation: row.start_location,
            detailsJSON: row.details_json
        )
        return Place(
            id: row.id,
            itineraryDayId: dayId,
            name: row.title,
            address: bookingAddress,
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
                carrierIATA: json?.carrier_iata ?? json?.carrierIATA,
                flightNumber: json?.flight_number ?? "",
                departureAirport: json?.origin_airport_iata ?? row.start_location ?? "",
                arrivalAirport: json?.destination_airport_iata ?? row.end_location ?? "",
                departureTime: start,
                arrivalTime: end,
                terminal: json?.terminal ?? "",
                gate: json?.gate ?? "",
                seat: json?.seat ?? "",
                lookupVerified: json?.lookup_verified ?? false,
                lookupStatus: json?.lookup_status,
                terminalDestination: json?.terminal_destination,
                gateDestination: json?.gate_destination,
                baggageClaim: json?.baggage_claim
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
                partySize: json?.party_size,
                address: trimmedOrNil(json?.address)
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
                serviceNumber: json?.service_number ?? "",
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

    /// Reads `trips.display_timezone` for a single trip. Returns nil when the
    /// column is null/empty, the row is missing, or the request fails — callers
    /// must always provide a sensible fallback (we never assume device TZ for
    /// booking placement). Lower-cased UUID input is required.
    private static func fetchTripDisplayTimezone(client: SupabaseClient, tripIdString: String) async -> String? {
        struct TripTzRow: Decodable, Sendable { let display_timezone: String? }
        do {
            let row: TripTzRow = try await client
                .from("trips")
                .select("display_timezone")
                .eq("id", value: tripIdString)
                .single()
                .execute()
                .value
            return row.display_timezone
        } catch {
            return nil
        }
    }

    /// Resolves the calendar-day timezone used to place bookings on a trip.
    ///
    /// Priority:
    /// 1. The first non-nil `trip_days.timezone` (per-day override).
    /// 2. `trips.display_timezone` (trip-wide canonical destination zone).
    /// 3. Device TZ (`.current`) — last-resort, only when both are missing.
    ///
    /// The fallback to `.current` historically caused intercontinental flights
    /// to land on the wrong itinerary day: a flight stored as a UTC instant
    /// could resolve to one calendar date in the device TZ and a different
    /// date in the trip TZ. Always prefer trip-side data when available.
    private static func resolveTripTimeZone(days: [ItineraryDay], tripDisplayTimezone: String?) -> TimeZone {
        for day in days {
            if let id = day.timeZoneIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty,
               let tz = TimeZone(identifier: id) {
                return tz
            }
        }
        if let id = tripDisplayTimezone?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty,
           let tz = TimeZone(identifier: id) {
            return tz
        }
        return .current
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
        if let exact = daysByDateKey[key] { return exact }

        // Exact key missed — usually because `trip_days.timezone` is null and
        // the device TZ pushed the date by 1. Pick the closest scheduled day
        // *within ±2 days* so a TZ-shifted booking still lands sensibly.
        // Anything further off is a data error (e.g. wrong year) and should
        // fall back deterministically to the first scheduled day rather than
        // attaching to an arbitrary "closest" day hundreds of days away.
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"

        guard let bookingDay = formatter.date(from: key) else {
            return fallbackDayId
        }
        let maxDistance = 2
        var best: (dayId: UUID, distance: Int)?
        for (dayKey, dayId) in daysByDateKey {
            guard let d = formatter.date(from: String(dayKey.prefix(10))) else { continue }
            let diff = abs(calendar.dateComponents([.day], from: bookingDay, to: d).day ?? Int.max)
            if diff > maxDistance { continue }
            if best == nil || diff < best!.distance {
                best = (dayId, diff)
            }
        }
        return best?.dayId ?? fallbackDayId
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

    /// Whether a `trip_bookings` row already exists (used for add-booking
    /// flows that insert a placeholder row so attachments can satisfy FK).
    private func tripBookingRowExists(client: SupabaseClient, id: UUID) async throws -> Bool {
        struct IdRow: Decodable, Sendable {
            let id: String
        }
        let rows: [IdRow] = try await client
            .from("trip_bookings")
            .select("id")
            .eq("id", value: id.uuidString)
            .limit(1)
            .execute()
            .value
        return !rows.isEmpty
    }

    /// Inserts a minimal `trip_bookings` row when none exists so
    /// `trip_booking_attachments` FK succeeds during add-booking document upload.
    func ensureBookingPlaceholderExistsIfNeeded(_ place: Place) async throws {
        guard place.isBooking else { return }
        let (client, userId) = try await requireClientAndUserId()
        if try await tripBookingRowExists(client: client, id: place.id) { return }
        let tripId = try await requireTripIdForDay(client: client, dayId: place.itineraryDayId)
        let row = try Self.buildBookingInsert(place: place, tripId: tripId, userId: userId)
        do {
            try await client.from("trip_bookings").insert(row).execute()
        } catch {
            if try await tripBookingRowExists(client: client, id: place.id) { return }
            throw error
        }
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

    private static func buildBookingInsert(place: Place, tripId: UUID, userId: UUID) throws -> TripBookingInsert {
        let payload = try bookingPayload(for: place)
        return TripBookingInsert(
            id: place.id,
            trip_id: tripId,
            user_id: userId,
            kind: payload.kind,
            title: place.name,
            confirmation_code: trimmedOrNil(place.confirmationNumber),
            provider: payload.provider,
            starts_at: startsAtISO(for: place),
            ends_at: endsAtISO(for: place),
            start_location: payload.startLocation,
            end_location: payload.endLocation,
            start_lat: place.lat,
            start_lng: place.lng,
            end_lat: nil,
            end_lng: nil,
            details_json: payload.details,
            amount: place.bookingAmount.map(DecimalCodec.init),
            currency: normalizedCurrency(place.bookingCurrencyCode),
            source: "manual",
            sort_order: place.sortOrder
        )
    }

    private static func buildBookingUpdate(
        place: Place,
        tripId: UUID,
        userId: UUID,
        updatedAt: String
    ) throws -> TripBookingUpdate {
        let payload = try bookingPayload(for: place)
        return TripBookingUpdate(
            trip_id: tripId,
            user_id: userId,
            kind: payload.kind,
            title: place.name,
            confirmation_code: trimmedOrNil(place.confirmationNumber),
            provider: payload.provider,
            starts_at: startsAtISO(for: place),
            ends_at: endsAtISO(for: place),
            start_location: payload.startLocation,
            end_location: payload.endLocation,
            start_lat: place.lat,
            start_lng: place.lng,
            end_lat: nil,
            end_lng: nil,
            details_json: payload.details,
            amount: place.bookingAmount.map(DecimalCodec.init),
            currency: normalizedCurrency(place.bookingCurrencyCode),
            sort_order: place.sortOrder,
            updated_at: updatedAt
        )
    }

    private struct BookingPayload {
        let kind: String
        let provider: String?
        let startLocation: String?
        let endLocation: String?
        let details: TripBookingDetailsPayload
    }

    private static func bookingPayload(for place: Place) throws -> BookingPayload {
        guard let details = place.bookingDetails else {
            return BookingPayload(
                kind: bookingKind(for: place.bookingCategoryEnum),
                provider: nil,
                startLocation: trimmedOrNil(place.address),
                endLocation: nil,
                details: emptyBookingDetails()
            )
        }

        switch details {
        case .flight(let flight):
            let carrier = normalizedCarrierIATA(
                flight.carrierIATA,
                airline: flight.airline,
                flightNumber: flight.flightNumber
            )
            let flightNumber = normalizedFlightNumber(flight.flightNumber, carrierIATA: carrier)
            return BookingPayload(
                kind: "flight",
                provider: trimmedOrNil(flight.airline),
                startLocation: trimmedOrNil(flight.departureAirport),
                endLocation: trimmedOrNil(flight.arrivalAirport),
                details: TripBookingDetailsPayload(
                    airline: trimmedOrNil(flight.airline),
                    carrier_iata: carrier,
                    flight_number: flightNumber,
                    origin_airport_iata: trimmedOrNil(flight.departureAirport),
                    destination_airport_iata: trimmedOrNil(flight.arrivalAirport),
                    lookup_verified: flight.lookupVerified,
                    lookup_status: flight.lookupStatus ?? (flight.lookupVerified ? "verified" : "manual"),
                    terminal: trimmedOrNil(flight.terminal),
                    terminal_destination: trimmedOrNil(flight.terminalDestination),
                    gate: trimmedOrNil(flight.gate),
                    gate_destination: trimmedOrNil(flight.gateDestination),
                    seat: trimmedOrNil(flight.seat),
                    baggage_claim: trimmedOrNil(flight.baggageClaim),
                    room_type: nil,
                    party_size: nil,
                    car_type: nil,
                    duration: nil,
                    ticket_number: nil,
                    service_number: nil,
                    address: nil
                )
            )
        case .hotel(let hotel):
            let propertyAddress = trimmedOrNil(place.address)
            return BookingPayload(
                kind: "lodging",
                provider: place.name,
                startLocation: propertyAddress,
                endLocation: nil,
                details: TripBookingDetailsPayload(
                    airline: nil,
                    carrier_iata: nil,
                    flight_number: nil,
                    origin_airport_iata: nil,
                    destination_airport_iata: nil,
                    lookup_verified: nil,
                    lookup_status: nil,
                    terminal: nil,
                    terminal_destination: nil,
                    gate: nil,
                    gate_destination: nil,
                    seat: nil,
                    baggage_claim: nil,
                    room_type: trimmedOrNil(hotel.roomType),
                    party_size: nil,
                    car_type: nil,
                    duration: nil,
                    ticket_number: nil,
                    service_number: nil,
                    address: propertyAddress
                )
            )
        case .restaurant(let restaurant):
            let venueAddress = trimmedOrNil(place.address) ?? trimmedOrNil(restaurant.address)
            return BookingPayload(
                kind: "restaurant",
                provider: place.name,
                startLocation: venueAddress,
                endLocation: nil,
                details: TripBookingDetailsPayload(
                    airline: nil,
                    carrier_iata: nil,
                    flight_number: nil,
                    origin_airport_iata: nil,
                    destination_airport_iata: nil,
                    lookup_verified: nil,
                    lookup_status: nil,
                    terminal: nil,
                    terminal_destination: nil,
                    gate: nil,
                    gate_destination: nil,
                    seat: nil,
                    baggage_claim: nil,
                    room_type: nil,
                    party_size: restaurant.partySize,
                    car_type: nil,
                    duration: nil,
                    ticket_number: nil,
                    service_number: nil,
                    address: venueAddress
                )
            )
        case .carRental(let car):
            return BookingPayload(
                kind: "car",
                provider: trimmedOrNil(car.company),
                startLocation: trimmedOrNil(car.pickupLocation),
                endLocation: trimmedOrNil(car.dropoffLocation),
                details: TripBookingDetailsPayload(
                    airline: nil,
                    carrier_iata: nil,
                    flight_number: nil,
                    origin_airport_iata: nil,
                    destination_airport_iata: nil,
                    lookup_verified: nil,
                    lookup_status: nil,
                    terminal: nil,
                    terminal_destination: nil,
                    gate: nil,
                    gate_destination: nil,
                    seat: nil,
                    baggage_claim: nil,
                    room_type: nil,
                    party_size: nil,
                    car_type: trimmedOrNil(car.carType),
                    duration: nil,
                    ticket_number: nil,
                    service_number: nil,
                    address: nil
                )
            )
        case .activity(let activity):
            return BookingPayload(
                kind: "tour",
                provider: trimmedOrNil(activity.provider),
                startLocation: trimmedOrNil(place.address),
                endLocation: nil,
                details: TripBookingDetailsPayload(
                    airline: nil,
                    carrier_iata: nil,
                    flight_number: nil,
                    origin_airport_iata: nil,
                    destination_airport_iata: nil,
                    lookup_verified: nil,
                    lookup_status: nil,
                    terminal: nil,
                    terminal_destination: nil,
                    gate: nil,
                    gate_destination: nil,
                    seat: nil,
                    baggage_claim: nil,
                    room_type: nil,
                    party_size: nil,
                    car_type: nil,
                    duration: activity.duration,
                    ticket_number: trimmedOrNil(activity.ticketNumber),
                    service_number: nil,
                    address: nil
                )
            )
        case .transport(let transport):
            return BookingPayload(
                kind: "train",
                provider: trimmedOrNil(transport.operatorName),
                startLocation: trimmedOrNil(transport.departureStation),
                endLocation: trimmedOrNil(transport.arrivalStation),
                details: TripBookingDetailsPayload(
                    airline: nil,
                    carrier_iata: nil,
                    flight_number: nil,
                    origin_airport_iata: nil,
                    destination_airport_iata: nil,
                    lookup_verified: nil,
                    lookup_status: nil,
                    terminal: nil,
                    terminal_destination: nil,
                    gate: nil,
                    gate_destination: nil,
                    seat: trimmedOrNil(transport.seat),
                    baggage_claim: nil,
                    room_type: nil,
                    party_size: nil,
                    car_type: nil,
                    duration: nil,
                    ticket_number: nil,
                    service_number: trimmedOrNil(transport.serviceNumber),
                    address: nil
                )
            )
        }
    }

    private static func bookingKind(for category: BookingCategory?) -> String {
        switch category {
        case .flight: return "flight"
        case .hotel: return "lodging"
        case .restaurant: return "restaurant"
        case .carRental: return "car"
        case .activity: return "tour"
        case .transport: return "train"
        case nil: return "tour"
        }
    }

    private static func emptyBookingDetails() -> TripBookingDetailsPayload {
        TripBookingDetailsPayload(
            airline: nil,
            carrier_iata: nil,
            flight_number: nil,
            origin_airport_iata: nil,
            destination_airport_iata: nil,
            lookup_verified: nil,
            lookup_status: nil,
            terminal: nil,
            terminal_destination: nil,
            gate: nil,
            gate_destination: nil,
            seat: nil,
            baggage_claim: nil,
            room_type: nil,
            party_size: nil,
            car_type: nil,
            duration: nil,
            ticket_number: nil,
            service_number: nil,
            address: nil
        )
    }

    private static func endsAtISO(for place: Place) -> String? {
        guard let end = place.endTime else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: end)
    }

    private static func normalizedCurrency(_ currency: String?) -> String {
        let code = currency?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() ?? ""
        return code.isEmpty ? "USD" : code
    }

    private static func trimmedOrNil(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func normalizedCarrierIATA(_ code: String?, airline: String, flightNumber: String) -> String? {
        let picked = code?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() ?? ""
        if picked.count >= 2 && picked.count <= 3 { return picked }
        if let catalogCode = FlightAirlineCatalog.airline(matchingName: airline)?.iataCode {
            return catalogCode
        }
        let compactFlight = flightNumber
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
            .replacingOccurrences(of: " ", with: "")
        let prefix = compactFlight.prefix { $0.isLetter }
        guard prefix.count >= 2 && prefix.count <= 3 else { return nil }
        return String(prefix)
    }

    private static func normalizedFlightNumber(_ value: String, carrierIATA: String?) -> String? {
        var normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
            .replacingOccurrences(of: " ", with: "")
        if let carrierIATA, normalized.hasPrefix(carrierIATA) {
            normalized.removeFirst(carrierIATA.count)
        }
        return normalized.isEmpty ? nil : normalized
    }
}

extension SupabaseManager.CityPlaceEnrichmentRow {
    /// Trimmed `city_places.thumbnail_url` for timeline/catalog thumbnails.
    var nonEmptyThumbnailURL: String? {
        guard let t = thumbnail_url?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }

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

