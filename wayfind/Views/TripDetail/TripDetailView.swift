import Observation
import SwiftUI

private struct TripHeaderMinYKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct TripDetailView: View {
    @Environment(MockDataService.self) private var dataService
    @Environment(ToastManager.self) private var toastManager
    @State private var viewModel: TripDetailViewModel?
    @State private var headerMinY: CGFloat = 0
    @State private var showMap = false
    @State private var showBookings = false
    @State private var showAddPlace = false
    @State private var showAddBooking = false
    @State private var addPlaceTargetDay: Int = 1
    @State private var fabOpen = false
    @State private var hasAutoScrolled = false
    @State private var discoveryManager = ForwardingDiscoveryManager()
    @State private var bannerDismissed = false
    @State private var showEditTrip = false
    @State private var showDeleteConfirmation = false
    @State private var placeToEdit: Place?
    @State private var placeToMove: Place?
    @State private var selectedPlace: Place?
    @State private var selectedPlacePrevious: Place?
    @Environment(\.dismiss) private var dismiss

    let trip: Trip

    private var tripBookingCount: Int {
        viewModel?.totalBookingsCount ?? 0
    }

    var body: some View {
        ZStack {
            Group {
                if let viewModel {
                    if viewModel.isLoading && viewModel.scheduledDays.isEmpty {
                        ProgressView()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        tripContent(viewModel: viewModel)
                    }
                } else {
                    AppColors.appBackground
                        .overlay { ProgressView() }
                }
            }

            SpeedDialFABView(
                isOpen: $fabOpen,
                items: [
                    (sfSymbol: "mappin.and.ellipse", label: "Add Place", action: {
                        addPlaceTargetDay = trip.currentDayNumber ?? 1
                        showAddPlace = true
                    }),
                    (sfSymbol: "airplane", label: "Add Booking", action: {
                        showAddBooking = true
                    }),
                ],
                footerTip: discoveryManager.shouldShowSpeedDialFooter(totalBookingsAcrossTrips: tripBookingCount)
                    ? SpeedDialFooterTip(email: discoveryManager.forwardingEmail, onCopy: {})
                    : nil
            )
        }
        .background(AppColors.appBackground)
        .navigationTitle(trip.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(AppColors.appBackground, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        showEditTrip = true
                    } label: {
                        Label("Edit Trip", systemImage: "pencil")
                    }
                    Divider()
                    Button {
                        viewModel?.expandAll()
                    } label: {
                        Label("Expand All Days", systemImage: "arrow.up.left.and.arrow.down.right")
                    }
                    Button {
                        viewModel?.collapseAll()
                    } label: {
                        Label("Collapse All Days", systemImage: "arrow.down.right.and.arrow.up.left")
                    }
                    Divider()
                    Button(role: .destructive) {
                        showDeleteConfirmation = true
                    } label: {
                        Label("Delete Trip", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 17))
                        .foregroundStyle(AppColors.appPrimary)
                }
            }
        }
        .confirmationDialog("Delete \(trip.title)?", isPresented: $showDeleteConfirmation, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                Task {
                    await dataService.deleteTrip(id: trip.id)
                }
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This action cannot be undone.")
        }
        .sheet(isPresented: $showEditTrip) {
            EditTripView(trip: viewModel?.trip ?? trip) { updatedTrip in
                Task {
                    await dataService.updateTrip(updatedTrip)
                    if updatedTrip.startDate != trip.startDate || updatedTrip.endDate != trip.endDate {
                        await dataService.regenerateDays(for: trip.id, startDate: updatedTrip.startDate, endDate: updatedTrip.endDate)
                    }
                    viewModel?.trip = updatedTrip
                    await viewModel?.loadTripData()
                }
                toastManager.show(ToastData(message: "Trip updated", type: .success))
            }
        }
        .sheet(item: $placeToEdit) { place in
            if place.isBooking {
                NavigationStack {
                    AddBookingView(
                        editingPlace: place,
                        onSave: { updatedPlace in
                            Task {
                                await dataService.updatePlace(updatedPlace)
                                await viewModel?.loadTripData()
                            }
                            toastManager.show(ToastData(message: "Updated", type: .success))
                        },
                        targetDayId: place.itineraryDayId
                    )
                }
            } else {
                EditPlaceView(place: place) { updatedPlace in
                    Task {
                        await dataService.updatePlace(updatedPlace)
                        await viewModel?.loadTripData()
                    }
                    toastManager.show(ToastData(message: "Updated", type: .success))
                }
            }
        }
        .sheet(item: $placeToMove) { place in
            if let vm = viewModel {
                let counts = Dictionary(uniqueKeysWithValues: vm.scheduledDays.map { ($0.id, vm.placesCount(for: $0)) })
                MoveToDaySheet(
                    place: place,
                    days: vm.scheduledDays,
                    currentDayId: place.itineraryDayId,
                    placesPerDay: counts
                ) { targetDayId in
                    Task {
                        await dataService.movePlace(placeId: place.id, toDayId: targetDayId)
                        await vm.loadTripData()
                    }
                    HapticManager.success()
                    let targetDay = vm.scheduledDays.first(where: { $0.id == targetDayId })
                    toastManager.show(ToastData(
                        message: "Moved to Day \(targetDay?.dayNumber ?? 0)",
                        type: .undo,
                        duration: 5,
                        undoAction: {
                            Task {
                                await dataService.movePlace(placeId: place.id, toDayId: place.itineraryDayId)
                                await vm.loadTripData()
                            }
                        }
                    ))
                }
            }
        }
        .sheet(item: $selectedPlace) { place in
            PlaceDetailSheet(
                place: place,
                previousPlace: selectedPlacePrevious,
                onEdit: { placeToEdit = place; selectedPlace = nil },
                onMove: { placeToMove = place; selectedPlace = nil },
                onDelete: {
                    if let vm = viewModel {
                        deletePlace(place, viewModel: vm)
                    }
                    selectedPlace = nil
                }
            )
        }
        .navigationDestination(isPresented: $showMap) {
            TripMapView(trip: trip)
        }
        .navigationDestination(isPresented: $showBookings) {
            BookingsScreenView(trip: trip)
        }
        .navigationDestination(isPresented: $showAddBooking) {
            if let vm = viewModel, let targetDayId = vm.scheduledDays.first(where: { $0.dayNumber == addPlaceTargetDay })?.id {
                AddBookingView(
                    onSave: { _ in Task { await vm.loadTripData() } },
                    targetDayId: targetDayId
                )
            }
        }
        .sheet(isPresented: $showAddPlace) {
            if let vm = viewModel {
                AddPlaceView(
                    selectedDayNumber: addPlaceTargetDay,
                    days: vm.scheduledDays,
                    wishlistPlaces: vm.wishlistPlaces
                ) { placeName, dayNumber in
                    guard let targetDay = vm.scheduledDays.first(where: { $0.dayNumber == dayNumber }) else { return }
                    let existingCount = vm.places(for: targetDay).count
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
                        await vm.loadTripData()
                    }
                    HapticManager.success()
                    showAddPlace = false
                }
            }
        }
        .task {
            if viewModel == nil {
                viewModel = TripDetailViewModel(trip: trip, dataService: dataService)
            }
            await viewModel?.loadTripData()
            bannerDismissed = discoveryManager.isBannerDismissed(for: trip.id)
        }
    }

    // MARK: - Trip Content

    @ViewBuilder
    private func tripContent(viewModel: TripDetailViewModel) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                TripDetailParallaxHeader(trip: trip, topInset: 0)
                    .background(
                        GeometryReader { geo in
                            Color.clear.preference(
                                key: TripHeaderMinYKey.self,
                                value: geo.frame(in: .named("tripScroll")).minY
                            )
                        }
                    )

                pillsRow(viewModel: viewModel)

                HStack {
                    Spacer()
                    Button {
                        let allCollapsed = viewModel.scheduledDays.allSatisfy { viewModel.isDayCollapsed($0) }
                        if allCollapsed {
                            viewModel.expandAll()
                        } else {
                            viewModel.collapseAll()
                        }
                    } label: {
                        let allCollapsed = viewModel.scheduledDays.allSatisfy { viewModel.isDayCollapsed($0) }
                        Text(allCollapsed ? "Expand all" : "Collapse all")
                            .font(.appCaption)
                            .foregroundStyle(AppColors.appPrimary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, AppSpacing.lg)
                .padding(.bottom, AppSpacing.sm)

                // Touchpoint 1: Timeline banner
                if discoveryManager.shouldShowTimelineBanner(tripBookingCount: tripBookingCount, tripId: trip.id) && !bannerDismissed {
                    ForwardingBannerView(
                        email: discoveryManager.forwardingEmail,
                        onCopy: {
                            withAnimation(AppSpring.smooth) {
                                bannerDismissed = true
                            }
                            discoveryManager.dismissBanner(for: trip.id)
                        },
                        onDismiss: {
                            withAnimation(AppSpring.smooth) {
                                bannerDismissed = true
                            }
                            discoveryManager.dismissBanner(for: trip.id)
                        }
                    )
                    .padding(.horizontal, AppSpacing.lg)
                    .padding(.bottom, AppSpacing.md)
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
                }

                ForEach(viewModel.scheduledDays) { day in
                    daySection(day: day, viewModel: viewModel)
                }

                if !viewModel.wishlistPlaces.isEmpty {
                    wishlistSection(viewModel: viewModel)
                }
            }
                .padding(.bottom, 80)
            }
            .coordinateSpace(name: "tripScroll")
            .onPreferenceChange(TripHeaderMinYKey.self) { headerMinY = $0 }
            .onChange(of: viewModel.isLoading) { _, isLoading in
                if isLoading == false, !hasAutoScrolled,
                   trip.status == .active,
                   let current = trip.currentDayNumber,
                   let todayDay = viewModel.scheduledDays.first(where: { $0.dayNumber == current }) {
                    hasAutoScrolled = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        withAnimation(AppSpring.smooth) {
                            proxy.scrollTo(todayDay.id, anchor: .top)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Pills Row

    private func pillsRow(viewModel: TripDetailViewModel) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: AppSpacing.sm) {
                PillButtonView(sfSymbol: "map", label: "Map", isActive: true) {
                    showMap = true
                }
                // Touchpoint 4: Pulse dot on Bookings pill when 0 bookings
                PillButtonView(
                    sfSymbol: "airplane",
                    label: "Bookings",
                    badgeCount: viewModel.totalBookingsCount,
                    showPulseDot: discoveryManager.shouldShowPillPulseDot(tripBookingCount: tripBookingCount),
                    isActive: true
                ) {
                    showBookings = true
                }
                PillButtonView(sfSymbol: "checklist", label: "Soon", isActive: false) {}
                PillButtonView(sfSymbol: "note.text", label: "Soon", isActive: false) {}
                PillButtonView(sfSymbol: "dollarsign.circle", label: "Soon", isActive: false) {}
            }
            .padding(.horizontal, AppSpacing.lg)
            .padding(.vertical, AppSpacing.md)
        }
    }

    // MARK: - Day Section

    @ViewBuilder
    private func daySection(day: ItineraryDay, viewModel: TripDetailViewModel) -> some View {
        let places = viewModel.places(for: day)
        let preview = places.prefix(3).map(\.name).joined(separator: ", ")
        let dayHasBookings = places.contains(where: \.isBooking)

        Section {
            if !viewModel.isDayCollapsed(day) {
                VStack(spacing: 0) {
                    Spacer()
                        .frame(height: AppSpacing.md)

                    if isTodayDay(day) {
                        NowIndicatorView()
                            .padding(.horizontal, AppSpacing.lg)
                            .padding(.bottom, AppSpacing.sm)
                    }

                    ForEach(viewModel.ongoingBookings(for: day), id: \.place.id) { item in
                        if item.isFirstAppearance {
                            OngoingBookingBannerView(
                                bookingName: item.place.name,
                                bookingType: item.place.bookingCategoryEnum ?? .hotel
                            )
                            .padding(.horizontal, AppSpacing.lg)
                            .padding(.bottom, AppSpacing.sm)
                        } else {
                            ongoingBookingFadedLine(place: item.place, day: day, viewModel: viewModel)
                        }
                    }

                    ForEach(Array(places.enumerated()), id: \.element.id) { index, place in
                        if index > 0 {
                            TimelineGapView(fromPlace: places[index - 1], toPlace: place)
                        }

                        Group {
                            if place.isBooking {
                                TimelineBookingCardView(
                                    place: place,
                                    dayNumber: day.dayNumber,
                                    onEdit: { placeToEdit = place },
                                    onMoveToDay: { placeToMove = place },
                                    onDelete: { deletePlace(place, viewModel: viewModel) }
                                )
                            } else {
                                TimelinePlaceCardView(
                                    place: place,
                                    dayNumber: day.dayNumber,
                                    onEdit: { placeToEdit = place },
                                    onMoveToDay: { placeToMove = place },
                                    onMoveToIdeas: { moveToIdeas(place, viewModel: viewModel) },
                                    onDelete: { deletePlace(place, viewModel: viewModel) }
                                )
                            }
                        }
                        .padding(.horizontal, AppSpacing.lg)
                        .padding(.bottom, AppSpacing.sm)
                        .onTapGesture {
                            selectedPlacePrevious = index > 0 ? places[index - 1] : nil
                            selectedPlace = place
                        }
                    }

                    InlineAddButtonView(
                        dayNumber: day.dayNumber
                    ) {
                        addPlaceTargetDay = day.dayNumber
                        showAddPlace = true
                    }
                    .padding(.horizontal, AppSpacing.lg)
                    .padding(.top, AppSpacing.xs)
                    .padding(.bottom, AppSpacing.lg)
                }
            }
        } header: {
            DaySectionHeaderView(
                day: day,
                titleText: viewModel.dayStatusText(for: day),
                itemCount: viewModel.placesCount(for: day),
                isCollapsed: viewModel.isDayCollapsed(day),
                contentPreview: preview
            ) {
                viewModel.toggleDayCollapse(day)
            }
            .id(day.id)
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func ongoingBookingFadedLine(place: Place, day: ItineraryDay, viewModel: TripDetailViewModel) -> some View {
        let bookingDayNum = viewModel.scheduledDays.first(where: { $0.id == place.itineraryDayId })?.dayNumber ?? 0
        let nightNumber = day.dayNumber - bookingDayNum
        let caption: String = {
            if let details = place.bookingDetails, case .hotel(let h) = details {
                let total: Int? = {
                    if let n = h.nights, n > 0 { return n }
                    guard let ci = h.checkInDate, let co = h.checkOutDate else { return nil }
                    let d = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: ci), to: Calendar.current.startOfDay(for: co)).day ?? 0
                    return max(d, 1)
                }()
                if let total { return "\(place.name) (Night \(nightNumber) of \(total))" }
            }
            return "\(place.name) (Night \(nightNumber))"
        }()
        Text(caption)
            .font(.appCaption)
            .foregroundStyle(AppColors.textTertiary)
            .padding(.horizontal, AppSpacing.lg)
            .padding(.bottom, AppSpacing.sm)
    }

    private func isTodayDay(_ day: ItineraryDay) -> Bool {
        guard trip.status == .active, let current = trip.currentDayNumber else { return false }
        return day.dayNumber == current
    }

    private func moveToIdeas(_ place: Place, viewModel: TripDetailViewModel) {
        guard let wishlistId = viewModel.wishlistDayId else { return }
        Task {
            await dataService.movePlace(placeId: place.id, toDayId: wishlistId)
            await viewModel.loadTripData()
        }
        HapticManager.success()
        toastManager.show(ToastData(
            message: "Moved to Ideas",
            type: .undo,
            duration: 5,
            undoAction: {
                Task {
                    await dataService.movePlace(placeId: place.id, toDayId: place.itineraryDayId)
                    await viewModel.loadTripData()
                }
            }
        ))
    }

    private func deletePlace(_ place: Place, viewModel: TripDetailViewModel) {
        let deleted = place
        Task {
            await dataService.deletePlace(id: place.id)
            await viewModel.loadTripData()
        }
        HapticManager.warning()
        toastManager.show(ToastData(
            message: "\(place.name) deleted",
            type: .undo,
            duration: 5,
            undoAction: {
                Task {
                    await dataService.addPlace(deleted)
                    await viewModel.loadTripData()
                }
            }
        ))
    }

    // MARK: - Wishlist Section

    @ViewBuilder
    private func wishlistSection(viewModel: TripDetailViewModel) -> some View {
        Section {
            VStack(spacing: 0) {
                Spacer()
                    .frame(height: AppSpacing.md)

                ForEach(viewModel.wishlistPlaces) { place in
                    Group {
                        if place.isBooking {
                            TimelineBookingCardView(
                                place: place,
                                dayNumber: 0,
                                onEdit: { placeToEdit = place },
                                onMoveToDay: { placeToMove = place },
                                onDelete: { deletePlace(place, viewModel: viewModel) }
                            )
                        } else {
                            TimelinePlaceCardView(
                                place: place,
                                dayNumber: 0,
                                onEdit: { placeToEdit = place },
                                onMoveToDay: { placeToMove = place },
                                onDelete: { deletePlace(place, viewModel: viewModel) }
                            )
                        }
                    }
                    .padding(.horizontal, AppSpacing.lg)
                    .padding(.bottom, AppSpacing.sm)
                }
            }
            .padding(.bottom, AppSpacing.xl)
        } header: {
            HStack {
                Text("Ideas & Wishlist")
                    .font(.sectionHeader)
                    .foregroundStyle(AppColors.textPrimary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, AppSpacing.lg)
            .padding(.vertical, AppSpacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppColors.appBackground)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(AppColors.appDivider)
                    .frame(height: 1)
            }
        }
    }
}

