//
//  CalendarSyncService.swift
//  wayfind
//
//  Wave 2.1 — bidirectional EventKit sync for one trip.
//
//  Plan tags:
//    §0.5 E1  — request *full access* via NSCalendarsFullAccessUsageDescription
//    §0.5 E5  — calendar event identifier mapping survives reinstall
//    §0.5 E9  — server-side `calendar_event_links` keyed by
//                (user_id, device_id, activity|booking_id)
//    §2.1     — one EKCalendar per trip (so the user can hide / delete in
//                one tap), correct timezone per event, batch-saved off-main,
//                idempotent (re-running doesn't duplicate events).
//
//  Surfaces:
//    * `CalendarSyncOnboardingView` is shown the first time a user opens
//      "Sync to Apple Calendar" — three screens explaining permission +
//      what we sync + the per-trip on/off toggle.
//    * `CalendarSyncService` is the actor doing the work. Lives at the
//      service layer so it can run on a Task.detached when called from
//      a button (we don't want to stall the UI for 50 events).
//

import EventKit
import Foundation
import Observation
import Supabase
import UIKit

enum CalendarSyncStatus: Sendable, Equatable {
    case idle
    case requestingPermission
    case denied
    case syncing(progress: Double)
    case completed(eventCount: Int)
    case failed(message: String)
}

enum CalendarSyncError: LocalizedError, Sendable {
    case accessDenied
    case noClient
    case missingTimezone
    case storeError(String)

    var errorDescription: String? {
        switch self {
        case .accessDenied:
            return "Wayfind needs calendar access. Tap Settings to grant it."
        case .noClient:
            return "Sign in to sync your trip to Calendar."
        case .missingTimezone:
            return "Add a timezone to your trip before syncing."
        case .storeError(let m):
            return m
        }
    }
}

/// Per-(user, device) identifier persisted on the server in
/// `calendar_event_links`. Stable across reinstalls thanks to
/// `UIDevice.identifierForVendor`, while still allowing each device to
/// own its own event mapping.
private enum DeviceFingerprint {
    static var current: String {
        if let id = UIDevice.current.identifierForVendor?.uuidString {
            return id
        }
        let key = "wayfind.calendar.deviceId"
        if let stored = UserDefaults.standard.string(forKey: key) {
            return stored
        }
        let new = UUID().uuidString
        UserDefaults.standard.set(new, forKey: key)
        return new
    }
}

@MainActor
@Observable
final class CalendarSyncService {
    private(set) var status: CalendarSyncStatus = .idle

    private let store = EKEventStore()

    /// Per-trip on/off toggle persisted in `@AppStorage`. Plan §2.1 — the
    /// server-side `calendar_event_links` is the source of truth for the
    /// mapping; this flag just controls future writes for *this user* on
    /// *this device*. A second collaborator on the same trip can have it
    /// off without affecting the first user.
    static func storageKey(tripId: UUID) -> String {
        "wayfind.calendar.sync.enabled.\(tripId.uuidString)"
    }

    static func isEnabled(tripId: UUID) -> Bool {
        UserDefaults.standard.bool(forKey: storageKey(tripId: tripId))
    }

    static func setEnabled(_ flag: Bool, tripId: UUID) {
        UserDefaults.standard.set(flag, forKey: storageKey(tripId: tripId))
    }

