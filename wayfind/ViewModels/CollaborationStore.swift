//
//  CollaborationStore.swift
//  wayfind
//
//  Per-active-trip @Observable store that owns collaborator state for the
//  members sheet, the toolbar avatar stack, and any other surface that needs
//  to know "who is on this trip" or "what can the current user do here?".
//
//  Lifecycle: bound to `coordinator.activeTrip.id` in `AppRootTabView`. When
//  the user opens a trip the host calls `bind(to:)`; when they return to the
//  list it calls `clear()`. Per the Phase 1 plan, this is the *only* place
//  collaborator state lives — child views read from `@Environment` rather
//  than re-fetching.
//
//  Mock-mode short-circuit: when `AppConfig.useRealBackend == false` we
//  synthesize an "owner-only" state so the rest of the UI (members sheet,
//  gates) renders without any network calls.
//

import Foundation
import Observation
import Supabase

@Observable @MainActor
final class CollaborationStore {
    enum LoadState: Hashable {
        case idle
        case loading
        case loaded
        case failed(message: String)
    }

    private(set) var members: [TripCollaborator] = []
    private(set) var loadState: LoadState = .idle
    private(set) var currentTripId: UUID?
    /// The auth user id of the signed-in user. Captured on `bind(to:)` so
    /// the gates (`canEdit`, `canManage`, `isCurrentUserOwner`) don't have
    /// to async over to `auth.session` every time SwiftUI evaluates them.
    private(set) var currentUserId: UUID?

    private var fetchTask: Task<Void, Never>?

    /// Plumbed through from the host. Defaults to the live service; tests can
    /// swap in their own `CollaboratorService`-shaped object once we add a
    /// protocol — Phase 1 keeps it concrete.
    private let service: CollaboratorService

    init(service: CollaboratorService? = nil) {
        // We can't put `.shared` in the default argument because the
        // shared singleton is `@MainActor`-isolated and the default is
        // evaluated in a nonisolated context (Swift 6 enforces this).
        // Resolving inside the body — which runs on `MainActor` because
        // the whole class is `@MainActor` — is the simple fix.
        self.service = service ?? .shared
    }

    #if DEBUG
    func seedPreviewOwner(tripId: UUID) {
        fetchTask?.cancel()
        let userId = UUID()
        currentTripId = tripId
        members = [
            TripCollaborator(
                id: nil,
                tripId: tripId,
                userId: userId,
                role: .owner,
                status: .accepted,
                invitedEmail: nil,
                displayName: "You",
                username: nil,
                avatarURLString: nil,
                email: nil
            )
        ]
        currentUserId = userId
        loadState = .loaded
    }
    #endif

    // MARK: - Lifecycle

    /// Switch to a new trip. Cancels any in-flight fetch for the previous
    /// trip and wipes member state immediately so the avatar stack doesn't
    /// flash the wrong people while the new fetch is in flight.
    func bind(to tripId: UUID) {
        if currentTripId == tripId, loadState != .idle, !members.isEmpty {
            // Already bound and have data — no-op so toolbar avatar reads
            // are stable across re-renders.
            return
        }
        fetchTask?.cancel()
        currentTripId = tripId
        members = []
        loadState = .loading

        if !AppConfig.useRealBackend {
            // Mock-mode short-circuit: synthesize an owner-only state so the
            // members sheet renders without crashing and so the gates
            // (`canEdit`, `canManage`) all return `true`.
            members = [
                TripCollaborator(
                    id: nil,
                    tripId: tripId,
                    userId: UUID(),
                    role: .owner,
                    status: .accepted,
                    invitedEmail: nil,
                    displayName: "You",
                    username: nil,
                    avatarURLString: nil,
                    email: nil
                )
            ]
            currentUserId = members.first?.userId
            loadState = .loaded
            return
        }

        fetchTask = Task { [tripId] in
            await loadCurrentUserIdIfNeeded()
            await self.fetchCollaborators(tripId: tripId)
        }
    }

    /// Force a refetch for the bound trip — used after a 403 demotion, after
    /// realtime tells us the membership changed, and after a successful
    /// management mutation in Phase 6.
    func refresh() {
        guard let tripId = currentTripId else { return }
        fetchTask?.cancel()
        fetchTask = Task { [tripId] in
            await self.fetchCollaborators(tripId: tripId)
        }
    }

    /// Awaitable variant used by Phase 6 management mutations so the caller
    /// can sequence "mutate → wait for store to refresh → present updated
    /// UI" without race conditions. Cancels any in-flight fetch task.
    func reloadMembers(tripId: UUID) async {
        guard currentTripId == tripId else {
            // Don't kick off a fetch for a trip we're no longer bound to —
            // the store's lifecycle is owned by the host and we'd leak a
            // task by writing back into a different trip's state.
            return
        }
        fetchTask?.cancel()
        await fetchCollaborators(tripId: tripId)
    }

