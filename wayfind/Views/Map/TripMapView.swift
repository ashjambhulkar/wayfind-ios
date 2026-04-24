import CoreLocation
import MapKit
import SwiftUI

/// Temporary pin dropped on the map for an autocomplete search result.
struct MapSearchPin: Identifiable {
    let id = UUID()
    let name: String
    let coordinate: CLLocationCoordinate2D
}

/// Downward-pointing triangle used for the search result pin callout.
private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

struct TripMapView: View {
    let trip: Trip
    /// Legacy binding kept for callers that still pass it; ignored internally.
    var externalSearchText: Binding<String>?
    /// Shared state with the tab accessory bar (iOS 26+). Nil when not in a tab.
    var sharedState: MapTabSharedState?

    @Environment(DataService.self) var dataService
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @Namespace private var mapScope

    @State private var searchText: String = ""
    @State private var places: [Place] = []
    @State private var dayNumberByDayId: [UUID: Int] = [:]
    @State private var selectedDayFilter: Int?
    @State private var selectedPlace: Place?
    @State private var position: MapCameraPosition
    @State private var showAddPlace = false
    @State private var scheduledDays: [ItineraryDay] = []
    @State private var wishlistPlaces: [Place] = []
    @State private var activeCategoryFilter: String?

    /// Temporary map pin for a search result selected from autocomplete.
    @State private var searchResultPin: MapSearchPin?

    /// Controls whether the expanded places sheet is shown.
    @State private var showPlacesSheet = false
    @State private var searchRegion: MKCoordinateRegion
    @State private var mapSearchDebounceGeneration = 0

    /// Hybrid is the default map style.
    @State private var mapMode: TripMapMode = .hybrid

    /// Track map container height so we can offset the camera above the sheet.
    @State private var mapContainerHeight: CGFloat = 0

    @State private var showMapModesSheet = false
    @State private var lastMapCamera: MapCamera?

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

    /// Trip pins to draw on the map.
    private var tripPlacesOnMap: [Place] {
        mapDisplayedPlaces
    }

    private var routePolylineCoordinates: [CLLocationCoordinate2D] {
        mapDisplayedPlaces
            .sorted { $0.sortOrder < $1.sortOrder }
            .compactMap { p in
                guard let lat = p.lat, let lng = p.lng else { return nil }
                return CLLocationCoordinate2D(latitude: lat, longitude: lng)
            }
    }

    private var polylineStrokeColor: Color {
        if let filter = selectedDayFilter {
            return AppColors.dayColor(for: filter)
        }
        return AppColors.appPrimary
    }

    private var sortedMapDisplayedPlaces: [Place] {
        mapDisplayedPlaces.sorted { $0.sortOrder < $1.sortOrder }
    }

    /// Center used when fitting the map; trip coordinates, otherwise equator/Prime Meridian.
    private var tripMapCenter: CLLocationCoordinate2D {
        CLLocationCoordinate2D(
            latitude: trip.lat ?? 0,
            longitude: trip.lng ?? 0
        )
    }

