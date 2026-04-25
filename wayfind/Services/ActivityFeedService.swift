//
//  ActivityFeedService.swift
//  wayfind
//
//  Phase 4 — Reads `trip_activity_log` rows for one trip and resolves the
//  per-row actor display name with a single batched `profiles` lookup.
//
//  Matches the Expo parity: most-recent first, soft cap of 120 rows so the
//  initial render stays snappy on cellular. The feed is intentionally
//  read-only — every meaningful row arrives via a server-side trigger,
//  never an iOS-side write.
//

import Foundation
import Supabase

@MainActor
final class ActivityFeedService {
    static let shared = ActivityFeedService()

    private init() {}

    private var client: SupabaseClient? {
        AuthSessionService.shared.client
    }

    /// Fetches the latest `limit` activity-log rows for the trip, then
    /// follows up with one batched `profiles` query so each row carries a
    /// resolved display name. The two requests run sequentially because
    /// the actor list is derived from the first response — the marginal
    /// latency vs running them in parallel is dominated by the first
    /// query anyway.
    func fetchTripActivityFeed(
        tripId: UUID,
        limit: Int = 120
    ) async throws -> [ActivityLogEntry] {
        guard let client else { throw SupabaseManagerError.notConfigured }
        let tripIdString = tripId.uuidString.lowercased()

        let rows: [TripActivityLogRow] = try await client
            .from("trip_activity_log")
            .select("id,trip_id,user_id,action,entity_type,entity_id,entity_name,metadata,created_at")
            .eq("trip_id", value: tripIdString)
            .order("created_at", ascending: false)
            .limit(limit)
            .execute()
            .value

        let actorIds = Array(Set(rows.map { $0.userId }))
        let actorNames = try await fetchActorDisplayNames(client: client, ids: actorIds)

        return rows.map { row in
            ActivityLogEntry(
                id: row.id,
                tripId: row.tripId,
                userId: row.userId,
                action: ActivityLogEntry.Action.from(rawValue: row.action),
                entityType: row.entityType,
                entityId: row.entityId,
                entityName: row.entityName,
                metadata: Self.flattenMetadata(row.metadata),
                createdAt: row.createdAt,
                actorDisplayName: actorNames[row.userId]
            )
        }
    }

    // MARK: - Profile name lookup

    private func fetchActorDisplayNames(
        client: SupabaseClient,
        ids: [UUID]
    ) async throws -> [UUID: String] {
        guard !ids.isEmpty else { return [:] }
        // Lowercased UUID strings — matches the convention everywhere else
        // in the iOS code so RLS filters bind identically across services.
        let lowercasedIds = ids.map { $0.uuidString.lowercased() }
        let rows: [ProfileNameRow] = try await client
            .from("profiles")
            .select("id,display_name,username")
            .in("id", values: lowercasedIds)
            .execute()
            .value
        // `Dictionary(_:uniquingKeysWith:)` — never assume PostgREST returns
        // unique rows. If duplicate ids slip through (shouldn't, but
        // defensively) we keep the first one.
        return Dictionary(
            rows.compactMap { row -> (UUID, String)? in
                let resolved = row.resolvedName
                guard !resolved.isEmpty else { return nil }
                return (row.id, resolved)
            },
            uniquingKeysWith: { existing, _ in existing }
        )
    }

    // MARK: - Metadata flattening

    /// `trip_activity_log.metadata` is a `jsonb` — we flatten it to
    /// `[String: String]` for the feed because every consumer (description
    /// rendering, future push-notification body) only needs the leaf
    /// scalars (role names, surface names, etc.). Nested objects are
    /// dropped silently to keep the surface area small.
    private static func flattenMetadata(_ payload: AnyJSON?) -> [String: String]? {
        guard let payload else { return nil }
        guard case .object(let object) = payload else { return nil }
        var result: [String: String] = [:]
        for (key, value) in object {
            switch value {
            case .string(let s): result[key] = s
            case .integer(let i): result[key] = String(i)
            case .double(let d): result[key] = String(d)
            case .bool(let b): result[key] = b ? "true" : "false"
            default: continue
            }
        }
        return result.isEmpty ? nil : result
    }
}

// MARK: - Wire types

private struct TripActivityLogRow: Decodable, Sendable {
    let id: UUID
    let tripId: UUID
    let userId: UUID
    let action: String
    let entityType: String?
    let entityId: UUID?
    let entityName: String?
    let metadata: AnyJSON?
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case tripId = "trip_id"
        case userId = "user_id"
        case action
        case entityType = "entity_type"
        case entityId = "entity_id"
        case entityName = "entity_name"
        case metadata
        case createdAt = "created_at"
    }
}

private struct ProfileNameRow: Decodable, Sendable {
    let id: UUID
    let displayName: String?
    let username: String?

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case username
    }

    var resolvedName: String {
        if let displayName = displayName?.trimmingCharacters(in: .whitespacesAndNewlines), !displayName.isEmpty {
            return displayName
        }
        if let username = username?.trimmingCharacters(in: .whitespacesAndNewlines), !username.isEmpty {
            return username.hasPrefix("@") ? String(username.dropFirst()) : username
        }
        return ""
    }
}


// =============================================================================
