//
//  FeatureFlagsService.swift
//  wayfind
//
//  Phase G.2 of the places-cost-and-owned-data plan.
//
//  Single source of truth for runtime feature flags coming from
//  `public.feature_flags`. Caches the full flag set in memory for
//  ~1h so a flag flip propagates fleet-wide within an hour without
//  hot-spotting Postgres for every map-search keystroke.
//
//  Design rules
//  ------------
//  • Pull-only — we never push from the device. The dashboard /
//    admin tooling owns writes.
//  • Defaults are CODE-SIDE — every getter accepts a default so the
//    app remains functional even with an offline first launch.
//  • Stale-while-revalidate — on cache miss we return the default
//    *immediately* and kick off a background refresh. Latency-
//    sensitive callers (map search, autocomplete) never block on
//    Supabase.
//  • Synchronous public API for the value getters; the refresh runs
//    on its own MainActor task. Views can read flag values during
//    body() without breaking their identity.
//

import Foundation
import Observation
import Supabase

@MainActor
@Observable
final class FeatureFlagsService {

    static let shared = FeatureFlagsService()

    /// Last successful refresh timestamp. nil before the first
    /// successful pull.
    private(set) var lastRefreshedAt: Date?

    /// Refresh window. 60min matches the documented client cache so
    /// flag dashboards quote the same SLA the device honors.
    private let refreshInterval: TimeInterval = 60 * 60

    /// In-memory snapshot of the table. Strings are stored decoded
    /// (no JSON quoting) so callers don't have to know the wire
    /// format. Reuses the type-erased `JSONValue` already used for
    /// flexible JSONB columns elsewhere in the app.
    private var values: [String: SupabaseManager.JSONValue] = [:]

    /// Single in-flight refresh task so concurrent first-call hits
    /// from different views don't fan out into N parallel SELECTs.
    /// Marked `@ObservationIgnored` so a SwiftUI view body that
    /// reads a flag value (and therefore lazily kicks `kickRefresh`)
    /// doesn't trip the "modifying state during view update" warning
    /// — `inFlight` is private machinery, not an observable property.
    @ObservationIgnored private var inFlight: Task<Void, Never>?

    // MARK: - Public flag readers

    func bool(_ flag: String, default fallback: Bool) -> Bool {
        kickRefreshIfStale()
        if case .bool(let b) = values[flag] { return b }
        if case .number(let n) = values[flag] { return n != 0 }
        return fallback
    }

    func int(_ flag: String, default fallback: Int) -> Int {
        kickRefreshIfStale()
        if case .number(let n) = values[flag] { return Int(n) }
        if case .string(let s) = values[flag], let n = Int(s) { return n }
        return fallback
    }

    func string(_ flag: String, default fallback: String) -> String {
        kickRefreshIfStale()
        if case .string(let s) = values[flag] { return s }
        return fallback
    }

    /// Force a refresh now, bypassing the 1h window. Used by debug
    /// menus and the app's "tap-to-refresh" flag inspector.
    func refreshNow() async {
        await refresh()
    }

    // MARK: - Strongly-typed convenience accessors

    /// Phase A — trip map search provider. See migration comment for
    /// the allowed values. Defaults to `china_fallback` so a brand-
    /// new install / offline launch keeps the existing behavior:
    /// MapKit worldwide except inside mainland China.
    enum MapSearchProvider: String {
        case apple
        case google
        case chinaFallback = "china_fallback"
    }

    /// Plain global default. Most callers should prefer
    /// `mapSearchProvider(forCountry:)` so the Phase G.3 rollout
    /// gating + country overrides apply.
    var mapSearchProvider: MapSearchProvider {
        let raw = string("flag_map_search_provider", default: "china_fallback")
        return MapSearchProvider(rawValue: raw) ?? .chinaFallback
    }