    init(trip: Trip, searchText: Binding<String>? = nil, sharedState: MapTabSharedState? = nil) {
        self.trip = trip
        self.externalSearchText = searchText
        self.sharedState = sharedState

        let center = CLLocationCoordinate2D(
            latitude: trip.lat ?? 0,
            longitude: trip.lng ?? 0
        )

        _position = State(
            initialValue: .camera(
                MapCamera(
                    centerCoordinate: center,
                    distance: 45_000_000,
                    heading: 0,
                    pitch: 0
                )
            )
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
            .navigationTitle(trip.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .tint(AppColors.appPrimary)
            .task {
                await loadMapData()
            }
            .onChange(of: places) { _, _ in
                fitMapForCurrentMode()
                syncToSharedState()
            }
            .onChange(of: selectedDayFilter) { _, _ in
                fitMapToMatchDayFilter(animated: !reduceMotion)
                sharedState?.selectedDayFilter = selectedDayFilter
            }
            .onChange(of: searchText) { _, newValue in
                externalSearchText?.wrappedValue = newValue

                if let active = activeCategoryFilter, newValue != active {
                    activeCategoryFilter = nil
                }

                fitMapToAnnotations()
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
            .onChange(of: sharedState?.searchResultToFocus?.1) { _, _ in
                if let result = sharedState?.searchResultToFocus {
                    handleSearchResultSelected(result.0, lat: result.1, lng: result.2)
                    sharedState?.searchResultToFocus = nil
                }
            }
            .onChange(of: selectedPlace) { oldPlace, newPlace in
                if oldPlace != nil && newPlace == nil {
                    withAnimation(Self.dayFilterMapAnimation) {
                        fitMapToAnnotations()
                    }
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
                withAnimation(Self.dayFilterMapAnimation) {
                    fitMapToAnnotations()
                }
            }
            .overlay(alignment: .topTrailing) {
                mapControlStack
            }
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
        sharedState.searchText = searchText
        sharedState.activeCategoryFilter = activeCategoryFilter
    }


    /// Hybrid is default. Both map styles use realistic elevation for globe-friendly zoom.
    private var currentMapStyle: MapStyle {
        mapMode.mapStyle
    }

    private var mapContent: some View {
        Map(position: $position, scope: mapScope) {
            UserAnnotation()

            ForEach(tripPlacesOnMap) { place in
                Annotation("", coordinate: place.coordinate) {
                    mapMarker(for: place)
                }
            }

            if let pin = searchResultPin {
                Annotation(pin.name, coordinate: pin.coordinate) {
                    searchResultMarker(pin: pin)
                }
            }

            if routePolylineCoordinates.count >= 2 {
                MapPolyline(coordinates: routePolylineCoordinates)
                    .stroke(polylineStrokeColor.opacity(0.4), lineWidth: 3)
            }
        }
        .mapStyle(currentMapStyle)
        .mapScope(mapScope)
        .onMapCameraChange(frequency: .onEnd) { context in
            let cam = context.camera
            lastMapCamera = cam
            let spanDeg = min(max(2 * cam.distance / 111_000, 0.04), 40)
            searchRegion = MKCoordinateRegion(
                center: cam.centerCoordinate,
                span: MKCoordinateSpan(
                    latitudeDelta: spanDeg,
                    longitudeDelta: min(spanDeg * 1.2, 50)
                )
            )
        }
        .accessibilityLabel("Map of places for \(trip.title)")
    }

    /// Compact vertical pill — right edge, just below nav bar.
    private var mapControlStack: some View {
        VStack(spacing: 0) {
            Button {
                HapticManager.light()
                position = .userLocation(fallback: .automatic)
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
        .padding(.top, 10)
        .padding(.trailing, 10)
    }

    private var emptyMapCard: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            Text("Add places to see them on the map")
                .font(.cardTitle)
                .foregroundStyle(AppColors.textPrimary)

            AppButton(title: "+ Add a Place", style: .outline) {
                showAddPlace = true
            }
        }
        .padding(AppSpacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColors.appSurface)
        .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous))
        .shadow(color: .black.opacity(0.1), radius: 16, y: 6)
    }

    @ViewBuilder
    private func mapMarker(for place: Place) -> some View {
        Button {
            HapticManager.light()
            selectedPlace = place
        } label: {
            if place.isBooking {
                bookingMarker(for: place)
            } else {
                dayMarker(for: place)
            }
        }
        .buttonStyle(.plain)
    }

    private func bookingMarker(for place: Place) -> some View {
        let color = place.bookingCategoryEnum?.color ?? AppColors.appPrimary
        let symbol = place.bookingCategoryEnum?.sfSymbol ?? "ticket.fill"

        return ZStack {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(color)
                .frame(width: 20, height: 20)
                .rotationEffect(.degrees(45))

            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
        }
        .frame(width: 28, height: 28)
    }

    private func dayMarker(for place: Place) -> some View {
        let dayNum = dayNumberByDayId[place.itineraryDayId] ?? 1
        let dayColor = AppColors.dayColor(for: dayNum)

        return ZStack {
            Circle()
                .fill(dayColor)
                .frame(width: 28, height: 28)

            Text("\(place.sortOrder + 1)")
                .font(.appSmall)
                .fontWeight(.bold)
                .foregroundStyle(.white)
        }
    }

    /// Distinctive orange pin for search autocomplete results.
    private func searchResultMarker(pin: MapSearchPin) -> some View {
        VStack(spacing: 0) {
            ZStack {
                Circle()
                    .fill(Color.orange)
                    .frame(width: 36, height: 36)
                    .shadow(color: .black.opacity(0.2), radius: 4, x: 0, y: 2)
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
            }
            Triangle()
                .fill(Color.orange)
                .frame(width: 10, height: 6)
        }
        .accessibilityLabel("Search result: \(pin.name)")
    }

    // MARK: - Search result selected from autocomplete

    func handleSearchResultSelected(_ name: String, lat: Double, lng: Double) {
        let pin = MapSearchPin(name: name, coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lng))
        searchResultPin = pin

        withAnimation(.spring(response: 0.55, dampingFraction: 0.86)) {
            position = .region(MKCoordinateRegion(
                center: pin.coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
            ))
        }

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

    /// Slightly longer spring so the camera has a clear "fly" when changing days.
    private static var dayFilterMapAnimation: Animation {
        .spring(response: 0.55, dampingFraction: 0.86)
    }

    private func fitMapToMatchDayFilter(animated: Bool) {
        if animated {
            withAnimation(Self.dayFilterMapAnimation) {
                fitMapForCurrentMode()
            }
        } else {
            fitMapForCurrentMode()
        }
    }

    private func fitMapForCurrentMode() {
        fitMapToAnnotations()
    }

    /// Pans so the selected pin appears centered in the visible region above
    /// the sheet, then opens the detail sheet after the animation settles.
    private func selectAndFocusPlace(_ place: Place) {
        guard let lat = place.lat, let lng = place.lng else {
            selectedPlace = place
            return
        }

        let covered = sheetCoveredFraction   // e.g. 0.5 for medium detent
        let visible = visibleMapFraction     // e.g. 0.5 for medium detent

        // Choose a comfortable zoom span for a single highlighted pin
        let baseSpan: Double = 0.008
        let adjustedSpan = baseSpan / visible
        // Move camera SOUTH so selected pin appears in the upper visible region
        let latOffset = adjustedSpan * (covered / 2 + 0.10)

        withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) {
            position = .region(
                MKCoordinateRegion(
                    center: CLLocationCoordinate2D(latitude: lat - latOffset, longitude: lng),
                    span: MKCoordinateSpan(latitudeDelta: adjustedSpan, longitudeDelta: adjustedSpan)
                )
            )
        }

        // Open detail after the pan animation completes
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            selectedPlace = place
        }
    }

