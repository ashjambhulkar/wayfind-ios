//
//  InviteService.swift
//  wayfind
//
//  Phase 2 collaboration service. Wraps:
//
//   • createInvite(tripId:role:accessFlags:) — owner-only INSERT into
//     `trip_invites`. Generates a 32-byte URL-safe random token using
//     `SecRandomCopyBytes` (cryptographically random, not `arc4random`).
//     Carries the three Phase 1.5 access flags so they propagate to
//     `trip_collaborators` at accept time.
//
//   • fetchInvitePreview(token:) — anon-callable RPC `get_invite_preview`.
//     Returns the trip name / dates / inviter name without leaking the
//     full collaborator list. Errors come back as a `200 OK` body with
//     `{"error": "..."}` per migration 20260410120000 line 230 — we parse
//     that into `InviteError`.
//
//   • acceptInvite(token:) — authenticated RPC `accept_invite`. Same
//     `200-with-error` contract as above. On success the trip ID is
//     returned so the caller can navigate.
//
//   • acceptPendingCollaborator(tripId:) — authenticated RPC
//     `accept_pending_collaborator`. Used when the user already has a
//     `trip_collaborators` row in `pending` status (email-invited but
//     not yet accepted) and confirms from the members sheet rather than
//     a fresh deep link.
//
//   • declinePendingCollaborator(tripId:) — direct UPDATE on
//     `trip_collaborators` flipping `status` to `'declined'`.
//
//  All UUIDs are lowercased before hitting `.eq` filters because
//  PostgREST is case-sensitive on UUID equality even though Postgres
//  itself is not (Supabase realtime in particular regresses on this).
//

import Foundation
import Supabase
import Security

@MainActor
final class InviteService {
    static let shared = InviteService()

    private init() {}

    private var client: SupabaseClient? {
        AuthSessionService.shared.client
    }

    // MARK: - Token generation

    /// Cryptographically random 32-byte token, base64url-encoded so it
    /// survives in URL paths without percent-escaping. Matches the
    /// length / charset of the existing tokens issued by the older
    /// Expo client.
    static func randomInviteToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            // Vanishingly rare in practice (would require the entropy
            // pool to be unavailable). UUID fallback keeps the call site
            // non-throwing; collision risk is still 1 in 2^122.
            return UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
        }
        let data = Data(bytes)
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: - Public API

    /// Owner-only — creates a fresh invite row that the share sheet can
    /// hand off to ShareLink. Returns the persisted invite so the caller
    /// can build the URL via `InviteDeepLink.shareableURL(for:)` and
    /// optionally render expiry metadata.
    func createInvite(
        tripId: UUID,
        role: TripRole,
        canAccessDocuments: Bool = true,
        canAccessExpenses: Bool = true,
        canAccessNotes: Bool = true
    ) async throws -> TripInvite {
        guard let client else { throw SupabaseManagerError.notConfigured }
        guard let session = try? await client.auth.session else {
            throw SupabaseManagerError.notAuthenticated
        }
        let userId = session.user.id

        let token = Self.randomInviteToken()
        let tripIdLower = tripId.uuidString.lowercased()
        let createdByLower = userId.uuidString.lowercased()

        // Phase 1.5 backend follow-up: once the migration adds the three
        // `can_access_*` columns to `trip_invites`, append them to this
        // payload so they propagate to `trip_collaborators` on accept.
        // PostgREST returns 400 on unknown columns — so we don't send
        // them yet. UI today still records the chosen values in the
        // returned `TripInvite` so we can wire them in once the column
        // ships, without rebuilding `InviteComposeSheet`.
        let payload = InviteInsertPayload(
            trip_id: tripIdLower,
            created_by: createdByLower,
            token: token,
            role: role.rawValue
        )

        do {
            let row: InviteSelectRow = try await client
                .from("trip_invites")
                .insert(payload, returning: .representation)
                .select("id,trip_id,created_by,token,role,max_uses,uses,expires_at,is_active,created_at,invited_email")
                .single()
                .execute()
                .value

            return TripInvite(
                id: row.id,
                tripId: row.trip_id,
                createdBy: row.created_by,
                token: row.token,
                role: TripRole(rawValue: row.role) ?? role,
                maxUses: row.max_uses,
                uses: row.uses,
                expiresAt: row.expires_at,
                isActive: row.is_active,
                createdAt: row.created_at,
                invitedEmail: row.invited_email,
                canAccessDocuments: canAccessDocuments,
                canAccessExpenses: canAccessExpenses,
                canAccessNotes: canAccessNotes
            )
        } catch {
            throw error
        }
    }

    /// Resolves an invite token into a recipient-facing preview. Callable
    /// without a session (the migration grants anon EXECUTE).
    func fetchInvitePreview(token: String) async throws -> InvitePreview {
        guard let client else { throw SupabaseManagerError.notConfigured }
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw InviteError.invalidOrExpired }

        let payload: AnyJSON = try await client
            .rpc("get_invite_preview", params: ["invite_token": trimmed])
            .execute()
            .value

        return try Self.decodePreviewOrThrow(payload: payload)
    }

    /// Accepts an invite for the current user. Returns the trip id so the
    /// caller can navigate; throws `InviteError` for any 200-with-error
    /// payload from the RPC.
    func acceptInvite(token: String) async throws -> UUID {
        guard let client else { throw SupabaseManagerError.notConfigured }
        guard (try? await client.auth.session) != nil else {
            throw InviteError.notAuthenticated
        }
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw InviteError.invalidOrExpired }

        let payload: AnyJSON = try await client
            .rpc("accept_invite", params: ["invite_token": trimmed])
            .execute()
            .value

        return try Self.decodeAcceptOrThrow(payload: payload)
    }

    /// Flips an existing pending collaborator row to accepted. Used from
    /// the members sheet "You're invited" card and the in-app invite
    /// notification path.
    func acceptPendingCollaborator(tripId: UUID) async throws -> TripRole {
        guard let client else { throw SupabaseManagerError.notConfigured }
        guard (try? await client.auth.session) != nil else {
            throw InviteError.notAuthenticated
        }
        let payload: AnyJSON = try await client
            .rpc("accept_pending_collaborator", params: ["p_trip_id": tripId.uuidString.lowercased()])
            .execute()
            .value

        return try Self.decodeAcceptPendingOrThrow(payload: payload)
    }

    /// Declines an existing pending collaborator row by flipping `status`
    /// to `'declined'`. Owner can re-invite later. RLS already restricts
    /// updates to the row's own `user_id` so we don't need a SECURITY
    /// DEFINER RPC.
    func declinePendingCollaborator(tripId: UUID) async throws {
        guard let client else { throw SupabaseManagerError.notConfigured }
        guard let session = try? await client.auth.session else {
            throw InviteError.notAuthenticated
        }
        let userId = session.user.id

        try await client
            .from("trip_collaborators")
            .update(["status": "declined"])
            .eq("trip_id", value: tripId.uuidString.lowercased())
            .eq("user_id", value: userId.uuidString.lowercased())
            .execute()
    }

    // MARK: - Decoding

    private static func decodePreviewOrThrow(payload: AnyJSON) throws -> InvitePreview {
        let data = try JSONEncoder().encode(payload)
        if let envelope = try? JSONDecoder().decode(ServerErrorEnvelope.self, from: data),
           let raw = envelope.error {
            throw InviteError.fromServerErrorString(raw)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601WithFractionalSeconds
        let row = try decoder.decode(InvitePreviewRow.self, from: data)
        return InvitePreview(
            tripId: row.trip_id,
            role: TripRole(rawValue: row.role) ?? .viewer,
            tripName: row.trip_name,
            coverImageURLString: row.cover_image_url,
            startDate: row.start_date,
            endDate: row.end_date,
            destination: row.destination,
            inviterName: row.inviter_name
        )
    }

    private static func decodeAcceptOrThrow(payload: AnyJSON) throws -> UUID {
        let data = try JSONEncoder().encode(payload)
        if let envelope = try? JSONDecoder().decode(ServerErrorEnvelope.self, from: data),
           let raw = envelope.error {
            throw InviteError.fromServerErrorString(raw)
        }
        let success = try JSONDecoder().decode(AcceptSuccessRow.self, from: data)
        return success.trip_id
    }

    private static func decodeAcceptPendingOrThrow(payload: AnyJSON) throws -> TripRole {
        let data = try JSONEncoder().encode(payload)
        if let envelope = try? JSONDecoder().decode(ServerErrorEnvelope.self, from: data),
           let raw = envelope.error {
            throw InviteError.fromServerErrorString(raw)
        }
        let success = try JSONDecoder().decode(AcceptPendingSuccessRow.self, from: data)
        return TripRole(rawValue: success.role) ?? .viewer
    }
}

