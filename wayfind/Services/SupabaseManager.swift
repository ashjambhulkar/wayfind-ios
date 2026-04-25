//
//  SupabaseManager.swift
//  wayfind
//

import Foundation
import Observation
import Supabase

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
            .select("id,username,display_name,avatar_url,bio,created_at,preferred_airport,preferred_currency")
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
        avatarURL: String?
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
            destination_place_id: nil,
            start_date: startISO,
            end_date: endISO,
            status: status,
            is_active: isActive,
            description: trip.notes,
            cover_image_url: trip.coverImageUrl,
            cover_attribution: trip.coverImageAttribution,
            privacy: "private",
            total_budget: 0,
            budget_currency: "USD"
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
            destination_place_id: nil,
            start_date: startISO,
            end_date: endISO,
            description: trip.notes,
            cover_image_url: trip.coverImageUrl,
            cover_attribution: trip.coverImageAttribution,
            status: status,
            is_active: isActive,
            updated_at: nowIso
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

    /// Subset of `city_places` columns we care about for timeline rendering.
    /// All optional — any single field can be null in the database depending
    /// on enrichment status.
    private struct CityPlaceEnrichmentRow: Decodable, Sendable {
        let place_id: String
        let rating: Double?
        let user_ratings_total: Int?
        let price_level: Int?
        let thumbnail_url: String?
        let ai_short_summary: String?
        let subtypes: [String]?
        let time_spent_min: Int?
        let time_spent_max: Int?
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
                .select("place_id,rating,user_ratings_total,price_level,thumbnail_url,ai_short_summary,subtypes,time_spent_min,time_spent_max")
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

        var userProfileDetail: UserProfileDetail {
            UserProfileDetail(
                id: id,
                username: username,
                displayName: display_name,
                avatarURLString: avatar_url,
                bio: bio,
                preferredAirport: preferred_airport,
                preferredCurrency: preferred_currency,
                createdAt: SupabaseModelMapping.parsePostgresTimestamp(created_at)
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
        let total_budget: Int
        let budget_currency: String
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
    }

    private struct TripDayRow: Decodable, Sendable {
        let id: UUID
        let trip_id: UUID
        let day_number: Int
        let date: String
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
            lat: nil,
            lng: nil,
            startDate: start,
            endDate: end,
            coverImageUrl: row.cover_image_url,
            coverImageAttribution: row.cover_attribution,
            notes: row.description,
            createdAt: created,
            updatedAt: updated,
            databaseStatus: row.status,
            isMarkedActiveOnServer: row.is_active
        )
    }

    private static func mapDayRow(_ row: TripDayRow, tripId: UUID) -> ItineraryDay {
        ItineraryDay(
            id: row.id,
            tripId: tripId,
            dayNumber: row.day_number,
            date: SupabaseModelMapping.parseDateOnly(row.date)
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
            heroImageUrl: row.hero_image_url ?? enrichment?.thumbnail_url,
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
            googlePlaceId: nil
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


// =============================================================================

