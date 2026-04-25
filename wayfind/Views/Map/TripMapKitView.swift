//
//  TripMapKitView.swift
//  wayfind
//
//  UIViewRepresentable around MKMapView. Replaces the SwiftUI `Map(...)` we
//  used in the trip map screen for three reasons:
//
//    1. True annotation clustering for search results. SwiftUI's Map has no
//       cluster API; building it on top requires us to recompute all
//       annotation positions on every zoom level, which loses identity and
//       prevents smooth cluster-bubble animation.
//
//    2. Sheet-aware camera framing through `setVisibleMapRect(_:edgePadding:
//       animated:)`. The previous code computed a south-offset latitude by
//       hand based on the bottom sheet's covered fraction. `edgePadding`
//       lets MapKit do the math against the visible region directly.
//
//    3. Stable-id annotation/overlay diffing. SwiftUI rebuilds the
//       annotation closure on every parent state change; that thrashes
//       MKAnnotationView reuse and kills cluster expand animations. The
//       diffing coordinator here keeps annotations long-lived and only
//       updates the ones whose visual fingerprint changed.
//
//  Phase 1 of the Map Screen Search Redesign plan.
//

import MapKit
import SwiftUI

// MARK: - Public input types

/// One leg between two consecutive trip stops. Apple-routed legs render
/// bolder than haversine fallbacks so the user can tell which legs are
/// real routes vs straight-line approximations. The optional `mode`
/// drives stroke style (dotted for walking, dashed for transit, solid
/// for driving) so the user can read the chosen transport at a glance.
struct TripRouteSegment: Identifiable, Equatable {
    let id: String
    let coordinates: [CLLocationCoordinate2D]
    let isApple: Bool
    /// Which routing mode produced this polyline (or that we want to
    /// represent visually). `nil` for haversine fallbacks where mode
    /// is unknown — renderer falls back to the solid driving style.
    let mode: AppleTravelTimesService.Mode?
    /// Cached travel time in minutes for callers that want to render
    /// midpoint badges. Optional — not all sources publish minutes.
    let minutes: Int?
    /// Per-leg stroke color. Lets the renderer color each leg by its
    /// day even when the user hasn't filtered to a specific day,
    /// matching the day pin/dot colors. `nil` falls back to the
    /// global `routeStrokeColor` so legacy callers stay correct.
    let strokeColor: UIColor?

    init(
        id: String,
        coordinates: [CLLocationCoordinate2D],
        isApple: Bool,
        mode: AppleTravelTimesService.Mode? = nil,
        minutes: Int? = nil,
        strokeColor: UIColor? = nil
    ) {
        self.id = id
        self.coordinates = coordinates
        self.isApple = isApple
        self.mode = mode
        self.minutes = minutes
        self.strokeColor = strokeColor
    }

    static func == (lhs: TripRouteSegment, rhs: TripRouteSegment) -> Bool {
        lhs.id == rhs.id
            && lhs.isApple == rhs.isApple
            && lhs.mode == rhs.mode
            && lhs.minutes == rhs.minutes
            && lhs.strokeColor == rhs.strokeColor
            && lhs.coordinates.count == rhs.coordinates.count
            && zip(lhs.coordinates, rhs.coordinates).allSatisfy {
                $0.latitude == $1.latitude && $0.longitude == $1.longitude
            }
    }
}

/// What MapKit should be looking at right now. The view applies the change
/// when the value advances to a new `id` so SwiftUI's diffing doesn't fire
/// `setVisibleMapRect` on every parent re-render. We deliberately do **not**
/// adopt `Equatable` — the coordinator diffs on `id` alone, and a couple of
/// the associated values (notably `[CLLocationCoordinate2D]`) don't get
/// synthesized equatability anyway.
struct TripMapCameraTarget {
    enum Kind {
        /// Fit a rect of coordinates with the given edge insets. The view
        /// will compute the bounding rect and apply `edgePadding`.
        case fit(coordinates: [CLLocationCoordinate2D], padding: UIEdgeInsets)

        /// Center on a single coordinate at a roughly-constant span.
        case center(CLLocationCoordinate2D, latMeters: Double, lngMeters: Double, padding: UIEdgeInsets)

        /// World globe view — used when the trip has no mappable places.
        case globe(CLLocationCoordinate2D)
    }