    /// Called from any data-layer mutation that hits a `403 Forbidden` after
    /// a membership change (e.g. the user was demoted from editor to viewer
    /// mid-action). Phase 6 wires this into `CollaboratorService` mutations.
    /// Phase 1 exposes the helper but no call site triggers it yet because
    /// no Phase 1 mutation path is reachable to a non-owner.
    func handleDemotionDetected(toastManager: ToastManager) {
        toastManager.show(
            ToastData(
                message: "Your role on this trip changed. Refreshing…",
                type: .warning,
                duration: 3
            )
        )
        refresh()
    }

    /// Clear all state. Called when the user returns from a trip to the list,
    /// when they sign out, or when the active trip is otherwise torn down.
    func clear() {
        fetchTask?.cancel()
        fetchTask = nil
        currentTripId = nil
        members = []
        loadState = .idle
        // We deliberately keep `currentUserId` cached across trip switches —
        // the auth session itself owns its lifetime, and re-fetching it on
        // every trip switch would round-trip to the auth session storage.
    }

    // MARK: - Derived gates

    var owner: TripCollaborator? {
        members.first(where: { $0.role == .owner })
    }

    var acceptedCollaborators: [TripCollaborator] {
        members.filter { $0.role != .owner && $0.status == .accepted }
    }

    var pendingCollaborators: [TripCollaborator] {
        members.filter { $0.role != .owner && $0.status == .pending }
    }

    var totalAcceptedMemberCount: Int {
        // owner + accepted collaborators
        (owner == nil ? 0 : 1) + acceptedCollaborators.count
    }

    var isCurrentUserOwner: Bool {
        guard let currentUserId, let ownerId = owner?.userId else { return false }
        return currentUserId == ownerId
    }

    /// True for the trip owner and for any accepted editor. The owner does
    /// not appear in `trip_collaborators`, so we treat them separately.
    var canEdit: Bool {
        if isCurrentUserOwner { return true }
        guard let currentUserId else { return false }
        return acceptedCollaborators.contains(where: {
            $0.userId == currentUserId && $0.role == .editor
        })
    }

    /// Only the owner can manage members (invite, remove, change roles, edit
    /// access). Phase 6 surfaces all of these behind this gate.
    var canManage: Bool {
        isCurrentUserOwner
    }

    /// The current user's own collaborator row, if any. Used by the members
    /// sheet to render the "leave trip" CTA and by realtime to detect a
    /// "you were removed" event for the bound trip.
    var selfMember: TripCollaborator? {
        guard let currentUserId else { return nil }
        return members.first(where: { $0.userId == currentUserId })
    }

    var pendingSelfMember: TripCollaborator? {
        guard let currentUserId else { return nil }
        return pendingCollaborators.first(where: { $0.userId == currentUserId })
    }

    // MARK: - Per-surface gates (Phase 1.5 — backend columns ship with the
    // 1.5 migration; until then `canAccess*` is `true` for every row, so
    // these gates resolve to the same answer as `canEdit` for editors and
    // always-true for the owner. This is wired now so Phase 1.5 doesn't
    // require touching any consumer files.)

    var canViewDocuments: Bool {
        if isCurrentUserOwner { return true }
        guard let self_ = selfMember, self_.status == .accepted else { return false }
        return self_.canAccessDocuments
    }

    var canEditDocuments: Bool {
        if isCurrentUserOwner { return true }
        guard let self_ = selfMember, self_.status == .accepted, self_.role == .editor else { return false }
        return self_.canAccessDocuments
    }

    var canViewExpenses: Bool {
        if isCurrentUserOwner { return true }
        guard let self_ = selfMember, self_.status == .accepted else { return false }
        return self_.canAccessExpenses
    }

    var canEditExpenses: Bool {
        if isCurrentUserOwner { return true }
        guard let self_ = selfMember, self_.status == .accepted, self_.role == .editor else { return false }
        return self_.canAccessExpenses
    }

    var canViewNotes: Bool {
        if isCurrentUserOwner { return true }
        guard let self_ = selfMember, self_.status == .accepted else { return false }
        return self_.canAccessNotes
    }

    var canEditNotes: Bool {
        if isCurrentUserOwner { return true }
        guard let self_ = selfMember, self_.status == .accepted, self_.role == .editor else { return false }
        return self_.canAccessNotes
    }

    // MARK: - Internal

    private func loadCurrentUserIdIfNeeded() async {
        if currentUserId != nil { return }
        guard AppConfig.useRealBackend else { return }
        guard let client = AuthSessionService.shared.client else { return }
        do {
            let session = try await client.auth.session
            self.currentUserId = session.user.id
        } catch {
            self.currentUserId = nil
        }
    }

    private func fetchCollaborators(tripId: UUID) async {
        do {
            let fetched = try await service.fetchTripMembers(tripId: tripId)
            // Guard against a stale response after the user already navigated
            // away (or to a different trip) before this fetch resolved.
            guard !Task.isCancelled, currentTripId == tripId else { return }
            self.members = fetched
            self.loadState = .loaded
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, currentTripId == tripId else { return }
            self.loadState = .failed(message: "We couldn't load this trip's members. Pull to retry.")
        }
    }
}


// =============================================================================
