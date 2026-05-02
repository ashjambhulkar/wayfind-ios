//
//  TripRealtimeService.swift
//  wayfind
//
//  Phase 3 — One-channel-per-active-trip realtime sync. Owned by
//  `AppRootTabView` and bound to `coordinator.activeTrip.id`. Subscribes
//  to the five tables that drive the trip-detail surface and merges
//  changes into `TripDetailViewModel` via debounced refetches.
//
//  Why bind at the tab-view level and not in `TripDetailView`: the detail
//  view's lifecycle fires every time the user switches tabs (Map / Budget
//  / Bookings) which would tear down and rebuild the channel mid-edit.
//  The tab-view sits one level up and only re-binds when the *trip*
//  changes — which is the channel's actual lifecycle.
//
//  The store is intentionally oblivious to mock-mode: when
//  `AppConfig.useRealBackend == false` the bind is a no-op so the rest of
//  the UI (which reads from the same `TripDetailViewModel`) keeps working
//  off of pre-seeded mock data.
//

import Foundation
import Observation
import Realtime
import Supabase
import SwiftUI

@Observable @MainActor
final class TripRealtimeService {
    // MARK: - State

    /// The trip we're currently subscribed to. `nil` when unbound.
    private(set) var currentTripId: UUID?

    enum ConnectionState: Hashable {
        case unbound
        case connecting
        case live
        case offline
    }
    private(set) var connectionState: ConnectionState = .unbound

    // MARK: - Wiring (set on bind, cleared on unbind)

    private weak var viewModel: TripDetailViewModel?
    private weak var collaborationStore: CollaborationStore?
    private weak var collaborationUi: TripCollaborationUiStore?
    private weak var toastManager: ToastManager?
    private var navigateAfterKick: (() -> Void)?
    private var tripTitleProvider: (() -> String)?
    /// Optional — set when the user has the Budget tab on screen. We do not
    /// require it on bind so a build that hasn't shown the budget yet still
    /// gets a clean realtime channel.
    private weak var budgetViewModel: BudgetViewModel?

    // MARK: - Channel + tasks

    private var channel: RealtimeChannelV2?
    private var subscriptions: [RealtimeSubscription] = []
    private var statusTask: Task<Void, Never>?
    private var subscribeTask: Task<Void, Never>?

    /// Per-table debounce tasks. Multiple realtime events arriving inside
    /// the debounce window collapse into a single refetch.
    private var debounceTasks: [DebounceKey: Task<Void, Never>] = [:]

    private enum DebounceKey: Hashable {
        case timeline           // trip_activities + trip_days + trip_bookings
        case trip               // trips row
        case collaborators      // trip_collaborators
        case budget             // trip_expenses + expense_splits + trip_budgets + expense_settlements
        case reconnect          // backoff after CHANNEL_ERROR / TIMED_OUT
    }

    /// Exponential-backoff bookkeeping for the channel reconnect loop. Reset
    /// to 0 on a successful `.subscribed` event and the first explicit `bind`.
    /// Capped at `maxReconnectDelayMs` so a long offline window doesn't
    /// stretch into multi-minute waits, while a flaky connection no longer
    /// hammers the backend (and the UI) every 500ms.
    private var reconnectAttempt: Int = 0
    private let maxReconnectDelayMs: Int = 16_000
    private var hasDrainedCurrentSubscription = false

    init() {}

    // MARK: - Lifecycle

    /// Bind to a trip and start a fresh realtime subscription. Tears down
    /// any existing channel first so a trip switch doesn't double-subscribe.
    func bind(
        to tripId: UUID,
        viewModel: TripDetailViewModel,
        collaborationStore: CollaborationStore,
        collaborationUi: TripCollaborationUiStore,
        toastManager: ToastManager,
        tripTitleProvider: @escaping () -> String,
        navigateAfterKick: @escaping () -> Void
    ) {
        if currentTripId == tripId, channel != nil { return }
        unbind()

        // Fresh bind — start the backoff over so a previous trip's
        // failures don't penalize the new subscription.
        reconnectAttempt = 0
        hasDrainedCurrentSubscription = false

        currentTripId = tripId
        self.viewModel = viewModel
        self.collaborationStore = collaborationStore
        self.collaborationUi = collaborationUi
        self.toastManager = toastManager
        self.tripTitleProvider = tripTitleProvider
        self.navigateAfterKick = navigateAfterKick

        // Mock-mode short-circuit. Everything else (members sheet, UI store
        // bind, viewModel.loadTripData) still runs from the host because
        // those don't depend on us.
        guard AppConfig.useRealBackend else {
            connectionState = .live
            return
        }

        guard AuthSessionService.shared.client != nil else {
            connectionState = .offline
            return
        }

        connectionState = .connecting
        startSubscription(tripId: tripId)
    }

