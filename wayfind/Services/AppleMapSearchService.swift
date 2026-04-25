//
//  AppleMapSearchService.swift
//  wayfind
//
//  MapKit-backed replacement for the iOS map screen's Google Places autocomplete.
//  Wraps `MKLocalSearchCompleter` for low-latency suggestions and `MKLocalSearch`
//  for the on-commit lat/lng resolve. Free, native, and ranks by viewport.
//
//  Used by `TripMapPlacesSheet`. The Stay Area picker still uses
//  `PlaceSearchService` (Google) because the AI generation contract requires a
//  Google `place_id`. See places-cost-and-owned-data plan, Phase A.
//

import Foundation
import MapKit
import Observation

/// One row in the autocomplete list. Wraps the underlying
/// `MKLocalSearchCompletion` so the caller can pass it back to `resolve(_:in:)`.
struct AppleMapSuggestion: Identifiable, Hashable {
    let id: String
    let title: String
    let subtitle: String
    fileprivate let completion: MKLocalSearchCompletion

    init(completion: MKLocalSearchCompletion) {
        self.id = "\(completion.title)|\(completion.subtitle)"
        self.title = completion.title
        self.subtitle = completion.subtitle
        self.completion = completion
    }

    static func == (lhs: AppleMapSuggestion, rhs: AppleMapSuggestion) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

/// Resolved MapKit hit ready to drop on the map.
struct AppleMapResolvedPlace: Hashable {
    let name: String
    let subtitle: String
    let coordinate: CLLocationCoordinate2D
    let placemarkTitle: String?

    static func == (lhs: AppleMapResolvedPlace, rhs: AppleMapResolvedPlace) -> Bool {
        lhs.name == rhs.name
            && lhs.subtitle == rhs.subtitle
            && lhs.coordinate.latitude == rhs.coordinate.latitude
            && lhs.coordinate.longitude == rhs.coordinate.longitude
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(name)
        hasher.combine(subtitle)
        hasher.combine(coordinate.latitude)
        hasher.combine(coordinate.longitude)
    }
}

/// MapKit autocomplete + resolve service. `@MainActor` because
/// `MKLocalSearchCompleter` requires main-thread access for its delegate.
///
/// Instantiate as a `@State` per-view; it's lightweight and the completer
/// is per-instance so concurrent searches don't trample each other.
@MainActor
@Observable
final class AppleMapSearchService: NSObject {

    /// Current suggestions surfaced as the user types. Mirrors the completer.
    private(set) var suggestions: [AppleMapSuggestion] = []

    /// Last error from the completer or resolver. UI may inspect for telemetry;
    /// we never surface this directly to the user — fall back to empty list.
    private(set) var lastError: Error?

    /// True between the moment the user commits a row and the moment we have
    /// the final coordinate. UI can show a tiny spinner if it wants.
    private(set) var isResolving: Bool = false

    private let completer: MKLocalSearchCompleter
    private var debounceTask: Task<Void, Never>?

    /// Minimum query length before we even hit MapKit. Matches the prior
    /// Google service threshold so users don't see a behavior change.
    private let minQueryLength: Int = 2

    /// 300ms feels right based on a side-by-side with the iOS Maps app.
    /// Long enough to skip mid-word junk, short enough to feel reactive.
    private let debounceMillis: Int = 300

    override init() {
        let c = MKLocalSearchCompleter()
        // .physicalFeature surfaces parks / mountains / beaches — important
        // for travel planning. Older iOS versions just get pointOfInterest
        // and address.
        if #available(iOS 18.0, *) {
            c.resultTypes = [.pointOfInterest, .address, .physicalFeature]
        } else {
            c.resultTypes = [.pointOfInterest, .address]
        }
        self.completer = c
        super.init()
        completer.delegate = self
    }