// MARK: - Parallax Header

private struct TripDetailParallaxHeader: View {
    let trip: Trip
    let topInset: CGFloat

    private var statusLabel: String {
        switch trip.status {
        case .upcoming: return "Upcoming"
        case .active: return "Active"
        case .past: return "Past"
        }
    }

    private var totalHeight: CGFloat { 240 + topInset }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            heroImage

            LinearGradient(
                colors: [.clear, Color.black.opacity(0.65)],
                startPoint: .top,
                endPoint: .bottom
            )

            VStack(alignment: .leading, spacing: AppSpacing.sm) {
                Text(statusLabel)
                    .font(.appSmall)
                    .foregroundStyle(.white)
                    .padding(.horizontal, AppSpacing.sm)
                    .padding(.vertical, AppSpacing.xs)
                    .background(Color.white.opacity(0.22))
                    .clipShape(Capsule())

                Text(trip.title)
                    .font(.sectionHeader)
                    .foregroundStyle(.white)
                    .lineLimit(2)

                Text("\(trip.startDate.shortFormatted) – \(trip.endDate.shortFormatted)")
                    .font(.appCaption)
                    .foregroundStyle(.white.opacity(0.9))
            }
            .padding(AppSpacing.lg)
        }
        .frame(maxWidth: .infinity)
        .frame(height: totalHeight)
        .clipped()
    }

    @ViewBuilder
    private var heroImage: some View {
        if let urlString = trip.coverImageUrl, let url = URL(string: urlString) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .empty, .failure:
                    PlaceholderGradientView(destinationName: trip.destination)
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFill()
                @unknown default:
                    PlaceholderGradientView(destinationName: trip.destination)
                }
            }
        } else {
            PlaceholderGradientView(destinationName: trip.destination)
        }
    }
}
