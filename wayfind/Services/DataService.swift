//
//  DataService.swift
//  wayfind
//
//  Created by Ashish Jambhulkar on 4/2/26.
//

import Foundation
import Observation

enum TripCoverUploadError: LocalizedError {
    case requiresSignedInBackend
    case couldNotReadImage

    var errorDescription: String? {
        switch self {
        case .requiresSignedInBackend:
            return "Cover photos require signing in with the live backend."
        case .couldNotReadImage:
            return "Could not read that photo. Try a different image."
        }
    }
}

enum ProfileSaveError: LocalizedError {
    case requiresSignedInBackend
    case couldNotReadImage

    var errorDescription: String? {
        switch self {
        case .requiresSignedInBackend:
            return "Profile changes require signing in with the live backend."
        case .couldNotReadImage:
            return "Could not read that photo. Try a different image."
        }
    }
}

@Observable
final class DataService {
    private let mock: MockDataService?
    private let real: SupabaseManager?

    init() {
        if AppConfig.useRealBackend {
            real = SupabaseManager()
            mock = nil
        } else {
            mock = MockDataService()
            real = nil
        }
    }

    #if DEBUG
    init(previewMockData: Bool) {
        if previewMockData {
            mock = MockDataService()
            real = nil
        } else if AppConfig.useRealBackend {
            real = SupabaseManager()
            mock = nil
        } else {
            mock = MockDataService()
            real = nil
        }
    }
    #endif

    func fetchTrips() async -> [Trip] {
        if let real { return (try? await real.fetchTrips()) ?? [] }
        return await mock!.fetchTrips()
    }

    /// Full `profiles` row for the signed-in user (nil in mock / offline mode or on error).
    func fetchOwnUserProfileDetail() async -> UserProfileDetail? {
        guard let real else { return nil }
        return try? await real.fetchOwnProfileDetail()
    }

    /// Profile stats strip + hero counts (Expo `fetchProfileAggregateStats`).
    func fetchProfileAggregateStats() async -> ProfileAggregateStats {
        if let real { return (try? await real.fetchProfileAggregateStats()) ?? .empty }
        return await mock!.fetchProfileAggregateStats()
    }

    /// Bulk timeline load: days + all activities + all bookings in parallel,
    /// merged and sorted per day. Replaces the old N+1 pattern.
    func fetchTripTimeline(for tripId: UUID) async -> (days: [ItineraryDay], placesByDayId: [UUID: [Place]]) {
        if let real { return (try? await real.fetchTripTimeline(for: tripId)) ?? ([], [:]) }
        return await mock!.fetchTripTimeline(for: tripId)
    }

    func fetchDays(for tripId: UUID) async -> [ItineraryDay] {
        if let real { return (try? await real.fetchDays(for: tripId)) ?? [] }
        return await mock!.fetchDays(for: tripId)
    }

    func fetchPlaces(for dayId: UUID) async -> [Place] {
        if let real { return (try? await real.fetchPlaces(for: dayId)) ?? [] }
        return await mock!.fetchPlaces(for: dayId)
    }

    @discardableResult
    func addTrip(_ trip: Trip) async -> Trip {
        if let real {
            if let created = try? await real.addTrip(trip) { return created }
            return trip
        }
        return await mock!.addTrip(trip)
    }

    func deleteTrip(id: UUID) async {
        if let real { try? await real.deleteTrip(id: id) }
        else { await mock!.deleteTrip(id: id) }
    }

    func addPlace(_ place: Place) async {
        if let real { try? await real.addPlace(place) }
        else { await mock!.addPlace(place) }
    }

    func deletePlace(id: UUID) async {
        if let real { try? await real.deletePlace(id: id) }
        else { await mock!.deletePlace(id: id) }
    }

    func updatePlace(_ place: Place) async {
        if let real { try? await real.updatePlace(place) }
        else { await mock!.updatePlace(place) }
    }

    func movePlace(placeId: UUID, toDayId: UUID) async {
        if let real { try? await real.movePlace(placeId: placeId, toDayId: toDayId) }
        else { await mock!.movePlace(placeId: placeId, toDayId: toDayId) }
    }

    func updateTrip(_ trip: Trip) async {
        if let real { try? await real.updateTrip(trip) }
        else { await mock!.updateTrip(trip) }
    }

