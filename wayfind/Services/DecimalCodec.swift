//
//  DecimalCodec.swift
//  wayfind
//
//  Tiny `Codable` wrapper that lets us round-trip PostgREST `numeric` columns
//  through `Decimal` without going through `Double` (which loses precision past
//  2^53 and routinely turns "12.50" into "12.499999999999998"). PostgREST may
//  return numerics as either JSON strings (its default for arbitrary-precision
//  values) or JSON numbers — we accept both and normalise to `Decimal`.
//
//  Encode side intentionally writes the value back out as a JSON string so the
//  round-trip stays lossless. PostgREST happily coerces strings into numerics
//  on insert; the alternative (let `JSONEncoder` serialise `Decimal` as a JSON
//  number) goes through `NSNumber.doubleValue` and silently rounds.
//

import Foundation

/// Lossless `Decimal` codec for PostgREST `numeric` columns.
struct DecimalCodec: Codable, Hashable, Sendable {
    let value: Decimal

    init(_ value: Decimal) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let raw = try? container.decode(String.self) {
            guard let parsed = Decimal(string: raw, locale: Locale(identifier: "en_US_POSIX")) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Invalid decimal string: \(raw)"
                )
            }
            value = parsed
            return
        }
        if let raw = try? container.decode(Decimal.self) {
            value = raw
            return
        }
        if let raw = try? container.decode(Double.self) {
            value = Decimal(raw)
            return
        }
        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "Could not decode numeric"
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        // `Decimal.description` emits the canonical lossless representation
        // (e.g. "12.50" stays "12.50", "0.000001" stays "0.000001"). PostgREST
        // happily parses this as a numeric column on insert/update.
        try container.encode(value.description)
    }
}

extension Decimal {
    /// Convenience for the (very common) "wrap or pass NULL" insert pattern.
    var supabaseEncoded: DecimalCodec { DecimalCodec(self) }
}


// =============================================================================
