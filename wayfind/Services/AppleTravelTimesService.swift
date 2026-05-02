//
//  AppleTravelTimesService.swift
//  wayfind
//
//  Phase J.3 of the Places cost-reduction & owned-data plan.
//
//  Computes per-mode travel times + polylines using `MKDirections` and
//  posts the results to the `upload-travel-leg` Edge Function (Phase
//  J.2). The intent is to back-fill `city_travel_times` with Apple-
//  sourced rows so the AI itinerary planner (Phase J.5) and the trip
//  map (Phase J.4) can stop calling Google Routes for legs the user
//  has already explored.
//
//  Behavioural envelope (intentionally cautious — burns user CPU + a
//  few mAh per leg):
//
//    • Throttled: at most 1 batch per minute per trip. Bigger volume
//      gets queued; the in-memory cache + the Edge Function's
//      `apple_refreshed_at` skip rule keep us idempotent.
//    • Batched: ≤ 50 legs per HTTP request to match the function's
//      MAX_LEGS_PER_REQUEST guard.
//    • In-memory cache of (cityProfileId, from, to) → CachedLeg so a
//      second `enqueue` with the same legs returns immediately.
//    • Concurrency: walking + driving + transit fire in parallel with
//      MapKit (3 in flight), but legs are processed serially so we
//      don't trigger MapKit throttling for whole trips.
//    • Cycling: deliberately omitted — `MKDirections` doesn't expose a
//      cycling transport type. Phase J.1 schema documents this; the
//      iOS layer falls back to a walking estimate.
//
//  This service is NOT a public API. Call sites:
//    • TripDetailViewModel (post-AI generation warm-up, Phase J.6)
//    • TripMapView (opportunistic enrichment when a polyline is
//      missing from `city_travel_times`)
//

import Auth
import Foundation
import MapKit
import os.signpost
import Supabase

@MainActor
@Observable
final class AppleTravelTimesService {

    // MARK: – Public types

    /// One leg the caller wants computed.
    struct LegRequest: Hashable, Sendable {
        let fromPlaceId: String
        let fromCoordinate: CLLocationCoordinate2D
        let toPlaceId: String
        let toCoordinate: CLLocationCoordinate2D

        // CLLocationCoordinate2D isn't Hashable on its own, so we hash
        // by place_id pair which is what the cache really keys on.
        static func == (lhs: LegRequest, rhs: LegRequest) -> Bool {
            lhs.fromPlaceId == rhs.fromPlaceId && lhs.toPlaceId == rhs.toPlaceId
        }
        func hash(into h: inout Hasher) {
            h.combine(fromPlaceId)
            h.combine(toPlaceId)
        }
    }

    enum Mode: String, CaseIterable, Sendable {
        case walking, driving, transit

        var transportType: MKDirectionsTransportType {
            switch self {
            case .walking: return .walking
            case .driving: return .automobile
            case .transit: return .transit
            }
        }
    }

    enum ServiceError: LocalizedError {
        case noSession
        case rateLimited(retryAfterMs: Int)
        case server(String)

        var errorDescription: String? {
            switch self {
            case .noSession: return "Not signed in"
            case .rateLimited: return "Travel-time cache rate limited"
            case .server(let m): return m
            }
        }
    }

    static let shared = AppleTravelTimesService()

    // MARK: – Public API

    /// Schedule a batch of legs for the given trip. Returns
    /// immediately; work runs in the background and the throttle
    /// window applies per `tripId`.
    ///
    /// `cityProfileId` is the destination scope — `city_travel_times`
    /// is keyed by it server-side so we never write a Tokyo leg into
    /// a Paris row.
    func enqueue(
        tripId: UUID,
        cityProfileId: UUID,
        legs: [LegRequest]
    ) {
        let pending = filterUncached(cityProfileId: cityProfileId, legs: legs)
        if pending.isEmpty { return }
        if !shouldFire(tripId: tripId) { return }

        Task.detached(priority: .utility) { [weak self] in
            await self?.run(
                tripId: tripId,
                cityProfileId: cityProfileId,
                legs: pending
            )
        }
    }

