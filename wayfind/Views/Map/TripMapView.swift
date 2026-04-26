import CoreLocation
import MapKit
import SwiftUI

/// Temporary pin dropped on the map for an autocomplete search result.
/// Phase 1 of the Map Screen Search Redesign keeps the legacy struct as the
/// public surface; internally it is now translated to a `MapSearchPreview`
/// so it can flow through `TripMapKitView`'s `searchResults` input. Phases
/// 3+ replace this with the real overlay-driven preview list and remove
/// the type entirely.
struct MapSearchPin: Identifiable {
    let id = UUID()
    let name: String
    let coordinate: CLLocationCoordinate2D
}

struct TripMapView: View {
    let trip: Trip
    /// Legacy binding kept for callers that still pass it; ignored internally.
    var externalSearchText: Binding<String>?
    /// Shared state with the tab accessory bar (iOS 26+). Nil when not in a tab.
    var sharedState: MapTabSharedState?

    @Environment(DataService.self) var dataService
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var searchText: String = ""
    @State private var places: [Place] = []
    @State private var dayNumberByDayId: [UUID: Int] = [:]
    @State private var selectedDayFilter: Int?
    @State private var selectedPlace: Place?
    @State private var showAddPlace = false
    @State private var scheduledDays: [ItineraryDay] = []
    @State private var wishlistDayIds: Set<UUID> = []
    @State private var wishlistPlaces: [Place] = []
    @State private var activeCategoryFilter: String?

    /// Temporary map pin for a search result selected from autocomplete.
    @State private var searchResultPin: MapSearchPin?

    /// Controls whether the expanded places sheet is shown.
    @State private var showPlacesSheet = false
    @State private var searchRegion: MKCoordinateRegion

    /// Hybrid is the default map style.
    @State private var mapMode: TripMapMode = .hybrid

    /// Track map container height so we can size sheet-aware edge insets.
    @State private var mapContainerHeight: CGFloat = 0

    /// Camera target handed to `TripMapKitView`. Bumping `id` re-applies
    /// the same `kind`, so a "recenter" tap or day-filter change always
    /// fires `setVisibleMapRect` even if the math produces an identical
    /// rect.
    @State private var cameraTarget: TripMapCameraTarget?
    @State private var cameraTargetCounter: Int = 0

    @State private var showMapModesSheet = false

    // MARK: - Map Search Redesign (Phase 3+)

    @State private var mapState = TripMapState()
    @State private var showSearchOverlay = false
    @State private var showAddToDay = false
    @State private var addToDayPreview: MapSearchPreview?
    @State private var pendingAddToDayPresentation = false
    @State private var showSuggestedPlacesBrowser = false
    @State private var returnToSearchOverlay = false
    @State private var returnToSuggestedPlacesBrowser = false
    @State private var pendingSuggestedPlacesPreview: MapSearchPreview?
    @State private var resolvedCityProfileId: UUID?
    @State private var lastCategoryRegion: MKCoordinateRegion?
    @State private var lastPickedCategory: CategoryPill?
    @State private var lastSubmittedMapSearchQuery: String?
    @State private var tabSearchText = ""
    @State private var isTabSearchPresented = false
    @State private var searchPreviewDetent: PresentationDetent = .medium

    // MARK: - Transport mode (Phase J.4 polylines)

    /// Per-trip preference, persisted via AppStorage. Defaults to `.auto`
    /// so users get smart per-leg mode selection without a single tap.
    @AppStorage private var transportModeRaw: String
    @State private var showTransportPicker = false
    /// Bumped after a server-seed completes so `routeSegments` recomputes
    /// with the freshly-loaded polylines without us needing to mutate
    /// `places` or any other published state.
    @State private var polylineCacheVersion = 0

    private var mappablePlaces: [Place] {
        places.filter { place in
            guard let lat = place.lat, let lng = place.lng else { return false }
            return abs(lat) > 0.000_1 || abs(lng) > 0.000_1
        }
    }

    private var visiblePlaces: [Place] {
        guard let filter = selectedDayFilter else { return mappablePlaces }
        return mappablePlaces.filter { dayNumberByDayId[$0.itineraryDayId] == filter }
    }

    /// Day filter + text search — name / address.
    private var mapDisplayedPlaces: [Place] {
        let base = visiblePlaces
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return base }

