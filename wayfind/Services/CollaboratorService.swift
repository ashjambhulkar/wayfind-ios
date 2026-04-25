//
//  CollaboratorService.swift
//  wayfind
//
//  Phase 1 read-only surface for trip membership. Wraps the two
//  `SECURITY DEFINER` profile-snippet RPCs plus a direct fetch of
//  `trip_collaborators`. Owner is NOT in `trip_collaborators` — it lives on
//  `trips.user_id` — so the store fetches the owner profile snippet via a
//  separate RPC and merges it in.
//
//  Phase 6 will extend this with `updateRole`, `updateAccessFlags`,
//  `removeCollaborator`, `leaveTrip`, and `deactivateInvite`. Phase 1.5
//  will start populating the per-surface access flags once the backend
//  migration ships the columns.
//

import Foundation
import Supabase

@MainActor
final class CollaboratorService {
    static let shared = CollaboratorService()

    private init() {}

    private var client: SupabaseClient? {
        AuthSessionService.shared.client
    }

    // MARK: - Public API

    /// Fetches the synthesized owner row + every accepted/pending row in
    /// `trip_collaborators` for the given trip. Pending rows include
    /// invitee-only rows that don't yet have a `user_id` (email-only
    /// invites that haven't been accepted yet).
    ///
    /// Failure modes are routed through the throwing API so the store can
    /// distinguish "you were demoted" (403) from "network blip" (other) and
    /// surface the right toast.
    func fetchTripMembers(tripId: UUID) async throws -> [TripCollaborator] {
        guard let client else { throw SupabaseManagerError.notConfigured }
        let tripIdString = tripId.uuidString.lowercased()

        async let ownerSnippetTask = fetchOwnerSnippet(client: client, tripId: tripIdString)
        async let collaboratorSnippetsTask = fetchCollaboratorSnippets(client: client, tripId: tripIdString)
        async let collaboratorRowsTask = fetchCollaboratorRows(client: client, tripId: tripIdString)
        async let tripOwnerTask = fetchTripOwnerId(client: client, tripId: tripIdString)

        let (ownerSnippet, snippetRows, collaboratorRows, ownerId) = try await (
            ownerSnippetTask,
            collaboratorSnippetsTask,
            collaboratorRowsTask,
            tripOwnerTask
        )

        // Use uniquingKeysWith defensively in case the RPC ever returns the
        // same user_id twice (shouldn't happen, but `Dictionary(uniqueKeysWithValues:)`
        // would crash if it did).
        let snippetByUserId = Dictionary(
            snippetRows.compactMap { snippet -> (UUID, CollaboratorProfileSnippet)? in
                guard let uuid = snippet.userId else { return nil }
                return (uuid, snippet)
            },
            uniquingKeysWith: { existing, _ in existing }
        )

        var members: [TripCollaborator] = []

        // Synthesize the owner row. The owner profile snippet RPC returns
        // `null` (jsonb null) when the caller cannot view the trip; we
        // tolerate that and fall back to "Trip owner".
        if let ownerId {
            members.append(
                TripCollaborator(
                    id: nil,
                    tripId: tripId,
                    userId: ownerId,
                    role: .owner,
                    status: .accepted,
                    invitedEmail: nil,
                    displayName: ownerSnippet?.displayName,
                    username: ownerSnippet?.username,
                    avatarURLString: ownerSnippet?.avatarURLString,
                    email: nil
                )
            )
        }

        for row in collaboratorRows {
            let role = TripRole(rawValue: row.role) ?? .viewer
            let status = CollaboratorStatus(rawValue: row.status) ?? .accepted
            let snippet = row.userId.flatMap { snippetByUserId[$0] }
            members.append(
                TripCollaborator(
                    id: row.id,
                    tripId: tripId,
                    userId: row.userId,
                    role: role,
                    status: status,
                    invitedEmail: row.invitedEmail,
                    displayName: snippet?.displayName,
                    username: snippet?.username,
                    avatarURLString: snippet?.avatarURLString,
                    email: snippet?.email
                )
            )
        }

        return members
    }

    // MARK: - Phase 6 mutations

    /// Updates a collaborator's role between `editor` and `viewer`. Owner
    /// rows can't be demoted via this path — the UI never surfaces the
    /// option, and the backend RLS would refuse anyway.
    func updateRole(rowId: UUID, role: TripRole) async throws {
        guard let client else { throw SupabaseManagerError.notConfigured }
        precondition(role != .owner, "Cannot demote / promote into owner role")
        let payload = RoleUpdatePayload(role: role.rawValue)
        try await client
            .from("trip_collaborators")
            .update(payload)
            .eq("id", value: rowId.uuidString.lowercased())
            .execute()
    }

