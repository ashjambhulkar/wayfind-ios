//
//  DataService.swift
//  wayfind
//
//  Created by Ashish Jambhulkar on 4/2/26.
//

import Foundation
import Observation

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

    func fetchDays(for tripId: UUID) async -> [ItineraryDay] {
        if let real { return (try? await real.fetchDays(for: tripId)) ?? [] }
        return await mock!.fetchDays(for: tripId)
    }

    func fetchPlaces(for dayId: UUID) async -> [Place] {
        if let real { return (try? await real.fetchPlaces(for: dayId)) ?? [] }
        return await mock!.fetchPlaces(for: dayId)
    }

    func addTrip(_ trip: Trip) async {
        if let real { try? await real.addTrip(trip) }
        else { await mock!.addTrip(trip) }
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

    func regenerateDays(for tripId: UUID, startDate: Date, endDate: Date) async {
        if let real { try? await real.regenerateDays(for: tripId, startDate: startDate, endDate: endDate) }
        else { await mock!.regenerateDays(for: tripId, startDate: startDate, endDate: endDate) }
    }

    func fetchParsedBookings(for tripId: UUID) async -> [ParsedBooking] {
        if let real { return (try? await real.fetchParsedBookings(for: tripId)) ?? [] }
        return await mock!.fetchParsedBookings(for: tripId)
    }
}
