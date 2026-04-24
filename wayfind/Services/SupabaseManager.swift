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

        try await client
            .from("trips")
            .update(payload)
            .eq("id", value: trip.id.uuidString)
            .eq("user_id", value: userId.uuidString)
            .execute()
    }

    func deleteTrip(id: UUID) async throws {
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

    func registerDeviceToken(_ token: String, userId: UUID) async throws {
        _ = token
        _ = userId
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
        let sort_order: Int
        let booking_id: UUID?
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

    private static func mapActivityRow(_ row: TripActivityRow, dayId: UUID) -> Place {
        let isBooking = row.booking_id != nil
        let start = row.starts_at.flatMap { SupabaseModelMapping.parsePostgresTimestamp($0) }
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
            endTime: nil,
            isBooking: isBooking,
            bookingType: isBooking ? "activity" : nil,
            confirmationNumber: nil,
            bookingDetails: nil,
            googlePlaceId: row.place_id
        )
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