// MARK: - Wire types

private struct InviteInsertPayload: Encodable {
    let trip_id: String
    let created_by: String
    let token: String
    let role: String
}

private struct InviteSelectRow: Decodable {
    let id: UUID
    let trip_id: UUID
    let created_by: UUID
    let token: String
    let role: String
    let max_uses: Int?
    let uses: Int
    let expires_at: Date?
    let is_active: Bool
    let created_at: Date?
    let invited_email: String?
}

private struct InvitePreviewRow: Decodable {
    let trip_id: UUID
    let role: String
    let trip_name: String
    let cover_image_url: String?
    let start_date: Date?
    let end_date: Date?
    let destination: String?
    let inviter_name: String?
}

private struct AcceptSuccessRow: Decodable {
    let trip_id: UUID
    let role: String?
}

private struct AcceptPendingSuccessRow: Decodable {
    let role: String
    let trip_id: UUID?
}

private struct ServerErrorEnvelope: Decodable {
    let error: String?
}

// MARK: - JSONDecoder helpers

private extension JSONDecoder.DateDecodingStrategy {
    /// PostgREST and our RPCs sometimes return ISO8601 with fractional
    /// seconds (`2026-04-30T12:00:00.123456+00:00`). The default
    /// `.iso8601` strategy doesn't tolerate fractional seconds. Provide
    /// a strategy that handles both.
    static var iso8601WithFractionalSeconds: JSONDecoder.DateDecodingStrategy {
        .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            let withFractional = ISO8601DateFormatter()
            withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = withFractional.date(from: raw) { return date }
            let plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
            if let date = plain.date(from: raw) { return date }
            // Fall back to a date-only formatter (Postgres `date` columns).
            let dateOnly = DateFormatter()
            dateOnly.calendar = Calendar(identifier: .iso8601)
            dateOnly.locale = Locale(identifier: "en_US_POSIX")
            dateOnly.timeZone = TimeZone(identifier: "UTC")
            dateOnly.dateFormat = "yyyy-MM-dd"
            if let date = dateOnly.date(from: raw) { return date }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Could not parse date string: \(raw)"
            )
        }
    }
}


// =============================================================================