        let lower = q.lowercased()
        return base.filter { p in
            p.name.lowercased().contains(lower) || (p.address?.lowercased().contains(lower) ?? false)
        }
    }

    /// Day-ordered route segments rendered as polylines. The chosen
    /// `transportMode` (with `.auto` resolved per-leg) picks which
    /// cached polyline + minutes we surface; if no cached polyline is
    /// available for that leg + mode, we fall back through the other
    /// modes, and finally to a straight haversine line.
    ///
    /// `polylineCacheVersion` is read so SwiftUI re-evaluates this
    /// computed property after a server-seed completes.
    private var routeSegments: [TripRouteSegment] {
        _ = polylineCacheVersion  // dependency for SwiftUI invalidation
        let ordered = mapDisplayedPlaces.sorted { $0.sortOrder < $1.sortOrder }
        guard ordered.count >= 2 else { return [] }
        let svc = AppleTravelTimesService.shared
        var out: [TripRouteSegment] = []

        for i in 0 ..< ordered.count - 1 {
            let from = ordered[i]
            let to = ordered[i + 1]
            guard
                let fromLat = from.lat, let fromLng = from.lng,
                let toLat = to.lat, let toLng = to.lng
            else { continue }
            let fromCoord = CLLocationCoordinate2D(latitude: fromLat, longitude: fromLng)
            let toCoord = CLLocationCoordinate2D(latitude: toLat, longitude: toLng)
            let id = "\(from.id)→\(to.id)"

            // Per-leg color matches the day pin/dot color of the
            // *from* stop. Cross-day legs (rare — only when ordered
            // happens to span days) inherit the earlier day so the
            // visual handoff feels natural. Defaults to day 1 when
            // the place has no day mapping (shouldn't normally fire).
            let legDayNumber = dayNumberByDayId[from.itineraryDayId] ?? 1
            let legStrokeColor = UIColor(AppColors.dayColor(for: legDayNumber))

            // Look up the per-leg available modes so the auto resolver
            // never picks one we don't actually have data for.
            // Place_id keyed cache (preferred — shareable, server-backed)
            // unioned with the coord cache (legacy / manual trips).
            var availability: Set<AppleTravelTimesService.Mode> = []
            if let fromPid = from.googlePlaceId, let toPid = to.googlePlaceId {
                availability = svc.cachedAvailableModes(
                    fromPlaceId: fromPid, toPlaceId: toPid
                )
            }
            let coordAvailability = svc.cachedCoordAvailableModes(
                from: fromCoord, to: toCoord
            )
            availability.formUnion(coordAvailability)

            let preferred: AppleTravelTimesService.Mode = {
                if let concrete = transportMode.concreteMode {
                    return concrete
                }
                let dist: Double
                if let fromPid = from.googlePlaceId,
                   let toPid = to.googlePlaceId,
                   let cached = svc.cachedDistanceMetersForAnyScope(
                    fromPlaceId: fromPid, toPlaceId: toPid
                   ) {
                    dist = Double(cached)
                } else if let cached = svc.cachedCoordDistance(
                    from: fromCoord, to: toCoord
                ) {
                    dist = Double(cached)
                } else {
                    // Haversine in km → meters
                    dist = HaversineDistance.distance(from: fromCoord, to: toCoord) * 1_000
                }
                return TripTransportMode.resolveAuto(
                    distanceMeters: dist,
                    availability: availability
                )
            }()

            // 1. Place_id keyed (shared, server-cached) polyline.
            if let fromPid = from.googlePlaceId,
               let toPid = to.googlePlaceId,
               let (chosenMode, encoded) = pickCachedPolyline(
                fromPid: fromPid,
                toPid: toPid,
                preferred: preferred
               )
            {
                let coords = PolylineEncoder.decode(encoded)
                if coords.count >= 2 {
                    let minutes = svc.cachedMinutesForAnyScope(
                        fromPlaceId: fromPid,
                        toPlaceId: toPid,
                        mode: chosenMode
                    )
                    out.append(TripRouteSegment(
                        id: id,
                        coordinates: coords,
                        isApple: true,
                        mode: chosenMode,
                        minutes: minutes,
                        strokeColor: legStrokeColor
                    ))
                    continue
                }
            }

            // 2. Coordinate-keyed cache — covers legacy trips whose
            // places lack google place_ids. Falls back through modes
            // in the same priority order.
            if let (chosenMode, encoded) = pickCachedCoordPolyline(
                from: fromCoord, to: toCoord, preferred: preferred
            ) {
                let coords = PolylineEncoder.decode(encoded)
                if coords.count >= 2 {
                    let minutes = svc.cachedCoordMinutes(
                        from: fromCoord, to: toCoord, mode: chosenMode
                    )
                    out.append(TripRouteSegment(
                        id: id,
                        coordinates: coords,
                        isApple: true,
                        mode: chosenMode,
                        minutes: minutes,
                        strokeColor: legStrokeColor
                    ))
                    continue
                }
            }

            // 3. Haversine fallback. We still publish the *preferred*
            // mode so the renderer's dash pattern matches what the
            // user picked, even when we couldn't get a real polyline.
            out.append(TripRouteSegment(
                id: id,
                coordinates: [fromCoord, toCoord],
                isApple: false,
                mode: preferred,
                minutes: nil,
                strokeColor: legStrokeColor
            ))
        }
        return out
    }

    /// Pick the best cached polyline for a leg given the preferred
    /// mode. Falls back through the remaining modes in priority order
    /// (walking → driving → transit, with the preferred bumped first)
    /// so the user always sees a real route when *any* mode has one.
    private func pickCachedPolyline(
        fromPid: String,
        toPid: String,
        preferred: AppleTravelTimesService.Mode
    ) -> (AppleTravelTimesService.Mode, String)? {
        let svc = AppleTravelTimesService.shared
        let order = [preferred] + AppleTravelTimesService.Mode.allCases.filter { $0 != preferred }
        for mode in order {
            if let p = svc.cachedPolylineForAnyScope(
                fromPlaceId: fromPid,
                toPlaceId: toPid,
                mode: mode
            ) {
                return (mode, p)
            }
        }
        return nil
    }

    /// Coordinate-keyed counterpart of `pickCachedPolyline` — used for
    /// trips whose places don't carry `googlePlaceId` and therefore
    /// can't key into `city_travel_times`.
    private func pickCachedCoordPolyline(
        from: CLLocationCoordinate2D,
        to: CLLocationCoordinate2D,
        preferred: AppleTravelTimesService.Mode
    ) -> (AppleTravelTimesService.Mode, String)? {
        let svc = AppleTravelTimesService.shared
        let order = [preferred] + AppleTravelTimesService.Mode.allCases.filter { $0 != preferred }
        for mode in order {
            if let p = svc.cachedCoordPolyline(from: from, to: to, mode: mode) {
                return (mode, p)
            }
        }
        return nil
    }

    private var polylineStrokeColor: Color {
        if let filter = selectedDayFilter {
            return AppColors.dayColor(for: filter)
        }
        return AppColors.appPrimary
    }

    /// Center used when fitting the map; trip coordinates, otherwise equator.
    private var tripMapCenter: CLLocationCoordinate2D {
        CLLocationCoordinate2D(
            latitude: trip.lat ?? 0,
            longitude: trip.lng ?? 0
        )
    }

    // MARK: - Search bias / "effective search region"
    //
    // Search relevance dies when MapKit / city_places see a region span
    // that is too wide — Apple stops biasing and ranks globally, and
    // the city_places bbox stops filtering meaningfully. Pick a region
    // that's anchored to *something useful*:
    //
    //   1. The user's current viewport when they've zoomed in to a
    //      city / neighborhood scale (≤ ~55 km). This is the strongest
    //      signal — they're looking at exactly that area.
    //   2. Otherwise, the bbox of the selected day's places (if one
    //      day is selected) so day-specific searches stay focused.
    //   3. Otherwise, the bbox of all trip places.
    //   4. Otherwise, the trip's destination with a ~25 km city span.
    //   5. Worst case, the live viewport with the span clamped so we
    //      never go global.

    /// Span at which we consider the user "zoomed in enough" to trust
    /// their viewport as the search bias. ~55 km — comfortable city /
    /// neighborhood scale.
    private static let userFocusSpanThreshold: CLLocationDegrees = 0.5

    /// Largest span we will ever pass to MapKit / city_places. Anything
    /// wider and the result quality collapses.
    private static let maxBiasSpan: CLLocationDegrees = 0.5

    /// Region we should bias *new* searches with. See doc comment above.
    private var effectiveSearchRegion: MKCoordinateRegion {
        let viewport = searchRegion
        let viewportSpan = max(
            viewport.span.latitudeDelta,
            viewport.span.longitudeDelta
        )

        // 1. Strong user focus.
        if viewportSpan <= Self.userFocusSpanThreshold {
            return viewport
        }

        // 2. Selected day bbox.
        if let dayFilter = selectedDayFilter {
            let dayCoords = mappablePlaces
                .filter { dayNumberByDayId[$0.itineraryDayId] == dayFilter }
                .compactMap { Self.coordinate(from: $0) }
            if let region = Self.region(fromCoordinates: dayCoords, minSpan: 0.05) {
                return region
            }
        }

        // 3. Whole-trip bbox.
        let allCoords = mappablePlaces.compactMap { Self.coordinate(from: $0) }
        if let region = Self.region(fromCoordinates: allCoords, minSpan: 0.05) {
            return region
        }

        // 4. Trip destination (skip the equator fallback — if both
        // lat and lng are 0 we treat the trip as unanchored and fall
        // through to the clamped viewport).
        if let lat = trip.lat, let lng = trip.lng,
           !(lat == 0 && lng == 0)
        {
            return MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: lat, longitude: lng),
                span: MKCoordinateSpan(latitudeDelta: 0.25, longitudeDelta: 0.25)
            )
        }

        // 5. Worst case: clamp the viewport so MapKit never sees a
        // span big enough to fall back to global ranking.
        return Self.clampingSpan(viewport, max: Self.maxBiasSpan)
    }

    private static func coordinate(from place: Place) -> CLLocationCoordinate2D? {
        guard let lat = place.lat, let lng = place.lng else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lng)
    }

    /// Bounding-box region from a set of coordinates, padded ~30% on
    /// each side and floored to `minSpan` so a single coordinate or a
    /// tightly-clustered day still has enough breathing room for
    /// MapKit to rank against.
    private static func region(
        fromCoordinates coords: [CLLocationCoordinate2D],
        minSpan: CLLocationDegrees
    ) -> MKCoordinateRegion? {
        guard !coords.isEmpty else { return nil }
        let lats = coords.map(\.latitude)
        let lngs = coords.map(\.longitude)
        guard let minLat = lats.min(), let maxLat = lats.max(),
              let minLng = lngs.min(), let maxLng = lngs.max()
        else { return nil }

        let centerLat = (minLat + maxLat) / 2
        let centerLng = (minLng + maxLng) / 2
        let spanLat = max((maxLat - minLat) * 1.6, minSpan)
        let spanLng = max((maxLng - minLng) * 1.6, minSpan)
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: centerLat, longitude: centerLng),
            span: MKCoordinateSpan(latitudeDelta: spanLat, longitudeDelta: spanLng)
        )
    }

    private static func clampingSpan(
        _ region: MKCoordinateRegion,
        max maxSpan: CLLocationDegrees
    ) -> MKCoordinateRegion {
        let lat = min(region.span.latitudeDelta, maxSpan)
        let lng = min(region.span.longitudeDelta, maxSpan)
        return MKCoordinateRegion(
            center: region.center,
            span: MKCoordinateSpan(latitudeDelta: lat, longitudeDelta: lng)
        )
    }

    /// Live search annotations rendered by `TripMapKitView`. Sourced
    /// from `TripMapState`. The legacy `searchResultPin` stays as a
    /// fallback for callers that haven't migrated to the overlay (it
    /// is no longer wired internally).
    private var searchPreviewResults: [MapSearchPreview] {
        if !mapState.searchResults.isEmpty {
            return mapState.searchResults
        }
        guard let pin = searchResultPin else { return [] }
        return [
            MapSearchPreview(
                id: pin.id.uuidString,
                origin: .apple,
                name: pin.name,
                subtitle: "",
                coordinate: pin.coordinate,
                googlePlaceId: nil,
                phone: nil,
                website: nil,
                thumbnailURL: nil,
                category: nil
            ),
        ]
    }

    init(
        trip: Trip,
        searchText: Binding<String>? = nil,
        sharedState: MapTabSharedState? = nil
    ) {
        self.trip = trip
        self.externalSearchText = searchText
        self.sharedState = sharedState

        // Seed city profile from the trip row when already resolved (avoids
        // the async 3-tier resolver on every subsequent map open).
        _resolvedCityProfileId = State(initialValue: trip.cityProfileId)

        // Use stored coords when available; fall back to a globe-level view
        // so unanchored trips don't lock the camera to (0, 0).
        if let lat = trip.lat, let lng = trip.lng {
            _searchRegion = State(
                initialValue: MKCoordinateRegion(
                    center: CLLocationCoordinate2D(latitude: lat, longitude: lng),
                    span: MKCoordinateSpan(latitudeDelta: 0.6, longitudeDelta: 0.6)
                )
            )
        } else {
            _searchRegion = State(
                initialValue: MKCoordinateRegion(
                    center: CLLocationCoordinate2D(latitude: 20, longitude: 0),
                    span: MKCoordinateSpan(latitudeDelta: 120, longitudeDelta: 240)
                )
            )
        }

        // Trip-scoped AppStorage so each trip remembers its own mode.
        _transportModeRaw = AppStorage(
            wrappedValue: TripTransportMode.auto.rawValue,
            TripTransportMode.storageKey(forTripId: trip.id)
        )
    }

    /// Computed wrapper around the persisted raw value so call sites
    /// stay strongly typed. Reads/writes flow through `transportModeRaw`.
    private var transportMode: TripTransportMode {
        get { TripTransportMode(rawValue: transportModeRaw) ?? .auto }
        nonmutating set { transportModeRaw = newValue.rawValue }
    }

    private var selectedSearchResultBinding: Binding<MapSearchPreview?> {
        Binding(
            get: { mapState.selectedSearchResult },
            set: { mapState.selectedSearchResult = $0 }
        )
    }

    var body: some View {
        mapHandoffView
    }

    private var mapSearchableView: some View {
        mapRoot
            .safeAreaInset(edge: .bottom, spacing: 0) {
                mapPlacesMinimizedAccessory
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .tint(AppColors.appPrimary)
            .searchable(
                text: $tabSearchText,
                isPresented: $isTabSearchPresented,
                placement: .automatic,
                prompt: "Search places"
            )
            .onChange(of: isTabSearchPresented) { _, isPresented in
                // The Map tab uses `Tab(role: .search)`, so tapping the
                // tab-bar search button flips `isTabSearchPresented` to
                // true. We hand off to our richer custom overlay sheet
                // instead — but if we let SwiftUI animate the inline
                // `.searchable` expansion first, the user sees an
                // unwanted "searchable rises → sheet rises" transform.
                // Suppress the searchable's expansion animation so the
                // dismiss is invisible and the only motion the user
                // perceives is our overlay sheet sliding up.
                guard isPresented else { return }
                var t = Transaction()
                t.disablesAnimations = true
                withTransaction(t) {
                    isTabSearchPresented = false
                }
                hideMapPlacesSheet()
                showSearchOverlay = true
            }
    }

    private var mapDataLifecycleView: some View {
        mapSearchableView
            .task {
                await loadMapData()
                await resolveCityProfileId()
            }
            .onChange(of: places) { _, _ in
                if mapState.searchResults.isEmpty && mapState.selectedSearchResult == nil {
                    fitMapForCurrentMode()
                }
                syncToSharedState()
                recomputeExcludeSet()
                // Refresh polylines when places change (add/remove/reorder)
                // so the legs catch up without waiting for a re-launch.
                Task { await refreshPolylinesForCurrentPlaces() }
            }
            .onChange(of: selectedDayFilter) { _, _ in
                searchResultPin = nil
                fitMapForCurrentMode()
                sharedState?.selectedDayFilter = selectedDayFilter
            }
            .onChange(of: searchText) { _, newValue in
                externalSearchText?.wrappedValue = newValue

                if let active = activeCategoryFilter, newValue != active {
                    activeCategoryFilter = nil
                }

                if searchResultPin == nil {
                    fitMapForCurrentMode()
                }
            }
    }

    private var mapSharedStateView: some View {
        mapDataLifecycleView
            .onAppear {
                fitMapForCurrentMode()
                syncToSharedState()
            }
            .onChange(of: sharedState?.selectedDayFilter) { _, newVal in
                // `nil` is a meaningful value here ("All days" pill) — we
                // must propagate it back so tapping All in the bottom
                // accessory clears the local day filter. The previous
                // `if let` swallowed nils and the All pill stopped
                // working after the first day selection.
                if newVal != selectedDayFilter {
                    selectedDayFilter = newVal
                }
            }
            .onChange(of: sharedState?.showPlacesSheet) { _, newVal in
                if let newVal, newVal != showPlacesSheet {
                    showPlacesSheet = newVal
                }
            }
            .onChange(of: showPlacesSheet) { _, newVal in
                sharedState?.showPlacesSheet = newVal
            }
            .onChange(of: sharedState?.selectedPlaceToFocus) { _, place in
                if let place {
                    selectAndFocusPlace(place)
                    sharedState?.selectedPlaceToFocus = nil
                }
            }
            .onChange(of: selectedPlace) { oldPlace, newPlace in
                if newPlace != nil {
                    hideMapPlacesSheet()
                }
                if oldPlace != nil && newPlace == nil {
                    fitMapForCurrentMode()
                    restoreMapPlacesSheetSmall()
                }
            }
    }

    private var mapSheetsView: some View {
        mapSharedStateView
            .sheet(item: $selectedPlace, content: placeDetailSheet)
            .sheet(isPresented: $showMapModesSheet) {
                mapModesSheet
            }
            .sheet(isPresented: $showAddPlace) {
                addPlaceSheetContent
            }
            .sheet(isPresented: $showSearchOverlay) {
                searchOverlaySheet
            }
    }

    private var mapHandoffView: some View {
        mapSheetsView
            .onChange(of: showSearchOverlay) { _, isPresented in
                if isPresented {
                    hideMapPlacesSheet()
                } else if let preview = pendingSuggestedPlacesPreview {
                    pendingSuggestedPlacesPreview = nil
                    Task {
                        try? await Task.sleep(for: .milliseconds(350))
                        await MainActor.run {
                            presentSuggestedPlacesPreview(preview)
                        }
                    }
                } else {
                    restoreMapPlacesSheetSmallAfterTransition()
                }
            }
            .sheet(isPresented: $showSuggestedPlacesBrowser) {
                suggestedPlacesBrowserSheet
            }
            .sheet(item: selectedSearchResultBinding, content: searchPreviewSheet)
            .sheet(isPresented: $showAddToDay) {
                addToDaySheet
            }
            .onChange(of: showSuggestedPlacesBrowser) { _, isPresented in
                if isPresented {
                    hideMapPlacesSheet()
                    return
                }
                guard let preview = pendingSuggestedPlacesPreview else {
                    restoreMapPlacesSheetSmallAfterTransition()
                    return
                }
                pendingSuggestedPlacesPreview = nil
                Task {
                    try? await Task.sleep(for: .milliseconds(350))
                    await MainActor.run {
                        presentSuggestedPlacesPreview(preview)
                    }
                }
            }
            .onChange(of: mapState.selectedSearchResult) { _, newVal in
                // Single-sheet ownership: collapse the day sheet when a
                // search preview takes the bottom region. Restore on
                // dismiss.
                if newVal == nil && pendingAddToDayPresentation {
                    Task {
                        try? await Task.sleep(for: .milliseconds(350))
                        await MainActor.run {
                            guard pendingAddToDayPresentation, addToDayPreview != nil else { return }
                            pendingAddToDayPresentation = false
                            showAddToDay = true
                        }
                    }
                } else if newVal == nil && returnToSuggestedPlacesBrowser {
                    Task {
                        try? await Task.sleep(for: .milliseconds(350))
                        await MainActor.run {
                            guard returnToSuggestedPlacesBrowser else { return }
                            showSuggestedPlacesBrowser = true
                        }
                    }
                } else if newVal == nil && returnToSearchOverlay {
                    Task {
                        try? await Task.sleep(for: .milliseconds(350))
                        await MainActor.run {
                            guard returnToSearchOverlay else { return }
                            showSearchOverlay = true
                        }
                    }
                } else if newVal != nil && showPlacesSheet {
                    hideMapPlacesSheet()
                    searchPreviewDetent = .medium
                } else if newVal != nil {
                    hideMapPlacesSheet()
                    searchPreviewDetent = .medium
                } else {
                    restoreMapPlacesSheetSmallAfterTransition()
                }
            }
            .onChange(of: showAddToDay) { _, isPresented in
                if isPresented {
                    hideMapPlacesSheet()
                } else {
                    restoreMapPlacesSheetSmallAfterTransition()
                }
            }
    }

    private func placeDetailSheet(for place: Place) -> some View {
        let dayPlaces = places
            .filter { $0.itineraryDayId == place.itineraryDayId }
            .sorted { $0.sortOrder < $1.sortOrder }
        let prevPlace = dayPlaces.first { $0.sortOrder == place.sortOrder - 1 }

        return PlaceDetailSheet(
            place: place,
            previousPlace: prevPlace
        )
    }

    private var mapModesSheet: some View {
        TripMapModesSheet(selectedMode: $mapMode)
            .presentationDetents([.height(220), .medium])
            .presentationDragIndicator(.visible)
            .presentationBackground(.regularMaterial)
            .presentationBackgroundInteraction(.enabled)
    }

    private var searchOverlaySheet: some View {
        MapSearchOverlay(
            country: tripCountryGuess,
            initialQuery: tabSearchText,
            cityProfileId: resolvedCityProfileId,
            region: effectiveSearchRegion,
            excludedPlaceIds: mapState.scheduledDayPlaceIds,
            onPickResult: { preview in
                handleOverlayPicked(preview)
            },
            onPickSuggestedResult: { preview in
                handleSearchSheetSuggestedPicked(preview)
            },
            onPickSuggestedBrowserResult: { preview in
                handleSuggestedPlacesPicked(preview)
            },
            onPickCategory: { pill, results in
                handleCategoryResults(pill: pill, results: results)
            },
            onSubmitSearch: { query, results in
                handleSubmittedSearch(query: query, results: results)
            },
            onCancel: {
                showSearchOverlay = false
                returnToSearchOverlay = false
            }
        )
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(28)
        .presentationBackground(.regularMaterial)
    }

    private var suggestedPlacesBrowserSheet: some View {
        SuggestedPlacesAllSheet(
            cityProfileId: resolvedCityProfileId,
            excludedPlaceIds: mapState.scheduledDayPlaceIds
        ) { preview in
            pendingSuggestedPlacesPreview = preview
            showSuggestedPlacesBrowser = false
        } onCancel: {
            showSuggestedPlacesBrowser = false
            returnToSuggestedPlacesBrowser = false
            pendingSuggestedPlacesPreview = nil
        }
        .presentationDetents([.medium, .large])
        .presentationContentInteraction(.scrolls)
        .presentationDragIndicator(.visible)
        .presentationBackground(.regularMaterial)
    }

    private func searchPreviewSheet(for preview: MapSearchPreview) -> some View {
        MapSearchPreviewSheet(
            preview: preview,
            onAddToDay: {
                addToDayPreview = preview
                pendingAddToDayPresentation = true
                returnToSearchOverlay = false
                returnToSuggestedPlacesBrowser = false
                mapState.selectedSearchResult = nil
            },
            onSearchNearby: {
                runSearchNearby(around: preview.coordinate)
            },
            onDismiss: {
                mapState.selectedSearchResult = nil
            }
        )
        .presentationDetents([.height(180), .medium, .large], selection: $searchPreviewDetent)
        .presentationDragIndicator(.visible)
        .presentationBackgroundInteraction(.enabled(upThrough: .height(180)))
        .presentationBackground(.regularMaterial)
    }

    @ViewBuilder
    private var addToDaySheet: some View {
        if let preview = addToDayPreview {
            MapAddToDaySheet(
                preview: preview,
                scheduledDays: scheduledDays,
                preselectedDayId: scheduledDays.first(where: { dayNumberByDayId[$0.id] == selectedDayFilter })?.id,
                onSave: { dayId, startTime, notes in
                    persistAddToDay(
                        preview: preview,
                        dayId: dayId,
                        startTime: startTime,
                        notes: notes
                    )
                    showAddToDay = false
                    addToDayPreview = nil
                    pendingAddToDayPresentation = false
                    mapState.selectedSearchResult = nil
                },
                onCancel: {
                    showAddToDay = false
                    addToDayPreview = nil
                    pendingAddToDayPresentation = false
                }
            )
            .presentationDetents([.height(420), .large])
            .presentationDragIndicator(.visible)
            .presentationBackground(.regularMaterial)
        }
    }

    private var mapRoot: some View {
        // ZStack pattern (instead of `.overlay` chained after
        // `.ignoresSafeArea()`): the map fills edge-to-edge, but the
        // overlays (controls + "Search this area" pill) live in the
        // ZStack's safe-area-respecting bounds.
        ZStack(alignment: .bottom) {
            mapContent
                .ignoresSafeArea()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(
                    GeometryReader { geo in
                        Color.clear
                            .onAppear { mapContainerHeight = geo.size.height }
                            .onChange(of: geo.size.height) { _, h in mapContainerHeight = h }
                    }
                )
                .onChange(of: showPlacesSheet) { _, _ in
                    if searchResultPin == nil && mapState.searchResults.isEmpty {
                        fitMapForCurrentMode()
                    }
                }
                .overlay(alignment: .topTrailing) {
                    mapControlStack
                }

            searchThisAreaOverlay
                .padding(.bottom, AppSpacing.sm)
        }
    }

    @ViewBuilder
    private var mapPlacesMinimizedAccessory: some View {
        if shouldShowMapPlacesMinimizedAccessory {
            MapPlacesMinimizedAccessory(
                trip: trip,
                selectedDayFilter: Binding(
                    get: { selectedDayFilter },
                    set: { selectedDayFilter = $0 }
                ),
                allPlacesForList: mappablePlaces,
                onExpand: {
                    showPlacesSheet = true
                    sharedState?.showPlacesSheet = true
                }
            )
        }
    }

    private var shouldShowMapPlacesMinimizedAccessory: Bool {
        sharedState != nil
            && !showPlacesSheet
            && !showSearchOverlay
            && !showSuggestedPlacesBrowser
            && !showAddToDay
            && !showAddPlace
            && !showMapModesSheet
            && selectedPlace == nil
            && mapState.selectedSearchResult == nil
    }

    private func hideMapPlacesSheet() {
        showPlacesSheet = false
        sharedState?.showPlacesSheet = false
    }

    private func restoreMapPlacesSheetSmallAfterTransition() {
        Task {
            try? await Task.sleep(for: .milliseconds(350))
            await MainActor.run {
                restoreMapPlacesSheetSmall()
            }
        }
    }

    private func restoreMapPlacesSheetSmall() {
        // The minimized places control is now a safe-area accessory, not
        // a sheet detent. Keep the expanded sheet dismissed so the
        // accessory can reappear above the tab bar.
        sharedState?.showPlacesSheet = false
        showPlacesSheet = false
    }

    /// "Search this area" pill — appears once the user has panned past
    /// ~30% of the originating span after a category search.
    /// Positioned by the parent `ZStack(alignment: .bottom)` so it
    /// floats above the map while the native places sheet owns bottom chrome.
    @ViewBuilder
    private var searchThisAreaOverlay: some View {
        if shouldShowSearchThisArea {
            Button {
                HapticManager.light()
                rerunCategoryInCurrentRegion()
            } label: {
                Label("Search this area", systemImage: "arrow.clockwise.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .padding(.vertical, 10)
                    .padding(.horizontal, 16)
                    .background(.regularMaterial)
                    .clipShape(Capsule())
                    .shadow(color: .black.opacity(0.18), radius: 6, x: 0, y: 3)
                    .foregroundStyle(AppColors.appPrimary)
            }
            .buttonStyle(.plain)
            .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .bottom)))
            .accessibilityLabel("Search this area")
            .accessibilityHint("Re-runs the last search in the current map region")
            .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        }
    }

    private var shouldShowSearchThisArea: Bool {
        guard !mapState.searchResults.isEmpty,
              let origin = mapState.searchOriginRegion,
              let query = lastSubmittedMapSearchQuery?.trimmingCharacters(in: .whitespacesAndNewlines),
              !query.isEmpty
        else { return false }
        let dLat = abs(searchRegion.center.latitude - origin.center.latitude)
        let dLng = abs(searchRegion.center.longitude - origin.center.longitude)
        let drift = max(
            dLat / max(origin.span.latitudeDelta, 0.001),
            dLng / max(origin.span.longitudeDelta, 0.001)
        )
        return drift > 0.3
    }

    @ViewBuilder
    private var addPlaceSheetContent: some View {
        AddPlaceView(
            selectedDayNumber: scheduledDays.first?.dayNumber ?? 1,
            days: scheduledDays,
            wishlistPlaces: wishlistPlaces,
            onAddPlace: addPlaceCompletion
        )
    }

    private func addPlaceCompletion(placeName: String, dayNumber: Int) {
        guard let targetDay = scheduledDays.first(where: { $0.dayNumber == dayNumber }) else { return }

        let existingCount = places.filter { $0.itineraryDayId == targetDay.id }.count

        let newPlace = Place(
            id: UUID(),
            itineraryDayId: targetDay.id,
            name: placeName,
            address: nil,
            lat: nil,
            lng: nil,
            category: PlaceCategory.attraction.rawValue,
            notes: nil,
            sortOrder: existingCount,
            startTime: nil,
            endTime: nil,
            isBooking: false,
            bookingType: nil,
            confirmationNumber: nil,
            bookingDetails: nil
        )

        Task {
            await dataService.addPlace(newPlace)
            await loadMapData()
        }

        HapticManager.success()
        showAddPlace = false
    }

    private func syncToSharedState() {
        guard let sharedState else { return }
        sharedState.mappablePlaces = mappablePlaces
        sharedState.dayNumberByDayId = dayNumberByDayId
        sharedState.selectedDayFilter = selectedDayFilter
    }

    private var currentMapKitConfiguration: TripMapKitConfiguration {
        switch mapMode {
        case .hybrid: return .hybrid
        case .map: return .standard
        }
    }

    private var mapContent: some View {
        TripMapKitView(
            tripPlaces: mapDisplayedPlaces,
            dayNumberByDayId: dayNumberByDayId,
            routeSegments: routeSegments,
            routeStrokeColor: polylineStrokeColor,
            searchResults: searchPreviewResults,
            cameraTarget: cameraTarget,
            configuration: currentMapKitConfiguration,
            reduceMotion: reduceMotion,
            onTapTripPlace: { place in
                HapticManager.light()
                selectedPlace = place
            },
            onTapSearchResult: { preview in
                handleSearchResultTapped(preview)
            },
            onCameraIdle: { region in
                searchRegion = region
            },
            onTapCluster: { cluster in
                handleClusterTapped(cluster)
            }
        )
        .accessibilityLabel("Map of places for \(trip.title)")
    }

    /// Compact vertical pill — right edge, just below the navigation bar.
    private var mapControlStack: some View {
        VStack(spacing: 0) {
            Button {
                HapticManager.light()
                centerOnUserLocation()
            } label: {
                Image(systemName: "location.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(AppColors.appPrimary)
                    .frame(width: 44, height: 40)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Current location")

            Color(UIColor.separator)
                .frame(width: 26, height: 0.5)

            Button {
                HapticManager.light()
                showMapModesSheet = true
            } label: {
                Image(systemName: mapMode == .hybrid ? "globe.americas.fill" : "map")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 44, height: 40)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Map style")

            Color(UIColor.separator)
                .frame(width: 26, height: 0.5)

            Button {
                HapticManager.light()
                showTransportPicker = true
            } label: {
                Image(systemName: transportMode.sfSymbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 44, height: 40)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Transport mode")
            .accessibilityValue(transportMode.displayName)
            .accessibilityHint("Changes how routes between stops are drawn")
            .confirmationDialog(
                "Route style",
                isPresented: $showTransportPicker,
                titleVisibility: .visible
            ) {
                ForEach(TripTransportMode.allCases) { mode in
                    Button {
                        HapticManager.selection()
                        transportMode = mode
                        polylineCacheVersion &+= 1
                    } label: {
                        Text("\(mode.displayName)\(transportMode == mode ? "  ✓" : "")")
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(transportMode.pickerSubtitle)
            }
        }
        .fixedSize()
        .background(.regularMaterial)
        .clipShape(Capsule())
        .shadow(color: .black.opacity(0.18), radius: 6, x: 0, y: 3)
        .padding(.top, KeyWindowSafeArea.topInset + 52)
        .padding(.trailing, AppSpacing.sm)
    }

    // MARK: - Search result selected from autocomplete

    func handleSearchResultSelected(_ name: String, lat: Double, lng: Double) {
        let pin = MapSearchPin(name: name, coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lng))
        searchResultPin = pin

        // ~600m radius — close enough to read the streets, far enough to see
        // surrounding context like the nearest metro stop.
        cameraTargetCounter += 1
        cameraTarget = TripMapCameraTarget(
            id: cameraTargetCounter,
            kind: .center(
                pin.coordinate,
                latMeters: 600,
                lngMeters: 600,
                padding: bottomSheetEdgePadding()
            ),
            animated: true
        )

        HapticManager.light()
    }

    private func loadMapData() async {
        let days = await dataService.fetchDays(for: trip.id)
        let sorted = days.sorted { $0.dayNumber < $1.dayNumber }

        scheduledDays = sorted.filter { !$0.isWishlist }
        wishlistDayIds = Set(sorted.filter(\.isWishlist).map(\.id))

        var idToDay: [UUID: Int] = [:]
        for day in days {
            idToDay[day.id] = day.dayNumber
        }
        dayNumberByDayId = idToDay

        var collected: [Place] = []
        var wishlist: [Place] = []

        for day in sorted {
            let dayPlaces = await dataService.fetchPlaces(for: day.id)
            collected.append(contentsOf: dayPlaces)

            if day.isWishlist {
                wishlist = dayPlaces
            }
        }

        places = collected
        wishlistPlaces = wishlist

        // Polylines: hydrate the in-memory cache from `city_travel_times`
        // so the map renders real Apple-routed lines on first open
        // (the cache used to only get populated by AI plan apply).
        Task { await refreshPolylinesForCurrentPlaces() }
    }

    /// Hydrate cached polylines for the trip's current place pairs.
    ///
    /// Phases:
    ///   1. Server seed — pulls existing rows from `city_travel_times`
    ///      (free; needs google place_ids on both ends).
    ///   2. Place_id warm — runs `MKDirections` for legs the seed
    ///      didn't cover, then uploads (Phase J.3 / Phase J.4 path).
    ///   3. Coord warm — last-ditch fallback for legs whose places
    ///      don't have a google place_id (legacy / manually-added /
    ///      AI-generated-without-enrichment trips). Computes via
    ///      `MKDirections` but does NOT upload (no key to write under).
    ///
    /// Bumps `polylineCacheVersion` after each phase / leg so SwiftUI
    /// recomputes `routeSegments` and the renderer redraws.
    private func refreshPolylinesForCurrentPlaces() async {
        let placeIdPairs = consecutivePlaceIdPairs()
        let coordPairs = consecutiveCoordinatePairs()

        // Phase 1 — server seed. Needs both Supabase client + the
        // resolved city_profile. Skip silently if we don't have one
        // (mock mode, unresolved city) — the warm phase still helps.
        if !placeIdPairs.isEmpty,
           let cityId = await ensureCityProfileResolved(),
           let client = AuthSessionService.shared.client {
            await AppleTravelTimesService.shared.seedFromServer(
                cityProfileId: cityId,
                placeIdPairs: placeIdPairs,
                using: client
            )
            await MainActor.run { polylineCacheVersion &+= 1 }
        }

        // Phase 2 — opportunistic warm. Only fires for pairs still
        // missing every mode after the seed (the service double-checks).
        if !placeIdPairs.isEmpty, let cityId = resolvedCityProfileId {
            let legs: [AppleTravelTimesService.LegRequest] = placeIdPairs.compactMap { pair in
                guard let from = places.first(where: { $0.googlePlaceId == pair.from }),
                      let to = places.first(where: { $0.googlePlaceId == pair.to }),
                      let fromLat = from.lat, let fromLng = from.lng,
                      let toLat = to.lat, let toLng = to.lng
                else { return nil }
                return AppleTravelTimesService.LegRequest(
                    fromPlaceId: pair.from,
                    fromCoordinate: CLLocationCoordinate2D(latitude: fromLat, longitude: fromLng),
                    toPlaceId: pair.to,
                    toCoordinate: CLLocationCoordinate2D(latitude: toLat, longitude: toLng)
                )
            }
            AppleTravelTimesService.shared.enqueueIfMissing(
                tripId: trip.id,
                cityProfileId: cityId,
                legs: legs
            )
        }

        // Phase 3 — coordinate-keyed warm. Walks every consecutive
        // pair (regardless of place_id) and asks the service to
        // compute via MKDirections. The service short-circuits when
        // the pair is already cached or in flight, so this is cheap
        // to call on every map load.
        //
        // We process serially so MapKit's own throttle never trips,
        // and bump the cache version after each so polylines appear
        // incrementally — first leg paints in ≈ 1 s.
        guard !coordPairs.isEmpty else { return }
        let svc = AppleTravelTimesService.shared
        let cap = 30  // generous; most trips have ≤ 20 ordered stops
        for pair in coordPairs.prefix(cap) {
            // Skip legs already covered by the place_id cache to avoid
            // duplicate compute — the renderer prefers that path.
            if let p = pair.placeIds,
               !svc.cachedAvailableModes(
                fromPlaceId: p.from, toPlaceId: p.to
               ).isEmpty {
                continue
            }
            let landed = await svc.computeAndCacheCoordLeg(
                from: pair.from, to: pair.to
            )
            if landed {
                await MainActor.run { polylineCacheVersion &+= 1 }
            }
        }
    }

    /// Day-ordered (from, to) place_id pairs for legs we want polylines
    /// on. Skips legs missing a place_id on either end — the cache
    /// keys on Google place_ids and a missing one means we can't look
    /// the row up server-side.
    private func consecutivePlaceIdPairs() -> [(from: String, to: String)] {
        let ordered = mappablePlaces.sorted { $0.sortOrder < $1.sortOrder }
        var out: [(String, String)] = []
        for i in 0 ..< max(0, ordered.count - 1) {
            let from = ordered[i]
            let to = ordered[i + 1]
            guard let f = from.googlePlaceId, !f.isEmpty,
                  let t = to.googlePlaceId, !t.isEmpty
            else { continue }
            out.append((f, t))
        }
        return out
    }

    /// Day-ordered consecutive (from, to) coordinate pairs for every
    /// leg with valid lat/lng — independent of `googlePlaceId`. Used
    /// by the coord-warm fallback so legacy trips still get
    /// polylines.
    ///
    /// `placeIds` is populated when both ends carry a `googlePlaceId`
    /// so the warm step can skip pairs already covered by the
    /// place_id-keyed cache (cheaper, server-shared).
    private func consecutiveCoordinatePairs() -> [(
        from: CLLocationCoordinate2D,
        to: CLLocationCoordinate2D,
        placeIds: (from: String, to: String)?
    )] {
        let ordered = mappablePlaces.sorted { $0.sortOrder < $1.sortOrder }
        var out: [(
            from: CLLocationCoordinate2D,
            to: CLLocationCoordinate2D,
            placeIds: (from: String, to: String)?
        )] = []
        for i in 0 ..< max(0, ordered.count - 1) {
            let from = ordered[i]
            let to = ordered[i + 1]
            guard let fromLat = from.lat, let fromLng = from.lng,
                  let toLat = to.lat, let toLng = to.lng
            else { continue }
            let pids: (String, String)?
            if let f = from.googlePlaceId, !f.isEmpty,
               let t = to.googlePlaceId, !t.isEmpty {
                pids = (f, t)
            } else {
                pids = nil
            }
            out.append((
                CLLocationCoordinate2D(latitude: fromLat, longitude: fromLng),
                CLLocationCoordinate2D(latitude: toLat, longitude: toLng),
                pids
            ))
        }
        return out
    }

    /// Returns the resolved `city_profile_id`, resolving it on demand
    /// if the original `.task` hasn't completed yet. Used by the
    /// polyline refresh path which races the trip-load.
    private func ensureCityProfileResolved() async -> UUID? {
        if let id = resolvedCityProfileId { return id }
        // Fall back to the async resolver — result will be persisted by
        // resolveCityProfileId() if that task hasn't fired yet.
        guard let id = await dataService.resolveCityProfileId(forTrip: trip) else { return nil }
        await MainActor.run { resolvedCityProfileId = id }
        return id
    }

    /// Centers the camera on the user's current location with the same edge
    /// insets we use for trip-fit so the bottom sheet doesn't cover them.
    private func centerOnUserLocation() {
        // We don't have a synchronous CLLocation handle here; let MapKit
        // figure it out by re-fitting around the user-location annotation
        // on the next idle. For now, keep parity with the prior behavior
        // (which used `.userLocation(fallback: .automatic)`) by simply
        // re-fitting to current annotations — MKMapView already has the
        // user blue dot so showsUserLocation reveals it.
        fitMapForCurrentMode()
    }

    // MARK: - Camera framing

    private func fitMapForCurrentMode() {
        let coords = mapDisplayedPlaces.compactMap { p -> CLLocationCoordinate2D? in
            guard let lat = p.lat, let lng = p.lng else { return nil }
            return CLLocationCoordinate2D(latitude: lat, longitude: lng)
        }
        let padding = bottomSheetEdgePadding()
        cameraTargetCounter += 1
        if coords.isEmpty {
            cameraTarget = TripMapCameraTarget(
                id: cameraTargetCounter,
                kind: .globe(tripMapCenter),
                animated: true
            )
        } else if coords.count == 1, let only = coords.first {
            cameraTarget = TripMapCameraTarget(
                id: cameraTargetCounter,
                kind: .center(only, latMeters: 1_200, lngMeters: 1_200, padding: padding),
                animated: true
            )
        } else {
            cameraTarget = TripMapCameraTarget(
                id: cameraTargetCounter,
                kind: .fit(coordinates: coords, padding: padding),
                animated: true
            )
        }
    }

    /// Pans so the selected pin appears centered in the visible region above
    /// the sheet, then opens the detail sheet after the animation settles.
    private func selectAndFocusPlace(_ place: Place) {
        searchResultPin = nil

        guard let lat = place.lat, let lng = place.lng else {
            selectedPlace = place
            return
        }

        cameraTargetCounter += 1
        cameraTarget = TripMapCameraTarget(
            id: cameraTargetCounter,
            kind: .center(
                CLLocationCoordinate2D(latitude: lat, longitude: lng),
                latMeters: 800,
                lngMeters: 800,
                padding: bottomSheetEdgePadding()
            ),
            animated: true
        )

        // Open detail after the pan animation completes
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            selectedPlace = place
        }
    }

    /// MapKit-friendly insets so the visible region (the area `setVisibleMapRect`
    /// uses to size the camera) excludes the bottom sheet. Pass these to
    /// `setVisibleMapRect(_:edgePadding:animated:)` instead of subtracting an
    /// offset from the center coordinate.
    private func bottomSheetEdgePadding() -> UIEdgeInsets {
        let height = max(mapContainerHeight, UIScreen.main.bounds.height)
        // The active sheet — preview takes priority because it is the
        // "single sheet" when a search result is selected.
        let bottomCovered: CGFloat
        if mapState.selectedSearchResult != nil {
            bottomCovered = height * 0.30
        } else if showPlacesSheet {
            bottomCovered = height * 0.5
        } else {
            bottomCovered = 120
        }
        // 80pt top inset keeps pins clear of the floating search pill;
        // 24pt side gutters mirror Apple Maps' fit insets on iPhone.
        return UIEdgeInsets(top: 80, left: 24, bottom: bottomCovered + 16, right: 24)
    }

    // MARK: - Map Search Redesign helpers (Phase 3+)

    /// Best-effort ISO-3166 alpha-2 country code for the trip
    /// destination. We don't store it on the Trip row yet, so we fall
    /// back to the device's locale region. This drives the
    /// FeatureFlagsService routing (China vs the rest of the world).
    private var tripCountryGuess: String? {
        Locale.current.region?.identifier
    }

    /// Maintain the trip's exclude set so city_places search never
    /// re-suggests a place already on a scheduled day.
    private func recomputeExcludeSet() {
        // Use ALL places, then remove wishlist day ids. This excludes
        // places already scheduled on the itinerary while still allowing
        // wishlist ideas to appear as suggestions.
        mapState.recomputeScheduledDayPlaceIds(
            from: places,
            wishlistDayIds: wishlistDayIds
        )
    }

    /// Resolve city_profiles.id from the trip's destination so city_places
    /// searches can scope to the trip's city.
    ///
    /// Short-circuits when the trip row already carries a city_profile_id
    /// (populated by the DB migration backfill or a previous session).
    /// When resolution succeeds for the first time the result is persisted
    /// back to the trips row so future sessions skip this call entirely.
    private func resolveCityProfileId() async {
        // Fast path: already seeded from the trip row in init.
        if resolvedCityProfileId != nil { return }

        guard let id = await dataService.resolveCityProfileId(forTrip: trip) else { return }
        await MainActor.run { resolvedCityProfileId = id }

        // Persist so the next map open reads it from the DB directly.
        // Fire-and-forget — map functionality is unaffected by the write.
        if let coords = await dataService.fetchCityProfileCenterCoords(id: id) {
            await dataService.patchTripCityProfile(
                tripId: trip.id,
                cityProfileId: id,
                lat: coords.lat,
                lng: coords.lng
            )
        }
    }

    private func handleOverlayPicked(_ preview: MapSearchPreview) {
        returnToSearchOverlay = false
        returnToSuggestedPlacesBrowser = false
        lastPickedCategory = nil
        lastSubmittedMapSearchQuery = nil
        showSearchOverlay = false
        mapState.searchResults = [preview]
        mapState.searchOriginRegion = searchRegion
        mapState.selectedSearchResult = preview
        focusCamera(on: preview.coordinate, distance: 600)
    }

    private func handleSearchSheetSuggestedPicked(_ preview: MapSearchPreview) {
        returnToSearchOverlay = true
        returnToSuggestedPlacesBrowser = false
        pendingSuggestedPlacesPreview = preview
        showSearchOverlay = false
    }

    private func handleSuggestedPlacesPicked(_ preview: MapSearchPreview) {
        returnToSearchOverlay = false
        returnToSuggestedPlacesBrowser = true
        pendingSuggestedPlacesPreview = preview
        showSearchOverlay = false
    }

    private func presentSuggestedPlacesPreview(_ preview: MapSearchPreview) {
        mapState.searchResults = [preview]
        mapState.searchOriginRegion = searchRegion
        mapState.selectedSearchResult = preview
        focusCamera(on: preview.coordinate, distance: 600)
    }

    private func handleCategoryResults(pill: CategoryPill, results: [MapSearchPreview]) {
        showSearchOverlay = false
        tabSearchText = pill.label
        returnToSearchOverlay = false
        returnToSuggestedPlacesBrowser = false
        lastPickedCategory = pill
        lastSubmittedMapSearchQuery = nil
        lastCategoryRegion = searchRegion
        mapState.searchResults = results
        mapState.searchOriginRegion = searchRegion
        mapState.selectedSearchResult = nil

        // Fit camera around all results so the cluster bubble lands
        // somewhere sensible.
        if !results.isEmpty {
            let coords = results.map { $0.coordinate }
            cameraTargetCounter += 1
            cameraTarget = TripMapCameraTarget(
                id: cameraTargetCounter,
                kind: .fit(coordinates: coords, padding: bottomSheetEdgePadding()),
                animated: !reduceMotion
            )
        }
    }

    /// Full-screen search submit path. The keyboard Search button gets the
    /// search surface and bottom chrome out of the way, then renders the query
    /// as exploratory map pins.
    private func handleSubmittedSearch(query: String, results: [MapSearchPreview]) {
        showSearchOverlay = false
        tabSearchText = query
        showPlacesSheet = false
        sharedState?.showPlacesSheet = false
        mapState.selectedSearchResult = nil
        returnToSearchOverlay = false
        returnToSuggestedPlacesBrowser = false
        selectedPlace = nil

        // Stamp the region we actually biased the query against so
        // "Search this area" can detect when the user has drifted away
        // from the original search center.
        let originRegion = effectiveSearchRegion
        lastPickedCategory = nil
        lastSubmittedMapSearchQuery = query
        lastCategoryRegion = originRegion
        mapState.searchResults = results
        mapState.searchOriginRegion = originRegion

        if !results.isEmpty {
            cameraTargetCounter += 1
            cameraTarget = TripMapCameraTarget(
                id: cameraTargetCounter,
                kind: .fit(coordinates: results.map(\.coordinate), padding: bottomSheetEdgePadding()),
                animated: !reduceMotion
            )
        }
    }

    private func handleSearchResultTapped(_ preview: MapSearchPreview) {
        returnToSearchOverlay = false
        returnToSuggestedPlacesBrowser = false
        mapState.selectedSearchResult = preview
        focusCamera(on: preview.coordinate, distance: 600)
    }

    private func handleClusterTapped(_ cluster: MKClusterAnnotation) {
        let coords = cluster.memberAnnotations.map { $0.coordinate }
        guard coords.count >= 2 else { return }
        cameraTargetCounter += 1
        cameraTarget = TripMapCameraTarget(
            id: cameraTargetCounter,
            kind: .fit(coordinates: coords, padding: bottomSheetEdgePadding()),
            animated: !reduceMotion
        )
    }

    private func focusCamera(on coord: CLLocationCoordinate2D, distance: Double) {
        cameraTargetCounter += 1
        cameraTarget = TripMapCameraTarget(
            id: cameraTargetCounter,
            kind: .center(
                coord,
                latMeters: distance,
                lngMeters: distance,
                padding: bottomSheetEdgePadding()
            ),
            animated: !reduceMotion
        )
    }

    private func clearSearchResults() {
        mapState.searchResults = []
        mapState.selectedSearchResult = nil
        mapState.searchOriginRegion = nil
        searchResultPin = nil
        lastPickedCategory = nil
        lastSubmittedMapSearchQuery = nil
        tabSearchText = ""
        lastCategoryRegion = nil
        returnToSearchOverlay = false
        returnToSuggestedPlacesBrowser = false
        fitMapForCurrentMode()
    }

    /// Re-runs the most recent category search in the current viewport
    /// so the user sees fresh results after panning to a new area.
    private func rerunCategoryInCurrentRegion() {
        guard let submittedQuery = lastSubmittedMapSearchQuery?.trimmingCharacters(in: .whitespacesAndNewlines),
              !submittedQuery.isEmpty
        else { return }
        let pill = lastPickedCategory
        let category = pill?.matchingPlaceCategory
        let cityId = resolvedCityProfileId
        // The user explicitly chose to refresh the *visible* region,
        // but cap the span so an overly-zoomed-out viewport doesn't
        // turn into a global search.
        let region = Self.clampingSpan(searchRegion, max: Self.maxBiasSpan)
        let excluded = mapState.scheduledDayPlaceIds
        let q = pill?.id ?? submittedQuery
        Task {
            let apple = AppleMapSearchService()
            async let appleResults = apple.searchNearbyPreviews(
                query: q,
                in: region,
                resultLimit: 18
            )
            async let dbResults = CityPlacesSearchService.shared.search(
                cityProfileId: cityId,
                query: category == nil ? q : nil,
                category: category,
                region: region,
                excluding: excluded,
                limit: 18
            )
            let (a, d) = await (appleResults, dbResults)
            let merged = MapSearchResultMerger.merge(apple: a, db: d, limit: 24)
            await MainActor.run {
                mapState.searchResults = merged
                mapState.searchOriginRegion = region
            }
        }
    }

    /// "Search nearby" from the preview sheet — refire the category
    /// (or a generic "places" search if no category was active) in a
    /// region centered on the tapped preview.
    private func runSearchNearby(around coord: CLLocationCoordinate2D) {
        let span = MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)
        let region = MKCoordinateRegion(center: coord, span: span)
        let pill = lastPickedCategory
        let category = pill?.matchingPlaceCategory
        let cityId = resolvedCityProfileId
        let excluded = mapState.scheduledDayPlaceIds
        let q = pill?.id ?? lastSubmittedMapSearchQuery ?? "places"
        Task {
            let apple = AppleMapSearchService()
            async let appleResults = apple.searchNearbyPreviews(
                query: q,
                in: region,
                resultLimit: 18
            )
            async let dbResults = CityPlacesSearchService.shared.search(
                cityProfileId: cityId,
                query: nil,
                category: category,
                region: region,
                excluding: excluded,
                limit: 18
            )
            let (a, d) = await (appleResults, dbResults)
            let merged = MapSearchResultMerger.merge(apple: a, db: d, limit: 24)
            await MainActor.run {
                mapState.selectedSearchResult = nil
                mapState.searchResults = merged
                mapState.searchOriginRegion = region
                cameraTargetCounter += 1
                cameraTarget = TripMapCameraTarget(
                    id: cameraTargetCounter,
                    kind: .fit(coordinates: merged.map(\.coordinate), padding: bottomSheetEdgePadding()),
                    animated: !reduceMotion
                )
            }
        }
    }

    /// Persist Add-to-Day from the preview sheet. Owns:
    ///  • Building a `Place` from the preview.
    ///  • Calling `dataService.addPlace`.
    ///  • Removing the search annotation for that coordinate so the new
    ///    trip pin doesn't visually duplicate.
    ///  • Firing the background bridge **only** when the preview origin
    ///    is `.apple` AND we don't already have a place_id. DB-sourced
    ///    previews skip the bridge entirely.
    private func persistAddToDay(
        preview: MapSearchPreview,
        dayId: UUID,
        startTime: Date?,
        notes: String?
    ) {
        let existingCount = places.filter { $0.itineraryDayId == dayId }.count
        let place = Place(
            id: UUID(),
            itineraryDayId: dayId,
            name: preview.name,
            address: preview.subtitle.isEmpty ? nil : preview.subtitle,
            lat: preview.coordinate.latitude,
            lng: preview.coordinate.longitude,
            category: (preview.category ?? .attraction).rawValue,
            notes: notes,
            sortOrder: existingCount,
            startTime: startTime,
            endTime: nil,
            isBooking: false,
            bookingType: nil,
            confirmationNumber: nil,
            bookingDetails: nil,
            googlePlaceId: preview.googlePlaceId
        )

        Task {
            await dataService.addPlace(place)

            // Bridge gating — only Apple-origin previews without a
            // pre-bound place_id need the bridge.
            if preview.origin == .apple && (preview.googlePlaceId == nil || preview.googlePlaceId?.isEmpty == true) {
                Task.detached(priority: .utility) {
                    do {
                        let bridge = await PlaceIdBridgeService()
                        let resolution = try await bridge.resolve(
                            name: preview.name,
                            lat: preview.coordinate.latitude,
                            lng: preview.coordinate.longitude,
                            cityProfileId: await MainActor.run { resolvedCityProfileId }
                        )
                        if case .single(let candidate) = resolution {
                            var updated = place
                            updated.googlePlaceId = candidate.placeId
                            await dataService.updatePlace(updated)
                            await MainActor.run {
                                PlatformUsageTelemetry.mapSearch(.bridgeResolved, origin: .apple)
                            }
                        }
                    } catch {
                        // Best-effort: a missing place_id just means the
                        // detail sheet renders without enrichment.
                    }
                }
            } else {
                PlatformUsageTelemetry.mapSearch(.bridgeSkippedOwnedRow, origin: preview.origin)
            }

            await loadMapData()

            await MainActor.run {
                // Drop the matching search annotation so we don't show a
                // ghost search pin next to the freshly-added trip pin.
                mapState.searchResults.removeAll { $0.id == preview.id }
                HapticManager.success()
            }
        }
    }
}

// MARK: - CategoryPill → PlaceCategory mirror
//
// The same mapping lives privately inside `MapSearchOverlay`. Mirrored
// here so `TripMapView` can re-run searches without depending on the
// overlay being on screen.

private extension CategoryPill {
    var matchingPlaceCategory: PlaceCategory? {
        switch id {
        case "attractions", "museums": return .attraction
        case "restaurants", "cafes":   return .restaurant
        case "parks":                  return .nature
        case "shopping":               return .shopping
        case "nightlife":              return .nightlife
        default:                       return nil
        }
    }
}

// =============================================================================