    /// Updates the live suggestions. Debounced; the caller may call freely on
    /// every keystroke.
    /// - Parameters:
    ///   - query: Raw search string (trimmed inside).
    ///   - region: Optional viewport biasing — pass the trip map's current
    ///     camera region so MapKit ranks nearby hits first.
    func update(query: String, region: MKCoordinateRegion?) {
        debounceTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= minQueryLength else {
            suggestions = []
            return
        }
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(self?.debounceMillis ?? 300))
            guard !Task.isCancelled, let self else { return }
            if let region {
                self.completer.region = region
            }
            self.completer.queryFragment = trimmed
        }
    }

    /// Clears suggestions and cancels any in-flight debounce. Call when the
    /// search field empties or the sheet dismisses to free the completer.
    func clear() {
        debounceTask?.cancel()
        suggestions = []
        completer.cancel()
        completer.queryFragment = ""
    }

    /// Resolves a tapped suggestion to a coordinate via `MKLocalSearch`.
    /// Returns `nil` for ambiguous queries (Apple sometimes returns empty
    /// `mapItems` even for a completion it produced).
    func resolve(_ suggestion: AppleMapSuggestion,
                 in region: MKCoordinateRegion?) async -> AppleMapResolvedPlace? {
        isResolving = true
        defer { isResolving = false }

        let signpost = PlatformUsageTelemetry.begin(.mkLocalSearch)
        var outcome: PlatformUsageTelemetry.Status = .error
        defer { PlatformUsageTelemetry.end(.mkLocalSearch, id: signpost, status: outcome) }

        let request = MKLocalSearch.Request(completion: suggestion.completion)
        if let region {
            request.region = region
        }

        do {
            let response = try await MKLocalSearch(request: request).start()
            guard let first = response.mapItems.first else {
                lastError = nil
                outcome = .empty
                return nil
            }
            let coord: CLLocationCoordinate2D = first.placemark.coordinate
            let name: String = first.name?.isEmpty == false ? first.name! : suggestion.title
            outcome = .ok
            return AppleMapResolvedPlace(
                name: name,
                subtitle: suggestion.subtitle,
                coordinate: coord,
                placemarkTitle: first.placemark.title
            )
        } catch {
            lastError = error
            return nil
        }
    }

    /// Direct natural-language search bypassing the completer. Used by the
    /// category pills ("restaurants", "coffee", "museums"): we already know
    /// the term and want the top-N hits in the viewport, no autocomplete.
    func searchNearby(naturalLanguage query: String,
                      in region: MKCoordinateRegion,
                      resultLimit: Int = 10) async -> [AppleMapResolvedPlace] {
        let signpost = PlatformUsageTelemetry.begin(.mkLocalSearch)
        var outcome: PlatformUsageTelemetry.Status = .error
        defer { PlatformUsageTelemetry.end(.mkLocalSearch, id: signpost, status: outcome) }

        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.region = region
        if #available(iOS 18.0, *) {
            request.resultTypes = [.pointOfInterest, .physicalFeature]
        } else {
            request.resultTypes = [.pointOfInterest]
        }

        do {
            let response = try await MKLocalSearch(request: request).start()
            let maxKm = Self.maxResultDistanceKm(for: region)
            let filtered = response.mapItems.filter { item in
                Self.isWithinRegion(
                    item.placemark.coordinate,
                    center: region.center,
                    maxKm: maxKm
                )
            }
            let mapped = filtered.prefix(resultLimit).map { item in
                AppleMapResolvedPlace(
                    name: item.name ?? query,
                    subtitle: item.placemark.title ?? "",
                    coordinate: item.placemark.coordinate,
                    placemarkTitle: item.placemark.title
                )
            }
            outcome = mapped.isEmpty ? .empty : .ok
            return mapped
        } catch {
            lastError = error
            return []
        }
    }

    // MARK: - MapSearchPreview producers (Phase 3+)

    /// Resolve a tapped suggestion to a `MapSearchPreview`. Returns nil
    /// when MapKit can't materialise the completion (rare — usually
    /// transient network) or when the resolved place is far outside the
    /// caller's bias region (Apple's silent global fallback).
    func resolveDetail(suggestion: AppleMapSuggestion,
                       in region: MKCoordinateRegion?) async -> MapSearchPreview? {
        let signpost = PlatformUsageTelemetry.begin(.mkLocalSearch)
        var outcome: PlatformUsageTelemetry.Status = .error
        defer { PlatformUsageTelemetry.end(.mkLocalSearch, id: signpost, status: outcome) }

        let request = MKLocalSearch.Request(completion: suggestion.completion)
        if let region {
            request.region = region
        }

        do {
            let response = try await MKLocalSearch(request: request).start()
            guard let first = response.mapItems.first else {
                outcome = .empty
                return nil
            }
            if let region {
                let maxKm = Self.maxResultDistanceKm(for: region)
                if !Self.isWithinRegion(
                    first.placemark.coordinate,
                    center: region.center,
                    maxKm: maxKm
                ) {
                    // Apple Maps fell back to a global match (e.g., a
                    // Chipotle in the US when the trip is in Bali).
                    // Reject so we don't yank the camera across the
                    // world. Caller surfaces an empty state instead.
                    outcome = .empty
                    return nil
                }
            }
            outcome = .ok
            return Self.preview(from: first, fallbackName: suggestion.title)
        } catch {
            lastError = error
            return nil
        }
    }

    /// Same `searchNearby(naturalLanguage:in:)` flow, but typed as
    /// previews so the overlay merge step doesn't have to translate.
    /// Filters out results far outside the bias region so MapKit's
    /// silent global fallback doesn't render pins on another continent.
    func searchNearbyPreviews(query: String,
                              in region: MKCoordinateRegion,
                              resultLimit: Int = 10) async -> [MapSearchPreview] {
        let signpost = PlatformUsageTelemetry.begin(.mkLocalSearch)
        var outcome: PlatformUsageTelemetry.Status = .error
        defer { PlatformUsageTelemetry.end(.mkLocalSearch, id: signpost, status: outcome) }

        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.region = region
        if #available(iOS 18.0, *) {
            request.resultTypes = [.pointOfInterest, .physicalFeature]
        } else {
            request.resultTypes = [.pointOfInterest]
        }

        do {
            let response = try await MKLocalSearch(request: request).start()
            let maxKm = Self.maxResultDistanceKm(for: region)
            let filtered = response.mapItems.filter { item in
                Self.isWithinRegion(
                    item.placemark.coordinate,
                    center: region.center,
                    maxKm: maxKm
                )
            }
            let previews = filtered
                .prefix(resultLimit)
                .map { Self.preview(from: $0, fallbackName: query) }
            outcome = previews.isEmpty ? .empty : .ok
            return previews
        } catch {
            lastError = error
            return []
        }
    }

    // MARK: - Look Around (iOS 16+) with LRU cache

    private struct LookAroundKey: Hashable {
        let lat: Int  // lat * 1000, rounded
        let lng: Int

        init(_ coord: CLLocationCoordinate2D) {
            lat = Int((coord.latitude * 1000).rounded())
            lng = Int((coord.longitude * 1000).rounded())
        }
    }

    /// Tiny LRU keyed by ~3-decimal lat/lng. Apple rate-limits Look
    /// Around scene fetches across the whole device, so a bounded
    /// in-memory cache prevents the search overlay from re-fetching
    /// scenes the user just dismissed.
    private var lookAroundCache: [(LookAroundKey, MKLookAroundScene?)] = []
    private let lookAroundCacheCap = 16

    @available(iOS 16.0, *)
    func lookAroundScene(for coordinate: CLLocationCoordinate2D) async -> MKLookAroundScene? {
        let key = LookAroundKey(coordinate)
        if let cached = lookAroundCache.first(where: { $0.0 == key }) {
            return cached.1
        }

        var scene: MKLookAroundScene?
        do {
            scene = try await MKLookAroundSceneRequest(coordinate: coordinate).scene
        } catch {
            scene = nil
        }

        PlatformUsageTelemetry.record(.mkLocalSearch, status: scene == nil ? .empty : .ok)

        // LRU insert — drop oldest entry if we're at cap.
        if lookAroundCache.count >= lookAroundCacheCap {
            lookAroundCache.removeFirst()
        }
        lookAroundCache.append((key, scene))
        return scene
    }

    // MARK: - Helpers

    /// Maximum allowable distance (km) between a search hit and the
    /// bias region's center before we treat the hit as Apple's global
    /// fallback. Scaled to the region span — tight viewports still get
    /// a 75 km floor so the user can grab a place "in the same metro
    /// area" while looking at downtown.
    static func maxResultDistanceKm(for region: MKCoordinateRegion) -> Double {
        // ~111 km per latitude degree; longitude varies with cosine but
        // for a coarse "is it on the same continent" check the latitude
        // approximation is plenty.
        let largerSpanDeg = max(
            region.span.latitudeDelta,
            region.span.longitudeDelta
        )
        let halfSpanKm = (largerSpanDeg * 111.0) / 2.0
        // 3× half-span ≈ 1.5× full span — generous enough to keep
        // edge-of-viewport results, strict enough to drop another
        // continent. Floor at 75 km so we always allow "next town over".
        return max(3.0 * halfSpanKm, 75.0)
    }

    /// True when `coordinate` is within `maxKm` of `center` (great-circle).
    static func isWithinRegion(
        _ coordinate: CLLocationCoordinate2D,
        center: CLLocationCoordinate2D,
        maxKm: Double
    ) -> Bool {
        // Defensive: an unanchored region (0,0 fallback) shouldn't
        // accidentally filter every result. Treat as "no constraint".
        if abs(center.latitude) < 0.000_001 && abs(center.longitude) < 0.000_001 {
            return true
        }
        return HaversineDistance.distance(from: center, to: coordinate) <= maxKm
    }

    private static func preview(from item: MKMapItem, fallbackName: String) -> MapSearchPreview {
        let coord = item.placemark.coordinate
        let name = (item.name?.isEmpty == false ? item.name! : fallbackName)
        let subtitle = item.placemark.title ?? ""
        let id = "apple|\(name)|\(String(format: "%.5f", coord.latitude))|\(String(format: "%.5f", coord.longitude))"
        return MapSearchPreview(
            id: id,
            origin: .apple,
            name: name,
            subtitle: subtitle,
            coordinate: coord,
            googlePlaceId: nil,
            phone: item.phoneNumber,
            website: item.url,
            thumbnailURL: nil,
            category: PlaceCategoryMapper.from(item: item)
        )
    }
}

