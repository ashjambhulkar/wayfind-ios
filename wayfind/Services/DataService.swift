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
        avatarURL: String?
    ) async throws {
        guard let real else { throw ProfileSaveError.requiresSignedInBackend }
        try await real.updateProfileFields(
            displayName: displayName,
            username: username,
            bio: bio,
            preferredAirport: preferredAirport,
            preferredCurrency: preferredCurrency,
            avatarURL: avatarURL
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
    func tripHeroShortcutCounts(tripId: UUID) async -> (checklistDone: Int, checklistTotal: Int, noteCount: Int) {
        guard let real else { return (0, 0, 0) }
        do {
            try? await real.ensureTripChecklistTemplates(tripId: tripId)
            let progress = try await real.fetchTripChecklistProgress(tripId: tripId)
            let notes = try await real.fetchTripNoteCount(tripId: tripId)
            return (progress.done, progress.total, notes)
        } catch {
            return (0, 0, 0)
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
        if let real { return (try? await real.listTemplateTripChecklistsWithItems(tripId: tripId)) ?? [] }
        return await mock!.listTemplateTripChecklistsWithItems(tripId: tripId)
    }

    func setChecklistItemDone(itemId: UUID, isDone: Bool) async {
        if let real { try? await real.setChecklistItemDone(itemId: itemId, isDone: isDone) }
        else { await mock!.setChecklistItemDone(itemId: itemId, isDone: isDone) }
    }
}