    /// Direct, in-memory lookup. Returns `nil` when we have no cached
    /// Apple result for the requested mode — caller should fall back
    /// to whatever it has (haversine, Google, server cache row).
    func cachedMinutes(
        cityProfileId: UUID,
        fromPlaceId: String,
        toPlaceId: String,
        mode: Mode
    ) -> Int? {
        let key = CacheKey(
            cityProfileId: cityProfileId,
            fromPlaceId: fromPlaceId,
            toPlaceId: toPlaceId
        )
        return cache[key]?.minutes(for: mode)
    }

    /// City-scoped route distance in meters when both Google place ids are known.
    func cachedDistanceMeters(
        cityProfileId: UUID,
        fromPlaceId: String,
        toPlaceId: String
    ) -> Int? {
        let key = CacheKey(
            cityProfileId: cityProfileId,
            fromPlaceId: fromPlaceId,
            toPlaceId: toPlaceId
        )
        return cache[key]?.distanceMeters
    }

    /// Encoded polyline for the cached leg, if present. Used by
    /// TripMapView (Phase J.4) when the server-side row hasn't synced
    /// the polyline yet.
    func cachedPolyline(
        cityProfileId: UUID,
        fromPlaceId: String,
        toPlaceId: String,
        mode: Mode
    ) -> String? {
        let key = CacheKey(
            cityProfileId: cityProfileId,
            fromPlaceId: fromPlaceId,
            toPlaceId: toPlaceId
        )
        return cache[key]?.polyline(for: mode)
    }

    /// Unscoped polyline lookup for callers that don't carry the
    /// `cityProfileId` (e.g. TripMapView). Falls back across all
    /// cached scopes; safe because polylines are uniquely identified
    /// by their place-id pair regardless of which city profile owns
    /// the row server-side.
    func cachedPolylineForAnyScope(
        fromPlaceId: String,
        toPlaceId: String,
        mode: Mode
    ) -> String? {
        for (key, leg) in cache where
            key.fromPlaceId == fromPlaceId && key.toPlaceId == toPlaceId
        {
            if let p = leg.polyline(for: mode) { return p }
        }
        return nil
    }

    /// Returns which of the three modes have a cached polyline for the
    /// requested place pair, in any scope. Used by the map's "Auto"
    /// transport-mode resolver so it can pick the best concrete mode
    /// per leg without having to introspect cache internals.
    func cachedAvailableModes(
        fromPlaceId: String,
        toPlaceId: String
    ) -> Set<Mode> {
        var out: Set<Mode> = []
        for (key, leg) in cache where
            key.fromPlaceId == fromPlaceId && key.toPlaceId == toPlaceId
        {
            for mode in Mode.allCases {
                if leg.polyline(for: mode) != nil {
                    out.insert(mode)
                }
            }
        }
        return out
    }

    /// Cached travel-distance for a leg in any scope. Used by Auto
    /// mode bucketing when no concrete distance was passed in.
    func cachedDistanceMetersForAnyScope(
        fromPlaceId: String,
        toPlaceId: String
    ) -> Int? {
        for (key, leg) in cache where
            key.fromPlaceId == fromPlaceId && key.toPlaceId == toPlaceId
        {
            if let d = leg.distanceMeters { return d }
        }
        return nil
    }

    /// Route distance for a specific transport mode when MapKit returned one.
    func cachedRouteDistanceMeters(
        cityProfileId: UUID,
        fromPlaceId: String,
        toPlaceId: String,
        mode: Mode
    ) -> Int? {
        let key = CacheKey(
            cityProfileId: cityProfileId,
            fromPlaceId: fromPlaceId,
            toPlaceId: toPlaceId
        )
        return cache[key]?.routeDistanceMeters(for: mode)
    }

    func cachedRouteDistanceMetersForAnyScope(
        fromPlaceId: String,
        toPlaceId: String,
        mode: Mode
    ) -> Int? {
        for (key, leg) in cache where
            key.fromPlaceId == fromPlaceId && key.toPlaceId == toPlaceId
        {
            if let d = leg.routeDistanceMeters(for: mode) { return d }
        }
        return nil
    }

