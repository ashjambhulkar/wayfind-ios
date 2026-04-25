//
//  RealtimeRowDecoder.swift
//  wayfind
//
//  Phase 3 — Bridges supabase-swift `[String: AnyJSON]` postgres-change
//  payloads (the `record` and `oldRecord` properties on `InsertAction`,
//  `UpdateAction`, `DeleteAction`) into typed `Decodable` structs.
//
//  We deliberately keep this layer thin: it only knows how to round-trip
//  through `JSONEncoder`/`JSONDecoder`, picking the same `keyDecodingStrategy`
//  PostgREST itself uses (snake_case keys → camelCase Swift). Callers
//  (TripRealtimeService) own the per-table decode shape and the merge
//  logic against `TripDetailViewModel`.
//

import Foundation
import Realtime

enum RealtimeRowDecoder {
    /// Shared decoder. Mirrors `PostgrestClient`'s ISO8601 + microseconds
    /// parsing so timestamps coming from realtime decode identically to
    /// the values fetched via PostgREST `select`.
    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        // We do NOT enable `.convertFromSnakeCase` here — every realtime
        // row type below opts into explicit `CodingKeys` so the casing is
        // unambiguous and we don't accidentally collapse fields like
        // `userRatingsTotal` ↔ `user_ratings_total` differently from how
        // PostgREST handles them.
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            // Postgres `timestamptz` over realtime arrives as either
            // `2026-04-24T22:14:01.123456Z` (with microseconds) or
            // `2026-04-24T22:14:01Z`. ISO8601DateFormatter only parses
            // up to fractional seconds so we strip beyond milliseconds.
            return Self.parseTimestamp(raw) ?? Date()
        }
        return decoder
    }()

    private static let isoFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let isoStandard: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// Decode a single `record` payload from a realtime postgres-change
    /// callback. Returns `nil` rather than throwing on shape mismatch so
    /// one malformed event can't crash the whole channel.
    static func decode<T: Decodable>(_: T.Type, from record: [String: AnyJSON]?) -> T? {
        guard let record else { return nil }
        do {
            let data = try JSONEncoder().encode(record)
            return try decoder.decode(T.self, from: data)
        } catch {
            return nil
        }
    }

    /// Lightweight helper to pull a `UUID?` from a realtime record without
    /// going through full Decodable — used by the kick handler to compare
    /// `record.userId` against the signed-in user before paying for a full
    /// row decode.
    static func uuid(_ key: String, in record: [String: AnyJSON]?) -> UUID? {
        guard case .string(let raw) = record?[key] else { return nil }
        return UUID(uuidString: raw)
    }

    /// Lightweight helper to pull a `Bool?` (or convert from int 0/1) from
    /// a realtime record without going through full Decodable. Used by the
    /// access-revoke handler so we can compare each `can_access_*` flag
    /// across `oldRecord`/`record` without two full decodes.
    static func bool(_ key: String, in record: [String: AnyJSON]?) -> Bool? {
        guard let value = record?[key] else { return nil }
        switch value {
        case .bool(let b): return b
        case .integer(let i): return i != 0
        case .double(let d): return d != 0
        case .string(let s):
            let lower = s.lowercased()
            if lower == "true" || lower == "t" { return true }
            if lower == "false" || lower == "f" { return false }
            return nil
        default:
            return nil
        }
    }

    /// Lightweight helper to pull a `String?` from a realtime record.
    static func string(_ key: String, in record: [String: AnyJSON]?) -> String? {
        guard case .string(let raw) = record?[key] else { return nil }
        return raw
    }

    private static func parseTimestamp(_ raw: String) -> Date? {
        // Trim sub-millisecond precision: ISO8601DateFormatter rejects
        // `.withFractionalSeconds` payloads that go past `.SSS`.
        let normalized = trimSubMillisecond(raw)
        return isoFractional.date(from: normalized)
            ?? isoStandard.date(from: normalized)
            ?? isoStandard.date(from: stripTimezone(normalized))
    }

    private static func trimSubMillisecond(_ raw: String) -> String {
        guard let dotRange = raw.range(of: ".") else { return raw }
        // Find the next non-digit (Z / +HH:MM) after the dot.
        let suffixIndex = raw[dotRange.upperBound...].firstIndex(where: { !$0.isNumber }) ?? raw.endIndex
        let fractional = raw[dotRange.upperBound..<suffixIndex]
        guard fractional.count > 3 else { return raw }
        let trimmedFractional = fractional.prefix(3)
        return String(raw[..<dotRange.upperBound]) + trimmedFractional + String(raw[suffixIndex...])
    }

    private static func stripTimezone(_ raw: String) -> String {
        if let zRange = raw.range(of: "Z") {
            return String(raw[..<zRange.lowerBound]) + "Z"
        }
        return raw
    }
}


// =============================================================================
