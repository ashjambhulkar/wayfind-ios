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
    @State private var resolvedCityProfileId: UUID?
    @State private var lastCategoryRegion: MKCoordinateRegion?
    @State private var lastPickedCategory: CategoryPill?
    @State private var lastSubmittedMapSearchQuery: String?
    @State private var tabSearchText = ""
    @State private var isTabSearchPresented = false

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

    private var routeSegments: [TripRouteSegment] {
        let ordered = mapDisplayedPlaces.sorted { $0.sortOrder < $1.sortOrder }
        guard ordered.count >= 2 else { return [] }
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

            // Prefer the Apple-cached polyline (walking is the most useful
            // when the user is exploring the map). Falls back to driving
            // and transit before giving up to a straight haversine line.
            if let fromPid = from.googlePlaceId,
               let toPid = to.googlePlaceId,
               let encoded = bestCachedPolyline(fromPid: fromPid, toPid: toPid) {
                let coords = PolylineEncoder.decode(encoded)
                if coords.count >= 2 {
                    out.append(TripRouteSegment(id: id, coordinates: coords, isApple: true))
                    continue
                }
            }

            out.append(TripRouteSegment(
                id: id,
                coordinates: [fromCoord, toCoord],
                isApple: false
            ))
        }
        return out
    }

    private func bestCachedPolyline(
        fromPid: String,
        toPid: String
    ) -> String? {
        let svc = AppleTravelTimesService.shared
        for mode in [AppleTravelTimesService.Mode.walking, .driving, .transit] {
            if let p = svc.cachedPolylineForAnyScope(
                fromPlaceId: fromPid,
                toPlaceId: toPid,
                mode: mode
            ) {
                return p
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

        let center = CLLocationCoordinate2D(
            latitude: trip.lat ?? 0,
            longitude: trip.lng ?? 0
        )

        _searchRegion = State(
            initialValue: MKCoordinateRegion(
                center: center,
                span: MKCoordinateSpan(latitudeDelta: 0.6, longitudeDelta: 0.6)
            )
        )
    }

    var body: some View {
        mapRoot
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
                guard isPresented else { return }
                isTabSearchPresented = false
                tabSearchText = ""
                showSearchOverlay = true
            }
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
            .onAppear {
                fitMapForCurrentMode()
                syncToSharedState()
            }
            .onChange(of: sharedState?.selectedDayFilter) { _, newVal in
                if let newVal, newVal != selectedDayFilter {
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
                if oldPlace != nil && newPlace == nil {
                    fitMapForCurrentMode()
                }
            }
            .sheet(item: $selectedPlace) { place in
                let dayPlaces = places
                    .filter { $0.itineraryDayId == place.itineraryDayId }
                    .sorted { $0.sortOrder < $1.sortOrder }
                let prevPlace = dayPlaces.first(where: { $0.sortOrder == place.sortOrder - 1 })

                PlaceDetailSheet(
                    place: place,
                    previousPlace: prevPlace
                )
            }
            .sheet(isPresented: $showMapModesSheet) {
                TripMapModesSheet(selectedMode: $mapMode)
                    .presentationDetents([.height(220), .medium])
                    .presentationDragIndicator(.visible)
                    .presentationBackground(.regularMaterial)
                    .presentationBackgroundInteraction(.enabled)
            }
            .sheet(isPresented: $showAddPlace) {
                addPlaceSheetContent
            }
            .fullScreenCover(isPresented: $showSearchOverlay) {
                MapSearchOverlay(
                    country: tripCountryGuess,
                    cityProfileId: resolvedCityProfileId,
                    region: searchRegion,
                    excludedPlaceIds: mapState.scheduledDayPlaceIds,
                    onPickResult: { preview in
                        handleOverlayPicked(preview)
                    },
                    onPickCategory: { pill, results in
                        handleCategoryResults(pill: pill, results: results)
                    },
                    onSubmitSearch: { query, results in
                        handleSubmittedSearch(query: query, results: results)
                    },
                    onCancel: {
                        showSearchOverlay = false
                    }
                )
            }
            .sheet(item: Binding(
                get: { mapState.selectedSearchResult },
                set: { mapState.selectedSearchResult = $0 }
            )) { preview in
                MapSearchPreviewSheet(
                    preview: preview,
                    onAddToDay: {
                        addToDayPreview = preview
                        showAddToDay = true
                    },
                    onSearchNearby: {
                        runSearchNearby(around: preview.coordinate)
                    },
                    onDismiss: {
                        mapState.selectedSearchResult = nil
                    }
                )
                .presentationDetents([.height(220), .medium])
                .presentationDragIndicator(.visible)
                .presentationBackgroundInteraction(.enabled(upThrough: .height(220)))
                .presentationBackground(.regularMaterial)
            }
            .sheet(isPresented: $showAddToDay) {
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
                            mapState.selectedSearchResult = nil
                        },
                        onCancel: {
                            showAddToDay = false
                            addToDayPreview = nil
                        }
                    )
                    .presentationDetents([.height(420), .large])
                    .presentationDragIndicator(.visible)
                    .presentationBackground(.regularMaterial)
                }
            }
            .onChange(of: mapState.selectedSearchResult) { _, newVal in
                // Single-sheet ownership: collapse the day sheet when a
                // search preview takes the bottom region. Restore on
                // dismiss.
                if newVal != nil && showPlacesSheet {
                    showPlacesSheet = false
                }
            }
    }

    private var mapRoot: some View {
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
            .overlay(alignment: .top) {
                searchThisAreaOverlay
            }
    }

    /// "Search this area" pill — appears once the user has panned past
    /// ~30% of the originating span after a category search.
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
            .padding(.top, 14)
            .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
            .accessibilityLabel("Search this area")
            .accessibilityHint("Re-runs the last search in the current map region")
            .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        }
    }

    private var shouldShowSearchThisArea: Bool {
        guard !mapState.searchResults.isEmpty,
              let origin = mapState.searchOriginRegion
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

    /// Compact vertical pill — right edge, below the search affordance so the
    /// top map chrome does not crowd the native navigation/search region.
    private var mapControlStack: some View {
        VStack(spacing: 0) {
            Button {
                HapticManager.light()
                centerOnUserLocation()
            } label: {
                Image(systemName: "location.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(AppColors.appPrimary)
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Current location")

            Color(UIColor.separator)
                .frame(width: 18, height: 0.5)

            Button {
                HapticManager.light()
                showMapModesSheet = true
            } label: {
                Image(systemName: mapMode == .hybrid ? "globe.americas.fill" : "map")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Map style")
        }
        .fixedSize()
        .background(.regularMaterial)
        .clipShape(Capsule())
        .shadow(color: .black.opacity(0.18), radius: 6, x: 0, y: 3)
        .padding(.top, 72)
        .padding(.trailing, 10)
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
        let wishlistDayIds = Set(
            scheduledDays.filter { $0.isWishlist }.map(\.id)
        )
        // Use ALL places (not just scheduledDays) so wishlist days are
        // intentionally excluded by the wishlist day-id filter inside.
        mapState.recomputeScheduledDayPlaceIds(
            from: places,
            wishlistDayIds: wishlistDayIds
        )
    }

    /// Resolve city_profiles.id from the trip's destinationPlaceId so
    /// city_places searches can scope to the trip's city.
    private func resolveCityProfileId() async {
        guard let placeId = trip.destinationPlaceId else { return }
        let id = await dataService.fetchCityProfileId(googlePlaceId: placeId)
        await MainActor.run { resolvedCityProfileId = id }
    }

    private func handleOverlayPicked(_ preview: MapSearchPreview) {
        showSearchOverlay = false
        mapState.searchResults = [preview]
        mapState.searchOriginRegion = searchRegion
        mapState.selectedSearchResult = preview
        focusCamera(on: preview.coordinate, distance: 600)
    }

    private func handleCategoryResults(pill: CategoryPill, results: [MapSearchPreview]) {
        showSearchOverlay = false
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
        showPlacesSheet = false
        sharedState?.showPlacesSheet = false
        mapState.selectedSearchResult = nil
        selectedPlace = nil

        let region = searchRegion
        lastPickedCategory = nil
        lastSubmittedMapSearchQuery = query
        lastCategoryRegion = region
        mapState.searchResults = results
        mapState.searchOriginRegion = region

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
        lastCategoryRegion = nil
        fitMapForCurrentMode()
    }

    /// Re-runs the most recent category search in the current viewport
    /// so the user sees fresh results after panning to a new area.
    private func rerunCategoryInCurrentRegion() {
        guard lastPickedCategory != nil || lastSubmittedMapSearchQuery != nil else { return }
        let pill = lastPickedCategory
        let category = pill?.matchingPlaceCategory
        let cityId = resolvedCityProfileId
        let region = searchRegion
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