    func uploadTripCoverPhoto(tripId: UUID, imageData: Data) async throws -> String {
        guard let real else { throw TripCoverUploadError.requiresSignedInBackend }
        return try await real.uploadCoverPhoto(data: imageData, tripId: tripId)
    }

    func uploadProfileAvatar(imageData: Data, contentType: String) async throws -> String {
        guard let real else { throw ProfileSaveError.requiresSignedInBackend }
        return try await real.uploadProfileAvatar(imageData: imageData, contentType: contentType)
    }

    func updateUserProfile(
        displayName: String?,
        username: String,
        bio: String?,
        preferredAirport: String?,
        preferredCurrency: String?,
        avatarURL: String?,
        venmoUsername: String?,
        paypalUsername: String?
    ) async throws {
        guard let real else { throw ProfileSaveError.requiresSignedInBackend }
        try await real.updateProfileFields(
            displayName: displayName,
            username: username,
            bio: bio,
            preferredAirport: preferredAirport,
            preferredCurrency: preferredCurrency,
            avatarURL: avatarURL,
            venmoUsername: venmoUsername,
            paypalUsername: paypalUsername
        )
    }

    func regenerateDays(for tripId: UUID, startDate: Date, endDate: Date) async {
        if let real { try? await real.regenerateDays(for: tripId, startDate: startDate, endDate: endDate) }
        else { await mock!.regenerateDays(for: tripId, startDate: startDate, endDate: endDate) }
    }

    func fetchParsedBookings(for tripId: UUID) async -> [ParsedBooking] {
        if let real { return (try? await real.fetchParsedBookings(for: tripId)) ?? [] }
        return await mock!.fetchParsedBookings(for: tripId)
    }

    /// Counts for trip detail hero pills (Expo `TripDetailHero` checklist + notes chips).
    /// Returns nil on network/RLS failure so callers can preserve the last
    /// visible counts instead of flashing them back to zero.
    func tripHeroShortcutCounts(tripId: UUID) async -> (checklistDone: Int, checklistTotal: Int, noteCount: Int)? {
        guard let real else { return (0, 0, 0) }
        do {
            try? await real.ensureTripChecklistTemplates(tripId: tripId)
            let progress = try await real.fetchTripChecklistProgress(tripId: tripId)
            let notes = try await real.fetchTripNoteCount(tripId: tripId)
            return (progress.done, progress.total, notes)
        } catch {
            return nil
        }
    }

    func listTripNotes(tripId: UUID) async -> [TripNote] {
        if let real { return (try? await real.listTripNotes(tripId: tripId)) ?? [] }
        return await mock!.listTripNotes(tripId: tripId)
    }

    func createTripNote(tripId: UUID) async -> TripNote? {
        if let real { return try? await real.createTripNote(tripId: tripId) }
        return await mock!.createTripNote(tripId: tripId)
    }

    func updateTripNote(noteId: UUID, title: String, body: String) async {
        if let real { try? await real.updateTripNote(noteId: noteId, title: title, body: body) }
        else { await mock!.updateTripNote(noteId: noteId, title: title, body: body) }
    }

    func deleteTripNote(noteId: UUID) async {
        if let real { try? await real.deleteTripNote(noteId: noteId) }
        else { await mock!.deleteTripNote(noteId: noteId) }
    }

    func listTemplateTripChecklistsWithItems(tripId: UUID) async -> [TripChecklistWithItems] {
        if let real {
            try? await real.ensureTripChecklistTemplates(tripId: tripId)
            return (try? await real.listTemplateTripChecklistsWithItems(tripId: tripId)) ?? []
        }
        return await mock!.listTemplateTripChecklistsWithItems(tripId: tripId)
    }