    func cachedCoordRouteDistance(
        from: CLLocationCoordinate2D,
        to: CLLocationCoordinate2D,
        mode: Mode
    ) -> Int? {
        let key = CoordCacheKey(from: from, to: to)
        return coordCache[key]?.routeDistanceMeters(for: mode)
    }

    /// Unscoped minutes lookup. Mirrors `cachedPolylineForAnyScope`
    /// for the time-readout the map's segment badges surface.
    func cachedMinutesForAnyScope(
        fromPlaceId: String,
        toPlaceId: String,
        mode: Mode
    ) -> Int? {
        for (key, leg) in cache where
            key.fromPlaceId == fromPlaceId && key.toPlaceId == toPlaceId
        {
            if let m = leg.minutes(for: mode) { return m }
        }
        return nil
    }

    // MARK: – Server seed (Phase J.4 read path)

    /// One row from `city_travel_times` keyed for direct cache insert.
    /// Public so the read path can use a single typed query in the
    /// caller without us re-encoding the columns there.
    private struct ServerLegRow: Decodable, Sendable {
        let from_place_id: String
        let to_place_id: String
        let distance_meters: Int?
        let walking_minutes: Int?
        let driving_minutes: Int?
        let transit_minutes: Int?
        let walking_polyline: String?
        let driving_polyline: String?
        let transit_polyline: String?
    }

    /// Hydrate the in-memory cache from `city_travel_times` for the
    /// trip's stop pairs. Free — the table is public-read RLS, so
    /// this is one PostgREST round-trip with no auth gating beyond
    /// the user already being signed in.
    ///
    /// The map screen calls this on load so polylines render even
    /// when the trip wasn't generated through the AI planner (which
    /// is the only path that populated the cache historically).
    ///
    /// - Parameters:
    ///   - cityProfileId: Trip's city scope.
    ///   - placeIdPairs: Array of (from_place_id, to_place_id) tuples.
    ///     Only the *forward* direction is queried — Apple's `MKDirections`
    ///     produces deterministic results for direction so callers should
    ///     pass both A→B and B→A if both are needed.
    ///   - client: Supabase client. Pass through to avoid re-resolving.
    func seedFromServer(
        cityProfileId: UUID,
        placeIdPairs: [(from: String, to: String)],
        using client: SupabaseClient
    ) async {
        guard !placeIdPairs.isEmpty else { return }

        // Build an OR filter of (from_place_id.eq.X,to_place_id.eq.Y)
        // pairs. PostgREST's `or(...)` clause chains AND inside each
        // element so we use `and(...)` per pair. Cap to a sensible
        // batch — most trips have ≤ 60 legs.
        let work = Array(placeIdPairs.prefix(120))
        let pairFilters = work.map { pair in
            "and(from_place_id.eq.\(pair.from),to_place_id.eq.\(pair.to))"
        }
        let orFilter = pairFilters.joined(separator: ",")

        do {
            let rows: [ServerLegRow] = try await client
                .from("city_travel_times")
                .select("""
                from_place_id,to_place_id,distance_meters,\
                walking_minutes,driving_minutes,transit_minutes,\
                walking_polyline,driving_polyline,transit_polyline
                """)
                .eq("city_profile_id", value: cityProfileId.uuidString.lowercased())
                .or(orFilter)
                .execute()
                .value

            for row in rows {
                let key = CacheKey(
                    cityProfileId: cityProfileId,
                    fromPlaceId: row.from_place_id,
                    toPlaceId: row.to_place_id
                )
                var leg = cache[key] ?? CachedLeg(refreshedAt: Date())
                if let d = row.distance_meters { leg.distanceMeters = d }
                if let m = row.walking_minutes { leg.walkingMinutes = m }
                if let m = row.driving_minutes { leg.drivingMinutes = m }
                if let m = row.transit_minutes { leg.transitMinutes = m }
                if let p = row.walking_polyline, !p.isEmpty { leg.walkingPolyline = p }
                if let p = row.driving_polyline, !p.isEmpty { leg.drivingPolyline = p }
                if let p = row.transit_polyline, !p.isEmpty { leg.transitPolyline = p }
                // Use server-row arrival as the cache freshness anchor —
                // we don't store the row's `computed_at` in CachedLeg so
                // `now` is the safest stamp (within the throttle window).
                leg.refreshedAt = Date()
                cache[key] = leg
            }
        } catch {
            ObservabilityService.breadcrumb(
                "server_seed_failed",
                category: "travel_times",
                level: .warning,
                context: ["city_profile_id": cityProfileId]
            )
            #if DEBUG
            print("[AppleTravelTimes] server seed failed: \(error)")
            #endif
        }
    }

