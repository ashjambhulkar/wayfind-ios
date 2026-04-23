import CoreLocation
import MapKit
import SwiftUI

struct TripMapView: View {
    let trip: Trip

    @Environment(DataService.self) var dataService

    @State private var places: [Place] = []
    @State private var dayNumberByDayId: [UUID: Int] = [:]
    @State private var selectedDayFilter: Int?
    @State private var selectedPlace: Place?
    @State private var position: MapCameraPosition = .automatic
    @State private var showAddPlace = false
    @State private var scheduledDays: [ItineraryDay] = []
    @State private var wishlistPlaces: [Place] = []

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

    private var routePolylineCoordinates: [CLLocationCoordinate2D] {
        visiblePlaces
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

    var body: some View {
        ZStack(alignment: .top) {
            Map(position: $position) {
                ForEach(visiblePlaces) { place in
                    Annotation("", coordinate: place.coordinate) {
                        mapMarker(for: place)
                    }
                }
                if routePolylineCoordinates.count >= 2 {
                    MapPolyline(coordinates: routePolylineCoordinates)
                        .stroke(polylineStrokeColor.opacity(0.4), lineWidth: 3)
                }
            }
            .mapStyle(.standard)
            .ignoresSafeArea(edges: .bottom)

            VStack(spacing: 0) {
                DayFilterChipsView(selectedDay: $selectedDayFilter, dayCount: trip.dayCount, unselectedBackground: AppColors.appSurface)
                    .padding(.horizontal, AppSpacing.md)
                    .padding(.vertical, AppSpacing.sm)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous))
                    .padding(.horizontal, AppSpacing.lg)
                    .padding(.top, AppSpacing.sm)

                Spacer(minLength: 0)
            }

            if places.isEmpty {
                VStack {
                    Spacer()
                    emptyMapCard
                        .padding(.horizontal, AppSpacing.lg)
                        .padding(.bottom, AppSpacing.xxl)
                }
            }
        }
        .background(AppColors.appBackground)
        .navigationTitle("Map")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await loadMapData()
        }
        .onChange(of: places) { _, _ in
            fitMapToAnnotations()
        }
        .onChange(of: selectedDayFilter) { _, _ in
            fitMapToAnnotations()
        }
        .onAppear {
            fitMapToAnnotations()
        }
        .sheet(item: $selectedPlace) { place in
            PlaceCalloutView(place: place)
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showAddPlace) {
            AddPlaceView(
                selectedDayNumber: scheduledDays.first?.dayNumber ?? 1,
                days: scheduledDays,
                wishlistPlaces: wishlistPlaces
            ) { placeName, dayNumber in
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
        }
    }

    private var emptyMapCard: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            Text("Add places to see them on the map")
                .font(.cardTitle)
                .foregroundStyle(AppColors.textPrimary)
            AppButton(title: "+ Add a Place", style: .outline) { showAddPlace = true }
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

    private func fitMapToAnnotations() {
        let coords = visiblePlaces.map(\.coordinate)
        guard !coords.isEmpty else {
            let center = CLLocationCoordinate2D(
                latitude: trip.lat ?? 40.0,
                longitude: trip.lng ?? -100.0
            )
            position = .region(MKCoordinateRegion(center: center, span: MKCoordinateSpan(latitudeDelta: 0.2, longitudeDelta: 0.2)))
            return
        }
        if coords.count == 1 {
            let c = coords[0]
            position = .region(MKCoordinateRegion(center: c, span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)))
            return
        }
        let minLat = coords.map(\.latitude).min() ?? 0
        let maxLat = coords.map(\.latitude).max() ?? 0
        let minLon = coords.map(\.longitude).min() ?? 0
        let maxLon = coords.map(\.longitude).max() ?? 0
        let midLat = (minLat + maxLat) / 2
        let midLon = (minLon + maxLon) / 2
        var latDelta = max(maxLat - minLat, 0.02) * 1.35
        var lonDelta = max(maxLon - minLon, 0.02) * 1.35
        latDelta = max(latDelta, 0.02)
        lonDelta = max(lonDelta, 0.02)
        let region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: midLat, longitude: midLon),
            span: MKCoordinateSpan(latitudeDelta: latDelta, longitudeDelta: lonDelta)
        )
        position = .region(region)
    }
}