    func addChecklistItem(checklistId: UUID, tripId: UUID, title: String, sortOrder: Int) async -> TripChecklistItem? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let real {
            try? await real.ensureTripChecklistTemplates(tripId: tripId)
            return try? await real.addChecklistItem(
                checklistId: checklistId,
                tripId: tripId,
                title: trimmed,
                sortOrder: sortOrder
            )
        }
        return await mock!.addChecklistItem(
            checklistId: checklistId,
            tripId: tripId,
            title: trimmed,
            sortOrder: sortOrder
        )
    }

    func setChecklistItemDone(itemId: UUID, isDone: Bool) async {
        if let real { try? await real.setChecklistItemDone(itemId: itemId, isDone: isDone) }
        else { await mock!.setChecklistItemDone(itemId: itemId, isDone: isDone) }
    }

    func deleteChecklistItem(itemId: UUID) async {
        if let real { try? await real.deleteChecklistItem(itemId: itemId) }
        else { await mock!.deleteChecklistItem(itemId: itemId) }
    }

    // MARK: - Collaborative budget (Phase 1)

    /// Bulk-loads expenses + splits + per-category budgets + settlements for a
    /// single trip. Returns an empty snapshot on RLS failure so the UI can
    /// preserve the last-known state instead of flashing to "no expenses".
    func fetchBudgetSnapshot(tripId: UUID) async -> BudgetSnapshot {
        if real != nil {
            return (try? await BudgetService.shared.fetchAll(tripId: tripId)) ?? .empty
        }
        return await mock!.fetchBudgetSnapshot(tripId: tripId)
    }

    /// Updates the trip-level budget cap (owner-only via RLS on `trips`).
    func updateTripTotalBudget(tripId: UUID, totalBudget: Decimal?, currency: String) async {
        if real != nil {
            try? await BudgetService.shared.updateTripTotalBudget(
                tripId: tripId,
                totalBudget: totalBudget,
                currency: currency
            )
        } else {
            await mock!.updateTripTotalBudget(tripId: tripId, totalBudget: totalBudget, currency: currency)
        }
    }

    @discardableResult
    func addExpense(_ expense: TripExpense, splits: [ExpenseSplit]) async -> TripExpense {
        if real != nil {
            if let created = try? await BudgetService.shared.addExpense(expense, splits: splits) {
                return created
            }
            return expense
        }
        return await mock!.addExpense(expense, splits: splits)
    }

    func updateExpense(_ expense: TripExpense, splits: [ExpenseSplit]) async {
        if real != nil {
            try? await BudgetService.shared.updateExpense(expense, splits: splits)
        } else {
            await mock!.updateExpense(expense, splits: splits)
        }
    }

    func deleteExpense(id: UUID) async {
        if real != nil {
            try? await BudgetService.shared.deleteExpense(id: id)
        } else {
            await mock!.deleteExpense(id: id)
        }
    }

    func upsertCategoryBudget(
        tripId: UUID,
        category: ExpenseCategory,
        plannedAmount: Decimal,
        currency: String
    ) async {
        if real != nil {
            try? await BudgetService.shared.upsertCategoryBudget(
                tripId: tripId,
                category: category,
                plannedAmount: plannedAmount,
                currency: currency
            )
        } else {
            await mock!.upsertCategoryBudget(
                tripId: tripId,
                category: category,
                plannedAmount: plannedAmount,
                currency: currency
            )
        }
    }

    func deleteCategoryBudget(id: UUID) async {
        if real != nil {
            try? await BudgetService.shared.deleteCategoryBudget(id: id)
        } else {
            await mock!.deleteCategoryBudget(id: id)
        }
    }

    @discardableResult
    func addSettlement(_ settlement: ExpenseSettlement) async -> ExpenseSettlement {
        if real != nil {
            if let inserted = try? await BudgetService.shared.addSettlement(settlement) {
                return inserted
            }
            return settlement
        }
        return await mock!.addSettlement(settlement)
    }

    func markSettled(id: UUID, method: ExpenseSettlement.SettlementMethod) async {
        if real != nil {
            try? await BudgetService.shared.markSettled(id: id, method: method)
        } else {
            await mock!.markSettled(id: id, method: method)
        }
    }

    // MARK: - city_places enrichment refetch (Phase D.3)

    /// Re-reads the `city_places` enrichment row for a Google `place_id`.
    /// Used by `PlaceDetailSheet` to refresh fields after the foreground
    /// enrichment job completes. Returns nil in mock mode.
    func fetchCityPlaceEnrichment(googlePlaceId: String) async -> SupabaseManager.CityPlaceEnrichmentRow? {
        guard let real else { return nil }
        return try? await real.fetchCityPlaceEnrichment(googlePlaceId: googlePlaceId)
    }

    /// Phase J.6 — Resolve `city_profiles.id` for a Google `place_id`.
    /// Used by the AI day planner to scope `AppleTravelTimesService`
    /// warm-ups to the correct destination row in `city_travel_times`.
    /// Returns `nil` in mock mode and on lookup miss.
    func fetchCityProfileId(googlePlaceId: String) async -> UUID? {
        guard let real else { return nil }
        return await real.fetchCityProfileId(forGooglePlaceId: googlePlaceId)
    }

    /// Robust 3-tier `city_profile_id` resolver for a trip — slug match,
    /// then geo proximity, then legacy `place_id` lookup. Use this for
    /// any new caller that needs a city profile from a `Trip` rather
    /// than just a Google place id, since trip destinations are usually
    /// localities (not POIs in `city_places`). Returns `nil` in mock
    /// mode and when none of the tiers match.
    func resolveCityProfileId(forTrip trip: Trip) async -> UUID? {
        guard let real else { return nil }
        return await real.resolveCityProfileId(forTrip: trip)
    }

    /// Fetches center_lat / center_lng for a city_profiles row by id.
    /// Used after first-time async resolution to persist coords to trips.
    /// Returns nil in mock mode and on miss.
    func fetchCityProfileCenterCoords(id: UUID) async -> (lat: Double, lng: Double)? {
        guard let real else { return nil }
        return await real.fetchCityProfileCenterCoords(id: id)
    }

    /// Persists a resolved city_profile_id/lat/lng back to the trips row
    /// so subsequent map opens skip the 3-tier resolver. No-op in mock mode.
    /// Best-effort — callers should not await a result.
    func patchTripCityProfile(
        tripId: UUID,
        cityProfileId: UUID,
        lat: Double,
        lng: Double
    ) async {
        guard let real else { return }
        await real.patchTripCityProfile(
            tripId: tripId,
            cityProfileId: cityProfileId,
            lat: lat,
            lng: lng
        )
    }

    /// Enqueues a foreground enrichment job for the given Google `place_id`.
    /// Stampede-deduped server-side. No-op in mock mode.
    func requestCityPlaceEnrichment(googlePlaceId: String) async {
        guard let real else { return }
        _ = await real.requestCityPlaceEnrichment(forGooglePlaceId: googlePlaceId)
    }

    /// Phase H.3 — TTL-driven lazy refresh. Asks the server to enqueue
    /// focused 'details' or 'images' enrichment jobs only if the row is
    /// stale relative to the configured TTL feature flags. No-op in mock
    /// mode. Best-effort; safe to call from `.task`.
    func refreshCityPlaceIfStale(
        googlePlaceId: String,
        priority: String = "background"
    ) async {
        guard let real else { return }
        _ = await real.refreshCityPlaceIfStale(
            forGooglePlaceId: googlePlaceId,
            priority: priority
        )
    }

    // MARK: - Phase F (user photos)

    struct PhotoUploadQuotaVerdict: Sendable {
        let allowed: Bool
        let reason: String
        let remaining: Int
    }

    /// Wraps `check_photo_upload_quota` RPC. Mock mode always allows
    /// (1 remaining) so the flow is testable offline.
    func checkPhotoUploadQuota(cityPlaceId: UUID) async -> PhotoUploadQuotaVerdict {
        guard let real else {
            return PhotoUploadQuotaVerdict(allowed: true, reason: "ok", remaining: 1)
        }
        return await real.checkPhotoUploadQuota(cityPlaceId: cityPlaceId)
    }

    struct UploadedPhotoStub: Sendable {
        let photoId: UUID
        let storagePath: String
    }

    /// Uploads bytes to the quarantine bucket and inserts the matching
    /// `place_user_photos` row in `pending_moderation`. Returns the new
    /// photo id for the moderation call. Mock mode synthesizes IDs but
    /// does no network work.
    func uploadQuarantinedPlacePhoto(
        cityPlaceId: UUID,
        imageData: Data,
        exifLat: Double?,
        exifLng: Double?,
        progress: @escaping @Sendable (Double) -> Void
    ) async -> Result<UploadedPhotoStub, PlacePhotoUploadError> {
        guard let real else {
            return .success(UploadedPhotoStub(
                photoId: UUID(),
                storagePath: "mock/\(UUID().uuidString).jpg"
            ))
        }
        return await real.uploadQuarantinedPlacePhoto(
            cityPlaceId: cityPlaceId,
            imageData: imageData,
            exifLat: exifLat,
            exifLng: exifLng,
            progress: progress
        )
    }

    enum ModerationOutcome: Sendable {
        case approved(URL)
        case pendingReview(String?)
        case rejected(String, String?)
        case failure(String)
    }

    func invokeModeratePlacePhoto(photoId: UUID) async -> ModerationOutcome {
        guard let real else {
            return .pendingReview("Mock backend cannot moderate.")
        }
        return await real.invokeModeratePlacePhoto(photoId: photoId)
    }

    // MARK: - Phase F.7 (rejection events + DSA appeals)

    /// Photo lifecycle events the uploader has not acknowledged yet —
    /// surfaces "Your photo of X was rejected because Y" badges /
    /// inbox rows. Returns oldest-first so the UI can show them as a
    /// stack.
    func fetchUnacknowledgedPhotoEvents() async -> [PhotoLifecycleEvent] {
        guard let real else { return [] }
        return (try? await real.fetchUnacknowledgedPhotoEvents()) ?? []
    }

    /// Marks the event as read so it disappears from the badge.
    func acknowledgePhotoEvent(_ id: Int64) async {
        guard let real else { return }
        await real.acknowledgePhotoEvent(id: id)
    }

    /// File a DSA Article 20 appeal against a moderation decision.
    /// Returns true if the row was inserted; we don't expose the new
    /// row to the UI because the workflow is asynchronous from this
    /// point on.
    @discardableResult
    func submitDsaAppeal(photoId: UUID, appealText: String) async -> Bool {
        guard let real else { return true }
        return await real.submitDsaAppeal(photoId: photoId, appealText: appealText)
    }

    // MARK: - Phase F.8 (per-photo community reports)

    /// Result of a per-photo report. `success(escalated:)` means the
    /// row was written; `escalated == true` indicates the threshold of
    /// 3 distinct reporters tipped over and the photo flipped back to
    /// `pending_review`. `failure` carries a user-readable message
    /// (e.g. "You can't report your own photo.") for the inline error.
    enum PhotoReportOutcome: Sendable {
        case success(escalated: Bool)
        case failure(message: String)
    }

    /// Wraps the `report_user_photo` RPC. Returns immediately in mock
    /// mode so the UX flow stays exercisable offline.
    func reportUserPhoto(
        photoId: UUID,
        reason: String,
        details: String?
    ) async -> PhotoReportOutcome {
        guard let real else { return .success(escalated: false) }
        return await real.reportUserPhoto(
            photoId: photoId,
            reason: reason,
            details: details
        )
    }

    /// Phase E — submit a user report against a city_places row.
    /// Returns true if at least one place row was successfully reported
    /// (i.e. the place exists in our pool). Mock mode always returns true
    /// so the UX flow is testable without a backend.
    @discardableResult
    func reportCityPlace(googlePlaceId: String, reason: String, details: String? = nil) async -> Bool {
        guard let real else { return true }
        return await real.reportCityPlace(
            forGooglePlaceId: googlePlaceId,
            reason: reason,
            details: details
        )
    }

    // MARK: - Wave 0 — shared attachment + analytics surface

    /// Calls the `commit-attachment` Edge Function. Used by
    /// `BackgroundUploader` for every attachment surface (activity,
    /// booking, document, expense receipt). Mock mode returns a synthesized
    /// commit pointing at a no-op URL so SwiftUI previews still flow.
    func commitAttachment(descriptor: AttachmentUploadDescriptor) async throws -> AttachmentCommitResult {
        if let real {
            return try await real.commitAttachment(descriptor: descriptor)
        }
        return AttachmentCommitResult(
            rowId: UUID(),
            storagePath: "mock/\(descriptor.surface.rawValue)/\(UUID().uuidString)",
            bucket: "mock",
            signedUploadURL: URL(string: "https://example.invalid/mock-upload")!
        )
    }

    /// Logs a soft-gate attempt via `record_pro_gate_attempt` RPC. Fire and
    /// forget — analytics never block the UI. Plan §0.5 U1.
    func recordProGateAttempt(
        gate: ProGate,
        surface: String? = nil,
        metadata: [String: String] = [:]
    ) async {
        guard let real else { return }
        try? await real.recordProGateAttempt(
            gateName: gate.rawValue,
            surface: surface,
            metadata: metadata
        )
    }
}

/// Stable analytics ids per plan §0.5 U1. New gates must be added here so
/// the dashboard team has a closed enum to filter against.
enum ProGate: String, Sendable {
    case documents
    case csvExport = "csv_export"
    case currencyMulti = "currency_multi"
    case flightTracking = "flight_tracking"
    case aiDayPlanner = "ai_day_planner"
}


// =============================================================================