    // MARK: – Coordinate-keyed cache (legacy / manual trips)
    //
    // Trips created before the Google place_id pipeline (or with
    // manually-added places) don't carry a `googlePlaceId` on either
    // end of a leg. `city_travel_times` is keyed by Google place_ids,
    // so the read-and-warm path above can't help them.
    //
    // This parallel cache is keyed by rounded (lat, lng) pairs and
    // populated on-the-fly via `MKDirections`. We deliberately do NOT
    // upload these to `city_travel_times` because the row would have
    // no usable foreign key — the server-side AI planner expects
    // place_id-anchored rows, and writing a synthetic key would
    // pollute the table.

    private struct CoordCacheKey: Hashable {
        let fromLat: Int  // ×10_000 — ~11 m precision
        let fromLng: Int
        let toLat: Int
        let toLng: Int

        init(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) {
            fromLat = Int((from.latitude * 10_000).rounded())
            fromLng = Int((from.longitude * 10_000).rounded())
            toLat = Int((to.latitude * 10_000).rounded())
            toLng = Int((to.longitude * 10_000).rounded())
        }
    }

    private var coordCache: [CoordCacheKey: CachedLeg] = [:]
    private var coordInFlight: Set<CoordCacheKey> = []

    /// Polyline for a coordinate pair, if one was previously computed
    /// via `computeAndCacheCoordLeg`. Returns nil when no compute has
    /// run for this pair yet.
    func cachedCoordPolyline(
        from: CLLocationCoordinate2D,
        to: CLLocationCoordinate2D,
        mode: Mode
    ) -> String? {
        let key = CoordCacheKey(from: from, to: to)
        return coordCache[key]?.polyline(for: mode)
    }

    func cachedCoordMinutes(
        from: CLLocationCoordinate2D,
        to: CLLocationCoordinate2D,
        mode: Mode
    ) -> Int? {
        let key = CoordCacheKey(from: from, to: to)
        return coordCache[key]?.minutes(for: mode)
    }

    func cachedCoordAvailableModes(
        from: CLLocationCoordinate2D,
        to: CLLocationCoordinate2D
    ) -> Set<Mode> {
        let key = CoordCacheKey(from: from, to: to)
        guard let leg = coordCache[key] else { return [] }
        var out: Set<Mode> = []
        for mode in Mode.allCases where leg.polyline(for: mode) != nil {
            out.insert(mode)
        }
        return out
    }

    func cachedCoordDistance(
        from: CLLocationCoordinate2D,
        to: CLLocationCoordinate2D
    ) -> Int? {
        let key = CoordCacheKey(from: from, to: to)
        return coordCache[key]?.distanceMeters
    }

