//
//  TripCollaborator.swift
//  wayfind
//
//  Mirrors the `trip_collaborators` table joined with the embedded profile
//  snippet returned by `list_trip_collaborator_profile_snippets`. The owner
//  of a trip lives on `trips.user_id`, NOT in this table — `CollaborationStore`
//  synthesizes a virtual `.owner` row from the trip + owner profile snippet
//  so the members sheet can render owner + collaborators in a single list.
//

import Foundation

enum TripRole: String, Codable, Hashable, CaseIterable {
    case owner
    case editor
    case viewer

    /// Verb-rich label shown in member rows and invite role pickers.
    /// Plan UX guideline: prefer "Can edit" / "Can view" over "Editor" /
    /// "Viewer" in body copy because it reads more like Apple Mail / iCloud
    /// share semantics. Use `displayLabel` in chips and `verboseLabel` in
    /// descriptions.
    var displayLabel: String {
        switch self {
        case .owner: return "Owner"
        case .editor: return "Editor"
        case .viewer: return "Viewer"
        }
    }

    var verboseLabel: String {
        switch self {
        case .owner: return "Owner"
        case .editor: return "Can edit"
        case .viewer: return "Can view"
        }
    }
}

enum CollaboratorStatus: String, Codable, Hashable {
    case pending
    case accepted
    case declined
}

/// One member of a trip. May represent the owner (synthesized — `id` is
/// `nil` for the owner row because the owner does not live in
/// `trip_collaborators`) or a real `trip_collaborators` row.
struct TripCollaborator: Identifiable, Hashable {
    /// `trip_collaborators.id` for real rows; `nil` for the synthesized owner row.
    let id: UUID?
    let tripId: UUID
    let userId: UUID?
    let role: TripRole
    let status: CollaboratorStatus
    let invitedEmail: String?
    let displayName: String?
    let username: String?
    let avatarURLString: String?
    let email: String?

    /// Per-surface access flags — independent of role. The owner is always
    /// `true` for all three. Phase 1 hard-codes these to `true` for editor /
    /// viewer rows because the backend columns ship in Phase 1.5; once the
    /// migration lands the service will start populating these from the
    /// real columns.
    var canAccessDocuments: Bool = true
    var canAccessExpenses: Bool = true
    var canAccessNotes: Bool = true

    /// Optional payment handles surfaced by the SECURITY DEFINER
    /// `get_trip_owner_profile_snippet` /
    /// `list_trip_collaborator_profile_snippets` RPCs so the
    /// `SettlementCompleteSheet` can deep-link into Venmo / PayPal without
    /// requiring direct profile-row access. `nil` when the recipient hasn't
    /// filled them in from Edit Profile — the UI gracefully falls back to a
    /// "no deep link" caption in that case.
    var venmoUsername: String?
    var paypalUsername: String?

    /// Stable identifier for SwiftUI / haptics / avatar palette. Real rows use
    /// their `trip_collaborators.id`; the synthesized owner row uses the trip's
    /// owner `userId` (always present for the owner row).
    var stableID: String {
        if let id { return id.uuidString }
        if let userId { return "owner:\(userId.uuidString)" }
        return "owner:\(tripId.uuidString)"
    }

    var avatarURL: URL? {
        guard let avatarURLString, !avatarURLString.isEmpty else { return nil }
        return URL(string: avatarURLString)
    }

    /// Best-effort label for member rows: `displayName` → username (no @) →
    /// email local-part → "Pending invite" for unaccepted email-only rows.
    var resolvedDisplayName: String {
        if let displayName = displayName?.trimmingCharacters(in: .whitespacesAndNewlines), !displayName.isEmpty {
            return displayName
        }
        if let username = username?.trimmingCharacters(in: .whitespacesAndNewlines), !username.isEmpty {
            return username.hasPrefix("@") ? String(username.dropFirst()) : username
        }
        if let email = email?.trimmingCharacters(in: .whitespacesAndNewlines), !email.isEmpty {
            return String(email.split(separator: "@").first ?? Substring(email))
        }
        if let invitedEmail = invitedEmail?.trimmingCharacters(in: .whitespacesAndNewlines), !invitedEmail.isEmpty {
            return String(invitedEmail.split(separator: "@").first ?? Substring(invitedEmail))
        }
        return "Pending invite"
    }
}


// =============================================================================
