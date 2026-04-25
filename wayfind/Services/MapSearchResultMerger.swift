//
//  MapSearchResultMerger.swift
//  wayfind
//
//  Phase 4 of the Map Screen Search Redesign plan.
//
//  Owns the merge + dedupe logic between Apple MapKit results and
//  rows we already own in `city_places`. DB rows always win on
//  collision — they carry richer free fields (rating, hours, photos)
//  AND already have a Google `place_id` so the post-add bridge call
//  is skipped.
//
//  Dedupe keys, in order of strength:
//    1. Same Google `place_id` (rare today, common after the bridge
//       backfills).
//    2. Haversine distance ≤ 50 m AND case-folded name token overlap
//       (handles "Eiffel Tower" vs "Eiffel Tower (south entrance)").
//

import CoreLocation
import Foundation

enum MapSearchResultMerger {

    /// Merge Apple results with city_places previews. DB rows surface
    /// first; matching Apple rows are dropped.
    /// - Parameters:
    ///   - apple: Apple MapKit results (`.apple` origin).
    ///   - db: city_places results (`.cityPlaces` origin).
    ///   - limit: Cap on the merged list (default 24).
    /// - Returns: Merged list, DB-first, deduped.
    static func merge(
        apple: [MapSearchPreview],
        db: [MapSearchPreview],
        limit: Int = 24
    ) -> [MapSearchPreview] {
        var out: [MapSearchPreview] = []
        out.reserveCapacity(min(limit, apple.count + db.count))

        // 1. DB rows go in first (they win).
        for preview in db {
            out.append(preview)
            if out.count == limit { return out }
        }

        // 2. Apple rows that don't collide with anything already in
        //    `out` get appended. Telemetry lights up for every
        //    collision so we can measure DB coverage.
        for ap in apple {
            if let _ = out.firstIndex(where: { collides(lhs: ap, rhs: $0) }) {
                PlatformUsageTelemetry.mapSearch(.dbResultDeduped, origin: .apple)
                continue
            }
            out.append(ap)
            if out.count == limit { break }
        }

        // 3. Tally how many DB rows actually surfaced. (Cheap signal
        //    for the dashboard — "are we recovering paid data on the
        //    map yet".)
        if !db.isEmpty {
            for _ in db { PlatformUsageTelemetry.mapSearch(.dbResultMerged, origin: .cityPlaces) }
        }

        return out
    }

    private static func collides(lhs: MapSearchPreview, rhs: MapSearchPreview) -> Bool {
        if let a = lhs.googlePlaceId, let b = rhs.googlePlaceId, a == b {
            return true
        }
        let dist = haversine(
            lhs.coordinate.latitude, lhs.coordinate.longitude,
            rhs.coordinate.latitude, rhs.coordinate.longitude
        )
        guard dist <= 50 else { return false }
        return nameTokensOverlap(lhs.name, rhs.name)
    }

    private static func nameTokensOverlap(_ a: String, _ b: String) -> Bool {
        let aTokens = tokenize(a)
        let bTokens = tokenize(b)
        guard !aTokens.isEmpty, !bTokens.isEmpty else { return false }
        return !aTokens.isDisjoint(with: bTokens)
    }

    private static func tokenize(_ s: String) -> Set<String> {
        Set(
            s.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count >= 3 }
        )
    }

    /// Plain spherical haversine in metres. Good enough for "is this
    /// pin within 50 m of that pin" — we don't need geodesic accuracy.
    private static func haversine(_ lat1: Double, _ lon1: Double,
                                  _ lat2: Double, _ lon2: Double) -> Double {
        let R = 6_371_000.0
        let dLat = (lat2 - lat1) * .pi / 180
        let dLon = (lon2 - lon1) * .pi / 180
        let a = sin(dLat/2) * sin(dLat/2) +
                cos(lat1 * .pi / 180) * cos(lat2 * .pi / 180) *
                sin(dLon/2) * sin(dLon/2)
        let c = 2 * atan2(sqrt(a), sqrt(1 - a))
        return R * c
    }
}

// =============================================================================
