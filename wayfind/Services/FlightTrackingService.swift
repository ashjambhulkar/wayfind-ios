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

    func bind(tripId: UUID) async {
        if currentTripId == tripId { return }
        await unbind()
        currentTripId = tripId
        await refresh(tripId: tripId)
        await subscribeRealtime(tripId: tripId)
    }

    func unbind() async {
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
        // Filter server-side so the wire only carries this trip's rows.
        // This satisfies the plan's "server-side filtered Realtime"
        // requirement — without it the channel would broadcast every
        // user's flight updates to every connected client.
        let filter = "trip_id=eq.\(tripId.uuidString)"
        let ch = client.realtimeV2.channel("trip-flights:\(tripId.uuidString)")

        // Refetch on any change. Realtime payloads on UPDATE don't
        // always carry every column we decode (depends on REPLICA
        // IDENTITY) so a fresh single-row fetch is the safest path
        // and the call volume is tiny (≤ 1 per change per device).
        subscriptions.append(
            ch.onPostgresChange(
                AnyAction.self,
                schema: "public",
                table: "flight_statuses",
                filter: filter
            ) { [weak self] _ in
                guard let self else { return }
                Task { @MainActor [weak self] in
                    guard let self, let id = self.currentTripId else { return }
                    await self.refresh(tripId: id)
                }
            }
        )
        try? await ch.subscribeWithError()
        channel = ch
    }
}
