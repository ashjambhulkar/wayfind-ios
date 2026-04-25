//
//  CollaboratorRemovalGate.swift
//  wayfind
//
//  Phase 3 — One-shot suppression flag set by the user-initiated "Leave
//  trip" path (Phase 6) so the realtime kick handler doesn't double up
//  with the "you were removed by Alex" UX when the user explicitly chose
//  to leave themselves.
//
//  Contract:
//   1. Phase 6 `leaveTrip` flips `suppressNextKick = true` BEFORE issuing
//      the delete and ALWAYS uses `defer { CollaboratorRemovalGate.shared
//      .consumeSuppressFlag() }` so the flag is consumed exactly once
//      regardless of the delete succeeding or failing.
//   2. The kick handler reads `consumeSuppressFlag()` first thing on a
//      DELETE-self event. If it returns `true`, the handler bails out
//      silently — no toast, no haptic, no navigation. Otherwise the
//      "Alex removed you from <trip>" UX runs.
//
//  Why one-shot rather than per-trip: the realtime DELETE event arrives
//  AFTER the user has already navigated away (the leaveTrip path tears
//  the channel down on its own). If we tied the flag to a tripId we'd
//  have to keep the gate alive across the channel rebind, which makes
//  the lifecycle racy. A simple one-shot flip works because there's
//  always at most one in-flight self-delete at a time.
//

import Foundation
import os

@MainActor
final class CollaboratorRemovalGate {
    static let shared = CollaboratorRemovalGate()

    /// Set this BEFORE issuing the user-initiated leave / decline-pending
    /// call. The realtime DELETE event will arrive shortly after and the
    /// kick handler will consume the flag.
    var suppressNextKick = false

    private init() {}

    /// Reads and clears the suppression flag in one step. Idempotent: a
    /// second call returns `false` so a duplicate realtime event still
    /// drives the kick UX (we'd rather over-show than under-show in the
    /// rare case the gate goes stale).
    func consumeSuppressFlag() -> Bool {
        let value = suppressNextKick
        suppressNextKick = false
        return value
    }
}


// =============================================================================