    /// Compute polylines for walking + driving + transit via
    /// `MKDirections` and cache locally. Does NOT upload to
    /// `city_travel_times` — see the section comment above for why.
    /// Idempotent: returns immediately when the pair is already
    /// cached or in flight.
    ///
    /// Returns whether new data landed in the cache so the caller can
    /// trigger a SwiftUI refresh on success and skip the no-op.
    @discardableResult
    func computeAndCacheCoordLeg(
        from: CLLocationCoordinate2D,
        to: CLLocationCoordinate2D
    ) async -> Bool {
        let key = CoordCacheKey(from: from, to: to)
        if coordCache[key] != nil { return false }
        if coordInFlight.contains(key) { return false }
        coordInFlight.insert(key)
        defer { coordInFlight.remove(key) }

        // Reuse the existing per-mode parallel compute via a
        // synthetic LegRequest — only the coordinates matter here;
        // the place_ids are placeholders and we never upload.
        let synthetic = LegRequest(
            fromPlaceId: "coord:\(key.fromLat),\(key.fromLng)",
            fromCoordinate: from,
            toPlaceId: "coord:\(key.toLat),\(key.toLng)",
            toCoordinate: to
        )
        let computed = await compute(leg: synthetic)

        var cached = CachedLeg(refreshedAt: Date())
        cached.distanceMeters = computed.distanceMeters
        if let m = computed.modes[.walking] {
            cached.walkingMinutes = m.minutes
            cached.walkingPolyline = m.polyline
            cached.walkingRouteDistanceMeters = m.distanceMeters
        }
        if let m = computed.modes[.driving] {
            cached.drivingMinutes = m.minutes
            cached.drivingPolyline = m.polyline
            cached.drivingRouteDistanceMeters = m.distanceMeters
        }
        if let m = computed.modes[.transit] {
            cached.transitMinutes = m.minutes
            cached.transitPolyline = m.polyline
            cached.transitRouteDistanceMeters = m.distanceMeters
        }
        coordCache[key] = cached
        // Treat "no modes succeeded" as failure so the caller doesn't
        // think a refresh is warranted.
        return cached.walkingPolyline != nil
            || cached.drivingPolyline != nil
            || cached.transitPolyline != nil
    }

    /// Like `enqueue` but pre-filters the legs to those that don't
    /// already have a cached polyline for at least one mode. Matches
    /// the read-path behaviour: if the server seed already gave us a
    /// row, we don't burn user CPU re-computing it.
    func enqueueIfMissing(
        tripId: UUID,
        cityProfileId: UUID,
        legs: [LegRequest]
    ) {
        let pending = legs.filter { leg in
            cachedPolylineForAnyScope(
                fromPlaceId: leg.fromPlaceId,
                toPlaceId: leg.toPlaceId,
                mode: .walking
            ) == nil
            && cachedPolylineForAnyScope(
                fromPlaceId: leg.fromPlaceId,
                toPlaceId: leg.toPlaceId,
                mode: .driving
            ) == nil
            && cachedPolylineForAnyScope(
                fromPlaceId: leg.fromPlaceId,
                toPlaceId: leg.toPlaceId,
                mode: .transit
            ) == nil
        }
        guard !pending.isEmpty else { return }
        enqueue(tripId: tripId, cityProfileId: cityProfileId, legs: pending)
    }

    // MARK: – Internal: pipeline

    private struct CacheKey: Hashable {
        let cityProfileId: UUID
        let fromPlaceId: String
        let toPlaceId: String
    }

    private struct CachedLeg {
        var distanceMeters: Int?
        var walkingMinutes: Int?
        var drivingMinutes: Int?
        var transitMinutes: Int?
        var walkingRouteDistanceMeters: Int?
        var drivingRouteDistanceMeters: Int?
        var transitRouteDistanceMeters: Int?
        var walkingPolyline: String?
        var drivingPolyline: String?
        var transitPolyline: String?
        var refreshedAt: Date

        func minutes(for mode: Mode) -> Int? {
            switch mode {
            case .walking: return walkingMinutes
            case .driving: return drivingMinutes
            case .transit: return transitMinutes
            }
        }

        /// Per-mode length from MapKit when available; otherwise the leg-level `distanceMeters`
        /// (server aggregate or first successful route in `compute`).
        func routeDistanceMeters(for mode: Mode) -> Int? {
            let perMode: Int?
            switch mode {
            case .walking: perMode = walkingRouteDistanceMeters
            case .driving: perMode = drivingRouteDistanceMeters
            case .transit: perMode = transitRouteDistanceMeters
            }
            return perMode ?? distanceMeters
        }

        func polyline(for mode: Mode) -> String? {
            switch mode {
            case .walking: return walkingPolyline
            case .driving: return drivingPolyline
            case .transit: return transitPolyline
            }
        }
    }

    private var cache: [CacheKey: CachedLeg] = [:]
    private var lastFiredAt: [UUID: Date] = [:]
    private let throttleInterval: TimeInterval = 60
    private let maxLegsPerBatch = 50
    private static let signpostLog = OSLog(
        subsystem: "app.wayfind.travel",
        category: "AppleTravelTimes"
    )