    /// Phase G.3 — country-aware resolver with rollout bucketing.
    ///
    /// Resolution order:
    ///   1. `flag_map_search_provider_country_overrides[country]`
    ///      if present — this is the per-country kill-switch.
    ///   2. If the user is inside the rollout bucket, return the
    ///      global default (`flag_map_search_provider`).
    ///   3. Otherwise, return `.google` (the legacy fallback).
    ///
    /// `country` is ISO 3166-1 alpha-2 (uppercase). Pass the trip
    /// destination's country when known; the device's locale region
    /// is an acceptable fallback. Pass `nil` if neither is
    /// available — the resolver still works, it just skips step 1.
    func mapSearchProvider(forCountry country: String?) -> MapSearchProvider {
        // Country override wins over everything else.
        if let country = country?.uppercased(), !country.isEmpty,
           case .object(let overrides) = lookupRaw(
               flag: "flag_map_search_provider_country_overrides"
           ),
           case .string(let raw) = overrides[country],
           let provider = MapSearchProvider(rawValue: raw)
        {
            return provider
        }

        let pct = max(0, min(100, int(
            "flag_map_search_provider_rollout_pct",
            default: 100
        )))
        let bucket = MapSearchRolloutResolver.bucket(for: stableInstallId)
        if bucket < pct {
            return mapSearchProvider
        }
        return .google
    }

    /// Same `JSONValue` slot the public getters traverse, exposed so
    /// `mapSearchProvider(forCountry:)` can read object-shaped flags
    /// (the `country_overrides` map) without duplicating cache
    /// access logic.
    private func lookupRaw(flag: String) -> SupabaseManager.JSONValue? {
        kickRefreshIfStale()
        return values[flag]
    }

    /// Stable per-install identifier used for rollout bucketing.
    /// We use `identifierForVendor` because it is:
    ///   * available synchronously (no async/await),
    ///   * stable across launches for the same vendor + device,
    ///   * not tied to the auth session, so anonymous + signed-out
    ///     users still hit the same bucket the next launch.
    /// A reinstall reshuffles the bucket; that's acceptable and
    /// matches the cohort granularity we need for a 14-day rollout.
    @ObservationIgnored private var cachedStableId: String?
    private var stableInstallId: String {
        if let cachedStableId { return cachedStableId }
        let id = "device:\(MapSearchRolloutResolver.deviceId)"
        cachedStableId = id
        return id
    }

    /// Phase B.5 — Google Places autocomplete endpoint for the AI
    /// stay-area picker. Defaults to `new` so a brand-new install
    /// gets the same code path the rollout reached.
    enum StayAreaAutocompleteAPI: String {
        case new
        case legacy
    }

    var stayAreaAutocompleteAPI: StayAreaAutocompleteAPI {
        let raw = string("flag_stay_area_autocomplete_api", default: "new")
        return StayAreaAutocompleteAPI(rawValue: raw) ?? .new
    }

    /// Phase F master kill-switch. When false the upload UI and the
    /// carousel rendering of approved user photos both hide.
    var userPhotosEnabled: Bool {
        bool("flag_user_photos", default: true)
    }

    /// Phase H TTL inputs surfaced for completeness. 180-day
    /// defaults mirror the migration seed values.
    var cityPlacesDataTTLDays: Int {
        int("city_places_data_ttl_days", default: 180)
    }
    var cityPlacesImageTTLDays: Int {
        int("city_places_image_ttl_days", default: 180)
    }

    // MARK: - Private

    private func kickRefreshIfStale() {
        guard inFlight == nil else { return }
        let needs: Bool
        if let last = lastRefreshedAt {
            needs = Date().timeIntervalSince(last) > refreshInterval
        } else {
            needs = true
        }
        guard needs else { return }
        inFlight = Task { [weak self] in
            await self?.refresh()
            self?.inFlight = nil
        }
    }

    private func refresh() async {
        guard let client = AuthSessionService.shared.client else { return }
        struct Row: Decodable {
            let flag: String
            let value: SupabaseManager.JSONValue
        }
        do {
            let rows: [Row] = try await client
                .from("feature_flags")
                .select("flag,value")
                .execute()
                .value
            var next: [String: SupabaseManager.JSONValue] = [:]
            next.reserveCapacity(rows.count)
            for row in rows {
                next[row.flag] = row.value
            }
            self.values = next
            self.lastRefreshedAt = Date()
        } catch {
            // Best-effort. Keep the existing cached values; defaults
            // already fill the gap when nothing is loaded.
            #if DEBUG
            print("[FeatureFlagsService] refresh failed: \(error)")
            #endif
        }
    }
}