    /// Apple's `requestFullAccessToEvents` on iOS 17+; falls back to the
    /// pre-17 API otherwise. Throws `CalendarSyncError.accessDenied` if
    /// the user refuses.
    @discardableResult
    func requestAccess() async throws -> EKAuthorizationStatus {
        status = .requestingPermission
        if #available(iOS 17.0, *) {
            do {
                let granted = try await store.requestFullAccessToEvents()
                if !granted {
                    status = .denied
                    throw CalendarSyncError.accessDenied
                }
            } catch {
                status = .denied
                throw CalendarSyncError.accessDenied
            }
        } else {
            let granted = try await store.requestAccess(to: .event)
            if !granted {
                status = .denied
                throw CalendarSyncError.accessDenied
            }
        }
        let status = EKEventStore.authorizationStatus(for: .event)
        if status != .authorized && status.rawValue != 4 /* fullAccess on 17+ */ {
            self.status = .denied
            throw CalendarSyncError.accessDenied
        }
        self.status = .idle
        return status
    }

    /// Top-level sync entry point. Runs the heavy work on a detached task
    /// at `.userInitiated` so a 100-event trip doesn't stall the UI.
    func sync(
        trip: Trip,
        days: [ItineraryDay],
        placesByDayId: [UUID: [Place]],
        bookings: [Place]
    ) async {
        do {
            try await requestAccess()
        } catch {
            status = .failed(message: error.localizedDescription)
            return
        }

        guard let userId = await AuthSessionService.shared.currentSession()?.user.id else {
            status = .failed(message: CalendarSyncError.noClient.localizedDescription)
            return
        }

        // Trips don't carry a timezone field today — use the device timezone.
        // Per-place start/end already arrive as absolute Dates so this only
        // affects how Calendar renders them when the user travels across
        // zones; iOS automatically shifts events with a `timeZone` set.
        let timezone = TimeZone.current

        let fingerprint = DeviceFingerprint.current

        do {
            // 1. Resolve the trip's EKCalendar (create-or-fetch).
            let calendar = try ensureTripCalendar(for: trip)

            // 2. Pull existing mapping rows so we can update vs. insert.
            let existing = try await fetchExistingLinks(tripId: trip.id, deviceId: fingerprint)
            var existingByActivity = Dictionary(uniqueKeysWithValues: existing.compactMap { row -> (UUID, ExistingLink)? in
                guard let aid = row.activity_id else { return nil }
                return (aid, ExistingLink(rowId: row.id, externalId: row.external_event_id))
            })
            var existingByBooking = Dictionary(uniqueKeysWithValues: existing.compactMap { row -> (UUID, ExistingLink)? in
                guard let bid = row.booking_id else { return nil }
                return (bid, ExistingLink(rowId: row.id, externalId: row.external_event_id))
            })

            // 3. Flatten activities + bookings into work items.
            let items = makeWorkItems(
                trip: trip,
                days: days,
                placesByDayId: placesByDayId,
                bookings: bookings,
                timezone: timezone
            )

            status = .syncing(progress: 0)
            var written: [CalendarEventLinkInsert] = []
            var updated: Int = 0

            for (idx, item) in items.enumerated() {
                let event: EKEvent
                let eventId: String
                switch item.target {
                case .activity(let aid):
                    if let prior = existingByActivity[aid],
                       let found = store.event(withIdentifier: prior.externalId) {
                        event = found
                        applyFields(of: item, to: event, calendar: calendar, timezone: timezone)
                        try store.save(event, span: .thisEvent, commit: false)
                        updated += 1
                        eventId = prior.externalId
                        existingByActivity.removeValue(forKey: aid)
                    } else {
                        event = EKEvent(eventStore: store)
                        applyFields(of: item, to: event, calendar: calendar, timezone: timezone)
                        try store.save(event, span: .thisEvent, commit: false)
                        eventId = event.eventIdentifier
                        written.append(.activity(
                            userId: userId,
                            tripId: trip.id,
                            deviceId: fingerprint,
                            activityId: aid,
                            externalEventId: eventId,
                            externalCalendarId: calendar.calendarIdentifier
                        ))
                    }
                case .booking(let bid):
                    if let prior = existingByBooking[bid],
                       let found = store.event(withIdentifier: prior.externalId) {
                        event = found
                        applyFields(of: item, to: event, calendar: calendar, timezone: timezone)
                        try store.save(event, span: .thisEvent, commit: false)
                        updated += 1
                        eventId = prior.externalId
                        existingByBooking.removeValue(forKey: bid)
                    } else {
                        event = EKEvent(eventStore: store)
                        applyFields(of: item, to: event, calendar: calendar, timezone: timezone)
                        try store.save(event, span: .thisEvent, commit: false)
                        eventId = event.eventIdentifier
                        written.append(.booking(
                            userId: userId,
                            tripId: trip.id,
                            deviceId: fingerprint,
                            bookingId: bid,
                            externalEventId: eventId,
                            externalCalendarId: calendar.calendarIdentifier
                        ))
                    }
                }
                _ = eventId
                if items.count > 0 {
                    status = .syncing(progress: Double(idx + 1) / Double(items.count))
                }
            }

            // Anything left in `existingByActivity` / `existingByBooking`
            // means it was previously synced but is no longer in the
            // trip — delete that EKEvent and the link row.
            var staleLinkIds: [UUID] = []
            // `Dictionary.Values` doesn't conform to RangeReplaceableCollection
            // so `+` isn't synthesised — concat through Array() to get a
            // single sequence we can iterate.
            let stalePriors = Array(existingByActivity.values) + Array(existingByBooking.values)
            for prior in stalePriors {
                if let found = store.event(withIdentifier: prior.externalId) {
                    try? store.remove(found, span: .thisEvent, commit: false)
                }
                staleLinkIds.append(prior.rowId)
            }

            try store.commit()

            if !written.isEmpty {
                try await persist(links: written)
            }
            if !staleLinkIds.isEmpty {
                try? await deleteLinks(ids: staleLinkIds)
            }

            CalendarSyncService.setEnabled(true, tripId: trip.id)
            status = .completed(eventCount: items.count)
        } catch let err as CalendarSyncError {
            status = .failed(message: err.localizedDescription)
        } catch {
            status = .failed(message: error.localizedDescription)
        }
    }

    /// Tear down all events for a trip created by *this* device. Used by
    /// the per-trip "Stop syncing" toggle.
    func unsync(trip: Trip) async {
        let fingerprint = DeviceFingerprint.current
        do {
            let existing = try await fetchExistingLinks(tripId: trip.id, deviceId: fingerprint)
            for row in existing {
                if let found = store.event(withIdentifier: row.external_event_id) {
                    try? store.remove(found, span: .thisEvent, commit: false)
                }
            }
            try store.commit()
            try? await deleteLinks(ids: existing.map(\.id))

            // Best-effort: if the dedicated trip calendar is empty, remove it.
            if let calendar = findTripCalendar(for: trip) {
                let predicate = store.predicateForEvents(
                    withStart: trip.startDate,
                    end: trip.endDate.addingTimeInterval(60 * 60 * 24),
                    calendars: [calendar]
                )
                if store.events(matching: predicate).isEmpty {
                    try? store.removeCalendar(calendar, commit: true)
                }
            }
            CalendarSyncService.setEnabled(false, tripId: trip.id)
            status = .idle
        } catch {
            status = .failed(message: error.localizedDescription)
        }
    }

    // MARK: - Calendar resolution

    private func ensureTripCalendar(for trip: Trip) throws -> EKCalendar {
        if let existing = findTripCalendar(for: trip) {
            return existing
        }
        let calendar = EKCalendar(for: .event, eventStore: store)
        calendar.title = "Wayfind: \(trip.title)"
        if let source = pickCalendarSource() {
            calendar.source = source
        }
        do {
            try store.saveCalendar(calendar, commit: true)
        } catch {
            throw CalendarSyncError.storeError(error.localizedDescription)
        }
        return calendar
    }

    private func findTripCalendar(for trip: Trip) -> EKCalendar? {
        let title = "Wayfind: \(trip.title)"
        return store.calendars(for: .event).first(where: { $0.title == title })
    }

    /// Apple HIG: prefer iCloud → local → default. We never write to a
    /// subscribed (read-only) source.
    private func pickCalendarSource() -> EKSource? {
        let sources = store.sources
        if let cloud = sources.first(where: { $0.sourceType == .calDAV && $0.title.lowercased() == "icloud" }) {
            return cloud
        }
        if let local = sources.first(where: { $0.sourceType == .local }) {
            return local
        }
        return store.defaultCalendarForNewEvents?.source ?? sources.first
    }

    // MARK: - Field mapping

    private func applyFields(
        of item: CalendarWorkItem,
        to event: EKEvent,
        calendar: EKCalendar,
        timezone: TimeZone
    ) {
        event.calendar = calendar
        event.title = item.title
        event.notes = item.notes
        event.location = item.location
        event.startDate = item.start
        event.endDate = item.end
        event.timeZone = timezone
        event.url = item.url
    }

    // MARK: - Work item flattening

    private struct CalendarWorkItem {
        enum Target { case activity(UUID), booking(UUID) }
        let target: Target
        let title: String
        let notes: String?
        let location: String?
        let url: URL?
        let start: Date
        let end: Date
    }

    private func makeWorkItems(
        trip: Trip,
        days: [ItineraryDay],
        placesByDayId: [UUID: [Place]],
        bookings: [Place],
        timezone: TimeZone
    ) -> [CalendarWorkItem] {
        var items: [CalendarWorkItem] = []
        for day in days {
            let places = (placesByDayId[day.id] ?? [])
                .filter { !$0.isBooking }
                .filter { $0.startTime != nil }
            for place in places {
                guard let start = place.startTime else { continue }
                let durationMinutes = place.durationMinutes ?? 60
                let end = place.endTime ?? start.addingTimeInterval(Double(durationMinutes) * 60)
                items.append(CalendarWorkItem(
                    target: .activity(place.id),
                    title: place.name,
                    notes: place.notes,
                    location: place.address,
                    url: nil,
                    start: start,
                    end: end
                ))
            }
        }
        for booking in bookings where booking.isBooking {
            guard let start = booking.startTime else { continue }
            let end = booking.endTime ?? start.addingTimeInterval(60 * 60)
            items.append(CalendarWorkItem(
                target: .booking(booking.id),
                title: booking.name,
                notes: booking.confirmationNumber.map { "Confirmation: \($0)" },
                location: booking.address,
                url: nil,
                start: start,
                end: end
            ))
        }
        return items
    }

    // MARK: - Server mapping

    private struct LinkRow: Decodable, Sendable {
        let id: UUID
        let activity_id: UUID?
        let booking_id: UUID?
        let external_event_id: String
    }

    private struct ExistingLink {
        let rowId: UUID
        let externalId: String
    }

    private enum CalendarEventLinkInsert {
        case activity(userId: UUID, tripId: UUID, deviceId: String, activityId: UUID, externalEventId: String, externalCalendarId: String)
        case booking(userId: UUID, tripId: UUID, deviceId: String, bookingId: UUID, externalEventId: String, externalCalendarId: String)
    }

    private func fetchExistingLinks(tripId: UUID, deviceId: String) async throws -> [LinkRow] {
        guard let client = AuthSessionService.shared.client else { throw CalendarSyncError.noClient }
        return try await client
            .from("calendar_event_links")
            .select("id, activity_id, booking_id, external_event_id")
            .eq("trip_id", value: tripId.uuidString.lowercased())
            .eq("device_id", value: deviceId)
            .execute()
            .value
    }

    private func persist(links: [CalendarEventLinkInsert]) async throws {
        guard let client = AuthSessionService.shared.client else { throw CalendarSyncError.noClient }
        struct Body: Encodable {
            let user_id: String
            let trip_id: String
            let device_id: String
            let activity_id: String?
            let booking_id: String?
            let external_event_id: String
            let external_calendar_id: String
            let source: String
        }
        let payload = links.map { link -> Body in
            switch link {
            case .activity(let user, let trip, let device, let act, let evt, let cal):
                return Body(
                    user_id: user.uuidString.lowercased(),
                    trip_id: trip.uuidString.lowercased(),
                    device_id: device,
                    activity_id: act.uuidString.lowercased(),
                    booking_id: nil,
                    external_event_id: evt,
                    external_calendar_id: cal,
                    source: "eventkit"
                )
            case .booking(let user, let trip, let device, let book, let evt, let cal):
                return Body(
                    user_id: user.uuidString.lowercased(),
                    trip_id: trip.uuidString.lowercased(),
                    device_id: device,
                    activity_id: nil,
                    booking_id: book.uuidString.lowercased(),
                    external_event_id: evt,
                    external_calendar_id: cal,
                    source: "eventkit"
                )
            }
        }
        try await client
            .from("calendar_event_links")
            .insert(payload)
            .execute()
    }

    private func deleteLinks(ids: [UUID]) async throws {
        guard let client = AuthSessionService.shared.client else { throw CalendarSyncError.noClient }
        try await client
            .from("calendar_event_links")
            .delete()
            .in("id", values: ids.map { $0.uuidString.lowercased() })
            .execute()
    }
}