    private func filterUncached(
        cityProfileId: UUID,
        legs: [LegRequest]
    ) -> [LegRequest] {
        let now = Date()
        let cutoff = now.addingTimeInterval(-30 * 24 * 60 * 60)
        return legs.filter { leg in
            let key = CacheKey(
                cityProfileId: cityProfileId,
                fromPlaceId: leg.fromPlaceId,
                toPlaceId: leg.toPlaceId
            )
            guard let cached = cache[key] else { return true }
            return cached.refreshedAt < cutoff
        }
    }

    private func shouldFire(tripId: UUID) -> Bool {
        let now = Date()
        if let last = lastFiredAt[tripId],
           now.timeIntervalSince(last) < throttleInterval {
            return false
        }
        lastFiredAt[tripId] = now
        return true
    }

    private func run(
        tripId: UUID,
        cityProfileId: UUID,
        legs: [LegRequest]
    ) async {
        let signpostId = OSSignpostID(log: Self.signpostLog)
        os_signpost(.begin, log: Self.signpostLog,
                    name: "AppleTravelTimes.run",
                    signpostID: signpostId,
                    "%{public}d legs", legs.count)
        defer {
            os_signpost(.end, log: Self.signpostLog,
                        name: "AppleTravelTimes.run",
                        signpostID: signpostId)
        }

        // Cap each fire to maxLegsPerBatch — anything beyond that
        // waits for the next throttle window.
        let work = Array(legs.prefix(maxLegsPerBatch))
        var payload: [LegPayload] = []
        for leg in work {
            if Task.isCancelled { break }
            let computed = await compute(leg: leg)
            store(cityProfileId: cityProfileId, leg: leg, computed: computed)
            payload.append(LegPayload.from(
                request: leg,
                computed: computed
            ))
        }
        guard !payload.isEmpty else { return }

        do {
            try await upload(
                cityProfileId: cityProfileId,
                legs: payload
            )
        } catch ServiceError.rateLimited(let retry) {
            ObservabilityService.breadcrumb(
                "upload_rate_limited",
                category: "travel_times",
                level: .warning,
                context: [
                    "retry_ms": retry,
                    "leg_count": payload.count,
                ]
            )
            #if DEBUG
            print("AppleTravelTimes upload rate-limited; retry in \(retry)ms")
            #endif
        } catch {
            ObservabilityService.capture(
                error: error,
                domain: "travel_times",
                reason: "upload_failed",
                context: [
                    "city_profile_id": cityProfileId,
                    "leg_count": payload.count,
                ]
            )
            #if DEBUG
            print("AppleTravelTimes upload failed: \(error)")
            #endif
        }
    }

    // MARK: – MapKit

    private struct ComputedLeg {
        var distanceMeters: Int?
        var modes: [Mode: ComputedMode] = [:]
    }
    private struct ComputedMode {
        var minutes: Int
        var polyline: String?
        var distanceMeters: Int
    }

    private func compute(leg: LegRequest) async -> ComputedLeg {
        // Three modes in parallel; MapKit's MKDirections has its own
        // throttle, but 3 simultaneous requests stays well inside it.
        async let walking = directions(leg: leg, mode: .walking)
        async let driving = directions(leg: leg, mode: .driving)
        async let transit = directions(leg: leg, mode: .transit)

        let (w, d, t) = await (walking, driving, transit)

        var out = ComputedLeg()
        // Distance comes from whichever route succeeded first; walking
        // is the most accurate for door-to-door figures so we prefer it.
        if let w {
            out.modes[.walking] = ComputedMode(minutes: w.minutes, polyline: w.polyline, distanceMeters: w.distanceMeters)
            out.distanceMeters = w.distanceMeters
        }
        if let d {
            out.modes[.driving] = ComputedMode(minutes: d.minutes, polyline: d.polyline, distanceMeters: d.distanceMeters)
            out.distanceMeters = out.distanceMeters ?? d.distanceMeters
        }
        if let t {
            out.modes[.transit] = ComputedMode(minutes: t.minutes, polyline: t.polyline, distanceMeters: t.distanceMeters)
            out.distanceMeters = out.distanceMeters ?? t.distanceMeters
        }
        return out
    }