    /// Increment to force a re-application of the same `kind` (e.g. user
    /// tapped "Recenter").
    let id: Int
    let kind: Kind
    let animated: Bool
}

/// Map style. Mirrors `TripMapMode` so the view layer stays decoupled
/// from the existing settings sheet.
enum TripMapKitConfiguration: Equatable {
    case standard
    case hybrid
}

// MARK: - The representable

struct TripMapKitView: UIViewRepresentable {

    // Inputs
    let tripPlaces: [Place]
    let dayNumberByDayId: [UUID: Int]
    let routeSegments: [TripRouteSegment]
    let routeStrokeColor: Color
    let searchResults: [MapSearchPreview]
    let cameraTarget: TripMapCameraTarget?
    let configuration: TripMapKitConfiguration
    let reduceMotion: Bool

    // Callbacks
    var onTapTripPlace: (Place) -> Void = { _ in }
    var onTapSearchResult: (MapSearchPreview) -> Void = { _ in }
    var onCameraIdle: (MKCoordinateRegion) -> Void = { _ in }
    var onTapCluster: (MKClusterAnnotation) -> Void = { _ in }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.showsUserLocation = true
        map.showsCompass = false
        map.showsScale = false
        map.pointOfInterestFilter = .excludingAll  // our pins, not Apple's
        map.preferredConfiguration = Self.makeConfiguration(configuration)

        map.register(
            TripPlaceAnnotationView.self,
            forAnnotationViewWithReuseIdentifier: TripPlaceAnnotationView.reuseId
        )
        map.register(
            BookingAnnotationView.self,
            forAnnotationViewWithReuseIdentifier: BookingAnnotationView.reuseId
        )
        map.register(
            SearchResultAnnotationView.self,
            forAnnotationViewWithReuseIdentifier: SearchResultAnnotationView.reuseId
        )
        map.register(
            SearchResultClusterView.self,
            forAnnotationViewWithReuseIdentifier: SearchResultClusterView.reuseId
        )
        map.register(
            RouteBadgeAnnotationView.self,
            forAnnotationViewWithReuseIdentifier: RouteBadgeAnnotationView.reuseId
        )

        // Initial sync so the first frame has data.
        context.coordinator.applyAnnotations(to: map, places: tripPlaces, dayNumberByDayId: dayNumberByDayId)
        context.coordinator.applySearchResults(to: map, results: searchResults)
        context.coordinator.applyOverlays(to: map, segments: routeSegments)
        context.coordinator.applyBadgeVisibility(to: map)
        if let target = cameraTarget {
            context.coordinator.apply(camera: target, to: map, reduceMotion: reduceMotion)
        }
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self

        // Configuration first — switching style mid-update doesn't disturb
        // the annotation set.
        let desiredConfig = Self.makeConfiguration(configuration)
        if !coordinator.matchesAppliedConfiguration(desiredConfig) {
            map.preferredConfiguration = desiredConfig
            coordinator.appliedConfigurationKind = configuration
        }

        coordinator.applyAnnotations(to: map, places: tripPlaces, dayNumberByDayId: dayNumberByDayId)
        coordinator.applySearchResults(to: map, results: searchResults)
        coordinator.applyOverlays(to: map, segments: routeSegments)
        coordinator.routeStrokeColor = UIColor(routeStrokeColor)