    /// Updates the three Phase 1.5 per-surface access flags in a single
    /// patch so the realtime layer fires one UPDATE event (per row) and
    /// observers can react with a single re-render.
    func updateAccessFlags(
        rowId: UUID,
        canAccessDocuments: Bool,
        canAccessExpenses: Bool,
        canAccessNotes: Bool
    ) async throws {
        guard let client else { throw SupabaseManagerError.notConfigured }
        let payload = AccessFlagsUpdatePayload(
            canAccessDocuments: canAccessDocuments,
            canAccessExpenses: canAccessExpenses,
            canAccessNotes: canAccessNotes
        )
        try await client
            .from("trip_collaborators")
            .update(payload)
            .eq("id", value: rowId.uuidString.lowercased())
            .execute()
    }

    /// Removes a collaborator (any role except owner) from a trip. The
    /// realtime DELETE handler in `TripRealtimeService` picks this up and
    /// fires the kick UX on the removed user's session.
    func removeCollaborator(rowId: UUID) async throws {
        guard let client else { throw SupabaseManagerError.notConfigured }
        try await client
            .from("trip_collaborators")
            .delete()
            .eq("id", value: rowId.uuidString.lowercased())
            .execute()
    }

    /// Self-leave path. Sets `CollaboratorRemovalGate.suppressNextKick`
    /// before the delete so the realtime DELETE event for our own row
    /// doesn't double-fire the "you were removed" toast — we already
    /// know we're leaving and the host will navigate us back to the
    /// trip list. On error we consume the flag immediately so a future
    /// legitimate kick (someone else removed us before we recovered)
    /// still gets the proper UX.
    func leaveTrip(rowId: UUID) async throws {
        guard let client else { throw SupabaseManagerError.notConfigured }
        CollaboratorRemovalGate.shared.suppressNextKick = true
        do {
            try await client
                .from("trip_collaborators")
                .delete()
                .eq("id", value: rowId.uuidString.lowercased())
                .execute()
        } catch {
            // The realtime event won't arrive (delete failed) so consume
            // the gate now to keep behavior symmetric with the success
            // path. Without this, a real kick that arrives later would
            // be silently swallowed.
            _ = CollaboratorRemovalGate.shared.consumeSuppressFlag()
            throw error
        }
    }

    /// Marks an outstanding invite as inactive (sets `is_active=false`)
    /// so the share link stops resolving. Phase 6 surfaces this from the
    /// active-invites section in the members sheet.
    func deactivateInvite(inviteId: UUID) async throws {
        guard let client else { throw SupabaseManagerError.notConfigured }
        let payload = InviteDeactivatePayload(isActive: false)
        try await client
            .from("trip_invites")
            .update(payload)
            .eq("id", value: inviteId.uuidString.lowercased())
            .execute()
    }

    /// Lists active (non-expired, `is_active=true`) invites for the trip
    /// so the owner can manage them in the members sheet.
    func listActiveInvites(tripId: UUID) async throws -> [TripInviteRow] {
        guard let client else { throw SupabaseManagerError.notConfigured }
        let rows: [TripInviteRow] = try await client
            .from("trip_invites")
            .select("id,trip_id,created_by,role,created_at,expires_at,is_active")
            .eq("trip_id", value: tripId.uuidString.lowercased())
            .eq("is_active", value: true)
            .order("created_at", ascending: false)
            .execute()
            .value
        // Filter expired client-side — RLS doesn't strip past-due rows
        // server-side, and we want the UI to read "no active invites"
        // when the only outstanding link is dead.
        let now = Date()
        return rows.filter { row in
            guard let expiresAt = row.expiresAt else { return true }
            return expiresAt > now
        }
    }

    // MARK: - RPC / SELECT helpers

    private func fetchOwnerSnippet(client: SupabaseClient, tripId: String) async throws -> CollaboratorProfileSnippet? {
        let payload: AnyJSON = try await client
            .rpc("get_trip_owner_profile_snippet", params: ["p_trip_id": tripId])
            .execute()
            .value
        return try Self.decodeOwnerSnippet(from: payload)
    }

    private func fetchCollaboratorSnippets(client: SupabaseClient, tripId: String) async throws -> [CollaboratorProfileSnippet] {
        let payload: AnyJSON = try await client
            .rpc("list_trip_collaborator_profile_snippets", params: ["p_trip_id": tripId])
            .execute()
            .value
        return Self.decodeCollaboratorSnippets(from: payload)
    }