// MARK: - PlaceCategory inference from MKMapItem

private enum PlaceCategoryMapper {
    static func from(item: MKMapItem) -> PlaceCategory? {
        guard let poi = item.pointOfInterestCategory else { return nil }
        switch poi {
        case .restaurant, .bakery, .brewery, .cafe, .winery, .foodMarket:
            return .restaurant
        case .hotel, .campground:
            return .hotel
        case .museum, .theater, .library:
            return .attraction
        case .park, .beach, .nationalPark, .marina:
            return .nature
        case .store:
            return .shopping
        case .nightlife:
            return .nightlife
        case .airport, .publicTransport, .gasStation, .parking:
            return .transport
        default:
            return .attraction
        }
    }
}

// MARK: - MKLocalSearchCompleterDelegate
//
// `nonisolated` because MapKit invokes us off the main actor. We hop back via
// `Task { @MainActor in ... }` to mutate the published state safely.

extension AppleMapSearchService: MKLocalSearchCompleterDelegate {
    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        let mapped = completer.results.map { AppleMapSuggestion(completion: $0) }
        // Phase G.1 — telemetry for each completer callback. Counts
        // *callbacks* not keystrokes, since the completer batches its
        // own debounce internally before pushing results.
        PlatformUsageTelemetry.record(
            .mkLocalSearchCompleter,
            status: mapped.isEmpty ? .empty : .ok,
            count: mapped.count
        )
        Task { @MainActor in
            self.suggestions = mapped
        }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        PlatformUsageTelemetry.record(.mkLocalSearchCompleter, status: .error)
        Task { @MainActor in
            self.lastError = error
            self.suggestions = []
        }
    }
}