    /// Hooks the Budget tab's view-model into the realtime channel so each
    /// `trip_expenses` / `expense_splits` / `trip_budgets` /
    /// `expense_settlements` event triggers a debounced reload. Safe to call
    /// before or after `bind(to:)` — the realtime channel itself already
    /// listens for those tables; this just installs the reload target.
    func bindBudget(_ viewModel: BudgetViewModel) {
        budgetViewModel = viewModel
    }

    /// Drops the budget reload target without tearing down the channel. The
    /// budget subscriptions keep firing (they're cheap), but the no-op
    /// debounce body is a single nil-check.
    func unbindBudget() {
        budgetViewModel = nil
    }

    /// Tear down the channel and cancel every in-flight task. Safe to call
    /// from sign-out, trip-list return, or test cleanup.
    func unbind() {
        subscribeTask?.cancel()
        subscribeTask = nil
        statusTask?.cancel()
        statusTask = nil
        for task in debounceTasks.values { task.cancel() }
        debounceTasks.removeAll()
        for sub in subscriptions { sub.cancel() }
        subscriptions.removeAll()

        if let channel {
            // Fire-and-forget unsubscribe — tearing down ahead of an
            // imminent rebind shouldn't block the main actor.
            Task { await channel.unsubscribe() }
        }
        channel = nil

        currentTripId = nil
        viewModel = nil
        collaborationStore = nil
        collaborationUi = nil
        toastManager = nil
        navigateAfterKick = nil
        tripTitleProvider = nil
        budgetViewModel = nil
        connectionState = .unbound
    }

    // MARK: - Subscription setup

    private func startSubscription(tripId: UUID) {
        guard let client = AuthSessionService.shared.client else {
            connectionState = .offline
            return
        }

        let tripIdString = tripId.uuidString.lowercased()
        // Unique suffix so server-side channel reuse can't collide with a
        // stale channel from a previous bind cycle (e.g. quick A→B→A trip
        // switch where A's channel hasn't fully torn down yet).
        let topic = "trip:\(tripIdString):\(UUID().uuidString)"
        let filter = "trip_id=eq.\(tripIdString)"

        let newChannel = client.realtimeV2.channel(topic)
        channel = newChannel
        hasDrainedCurrentSubscription = false

        subscriptions = []

        // ===== trip_activities =====
        // The 15-field meaningful-change filter sits inside the UPDATE
        // handler; INSERT and DELETE always trigger a refetch. We capture
        // the actor user id from `created_by` for the flash store.
        subscriptions.append(
            newChannel.onPostgresChange(
                InsertAction.self,
                schema: "public",
                table: "trip_activities",
                filter: filter
            ) { [weak self] action in
                Task { @MainActor [weak self] in
                    self?.handleActivityInsert(action)
                }
            }
        )
        subscriptions.append(
            newChannel.onPostgresChange(
                UpdateAction.self,
                schema: "public",
                table: "trip_activities",
                filter: filter
            ) { [weak self] action in
                Task { @MainActor [weak self] in
                    self?.handleActivityUpdate(action)
                }
            }
        )
        subscriptions.append(
            newChannel.onPostgresChange(
                DeleteAction.self,
                schema: "public",
                table: "trip_activities",
                filter: filter
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.scheduleTimelineRefetch()
                }
            }
        )

