//
//  TripInvite.swift
//  wayfind
//
//  Mirrors a row in `trip_invites`. Created by `InviteService.createInvite`
//  and surfaced in the members sheet's "Active invites" section (Phase 6).
//
//  Phase 1.5 backend dependency — once the migration adds the three
//  per-surface access flag columns to `trip_invites`, the iOS-side
//  `createInvite` call writes them so they propagate to the
//  `trip_collaborators` row at accept time. The model already carries the
//  flags so all downstream call sites compile against a stable shape.
//

import Foundation

struct TripInvite: Identifiable, Hashable, Sendable {
    let id: UUID
    let tripId: UUID
    let createdBy: UUID
    let token: String
    let role: TripRole
    let maxUses: Int?
    let uses: Int
    let expiresAt: Date?
    let isActive: Bool
    let createdAt: Date?
    let invitedEmail: String?

    /// Per-surface access flags carried to the resulting `trip_collaborators`
    /// row when the invitee accepts. Default `true` mirrors the post-migration
    /// column default and matches the iOS `TripCollaborator` defaults.
    var canAccessDocuments: Bool = true
    var canAccessExpenses: Bool = true
    var canAccessNotes: Bool = true
}


// =============================================================================
