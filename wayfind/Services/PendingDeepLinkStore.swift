//
//  PendingDeepLinkStore.swift
//  wayfind
//
//  Phase 5 — Cold-start / pre-coordinator buffer for incoming deep links
//  (push notification taps and `onOpenURL` arrivals). Two scenarios it
//  handles:
//
//  1. **Cold start from a notification tap**: `didFinishLaunchingWithOptions`
//     fires before `AppRootTabView` exists — there's no
//     `TabNavigationCoordinator` to call `openTrip(_:)` on yet. We seed
//     this store from `launchOptions` so the link survives the gap.
//  2. **Tap during sign-out**: a hot tap arrives while the user is on
//     `SignInView`. We can't navigate yet; we hold here and drain after
//     the auth state flips back to `.signedIn`.
//
//  Drained by `AppRootTabView` once `coordinator.activeTrip` is settable.
//  Independent from `PendingInviteStorage` which is a Keychain-backed
//  invite-token surface — that one survives across launches; this is an
//  in-memory buffer that resets on app kill.
//

import Foundation
import Observation

@Observable @MainActor
final class PendingDeepLinkStore {
    /// One pending deep link target. Today we only model the
    /// "open this trip" intent — Phase 6+ may add notification routes
    /// (e.g. "open the recent activity sheet for trip X") at which point
    /// we widen this enum.
    enum Pending: Hashable, Sendable {
        case openTrip(tripId: UUID)
    }

    private(set) var pending: Pending?

    init() {}

    func enqueue(_ link: Pending) {
        pending = link
    }

    /// Read-and-clear. Callers must consume on a single render pass so
    /// SwiftUI doesn't loop.
    func consume() -> Pending? {
        let snapshot = pending
        pending = nil
        return snapshot
    }

    func clear() {
        pending = nil
    }
}


// =============================================================================
