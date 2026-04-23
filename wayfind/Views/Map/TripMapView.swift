import CoreLocation
import MapKit
import SwiftUI

struct TripMapView: View {
    let trip: Trip
    /// Legacy binding kept for callers that still pass it; ignored internally.
    var externalSearchText: Binding<String>?

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

    /// Native `sheet` for places; temporarily hidden when another modal is on screen.
    @State private var isPlacesListSheetPresented = true
    @State private var placesListSheetDetent: PresentationDetent = .medium
    @State private var searchRegion: MKCoordinateRegion
    @State private var mapSearchDebounceGeneration = 0

    /// Hybrid is the default map style.
    @State private var mapMode: TripMapMode = .hybrid

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

    init(trip: Trip, searchText: Binding<String>? = nil) {
        self.trip = trip
        self.externalSearchText = searchText

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
            }
            .onChange(of: selectedDayFilter) { _, _ in
                fitMapToMatchDayFilter(animated: !reduceMotion)
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
                updatePlacesSheetVisibility()
            }
            .onChange(of: showMapModesSheet) { _, _ in
                updatePlacesSheetVisibility()
            }
            .onChange(of: showAddPlace) { _, _ in
                updatePlacesSheetVisibility()
            }
            .onChange(of: selectedPlace) { _, _ in
                updatePlacesSheetVisibility()
            }
            .sheet(isPresented: $isPlacesListSheetPresented) {
                placesListSheetContent
            }
            .sheet(item: $selectedPlace) { place in
                PlaceCalloutView(place: place)
                    .presentationDetents([.medium, .large])
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
    }

    @ViewBuilder
    private var placesListSheetContent: some View {
        TripMapPlacesSheet(
            trip: trip,
            selectedDayFilter: $selectedDayFilter,
            activeCategoryFilter: $activeCategoryFilter,
            mappablePlaces: mappablePlaces,
            allPlacesForList: sortedMapDisplayedPlaces,
            dayNumberByDayId: dayNumberByDayId,
            sheetDetent: $placesListSheetDetent,
            minSheetDetent: Self.placesListMinDetent,
            onSelectPlace: { place in
                selectedPlace = place
            },
            searchText: $searchText
        )
        .presentationDetents(
            [Self.placesListMinDetent, .medium, .large],
            selection: $placesListSheetDetent
        )
        .presentationBackground(.regularMaterial)
        .presentationBackgroundInteraction(.enabled)
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled()
        .tint(AppColors.appPrimary)
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

    private static var placesListMinDetent: PresentationDetent {
        .height(120)
    }

    /// One modal at a time: hide the places sheet while map modes, add place, or place callout is shown.
    private func updatePlacesSheetVisibility() {
        let otherModal = showMapModesSheet || showAddPlace || selectedPlace != nil
        isPlacesListSheetPresented = !otherModal
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
        .overlay(alignment: .topTrailing) {
            mapControlGroup
                .padding(.top, 120)
                .padding(.trailing, 14)
        }
        .accessibilityLabel("Map of places for \(trip.title)")
    }

    /// Apple Maps style vertical pill: native current-location button + map mode button.
    private var mapControlGroup: some View {
        VStack(spacing: 0) {
            MapUserLocationButton(scope: mapScope)
                .mapControlVisibility(.visible)
                .frame(width: 50, height: 44)
                .clipShape(Rectangle())
                .accessibilityLabel("Center on current location")

            Rectangle()
                .fill(Color.primary.opacity(0.12))
                .frame(height: 1)
                .padding(.horizontal, 7)

            Button {
                HapticManager.light()
                showMapModesSheet = true
            } label: {
                Image(systemName: mapMode == .hybrid ? "map.fill" : "map")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Map modes")
        }
        .frame(width: 50, height: 89)
        .background {
            Capsule(style: .continuous)
                .fill(.ultraThinMaterial)
        }
        .clipShape(Capsule(style: .continuous))
        .compositingGroup()
        .shadow(color: .black.opacity(0.2), radius: 10, y: 3)
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

    private func fitMapToAnnotations() {
        let coords = tripPlacesOnMap.map(\.coordinate)

        guard !coords.isEmpty else {
            position = globeMapPosition(center: tripMapCenter)
            return
        }

        if coords.count == 1 {
            let c = coords[0]

            position = .camera(
                MapCamera(
                    centerCoordinate: c,
                    distance: 12_000,
                    heading: 0,
                    pitch: 0
                )
            )
            return
        }

        let minLat = coords.map(\.latitude).min() ?? 0
        let maxLat = coords.map(\.latitude).max() ?? 0
        let minLon = coords.map(\.longitude).min() ?? 0
        let maxLon = coords.map(\.longitude).max() ?? 0

        var latDelta = max(maxLat - minLat, 0.02) * 1.35
        var lonDelta = max(maxLon - minLon, 0.02) * 1.35

        latDelta = max(latDelta, 0.02)
        lonDelta = max(lonDelta, 0.02)

        // Very wide spread: show the interactive globe instead of a flat world-spanning region.
        if latDelta > 55 || lonDelta > 90 {
            let midLat = (minLat + maxLat) / 2
            let midLon = (minLon + maxLon) / 2

            position = globeMapPosition(
                center: CLLocationCoordinate2D(
                    latitude: midLat,
                    longitude: midLon
                )
            )
            return
        }

        let midLat = (minLat + maxLat) / 2
        let midLon = (minLon + maxLon) / 2

        position = .region(
            MKCoordinateRegion(
                center: CLLocationCoordinate2D(
                    latitude: midLat,
                    longitude: midLon
                ),
                span: MKCoordinateSpan(
                    latitudeDelta: latDelta,
                    longitudeDelta: lonDelta
                )
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