//
//  ActivityPlaceSaver.swift
//  wayfind
//
//  Shared persistence boundary for turning selected search results into
//  itinerary activities. UI callers own refresh, haptics, toasts, and any
//  map-specific cleanup.
//

import CoreLocation
import Foundation

struct ActivityPlaceSaver {
    let dataService: DataService

    @discardableResult
    func save(
        preview: MapSearchPreview,
        dayId: UUID,
        existingPlacesForDay: [Place],
        startTime: Date?,
        notes: String?,
        cityProfileId: UUID?
    ) async -> Place {
        var place = Place(
            id: UUID(),
            itineraryDayId: dayId,
            name: preview.name,
            address: preview.subtitle.isEmpty ? nil : preview.subtitle,
            lat: preview.coordinate.latitude,
            lng: preview.coordinate.longitude,
            category: (preview.category ?? .attraction).rawValue,
            notes: notes,
            sortOrder: existingPlacesForDay.count,
            startTime: startTime,
            endTime: nil,
            isBooking: false,
            bookingType: nil,
            confirmationNumber: nil,
            bookingDetails: nil,
            googlePlaceId: preview.googlePlaceId
        )

        await dataService.addPlace(place)

        if preview.origin == .apple && (preview.googlePlaceId == nil || preview.googlePlaceId?.isEmpty == true) {
            if let bridgedPlaceId = await resolveGooglePlaceId(for: preview, cityProfileId: cityProfileId) {
                place.googlePlaceId = bridgedPlaceId
                await dataService.updatePlace(place)
            }
        } else {
            PlatformUsageTelemetry.mapSearch(.bridgeSkippedOwnedRow, origin: preview.origin)
        }

        return place
    }

    @discardableResult
    func saveManual(
        name: String,
        address: String?,
        category: PlaceCategory,
        dayId: UUID,
        existingPlacesForDay: [Place],
        startTime: Date?,
        notes: String?
    ) async -> Place {
        let trimmedAddress = address?.trimmingCharacters(in: .whitespacesAndNewlines)
        let place = Place(
            id: UUID(),
            itineraryDayId: dayId,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            address: trimmedAddress?.isEmpty == false ? trimmedAddress : nil,
            lat: nil,
            lng: nil,
            category: category.rawValue,
            notes: notes,
            sortOrder: existingPlacesForDay.count,
            startTime: startTime,
            endTime: nil,
            isBooking: false,
            bookingType: nil,
            confirmationNumber: nil,
            bookingDetails: nil
        )

        await dataService.addPlace(place)
        return place
    }

    private func resolveGooglePlaceId(
        for preview: MapSearchPreview,
        cityProfileId: UUID?
    ) async -> String? {
        do {
            let bridge = PlaceIdBridgeService()
            let resolution = try await bridge.resolve(
                name: preview.name,
                lat: preview.coordinate.latitude,
                lng: preview.coordinate.longitude,
                cityProfileId: cityProfileId
            )
            if case .single(let candidate) = resolution {
                PlatformUsageTelemetry.mapSearch(.bridgeResolved, origin: .apple)
                return candidate.placeId
            }
        } catch {
            // Best effort: a missing Google place id only limits later enrichment.
        }
        return nil
    }
}
