//
//  FlightTrackingService.swift
//  wayfind
//
//  Wave 3.3 — per-trip cache + realtime subscription for
//  `public.flight_statuses`. The view layer reads from `statusesByBookingId`
//  and the badge re-renders whenever the Edge Function writes a fresh
//  snapshot.
//
//  Lifecycle:
//    • `bind(tripId:)` is called from `TripDetailView` `.task`. It loads
//      the current statuses with a single PostgREST fetch and opens a
//      realtime channel filtered server-side by `trip_id=eq.<uuid>`.
//    • `unbind()` is called from `.onDisappear`. It tears down the
//      channel so a long backgrounded session doesn't keep eating
//      realtime quota.
//
//  Pro gating: tracking itself is a Pro feature. The badge in the
//  timeline is shown to *all* users (so they can see the value), but
//  for Free users it stays static and tapping it routes through the
//  upsell sheet. Wave 4.5 flips the polling subscription itself behind
//  the entitlement check.
//

import Foundation
import Observation
import Realtime
import Supabase

@MainActor
@Observable
final class FlightTrackingService {
    /// Bookings keyed by `flight_statuses.booking_id`. The badge view
    /// looks up by booking id, not flight number, because two trips
    /// could have the same flight number on the same day.
    private(set) var statusesByBookingId: [UUID: FlightStatus] = [:]

    private(set) var isLoading: Bool = false
    private(set) var lastError: String?
    private(set) var currentTripId: UUID?

    /// Window after which we render the amber "stale data" subtitle.
    /// 30 minutes is the rolling cap of our most aggressive polling
    /// tier; if we haven't refreshed in that long either the Edge
    /// Function is dead or the provider is.
    private let staleAfterSeconds: TimeInterval = 30 * 60

    private var channel: RealtimeChannelV2?
    private var subscriptions: [RealtimeSubscription] = []
    /// Debounce task for the full-refresh fallback path. Cancelled on unbind
    /// and whenever a new debounce fires, so rapid server writes collapse
    /// into at most one round-trip per 500 ms window.
    private var flightRefetchTask: Task<Void, Never>?

    func bind(tripId: UUID) async {
        if currentTripId == tripId { return }
        await unbind()
        currentTripId = tripId
        await refresh(tripId: tripId)
        await subscribeRealtime(tripId: tripId)
    }

    func unbind() async {
        flightRefetchTask?.cancel()
        flightRefetchTask = nil
        currentTripId = nil
        subscriptions.removeAll()
        if let channel {
            await channel.unsubscribe()
        }
        channel = nil
    }

    func staleness(of status: FlightStatus, now: Date = Date()) -> Bool {
        status.isStale(now: now, staleAfter: staleAfterSeconds)
    }

    func tint(of status: FlightStatus, now: Date = Date()) -> FlightStatus.DisplayState.Tint {
        status.tint(now: now, staleAfter: staleAfterSeconds)
    }

    // MARK: - Loading

    private func refresh(tripId: UUID) async {
        guard let client = AuthSessionService.shared.client else { return }
        isLoading = true
        lastError = nil
        defer { isLoading = false }
        do {
            let rows: [FlightStatus] = try await client
                .from("flight_statuses")
                .select()
                .eq("trip_id", value: tripId.uuidString)
                .execute()
                .value
            var dict: [UUID: FlightStatus] = [:]
            for row in rows { dict[row.bookingId] = row }
            statusesByBookingId = dict
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Realtime

    private func subscribeRealtime(tripId: UUID) async {
        guard let client = AuthSessionService.shared.client else { return }
        let filter = "trip_id=eq.\(tripId.uuidString)"
        let ch = client.realtimeV2.channel("trip-flights:\(tripId.uuidString)")

        // INSERT — apply the new row directly to the in-memory dict.
        // Falls back to a debounced full-refresh if the payload can't be
        // decoded (e.g. schema mismatch during a migration).
        subscriptions.append(
            ch.onPostgresChange(
                InsertAction.self,
                schema: "public",
                table: "flight_statuses",
                filter: filter
            ) { [weak self] action in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if let status = RealtimeRowDecoder.decode(FlightStatus.self, from: action.record) {
                        self.statusesByBookingId[status.bookingId] = status
                    } else {
                        self.scheduleFlightRefetch()
                    }
                }
            }
        )

        // UPDATE — patch the existing entry in-place.
        // NOTE: If `flight_statuses` uses REPLICA IDENTITY DEFAULT, UPDATE
        // payloads only carry the primary key on `oldRecord` and the full
        // new row on `record`. That still decodes correctly here because we
        // only read `action.record`. Set REPLICA IDENTITY FULL on the table
        // in Supabase for complete old-row data on deletes.
        subscriptions.append(
            ch.onPostgresChange(
                UpdateAction.self,
                schema: "public",
                table: "flight_statuses",
                filter: filter
            ) { [weak self] action in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if let status = RealtimeRowDecoder.decode(FlightStatus.self, from: action.record) {
                        self.statusesByBookingId[status.bookingId] = status
                    } else {
                        // REPLICA IDENTITY DEFAULT may omit columns — fall back.
                        self.scheduleFlightRefetch()
                    }
                }
            }
        )

        // DELETE — remove the entry from the dict.
        // Needs REPLICA IDENTITY FULL (or at minimum DEFAULT with PK) to
        // carry `booking_id` on the old record; falls back to a full refresh
        // on decode failure so the dict doesn't drift.
        subscriptions.append(
            ch.onPostgresChange(
                DeleteAction.self,
                schema: "public",
                table: "flight_statuses",
                filter: filter
            ) { [weak self] action in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if let status = RealtimeRowDecoder.decode(FlightStatus.self, from: action.oldRecord) {
                        self.statusesByBookingId.removeValue(forKey: status.bookingId)
                    } else {
                        self.scheduleFlightRefetch()
                    }
                }
            }
        )

        try? await ch.subscribeWithError()
        channel = ch
    }

    /// Debounces full-refresh fallbacks so rapid server writes (e.g. a batch
    /// flight-status poll that writes several rows in quick succession) collapse
    /// into at most one PostgREST round-trip per 500 ms window.
    private func scheduleFlightRefetch() {
        flightRefetchTask?.cancel()
        flightRefetchTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled, let self, let id = self.currentTripId else { return }
            await self.refresh(tripId: id)
        }
    }
}
