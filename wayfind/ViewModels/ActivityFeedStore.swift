//
//  ActivityFeedStore.swift
//  wayfind
//
//  Phase 4 — Owns the recent-activity feed for one trip. Lifecycle is
//  scoped to the sheet's presentation: `bind(to:)` on appear, `unbind()`
//  on dismiss. Independent from `TripRealtimeService` because:
//
//  • the sheet is only present when the user explicitly opens it,
//  • the realtime subscription on `trip_activity_log` would otherwise
//    fire INSERT events that don't drive any visible UI in the rest of
//    the trip surface, and
//  • keeping it independent means the sheet can be reopened without
//    having to restart the master trip channel.
//
//  Realtime: filtered INSERT subscription on `trip_activity_log` with a
//  450ms debounce so a burst of trigger-driven inserts (e.g. day reorder
//  cascades into N row updates) collapses into a single refetch.
//

import Foundation
import Observation
import Realtime
import Supabase

@Observable @MainActor
final class ActivityFeedStore {
    enum LoadState: Hashable {
        case idle
        case loading
        case loaded
        case failed(message: String)
    }

    private(set) var entries: [ActivityLogEntry] = []
    private(set) var loadState: LoadState = .idle
    private(set) var currentTripId: UUID?

    private let service: ActivityFeedService

    private var fetchTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    private var statusTask: Task<Void, Never>?
    private var subscribeTask: Task<Void, Never>?
    private var subscriptions: [RealtimeSubscription] = []
    private var channel: RealtimeChannelV2?

    init(service: ActivityFeedService? = nil) {
        // Default arg can't reference the `@MainActor`-isolated singleton
        // from a nonisolated context (Swift 6 strict). Resolving in the
        // body runs under `@MainActor` and is safe.
        self.service = service ?? .shared
    }

    // MARK: - Lifecycle

    /// Bind to a trip and start a fresh subscription. If we're already
    /// bound to the same trip and have data, this is a no-op so re-opens
    /// of the sheet stay snappy.
    func bind(to tripId: UUID) {
        if currentTripId == tripId, channel != nil, !entries.isEmpty {
            return
        }
        unbind()
        currentTripId = tripId

        // Mock-mode: synthesize an empty feed so the sheet renders the
        // empty-state copy ("Activity will show up here") without trying
        // to call into PostgREST or open a realtime channel.
        guard AppConfig.useRealBackend else {
            loadState = .loaded
            entries = []
            return
        }

        loadState = entries.isEmpty ? .loading : .loaded
        scheduleFetch(initial: true)
        startRealtime(tripId: tripId)
    }

    /// Tear down the channel and the in-flight fetch. Called on sheet
    /// dismiss + on trip switch.
    func unbind() {
        fetchTask?.cancel()
        fetchTask = nil
        debounceTask?.cancel()
        debounceTask = nil
        statusTask?.cancel()
        statusTask = nil
        subscribeTask?.cancel()
        subscribeTask = nil
        for sub in subscriptions { sub.cancel() }
        subscriptions.removeAll()
        if let channel {
            Task { await channel.unsubscribe() }
        }
        channel = nil
        currentTripId = nil
    }

    /// User pull-to-refresh handler. Reuses the same fetch path.
    func refresh() async {
        guard let tripId = currentTripId else { return }
        await performFetch(tripId: tripId)
    }

    // MARK: - Fetch

    private func scheduleFetch(initial: Bool) {
        guard let tripId = currentTripId else { return }
        fetchTask?.cancel()
        fetchTask = Task { [weak self, tripId] in
            await self?.performFetch(tripId: tripId)
            await MainActor.run { [weak self] in
                self?.fetchTask = nil
            }
            _ = initial
        }
    }

    private func performFetch(tripId: UUID) async {
        do {
            let rows = try await service.fetchTripActivityFeed(tripId: tripId)
            guard !Task.isCancelled, currentTripId == tripId else { return }
            entries = rows
            loadState = .loaded
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, currentTripId == tripId else { return }
            // Show the cached entries (if any) but surface a non-blocking
            // failure message — pull-to-refresh in the sheet recovers.
            if entries.isEmpty {
                loadState = .failed(message: "We couldn't load this trip's activity. Pull to retry.")
            } else {
                loadState = .loaded
            }
        }
    }

    // MARK: - Realtime

    private func startRealtime(tripId: UUID) {
        guard let client = AuthSessionService.shared.client else { return }
        let tripIdString = tripId.uuidString.lowercased()
        let topic = "activity-feed:\(tripIdString):\(UUID().uuidString)"
        let filter = "trip_id=eq.\(tripIdString)"
        let newChannel = client.realtimeV2.channel(topic)
        channel = newChannel

        subscriptions = []
        subscriptions.append(
            newChannel.onPostgresChange(
                InsertAction.self,
                schema: "public",
                table: "trip_activity_log",
                filter: filter
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.scheduleDebouncedRefetch()
                }
            }
        )

        statusTask = Task { [weak self, channel = newChannel] in
            for await status in channel.statusChange {
                guard let self else { return }
                if status == .subscribed {
                    // After a successful subscribe (or resubscribe) drain
                    // any rows we missed during the offline window.
                    await MainActor.run { self.scheduleDebouncedRefetch() }
                }
            }
        }

        subscribeTask = Task { [channel = newChannel] in
            try? await channel.subscribeWithError()
        }
    }

    private func scheduleDebouncedRefetch() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 450_000_000) // 450ms
            guard !Task.isCancelled, let self else { return }
            self.scheduleFetch(initial: false)
            await MainActor.run { [weak self] in
                self?.debounceTask = nil
            }
        }
    }
}


// =============================================================================
