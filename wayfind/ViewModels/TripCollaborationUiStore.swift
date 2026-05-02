//
//  TripCollaborationUiStore.swift
//  wayfind
//
//  Phase 3 — Flash UX surface. Tracks "who just touched what" so the
//  itinerary cards can render a subtle attribution chip ("Alex · just now")
//  and a one-shot color pulse without each card hitting the network.
//
//  Replaces the Slack-style green-border treatment from the Expo app: it
//  doesn't survive a re-render, doesn't shift layout, and respects Reduce
//  Motion (no pulse, attribution chip only — the chip itself is text and
//  layout-stable).
//
//  Lifetime: tied to `coordinator.activeTrip.id` alongside `CollaborationStore`
//  in `AppRootTabView`. The owning `TripRealtimeService` calls
//  `markChange(...)` on every meaningfully-changed `trip_activities` row.
//  Entries auto-expire (8s for `.new`, 6s for `.updated`) so the chip fades
//  cleanly without a manual sweep call from any view.
//

import Foundation
import Observation
import SwiftUI

@Observable @MainActor
final class TripCollaborationUiStore {
    enum ChangeKind: Hashable {
        case new
        case updated
    }

    struct ChangeFlash: Identifiable, Hashable {
        let id: UUID
        let actorUserId: UUID?
        let actorDisplayName: String?
        let kind: ChangeKind
        let receivedAt: Date

        var displayActor: String {
            guard let name = actorDisplayName?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty
            else { return "Someone" }
            return name
        }
    }

    /// Per-place-id flash. The key is `Place.id` (which IS
    /// `trip_activities.id` — the ids are the same row in our model).
    private(set) var flashesByPlaceId: [UUID: ChangeFlash] = [:]

    /// Throttle for the selection haptic — at most one tick per 2 seconds
    /// so a burst of realtime events doesn't buzz the device.
    private var lastHapticAt: Date?

    /// Pending expiration tasks keyed by place id so a follow-up flash
    /// for the same row cancels its predecessor's auto-clear.
    private var expireTasks: [UUID: Task<Void, Never>] = [:]

    /// Currently-bound trip. We swap entirely on `bind(to:)` rather than
    /// merging because flashes from a previous trip would render against
    /// places that don't exist on the new trip.
    private(set) var currentTripId: UUID?

    init() {}

    // MARK: - Lifecycle

    func bind(to tripId: UUID) {
        if currentTripId == tripId { return }
        clear()
        currentTripId = tripId
    }

    func clear() {
        for task in expireTasks.values { task.cancel() }
        expireTasks.removeAll()
        flashesByPlaceId.removeAll()
        currentTripId = nil
        lastHapticAt = nil
        lastAnnouncedAt = nil
    }

    // MARK: - Flash recording

    /// Last announce time. Throttled to 2s like the haptic so VoiceOver
    /// users don't get flooded during a multi-row import or burst edit.
    private var lastAnnouncedAt: Date?

    /// Record a meaningful change to a place. Cancels any pending expire
    /// for the same place id and starts a fresh one. Selection haptic is
    /// throttled to once every 2s, and is suppressed entirely under
    /// Reduce Motion (HapticManager.selection() already gates on this).
    func markChange(
        placeId: UUID,
        actorUserId: UUID?,
        actorDisplayName: String?,
        kind: ChangeKind,
        placeName: String? = nil
    ) {
        let now = Date()
        let flash = ChangeFlash(
            id: UUID(),
            actorUserId: actorUserId,
            actorDisplayName: actorDisplayName,
            kind: kind,
            receivedAt: now
        )
        flashesByPlaceId[placeId] = flash

        if let last = lastHapticAt, now.timeIntervalSince(last) < 2 {
            // Throttled — skip the haptic but still flash visually.
        } else {
            HapticManager.selection()
            lastHapticAt = now
        }

        // Throttled VoiceOver announce so the screen reader confirms the
        // realtime change without spamming during burst edits. Phrasing
        // names the actor (per copy guidelines: names not pronouns) and
        // the affected stop when we have it.
        if UIAccessibility.isVoiceOverRunning {
            if let last = lastAnnouncedAt, now.timeIntervalSince(last) < 2 {
                // Skip — recent announce already covered the burst.
            } else {
                let actor = flash.displayActor
                let verb = (kind == .new) ? "added" : "updated"
                let target: String
                if let placeName = placeName?.trimmingCharacters(in: .whitespacesAndNewlines), !placeName.isEmpty {
                    target = placeName
                } else {
                    target = "a stop"
                }
                let announcement = "\(actor) \(verb) \(target)."
                UIAccessibility.post(notification: .announcement, argument: announcement)
                lastAnnouncedAt = now
            }
        }

        expireTasks[placeId]?.cancel()
        let ttl: TimeInterval = (kind == .new) ? 8 : 6
        let placeIdCopy = placeId
        let flashIdCopy = flash.id
        expireTasks[placeId] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(ttl * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            // Only clear if the entry hasn't been replaced by a newer flash.
            if self.flashesByPlaceId[placeIdCopy]?.id == flashIdCopy {
                self.flashesByPlaceId.removeValue(forKey: placeIdCopy)
                self.expireTasks.removeValue(forKey: placeIdCopy)
            }
        }
    }

    func flash(for placeId: UUID) -> ChangeFlash? {
        flashesByPlaceId[placeId]
    }
}


// =============================================================================