        // ===== trip_days =====
        // Day creates / deletes / reorders all need the timeline reloaded
        // so the day-section renderer picks up the new ordering.
        subscriptions.append(
            newChannel.onPostgresChange(
                AnyAction.self,
                schema: "public",
                table: "trip_days",
                filter: filter
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.scheduleTimelineRefetch()
                }
            }
        )

        // ===== trip_bookings =====
        // Bookings render on the timeline alongside activities (hotel /
        // flight / car rental rows) so a booking change still invalidates
        // the timeline fetch.
        subscriptions.append(
            newChannel.onPostgresChange(
                AnyAction.self,
                schema: "public",
                table: "trip_bookings",
                filter: filter
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.scheduleTimelineRefetch()
                }
            }
        )

        // ===== Collaborative budget tables =====
        // Each event collapses into one debounced `BudgetViewModel.reload`
        // (300 ms — matches the spec). `trip_expenses` and `trip_budgets`
        // already have `trip_id`; `expense_splits` carries a denormalised
        // `trip_id` column populated by the `tg_expense_splits_set_trip_id`
        // trigger so we can filter by it without joining. `expense_settlements`
        // is a fresh table with `trip_id` from day one.
        for table in ["trip_expenses", "expense_splits", "trip_budgets", "expense_settlements"] {
            subscriptions.append(
                newChannel.onPostgresChange(
                    AnyAction.self,
                    schema: "public",
                    table: table,
                    filter: filter
                ) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.scheduleBudgetRefetch()
                    }
                }
            )
        }

        // ===== trips =====
        // Filter by `id=eq.<tripId>` here because `trips` doesn't have a
        // `trip_id` column — its primary key IS the trip id.
        let tripsFilter = "id=eq.\(tripIdString)"
        subscriptions.append(
            newChannel.onPostgresChange(
                UpdateAction.self,
                schema: "public",
                table: "trips",
                filter: tripsFilter
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.scheduleTripRefetch()
                }
            }
        )
        subscriptions.append(
            newChannel.onPostgresChange(
                DeleteAction.self,
                schema: "public",
                table: "trips",
                filter: tripsFilter
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    // Trip itself was deleted out from under us. Treat
                    // this as a kick — the trip is no longer reachable.
                    self?.handleTripDeleted()
                }
            }
        )

        // ===== trip_collaborators =====
        // Per-table debounce so a "remove all viewers" cascade collapses
        // into one fetch, but the per-event self-handlers (kick + access
        // revoke) still fire synchronously off the inbound payload.
        subscriptions.append(
            newChannel.onPostgresChange(
                InsertAction.self,
                schema: "public",
                table: "trip_collaborators",
                filter: filter
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.scheduleCollaboratorRefetch()
                }
            }
        )
        subscriptions.append(
            newChannel.onPostgresChange(
                UpdateAction.self,
                schema: "public",
                table: "trip_collaborators",
                filter: filter
            ) { [weak self] action in
                Task { @MainActor [weak self] in
                    self?.handleCollaboratorUpdate(action)
                }
            }
        )
        subscriptions.append(
            newChannel.onPostgresChange(
                DeleteAction.self,
                schema: "public",
                table: "trip_collaborators",
                filter: filter
            ) { [weak self] action in
                Task { @MainActor [weak self] in
                    self?.handleCollaboratorDelete(action)
                }
            }
        )

        // Status observer: drives reconnect on errors, transition to .live
        // once the server confirms the join.
        statusTask = Task { [weak self, channel = newChannel] in
            for await status in channel.statusChange {
                guard let self else { return }
                await MainActor.run { self.handleStatusChange(status) }
            }
        }

        subscribeTask = Task { [channel = newChannel] in
            // subscribeWithError is preferred — we surface failures via
            // status callbacks anyway, but throwing here lets us drop the
            // task and rely on the status observer for the next reconnect
            // attempt.
            try? await channel.subscribeWithError()
        }
    }

    private func handleStatusChange(_ status: RealtimeChannelStatus) {
        switch status {
        case .subscribed:
            // Reset backoff first so a future flap doesn't inherit the
            // last failure's exponent.
            let wasOffline = (connectionState == .offline)
            reconnectAttempt = 0
            connectionState = .live
            // Only drain once per concrete channel, or after a real
            // recovery from offline. `statusChange` can replay
            // `.subscribed`; treating every replay as a fresh load churns
            // the view model and visibly blips open SwiftUI menus.
            if wasOffline || !hasDrainedCurrentSubscription {
                hasDrainedCurrentSubscription = true
                scheduleTimelineRefetch()
                scheduleCollaboratorRefetch()
                scheduleBudgetRefetch()
            }
        case .subscribing:
            connectionState = .connecting
        case .unsubscribed:
            // Server kicked us, or the channel torn down. If we still
            // have a `currentTripId`, schedule a backed-off reconnect.
            // If `unbind` already nilled `currentTripId` the reconnect
            // bails out via its own guard.
            connectionState = .offline
            scheduleReconnect()
        case .unsubscribing:
            // Transient "in the process of closing" state. Do NOT
            // schedule a reconnect here — the channel will surface
            // either `.unsubscribed` (real failure) or settle, and
            // double-firing the reconnect from this state caused the
            // tight 500ms loop that hammered the timeline refetch.
            connectionState = .offline
        }
    }

    // MARK: - Refetch debouncers

    private func scheduleTimelineRefetch() {
        scheduleDebounce(.timeline, delayMs: 250) { [weak self] in
            guard let self, let viewModel = self.viewModel else { return }
            await viewModel.loadTripData()
        }
    }

    private func scheduleTripRefetch() {
        scheduleDebounce(.trip, delayMs: 250) { [weak self] in
            // TripDetailViewModel doesn't expose a trip-only refetch yet,
            // and a `trips` row update is rare (title / dates / cover) —
            // collapse with the timeline fetch which already re-applies
            // any computed counts off the trip row.
            guard let self, let viewModel = self.viewModel else { return }
            await viewModel.loadTripData()
        }
    }

    private func scheduleCollaboratorRefetch() {
        scheduleDebounce(.collaborators, delayMs: 280) { [weak self] in
            guard let self else { return }
            self.collaborationStore?.refresh()
        }
    }

    /// Coalesces every budget-table event into one `BudgetViewModel.reload`.
    /// 300 ms matches `phase4_realtime` in the implementation plan and lines
    /// up with how a sensible burst (insert expense → insert N splits) looks
    /// on the wire — they all arrive within ~50ms.
    private func scheduleBudgetRefetch() {
        scheduleDebounce(.budget, delayMs: 300) { [weak self] in
            guard let self, let viewModel = self.budgetViewModel else { return }
            await viewModel.reload()
        }
    }

    private func scheduleReconnect() {
        // Only retry while we're actually bound to a trip — if `unbind`
        // already nilled `currentTripId` we're tearing down on purpose.
        guard let tripId = currentTripId, AppConfig.useRealBackend else { return }

        // Coalesce: if a reconnect is already pending in the debounce
        // window, don't queue a second one (it would just cancel the
        // first via `scheduleDebounce` and reset the timer, defeating
        // the backoff).
        if debounceTasks[.reconnect] != nil { return }

        // 1s, 2s, 4s, 8s, 16s, 16s … capped. Computed off the *current*
        // attempt count, then bumped, so the first failure waits 1s and
        // each subsequent one doubles up to the cap.
        let attempt = reconnectAttempt
        reconnectAttempt = min(reconnectAttempt + 1, 6)
        let delayMs = min(1_000 * (1 << min(attempt, 4)), maxReconnectDelayMs)

        scheduleDebounce(.reconnect, delayMs: delayMs) { [weak self] in
            guard let self, self.currentTripId == tripId else { return }
            // Drop the stale channel state and rebuild from scratch.
            for sub in self.subscriptions { sub.cancel() }
            self.subscriptions.removeAll()
            self.statusTask?.cancel()
            self.statusTask = nil
            self.subscribeTask?.cancel()
            self.subscribeTask = nil
            if let channel = self.channel {
                Task { await channel.unsubscribe() }
            }
            self.channel = nil
            // Refetch is intentionally deferred: `handleStatusChange`
            // fires `scheduleTimelineRefetch()` + `scheduleCollaboratorRefetch()`
            // when the new channel reaches `.subscribed`. Refetching on
            // every reconnect *attempt* used to churn the viewmodel
            // every 500ms and visibly flicker any open Menu — the
            // timeline / collaborators surface is at most one full
            // refresh out of date until the channel actually comes
            // back, which is the right tradeoff vs constant churn.
            self.startSubscription(tripId: tripId)
        }
    }

    private func scheduleDebounce(
        _ key: DebounceKey,
        delayMs: Int,
        work: @escaping @MainActor () async -> Void
    ) {
        debounceTasks[key]?.cancel()
        debounceTasks[key] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000)
            guard !Task.isCancelled else { return }
            await work()
            await MainActor.run { [weak self] in
                self?.debounceTasks[key] = nil
            }
        }
    }

    // MARK: - Activity insert / update — flash UX

    private func handleActivityInsert(_ action: InsertAction) {
        guard let row = RealtimeRowDecoder.decode(TripActivityRemoteChange.self, from: action.record) else {
            scheduleTimelineRefetch()
            return
        }
        recordFlash(for: row, kind: .new)
        scheduleTimelineRefetch()
    }

    private func handleActivityUpdate(_ action: UpdateAction) {
        guard
            let oldRow = RealtimeRowDecoder.decode(TripActivityRemoteChange.self, from: action.oldRecord),
            let newRow = RealtimeRowDecoder.decode(TripActivityRemoteChange.self, from: action.record)
        else {
            scheduleTimelineRefetch()
            return
        }
        // Suppress the flash + refetch when the only thing that changed
        // is `updated_at` (or another non-visible column).
        guard TripActivityRemoteChange.meaningfullyChanged(old: oldRow, new: newRow) else {
            return
        }
        recordFlash(for: newRow, kind: .updated)
        scheduleTimelineRefetch()
    }

    /// Drops a flash for the place id carried on the row, attributing it
    /// to whichever collaborator's `created_by` matches. Self-edits are
    /// suppressed (we never flash someone for their own change).
    private func recordFlash(
        for row: TripActivityRemoteChange,
        kind: TripCollaborationUiStore.ChangeKind
    ) {
        guard let placeId = row.id else { return }
        let actorUserId = row.createdBy
        if let currentUserId = collaborationStore?.currentUserId, actorUserId == currentUserId {
            return
        }
        let actorName = displayName(for: actorUserId)
        collaborationUi?.markChange(
            placeId: placeId,
            actorUserId: actorUserId,
            actorDisplayName: actorName,
            kind: kind,
            placeName: row.title
        )
    }

    private func displayName(for userId: UUID?) -> String? {
        guard let userId, let collaborationStore else { return nil }
        if let member = collaborationStore.members.first(where: { $0.userId == userId }) {
            return member.resolvedDisplayName
        }
        return nil
    }

    // MARK: - Collaborator update — access flag handling

    private func handleCollaboratorUpdate(_ action: UpdateAction) {
        defer { scheduleCollaboratorRefetch() }
        guard let collaborationStore else { return }
        let rowUserId = RealtimeRowDecoder.uuid("user_id", in: action.record)
        guard let currentUserId = collaborationStore.currentUserId,
              rowUserId == currentUserId
        else { return }

        // Real DB columns are `can_see_*` — Phase 1 of collaborative budget
        // (`20260501120000_collaborative_budget_v1.sql`) backfills existing
        // rows to `true` and defaults new ones to `false`, so a bool here
        // is always present. We still default the read to `true` so a
        // missing column on a transient older replica doesn't false-trip
        // the warning.
        let scopes: [(key: String, label: String)] = [
            ("can_see_documents", "documents"),
            ("can_see_expenses", "expenses"),
            ("can_see_notes", "notes")
        ]
        for scope in scopes {
            let oldValue = RealtimeRowDecoder.bool(scope.key, in: action.oldRecord) ?? true
            let newValue = RealtimeRowDecoder.bool(scope.key, in: action.record) ?? true
            if oldValue == true, newValue == false {
                toastManager?.show(
                    ToastData(
                        message: "The owner removed your access to \(scope.label)",
                        type: .warning,
                        duration: 3
                    )
                )
                break
            }
        }
    }

    // MARK: - Collaborator delete + trip delete — kick UX

    private func handleCollaboratorDelete(_ action: DeleteAction) {
        defer { scheduleCollaboratorRefetch() }

        guard let collaborationStore else { return }
        let rowUserId = RealtimeRowDecoder.uuid("user_id", in: action.oldRecord)
        guard let currentUserId = collaborationStore.currentUserId,
              rowUserId == currentUserId
        else { return }

        // User-initiated leave already navigated us away — let the gate
        // suppress the kick UX so we don't double-fire.
        if CollaboratorRemovalGate.shared.consumeSuppressFlag() { return }

        let oldStatus = RealtimeRowDecoder.string("status", in: action.oldRecord)
        // Only show the kick UX when an *accepted* membership was removed.
        // A pending row being declined cleanly shouldn't trigger the
        // "you were removed" toast.
        guard oldStatus == "accepted" else { return }

        runKickUx()
    }

    private func handleTripDeleted() {
        // The trip itself disappeared — same UX as being removed by the
        // owner. Owner deleted-self path also lands here, but they
        // initiated it from the Delete Trip dialog so they expect the
        // navigation; the toast still reads sensibly.
        if CollaboratorRemovalGate.shared.consumeSuppressFlag() { return }
        runKickUx()
    }

    private func runKickUx() {
        let actor = collaborationStore?.owner?.resolvedDisplayName ?? "The trip owner"
        let tripTitle = tripTitleProvider?() ?? "this trip"
        HapticManager.warning()
        toastManager?.show(
            ToastData(
                message: "\(actor) removed you from \(tripTitle)",
                type: .warning,
                duration: 2.5
            )
        )
        // Hand off navigation to the host (AppRootTabView) — it knows
        // how to tear down the active trip and pop us back to the list.
        // We give the toast a moment to render before we navigate so the
        // user actually sees the message.
        let navigate = navigateAfterKick
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000) // 0.4s
            navigate?()
        }
    }
}


// =============================================================================