    private struct DirectionsResult {
        let minutes: Int
        let polyline: String?
        let distanceMeters: Int
    }

    private func directions(
        leg: LegRequest,
        mode: Mode
    ) async -> DirectionsResult? {
        let signpost = PlatformUsageTelemetry.begin(.mkDirections)
        var outcome: PlatformUsageTelemetry.Status = .error
        defer { PlatformUsageTelemetry.end(.mkDirections, id: signpost, status: outcome) }

        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: leg.fromCoordinate))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: leg.toCoordinate))
        request.transportType = mode.transportType
        request.requestsAlternateRoutes = false

        do {
            let response = try await MKDirections(request: request).calculate()
            guard let route = response.routes.first else {
                outcome = .empty
                return nil
            }
            outcome = .ok
            return DirectionsResult(
                minutes: max(1, Int(route.expectedTravelTime / 60)),
                polyline: PolylineEncoder.encode(route.polyline),
                distanceMeters: Int(route.distance)
            )
        } catch {
            return nil
        }
    }

    private func store(
        cityProfileId: UUID,
        leg: LegRequest,
        computed: ComputedLeg
    ) {
        let key = CacheKey(
            cityProfileId: cityProfileId,
            fromPlaceId: leg.fromPlaceId,
            toPlaceId: leg.toPlaceId
        )
        var cached = cache[key] ?? CachedLeg(refreshedAt: Date())
        cached.distanceMeters = computed.distanceMeters ?? cached.distanceMeters
        if let m = computed.modes[.walking] {
            cached.walkingMinutes = m.minutes
            cached.walkingPolyline = m.polyline
            cached.walkingRouteDistanceMeters = m.distanceMeters
        }
        if let m = computed.modes[.driving] {
            cached.drivingMinutes = m.minutes
            cached.drivingPolyline = m.polyline
            cached.drivingRouteDistanceMeters = m.distanceMeters
        }
        if let m = computed.modes[.transit] {
            cached.transitMinutes = m.minutes
            cached.transitPolyline = m.polyline
            cached.transitRouteDistanceMeters = m.distanceMeters
        }
        cached.refreshedAt = Date()
        cache[key] = cached
    }

    // MARK: – HTTP

    private struct LegPayload: Encodable {
        let from_place_id: String
        let to_place_id: String
        let distance_meters: Int?
        let modes: [String: ModePayload]

        struct ModePayload: Encodable {
            let minutes: Int?
            let polyline: String?
        }

        static func from(
            request: LegRequest,
            computed: ComputedLeg
        ) -> LegPayload {
            var modes: [String: ModePayload] = [:]
            for mode in Mode.allCases {
                guard let m = computed.modes[mode] else { continue }
                modes[mode.rawValue] = ModePayload(
                    minutes: m.minutes,
                    polyline: m.polyline
                )
            }
            return LegPayload(
                from_place_id: request.fromPlaceId,
                to_place_id: request.toPlaceId,
                distance_meters: computed.distanceMeters,
                modes: modes
            )
        }
    }

    private struct UploadBody: Encodable {
        let city_profile_id: String
        let legs: [LegPayload]
    }

    private struct UploadResponse: Decodable {
        let ok: Bool?
        let written: Int?
        let skipped: Int?
        let error: String?
        let retry_after_ms: Int?
    }

    private func upload(
        cityProfileId: UUID,
        legs: [LegPayload]
    ) async throws {
        guard let token = await bearerToken() else {
            throw ServiceError.noSession
        }
        let url = URL(string: "\(AppConfig.supabaseURL)/functions/v1/upload-travel-leg")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(AppConfig.supabaseAnonKey, forHTTPHeaderField: "apikey")
        req.timeoutInterval = 12

        let body = UploadBody(
            city_profile_id: cityProfileId.uuidString.lowercased(),
            legs: legs
        )
        req.httpBody = try JSONEncoder().encode(body)

        let signpost = PlatformUsageTelemetry.begin(.uploadTravelLegEdge)
        var outcome: PlatformUsageTelemetry.Status = .error
        defer { PlatformUsageTelemetry.end(.uploadTravelLegEdge, id: signpost, status: outcome) }

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw ServiceError.server("invalid response")
        }
        switch http.statusCode {
        case 200:
            outcome = .ok
            return
        case 401, 403:
            throw ServiceError.noSession
        case 429:
            outcome = .rateLimited
            let parsed = try? JSONDecoder().decode(UploadResponse.self, from: data)
            throw ServiceError.rateLimited(retryAfterMs: parsed?.retry_after_ms ?? 60_000)
        default:
            let parsed = try? JSONDecoder().decode(UploadResponse.self, from: data)
            throw ServiceError.server(parsed?.error ?? "upload failed (\(http.statusCode))")
        }
    }

    private func bearerToken() async -> String? {
        guard let client = AuthSessionService.shared.client else { return nil }
        return try? await client.auth.session.accessToken
    }
}

