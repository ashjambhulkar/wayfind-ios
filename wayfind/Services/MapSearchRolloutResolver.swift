//
//  MapSearchRolloutResolver.swift
//  wayfind
//
//  Phase G.3 — bucketing helpers for the Phase A (Apple Maps)
//  rollout.
//
//  Centralizes two responsibilities:
//
//  1. Producing a stable per-device identifier.
//     `UIDevice.identifierForVendor` is synchronous, stable for the
//     same vendor + device across launches, and survives signing in
//     and out — exactly the "cohort identity" the rollout needs.
//
//  2. Hashing that identifier into a deterministic [0,99] bucket
//     using a tiny FNV-1a 32-bit hash. We don't need cryptographic
//     strength here — we just need a uniform distribution and the
//     same device always landing in the same bucket. Swift's
//     built-in `Hasher` is randomized per process and would land
//     the same device on different sides of the bucket boundary
//     across launches; that would defeat the rollout.
//

import Foundation
import UIKit

enum MapSearchRolloutResolver {

    /// Stable per-vendor device id. Falls back to a fresh-each-
    /// process UUID if the OS cannot mint one (extremely rare —
    /// happens in some restore-from-backup intermediate states).
    /// Falling back means that one launch may land in a different
    /// bucket than the previous; the caller (FeatureFlagsService)
    /// caches the resolved value for the lifetime of the process,
    /// so within a single session the experience stays consistent.
    static var deviceId: String {
        if let id = UIDevice.current.identifierForVendor?.uuidString {
            return id
        }
        return UUID().uuidString
    }

    /// Returns a stable bucket in [0, 99] for the given identifier.
    /// Same string in always produces the same bucket out, which is
    /// the contract Phase G.3 relies on so a user doesn't flip
    /// between providers within the same rollout cohort.
    static func bucket(for stableId: String) -> Int {
        let h = fnv1a32(stableId)
        return Int(h % 100)
    }

    /// Tiny FNV-1a 32-bit hash, sufficient for uniform bucketing
    /// over short ASCII identifiers. Implemented locally so we
    /// don't introduce a CryptoKit dependency for what amounts to
    /// a non-cryptographic mod-100.
    private static func fnv1a32(_ s: String) -> UInt32 {
        var hash: UInt32 = 0x811c_9dc5
        for byte in s.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 0x0100_0193
        }
        return hash
    }
}
