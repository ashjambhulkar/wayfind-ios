//
//  SupabaseManager.swift
//  wayfind
//
//  Created by Ashish Jambhulkar on 4/2/26.
//

import Foundation
import Observation

@Observable
final class SupabaseManager {
    init() {}

    func fetchTrips() async throws -> [Trip] {
        []
    }

    func addTrip(_ trip: Trip) async throws {}

    func updateTrip(_ trip: Trip) async throws {}

    func deleteTrip(id: UUID) async throws {}

    func fetchDays(for tripId: UUID) async throws -> [ItineraryDay] {
        []
    }

    func fetchPlaces(for dayId: UUID) async throws -> [Place] {
        []
    }

    func addPlace(_ place: Place) async throws {}

    func updatePlace(_ place: Place) async throws {}

    func deletePlace(id: UUID) async throws {}

    func movePlace(placeId: UUID, toDayId: UUID) async throws {}

    func regenerateDays(for tripId: UUID, startDate: Date, endDate: Date) async throws {}

    func fetchParsedBookings(for tripId: UUID) async throws -> [ParsedBooking] {
        []
    }

    func registerDeviceToken(_ token: String, userId: UUID) async throws {}

    func uploadCoverPhoto(data: Data, userId: UUID, tripId: UUID) async throws -> String {
        ""
    }
}