    private func fetchCollaboratorRows(client: SupabaseClient, tripId: String) async throws -> [TripCollaboratorRow] {
        // Phase 1.5 backend follow-up: once the migration adds the three
        // `can_access_documents` / `can_access_expenses` / `can_access_notes`
        // columns to `trip_collaborators`, append them to this select list
        // and decode them in `TripCollaboratorRow` (defaulting to `true`
        // for safety). Today we can't ask for those columns yet — PostgREST
        // returns 400 on unknown columns, so requesting them eagerly would
        // break the entire members fetch. The model already defaults to
        // `true` for every flag, which means the iOS-side per-surface
        // gates fall through to "owner-and-editor-only" semantics — the
        // exact behaviour we want until the migration ships and the owner
        // can explicitly revoke a surface.
        let rows: [TripCollaboratorRow] = try await client
            .from("trip_collaborators")
            .select("id,trip_id,user_id,role,status,invited_email,created_at")
            .eq("trip_id", value: tripId)
            .order("created_at", ascending: true)
            .execute()
            .value
        return rows
    }

    private func fetchTripOwnerId(client: SupabaseClient, tripId: String) async throws -> UUID? {
        let rows: [TripOwnerRow] = try await client
            .from("trips")
            .select("user_id")
            .eq("id", value: tripId)
            .limit(1)
            .execute()
            .value
        return rows.first?.userId
    }

    // MARK: - JSON decoding

    /// `get_trip_owner_profile_snippet` returns either `jsonb null` or a
    /// `jsonb_build_object`. Supabase-swift surfaces the `null` as
    /// `AnyJSON.null` which we tolerate.
    private static func decodeOwnerSnippet(from payload: AnyJSON) throws -> CollaboratorProfileSnippet? {
        if case .null = payload { return nil }
        let data = try JSONEncoder().encode(payload)
        struct OwnerSnippetJSON: Decodable {
            let display_name: String?
            let avatar_url: String?
            let username: String?
        }
        let row = try JSONDecoder().decode(OwnerSnippetJSON.self, from: data)
        return CollaboratorProfileSnippet(
            userId: nil,
            displayName: row.display_name,
            username: row.username,
            avatarURLString: row.avatar_url,
            email: nil
        )
    }

    /// `list_trip_collaborator_profile_snippets` returns `'[]'::jsonb` for the
    /// empty case and a `jsonb_agg(jsonb_build_object(...))` otherwise.
    private static func decodeCollaboratorSnippets(from payload: AnyJSON) -> [CollaboratorProfileSnippet] {
        if case .null = payload { return [] }
        guard let data = try? JSONEncoder().encode(payload) else { return [] }
        struct CollaboratorSnippetJSON: Decodable {
            let user_id: UUID?
            let display_name: String?
            let username: String?
            let avatar_url: String?
            let email: String?
        }
        guard let rows = try? JSONDecoder().decode([CollaboratorSnippetJSON].self, from: data) else { return [] }
        return rows.map { row in
            CollaboratorProfileSnippet(
                userId: row.user_id,
                displayName: row.display_name,
                username: row.username,
                avatarURLString: row.avatar_url,
                email: row.email
            )
        }
    }
}

// MARK: - Wire types

private struct CollaboratorProfileSnippet: Sendable {
    let userId: UUID?
    let displayName: String?
    let username: String?
    let avatarURLString: String?
    let email: String?
}

private struct TripCollaboratorRow: Decodable, Sendable {
    let id: UUID
    let tripId: UUID
    let userId: UUID?
    let role: String
    let status: String
    let invitedEmail: String?
    let createdAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case tripId = "trip_id"
        case userId = "user_id"
        case role
        case status
        case invitedEmail = "invited_email"
        case createdAt = "created_at"
    }
}

private struct TripOwnerRow: Decodable, Sendable {
    let userId: UUID

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
    }
}

// MARK: - Phase 6 wire types

private struct RoleUpdatePayload: Encodable, Sendable {
    let role: String
}

private struct AccessFlagsUpdatePayload: Encodable, Sendable {
    let canAccessDocuments: Bool
    let canAccessExpenses: Bool
    let canAccessNotes: Bool
    enum CodingKeys: String, CodingKey {
        case canAccessDocuments = "can_access_documents"
        case canAccessExpenses = "can_access_expenses"
        case canAccessNotes = "can_access_notes"
    }
}

private struct InviteDeactivatePayload: Encodable, Sendable {
    let isActive: Bool
    enum CodingKeys: String, CodingKey {
        case isActive = "is_active"
    }
}

/// Lightweight active-invite row used by the owner-only "Active invites"
/// section of `TripMembersSheet`. Mirrors `public.trip_invites`.
struct TripInviteRow: Decodable, Identifiable, Hashable, Sendable {
    let id: UUID
    let tripId: UUID
    let createdBy: UUID?
    let role: String
    let createdAt: Date?
    let expiresAt: Date?
    let isActive: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case tripId = "trip_id"
        case createdBy = "created_by"
        case role
        case createdAt = "created_at"
        case expiresAt = "expires_at"
        case isActive = "is_active"
    }

    var roleLabel: String {
        TripRole(rawValue: role)?.displayLabel ?? "Invite"
    }
}


// =============================================================================