    /// Reliable screen height — available immediately without GeometryReader.
    private var screenHeight: CGFloat {
        let h = mapContainerHeight > 0 ? mapContainerHeight : UIScreen.main.bounds.height
        return max(h, 400)
    }

    /// Fraction of the screen height covered by the bottom sheet (0…1).
    private var sheetCoveredFraction: CGFloat {
        let sheetH: CGFloat = showPlacesSheet ? screenHeight * 0.5 : 120
        return min(sheetH / screenHeight, 0.95)
    }

    /// Fraction of screen that is VISIBLE above the sheet (0…1).
    private var visibleMapFraction: CGFloat {
        max(1 - sheetCoveredFraction, 0.08)
    }

    private func fitMapToAnnotations() {
        let coords = tripPlacesOnMap.map(\.coordinate)
        guard !coords.isEmpty else {
            position = globeMapPosition(center: tripMapCenter)
            return
        }

        let covered  = sheetCoveredFraction   // e.g. 0.5 at medium
        let visible  = visibleMapFraction      // e.g. 0.5 at medium

        if coords.count == 1 {
            let c = coords[0]
            let baseSpan: Double = 0.008
            let adjustedSpan = baseSpan / visible
            // Move camera SOUTH so the pin appears in the northern (top) visible region
            let latOffset = adjustedSpan * (covered / 2 + 0.10)
            position = .region(
                MKCoordinateRegion(
                    center: CLLocationCoordinate2D(latitude: c.latitude - latOffset, longitude: c.longitude),
                    span: MKCoordinateSpan(latitudeDelta: adjustedSpan, longitudeDelta: adjustedSpan)
                )
            )
            return
        }

        let minLat = coords.map(\.latitude).min() ?? 0
        let maxLat = coords.map(\.latitude).max() ?? 0
        let minLon = coords.map(\.longitude).min() ?? 0
        let maxLon = coords.map(\.longitude).max() ?? 0

        // Annotation spread + comfortable padding
        let annotationLatSpan = max(maxLat - minLat, 0.006) * 1.25
        let annotationLonSpan = max(maxLon - minLon, 0.006) * 1.25

        // Expand vertically so the full annotation set fits inside the VISIBLE portion only
        var latDelta = annotationLatSpan / visible
        let lonDelta = max(annotationLonSpan, annotationLatSpan)
        latDelta = max(latDelta, 0.01)

        if latDelta > 55 || lonDelta > 90 {
            let midLat = (minLat + maxLat) / 2
            let midLon = (minLon + maxLon) / 2
            position = globeMapPosition(center: CLLocationCoordinate2D(latitude: midLat, longitude: midLon))
            return
        }

        let midLat = (minLat + maxLat) / 2
        let midLon = (minLon + maxLon) / 2

        // Shift the map center northward by exactly half the sheet-covered lat span
        // so the annotation group sits centered in the visible upper region.
        // Move the camera center SOUTH so annotations appear in the northern
        // (top, visible) region of the screen, above the bottom sheet.
        // + 0.10 adds a comfortable gap so pins don't sit right at the sheet edge.
        let latOffset = latDelta * (covered / 2 + 0.10)
        position = .region(
            MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: midLat - latOffset, longitude: midLon),
                span: MKCoordinateSpan(latitudeDelta: latDelta, longitudeDelta: lonDelta)
            )
        )
    }

    private func globeMapPosition(center: CLLocationCoordinate2D) -> MapCameraPosition {
        .camera(
            MapCamera(
                centerCoordinate: center,
                distance: 45_000_000,
                heading: 0,
                pitch: 0
            )
        )
    }
}

// =============================================================================