// MARK: – Polyline encoder (Google polyline algorithm, precision 1e-5)
//
// `MKPolyline` only exposes coordinates — there's no built-in encoder.
// Round-tripping to Google's algorithm makes the bytes interchangeable
// with everything we already cache server-side under the same column,
// and lets the existing decoder in `TripMapView` (used for legacy
// Google rows) work unchanged.

enum PolylineEncoder {
    /// Inverse of `encode(coordinates:)`. Tolerant: returns `[]` for
    /// truncated / corrupted strings instead of throwing, so a bad
    /// cache row never crashes the map.
    static func decode(_ encoded: String) -> [CLLocationCoordinate2D] {
        var lat: Int32 = 0
        var lng: Int32 = 0
        var index = encoded.startIndex
        var coords: [CLLocationCoordinate2D] = []
        while index < encoded.endIndex {
            guard let dLat = decodeChunk(encoded, index: &index) else { return coords }
            guard let dLng = decodeChunk(encoded, index: &index) else { return coords }
            lat &+= dLat
            lng &+= dLng
            coords.append(CLLocationCoordinate2D(
                latitude: Double(lat) / 1e5,
                longitude: Double(lng) / 1e5
            ))
        }
        return coords
    }

    private static func decodeChunk(
        _ encoded: String,
        index: inout String.Index
    ) -> Int32? {
        var result: UInt32 = 0
        var shift: UInt32 = 0
        while index < encoded.endIndex {
            let scalar = encoded.unicodeScalars[index]
            index = encoded.index(after: index)
            let byte = UInt32(scalar.value) - 63
            result |= (byte & 0x1f) << shift
            shift += 5
            if byte < 0x20 { break }
            if shift > 30 { return nil }
        }
        let signed = (result & 1) != 0 ? ~Int32(bitPattern: result >> 1) : Int32(bitPattern: result >> 1)
        return signed
    }

    static func encode(_ polyline: MKPolyline) -> String {
        let count = polyline.pointCount
        guard count > 0 else { return "" }
        var coords = [CLLocationCoordinate2D](
            repeating: CLLocationCoordinate2D(),
            count: count
        )
        polyline.getCoordinates(&coords, range: NSRange(location: 0, length: count))
        return encode(coordinates: coords)
    }

    static func encode(coordinates: [CLLocationCoordinate2D]) -> String {
        var prevLat: Int32 = 0
        var prevLng: Int32 = 0
        var out = ""
        for c in coordinates {
            let lat = Int32((c.latitude * 1e5).rounded())
            let lng = Int32((c.longitude * 1e5).rounded())
            out += encodeChunk(lat &- prevLat)
            out += encodeChunk(lng &- prevLng)
            prevLat = lat
            prevLng = lng
        }
        return out
    }

    private static func encodeChunk(_ value: Int32) -> String {
        var v = UInt32(bitPattern: value &<< 1)
        if value < 0 { v = ~v }
        var out = ""
        while v >= 0x20 {
            let chunk = Int(((v & 0x1f) | 0x20) + 63)
            out.append(Character(UnicodeScalar(chunk)!))
            v >>= 5
        }
        out.append(Character(UnicodeScalar(Int(v) + 63)!))
        return out
    }
}