        if let target = cameraTarget,
           coordinator.appliedCameraId != target.id {
            coordinator.apply(camera: target, to: map, reduceMotion: reduceMotion)
            coordinator.appliedCameraId = target.id
        }
    }

    private static func makeConfiguration(
        _ kind: TripMapKitConfiguration
    ) -> MKMapConfiguration {
        switch kind {
        case .standard:
            let cfg = MKStandardMapConfiguration()
            cfg.pointOfInterestFilter = .excludingAll
            return cfg
        case .hybrid:
            let cfg = MKHybridMapConfiguration()
            cfg.pointOfInterestFilter = .excludingAll
            return cfg
        }
    }

    // MARK: - Coordinator

    /// `@preconcurrency` on the conformance lets us implement the
    /// MKMapViewDelegate methods as `@MainActor` (which they effectively
    /// are — MapKit only calls them on the main thread) without Swift 6
    /// strict-concurrency complaining that the protocol slots are
    /// nonisolated.
    @MainActor
    final class Coordinator: NSObject, @preconcurrency MKMapViewDelegate {
        var parent: TripMapKitView
        var routeStrokeColor: UIColor
        var appliedConfigurationKind: TripMapKitConfiguration = .standard
        var appliedCameraId: Int?

        /// Stable lookup so we can diff in O(n) without rebuilding views.
        private var tripAnnotationsById: [String: TripPlaceAnnotation] = [:]
        private var bookingAnnotationsById: [String: BookingAnnotation] = [:]
        private var searchAnnotationsById: [String: SearchResultAnnotation] = [:]
        private var overlaysById: [String: MKPolyline] = [:]
        private var segmentMetaById: [String: TripRouteSegment] = [:]
        private var routeBadgesById: [String: RouteBadgeAnnotation] = [:]

        init(parent: TripMapKitView) {
            self.parent = parent
            self.routeStrokeColor = UIColor(parent.routeStrokeColor)
            super.init()
        }

        func matchesAppliedConfiguration(_ desired: MKMapConfiguration) -> Bool {
            // We compare by the high-level kind we built it from; MKConfig
            // identity isn't a public thing.
            return appliedConfigurationKind == parent.configuration
                && (
                    (parent.configuration == .standard && desired is MKStandardMapConfiguration)
                    || (parent.configuration == .hybrid && desired is MKHybridMapConfiguration)
                )
        }

        // MARK: – Annotation diffing

        func applyAnnotations(
            to map: MKMapView,
            places: [Place],
            dayNumberByDayId: [UUID: Int]
        ) {
            let mappable = places.filter { p in
                guard let lat = p.lat, let lng = p.lng else { return false }
                return abs(lat) > 0.0001 || abs(lng) > 0.0001
            }

            var nextTripIds = Set<String>()
            var nextBookingIds = Set<String>()
            var toAdd: [MKAnnotation] = []
            var toRemove: [MKAnnotation] = []

            for place in mappable {
                let key = place.id.uuidString
                if place.isBooking {
                    nextBookingIds.insert(key)
                    if let existing = bookingAnnotationsById[key] {
                        let candidate = BookingAnnotation(place: place)
                        if existing.visualFingerprint != candidate.visualFingerprint {
                            // Mutate in place so MKMapView keeps the view.
                            existing.coordinate = candidate.coordinate
                            existing.title = candidate.title
                        }
                    } else {
                        let new = BookingAnnotation(place: place)
                        bookingAnnotationsById[key] = new
                        toAdd.append(new)
                    }
                } else {
                    nextTripIds.insert(key)
                    let dayNum = dayNumberByDayId[place.itineraryDayId] ?? 1
                    if let existing = tripAnnotationsById[key] {
                        let candidate = TripPlaceAnnotation(place: place, dayNumber: dayNum)
                        if existing.visualFingerprint != candidate.visualFingerprint {
                            existing.coordinate = candidate.coordinate
                            existing.title = candidate.title
                            // Day number / sort label are `let` — must replace.
                            if existing.dayNumber != candidate.dayNumber
                                || existing.sortLabel != candidate.sortLabel {
                                toRemove.append(existing)
                                tripAnnotationsById[key] = candidate
                                toAdd.append(candidate)
                            }
                        }
                    } else {
                        let new = TripPlaceAnnotation(place: place, dayNumber: dayNum)
                        tripAnnotationsById[key] = new
                        toAdd.append(new)
                    }
                }
            }

            // Remove annotations that disappeared from `places`.
            for (key, ann) in tripAnnotationsById where !nextTripIds.contains(key) {
                toRemove.append(ann)
                tripAnnotationsById.removeValue(forKey: key)
            }
            for (key, ann) in bookingAnnotationsById where !nextBookingIds.contains(key) {
                toRemove.append(ann)
                bookingAnnotationsById.removeValue(forKey: key)
            }

            if !toRemove.isEmpty { map.removeAnnotations(toRemove) }
            if !toAdd.isEmpty { map.addAnnotations(toAdd) }
        }

        func applySearchResults(
            to map: MKMapView,
            results: [MapSearchPreview]
        ) {
            var nextIds = Set<String>()
            var toAdd: [MKAnnotation] = []
            var toRemove: [MKAnnotation] = []

            for preview in results {
                nextIds.insert(preview.id)
                if searchAnnotationsById[preview.id] == nil {
                    let ann = SearchResultAnnotation(preview: preview)
                    searchAnnotationsById[preview.id] = ann
                    toAdd.append(ann)
                }
                // We deliberately don't try to mutate existing search
                // results — preview content is immutable for the lifetime
                // of the search.
            }

            for (key, ann) in searchAnnotationsById where !nextIds.contains(key) {
                toRemove.append(ann)
                searchAnnotationsById.removeValue(forKey: key)
            }

            if !toRemove.isEmpty { map.removeAnnotations(toRemove) }
            if !toAdd.isEmpty { map.addAnnotations(toAdd) }
        }

        // MARK: – Overlay diffing

        func applyOverlays(to map: MKMapView, segments: [TripRouteSegment]) {
            var nextIds = Set<String>()
            var toRemove: [MKOverlay] = []
            var toAdd: [MKOverlay] = []

            for segment in segments {
                nextIds.insert(segment.id)
                if let existing = overlaysById[segment.id],
                   let prevMeta = segmentMetaById[segment.id],
                   prevMeta == segment {
                    _ = existing  // unchanged; keep
                } else {
                    if let existing = overlaysById[segment.id] {
                        toRemove.append(existing)
                    }
                    let polyline = MKPolyline(
                        coordinates: segment.coordinates,
                        count: segment.coordinates.count
                    )
                    polyline.title = segment.id
                    overlaysById[segment.id] = polyline
                    segmentMetaById[segment.id] = segment
                    toAdd.append(polyline)
                }
            }

            for (key, overlay) in overlaysById where !nextIds.contains(key) {
                toRemove.append(overlay)
                overlaysById.removeValue(forKey: key)
                segmentMetaById.removeValue(forKey: key)
            }

            if !toRemove.isEmpty { map.removeOverlays(toRemove) }
            if !toAdd.isEmpty { map.addOverlays(toAdd, level: .aboveRoads) }

            // Badges follow the polylines — same diff strategy.
            applyRouteBadges(to: map, segments: segments)
        }

        /// Create / update / remove the floating mode-and-time badges
        /// that ride at each leg's midpoint. Visibility (zoom-gated)
        /// is applied separately by `applyBadgeVisibility(to:)`.
        private func applyRouteBadges(to map: MKMapView, segments: [TripRouteSegment]) {
            var nextIds = Set<String>()
            var toAdd: [MKAnnotation] = []
            var toRemove: [MKAnnotation] = []

            for segment in segments {
                guard let mid = Self.midpoint(of: segment.coordinates) else { continue }
                let badgeId = "\(segment.id).badge"
                nextIds.insert(badgeId)

                let dayColor = segment.strokeColor ?? routeStrokeColor
                let candidate = RouteBadgeAnnotation(
                    segmentId: segment.id,
                    coordinate: mid,
                    mode: segment.mode,
                    minutes: segment.minutes,
                    dayColor: dayColor
                )

                if let existing = routeBadgesById[badgeId] {
                    if existing.visualFingerprint != candidate.visualFingerprint {
                        // Replace — the view's labelled state is baked
                        // in during configure(), so swapping the
                        // annotation forces a fresh layout.
                        toRemove.append(existing)
                        routeBadgesById[badgeId] = candidate
                        toAdd.append(candidate)
                    }
                } else {
                    routeBadgesById[badgeId] = candidate
                    toAdd.append(candidate)
                }
            }

            for (key, ann) in routeBadgesById where !nextIds.contains(key) {
                toRemove.append(ann)
                routeBadgesById.removeValue(forKey: key)
            }

            if !toRemove.isEmpty { map.removeAnnotations(toRemove) }
            if !toAdd.isEmpty { map.addAnnotations(toAdd) }

            applyBadgeVisibility(to: map)
        }

        /// Show badges only when the map is zoomed in enough that the
        /// label is readable. We use the latitude span as the zoom
        /// proxy — at ~0.05° (≈ 5.5 km tall on screen) badges read
        /// cleanly without crowding. Wider than that and we hide them
        /// to keep the dashed/dotted line styles legible on their own.
        func applyBadgeVisibility(to map: MKMapView) {
            let span = max(map.region.span.latitudeDelta, map.region.span.longitudeDelta)
            let visible = span <= 0.05
            for badge in routeBadgesById.values {
                if let view = map.view(for: badge) {
                    view.isHidden = !visible
                }
            }
        }

        /// Length-aware midpoint of a polyline. Walks the coordinates
        /// summing segment lengths so the badge sits at half the
        /// total *distance*, not just at the index midpoint —
        /// otherwise long-tail polylines would put the badge in the
        /// wrong half visually.
        private static func midpoint(of coords: [CLLocationCoordinate2D]) -> CLLocationCoordinate2D? {
            guard coords.count >= 2 else { return coords.first }
            // Project to MKMapPoint so distance math is metric.
            let points = coords.map { MKMapPoint($0) }
            var lengths: [Double] = []
            var total: Double = 0
            for i in 0 ..< points.count - 1 {
                let d = points[i].distance(to: points[i + 1])
                lengths.append(d)
                total += d
            }
            guard total > 0 else { return coords.first }
            let target = total / 2
            var running: Double = 0
            for i in 0 ..< lengths.count {
                let segLen = lengths[i]
                if running + segLen >= target {
                    let t = (target - running) / segLen
                    let a = points[i]
                    let b = points[i + 1]
                    let mp = MKMapPoint(
                        x: a.x + (b.x - a.x) * t,
                        y: a.y + (b.y - a.y) * t
                    )
                    return mp.coordinate
                }
                running += segLen
            }
            // Numerical edge case — fall back to the geometric mid.
            return coords[coords.count / 2]
        }

        // MARK: – Camera

        func apply(
            camera target: TripMapCameraTarget,
            to map: MKMapView,
            reduceMotion: Bool
        ) {
            let animated = target.animated && !reduceMotion
            switch target.kind {
            case .fit(let coords, let padding):
                let valid = coords.filter { CLLocationCoordinate2DIsValid($0) }
                if valid.count >= 2 {
                    let rect = Self.boundingRect(for: valid)
                    map.setVisibleMapRect(
                        rect,
                        edgePadding: padding,
                        animated: animated
                    )
                } else if let only = valid.first {
                    let region = MKCoordinateRegion(
                        center: only,
                        latitudinalMeters: 600,
                        longitudinalMeters: 600
                    )
                    map.setVisibleMapRect(
                        Self.mapRect(for: region),
                        edgePadding: padding,
                        animated: animated
                    )
                }
            case .center(let center, let latMeters, let lngMeters, let padding):
                guard CLLocationCoordinate2DIsValid(center) else { return }
                let region = MKCoordinateRegion(
                    center: center,
                    latitudinalMeters: latMeters,
                    longitudinalMeters: lngMeters
                )
                map.setVisibleMapRect(
                    Self.mapRect(for: region),
                    edgePadding: padding,
                    animated: animated
                )
            case .globe(let center):
                guard CLLocationCoordinate2DIsValid(center) else { return }
                let region = MKCoordinateRegion(
                    center: center,
                    span: MKCoordinateSpan(latitudeDelta: 80, longitudeDelta: 120)
                )
                map.setRegion(region, animated: animated)
            }
        }

        private static func boundingRect(
            for coords: [CLLocationCoordinate2D]
        ) -> MKMapRect {
            var rect = MKMapRect.null
            for coord in coords {
                let point = MKMapPoint(coord)
                let pointRect = MKMapRect(x: point.x, y: point.y, width: 0.001, height: 0.001)
                rect = rect.union(pointRect)
            }
            return rect
        }

        private static func mapRect(for region: MKCoordinateRegion) -> MKMapRect {
            let topLeft = CLLocationCoordinate2D(
                latitude: region.center.latitude + region.span.latitudeDelta / 2,
                longitude: region.center.longitude - region.span.longitudeDelta / 2
            )
            let bottomRight = CLLocationCoordinate2D(
                latitude: region.center.latitude - region.span.latitudeDelta / 2,
                longitude: region.center.longitude + region.span.longitudeDelta / 2
            )
            let topLeftPoint = MKMapPoint(topLeft)
            let bottomRightPoint = MKMapPoint(bottomRight)
            return MKMapRect(
                x: min(topLeftPoint.x, bottomRightPoint.x),
                y: min(topLeftPoint.y, bottomRightPoint.y),
                width: abs(bottomRightPoint.x - topLeftPoint.x),
                height: abs(bottomRightPoint.y - topLeftPoint.y)
            )
        }

        // MARK: – MKMapViewDelegate

        func mapView(
            _ mapView: MKMapView,
            viewFor annotation: MKAnnotation
        ) -> MKAnnotationView? {
            if annotation is MKUserLocation { return nil }

            if let cluster = annotation as? MKClusterAnnotation {
                return mapView.dequeueReusableAnnotationView(
                    withIdentifier: SearchResultClusterView.reuseId,
                    for: cluster
                )
            }

            switch annotation {
            case is TripPlaceAnnotation:
                return mapView.dequeueReusableAnnotationView(
                    withIdentifier: TripPlaceAnnotationView.reuseId,
                    for: annotation
                )
            case is BookingAnnotation:
                return mapView.dequeueReusableAnnotationView(
                    withIdentifier: BookingAnnotationView.reuseId,
                    for: annotation
                )
            case is SearchResultAnnotation:
                return mapView.dequeueReusableAnnotationView(
                    withIdentifier: SearchResultAnnotationView.reuseId,
                    for: annotation
                )
            case is RouteBadgeAnnotation:
                let view = mapView.dequeueReusableAnnotationView(
                    withIdentifier: RouteBadgeAnnotationView.reuseId,
                    for: annotation
                )
                // Apply current zoom-gated visibility so newly-added
                // badges don't pop in at a wide zoom.
                let span = max(
                    mapView.region.span.latitudeDelta,
                    mapView.region.span.longitudeDelta
                )
                view.isHidden = span > 0.05
                return view
            default:
                return nil
            }
        }

        func mapView(
            _ mapView: MKMapView,
            rendererFor overlay: MKOverlay
        ) -> MKOverlayRenderer {
            guard let polyline = overlay as? MKPolyline else {
                return MKOverlayRenderer(overlay: overlay)
            }
            let renderer = MKPolylineRenderer(polyline: polyline)

            // Lookup the segment metadata so we can style by both
            // provenance (Apple route vs haversine fallback) and the
            // chosen transport mode for that leg.
            let segment: TripRouteSegment? = polyline.title.flatMap { segmentMetaById[$0] }
            let isApple = segment?.isApple ?? false
            let mode = segment?.mode

            // Per-leg color (day-keyed) overrides the global stroke
            // when the caller supplied one; otherwise we fall back to
            // the legacy single color. Higher alpha across the board
            // — the previous 0.78 / 0.32 disappeared into satellite
            // imagery and rich basemap tiles.
            let baseColor = segment?.strokeColor ?? routeStrokeColor
            renderer.strokeColor = baseColor.withAlphaComponent(isApple ? 0.95 : 0.55)
            renderer.lineWidth = isApple ? 5.5 : 3.5
            renderer.lineCap = .round
            renderer.lineJoin = .round

            // Mode-aware dash pattern. Reads at a glance:
            //   • Walking — small dots, the universal "footsteps" cue.
            //   • Transit — long-dash + short-dash, hints at "stops".
            //   • Driving — solid, the conventional road-line.
            //   • nil mode (haversine) — solid like driving so the
            //     fallback stays visually quiet rather than fighting
            //     for attention with a dash pattern that implies a
            //     known mode.
            switch mode {
            case .walking:
                renderer.lineDashPattern = [2, 6]
                renderer.lineCap = .round
            case .transit:
                renderer.lineDashPattern = [10, 5, 2, 5]
            case .driving, nil:
                renderer.lineDashPattern = nil
            }
            return renderer
        }

        func mapView(
            _ mapView: MKMapView,
            didSelect view: MKAnnotationView
        ) {
            // Deselect immediately so future taps fire even when the same
            // annotation is reselected.
            mapView.deselectAnnotation(view.annotation, animated: false)

            if let cluster = view.annotation as? MKClusterAnnotation {
                parent.onTapCluster(cluster)
                return
            }
            if let trip = view.annotation as? TripPlaceAnnotation {
                if let place = parent.tripPlaces.first(where: { $0.id == trip.placeId }) {
                    parent.onTapTripPlace(place)
                }
                return
            }
            if let booking = view.annotation as? BookingAnnotation {
                if let place = parent.tripPlaces.first(where: { $0.id == booking.placeId }) {
                    parent.onTapTripPlace(place)
                }
                return
            }
            if let search = view.annotation as? SearchResultAnnotation {
                parent.onTapSearchResult(search.preview)
                return
            }
        }

        func mapView(
            _ mapView: MKMapView,
            regionDidChangeAnimated animated: Bool
        ) {
            parent.onCameraIdle(mapView.region)
            applyBadgeVisibility(to: mapView)
        }
    }
}

// =============================================================================
