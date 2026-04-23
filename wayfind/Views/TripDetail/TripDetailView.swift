import Observation
import SwiftUI

struct TripDetailView: View {
    @Environment(DataService.self) private var dataService
    @Environment(ToastManager.self) private var toastManager
    @State private var viewModel: TripDetailViewModel?

    // Sheet state
    @State private var showTripNotes = false
    @State private var showTripChecklists = false
    @State private var showAddPlace = false
    @State private var showAddBooking = false
    @State private var addPlaceTargetDay: Int = 1
    @State private var hasAutoScrolled = false
    @State private var discoveryManager = ForwardingDiscoveryManager()
    @State private var bannerDismissed = false
    @State private var showEditTrip = false
    @State private var showDeleteConfirmation = false
    @State private var placeToEdit: Place?
    @State private var placeToMove: Place?
    @State private var selectedPlace: Place?
    @State private var selectedPlacePrevious: Place?

    // Action bar navigation (map is opened from the trip "…" menu, not the action bar)
    @State private var showMap = false
    @State private var showBookings = false
    @State private var showBudget = false

    @Environment(\.dismiss) private var dismiss

    let trip: Trip

    private var tripBookingCount: Int {
        viewModel?.totalBookingsCount ?? 0
    }

    var body: some View {
        tripDetailNavigationShell
        .confirmationDialog("Delete \(viewModel?.trip.title ?? trip.title)?", isPresented: $showDeleteConfirmation, titleVisibility: .visible) {
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
        .navigationDestination(isPresented: $showTripNotes) {
            TripNotesView(trip: viewModel?.trip ?? trip)
                .toolbar(.hidden, for: .tabBar)
        }
        .navigationDestination(isPresented: $showTripChecklists) {
            TripChecklistsView(trip: viewModel?.trip ?? trip)
                .toolbar(.hidden, for: .tabBar)
        }
        .onChange(of: showTripNotes) { _, isOpen in
            if !isOpen {
                Task { await viewModel?.refreshHeroShortcutCounts() }
            }
        }
        .onChange(of: showTripChecklists) { _, isOpen in
            if !isOpen {
                Task { await viewModel?.refreshHeroShortcutCounts() }
            }
        }
        .navigationDestination(isPresented: $showAddBooking) {
            if let vm = viewModel, let targetDayId = vm.scheduledDays.first(where: { $0.dayNumber == addPlaceTargetDay })?.id {
                AddBookingView(
                    onSave: { _ in Task { await vm.loadTripData() } },
                    targetDayId: targetDayId
                )
                .toolbar(.hidden, for: .tabBar)
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

    /// Navigation shell: title, toolbar, and action-bar destinations.
    private var tripDetailNavigationShell: some View {
        Group {
            if let viewModel {
                if viewModel.isLoading && viewModel.scheduledDays.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack(spacing: 0) {
                        itineraryTab(viewModel: viewModel)

                        // Bottom action bar (replaces TabView)
                        tripActionBar(viewModel: viewModel)
                    }
                }
            } else {
                AppColors.appBackground
                    .overlay { ProgressView() }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppColors.appBackground)
        .navigationTitle(viewModel?.trip.title ?? trip.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.automatic, for: .navigationBar)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
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
                .accessibilityLabel("Trip actions")
            }
        }
        .navigationDestination(isPresented: $showMap) {
            TripMapView(trip: viewModel?.trip ?? trip)
                .toolbar(.hidden, for: .tabBar)
        }
        .navigationDestination(isPresented: $showBookings) {
            BookingsScreenView(trip: viewModel?.trip ?? trip)
                .toolbar(.hidden, for: .tabBar)
        }
        .navigationDestination(isPresented: $showBudget) {
            TripBudgetTabView()
                .navigationTitle("Budget")
                .toolbar(.hidden, for: .tabBar)
        }
    }

    // MARK: - Bottom Action Bar (glass effect, separated primary action)

    private func tripActionBar(viewModel: TripDetailViewModel) -> some View {
        HStack(spacing: 0) {
            // Left group: navigation actions
            HStack(spacing: 0) {
                actionBarButton(symbol: "map.fill", label: "Map") {
                    showMap = true
                }
                actionBarButton(symbol: "airplane", label: "Bookings") {
                    showBookings = true
                }
                actionBarButton(symbol: "creditcard", label: "Budget") {
                    showBudget = true
                }
            }

            // Separator
            Capsule()
                .fill(AppColors.appDivider)
                .frame(width: 1, height: 28)
                .padding(.horizontal, 2)

            // Right: primary "Add" action (separated like Tab role: .search)
            actionBarPrimaryButton {
                addPlaceTargetDay = trip.currentDayNumber ?? 1
                showAddPlace = true
            }
        }
        .padding(.horizontal, AppSpacing.md)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .background {
            glassBar
        }
    }

    /// Glass background that extends through the safe area.
    private var glassBar: some View {
        ZStack {
            // Frosted glass base
            Rectangle()
                .fill(.ultraThinMaterial)

            // Subtle top highlight for depth
            VStack(spacing: 0) {
                Rectangle()
                    .fill(.white.opacity(0.15))
                    .frame(height: 0.5)
                Spacer()
            }
        }
        .ignoresSafeArea(edges: .bottom)
    }

    // MARK: - Action Bar Buttons

    private func actionBarButton(symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button {
            HapticManager.light()
            action()
        } label: {
            VStack(spacing: 3) {
                Image(systemName: symbol)
                    .font(.system(size: 20, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(AppColors.textSecondary)
                    .frame(height: 28)

                Text(label)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(AppColors.textTertiary)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .contentShape(Rectangle())
        }
        .buttonStyle(ActionBarPressStyle())
        .accessibilityLabel(label)
    }

    /// Primary creation button — separated to the right with a filled capsule.
    private func actionBarPrimaryButton(action: @escaping () -> Void) -> some View {
        Button {
            HapticManager.medium()
            action()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .bold))
                Text("Add")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 20)
            .frame(height: 40)
            .background(
                Capsule()
                    .fill(AppColors.appPrimary)
                    .shadow(color: AppColors.appPrimary.opacity(0.25), radius: 8, x: 0, y: 4)
            )
        }
        .buttonStyle(ActionBarPressStyle())
        .accessibilityLabel("Add place or booking")
    }

    // MARK: - Itinerary Content (always visible, no tab switching)

    @ViewBuilder
    private func itineraryTab(viewModel: TripDetailViewModel) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    TripDetailHeroHeader(trip: viewModel.trip)

                    LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
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
                }
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .topLeading)
            }
            .contentMargins(.bottom, AppSpacing.sm, for: .scrollContent)
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
                PillButtonView(
                    sfSymbol: "checklist",
                    label: "Checklist",
                    trailingDetail: viewModel.checklistTotalCount > 0
                        ? " \(viewModel.checklistDoneCount)/\(viewModel.checklistTotalCount)"
                        : nil,
                    isActive: true
                ) {
                    HapticManager.light()
                    showTripChecklists = true
                }
                PillButtonView(
                    sfSymbol: "note.text",
                    label: "Notes",
                    trailingDetail: viewModel.noteCount > 0 ? " \(viewModel.noteCount)" : nil,
                    isActive: true
                ) {
                    HapticManager.light()
                    showTripNotes = true
                }
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

// MARK: - Action Bar Button Style

private struct ActionBarPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.90 : 1.0)
            .opacity(configuration.isPressed ? 0.7 : 1.0)
            .animation(AppSpring.snappy, value: configuration.isPressed)
    }
}

// MARK: - Hero header (cover image)

/// Edge‑to‑edge cover in a **fixed** hero rect: one width × one height, `aspectRatio(.fill)`, top‑pinned.
/// Previous version used `visibleHeroHeight + navChromeTop` inside a **bottom‑aligned** `ZStack` clipped to
/// `visibleHeroHeight`, which discarded the **top** of the bitmap (wrong crop / “card” look).
private struct TripDetailHeroHeader: View {
    let trip: Trip

    private var statusLabel: String {
        switch trip.status {
        case .upcoming: return "Upcoming"
        case .active: return "Active"
        case .past: return "Past"
        }
    }

    private var heroHeight: CGFloat {
        TripDetailOverlayMetrics.visibleHeroHeight
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            GeometryReader { proxy in
                let width = max(proxy.size.width, 1)
                heroCoverSurface(width: width, height: heroHeight)
                    .frame(width: width, height: heroHeight, alignment: .top)
                    .clipped()
            }
            .frame(height: heroHeight)
            .frame(maxWidth: .infinity, alignment: .top)
            .allowsHitTesting(false)

            LinearGradient(
                colors: [
                    Color.black.opacity(0.0),
                    Color.black.opacity(0.38),
                    Color.black.opacity(0.72),
                ],
                startPoint: UnitPoint(x: 0.5, y: 0.15),
                endPoint: .bottom
            )
            .frame(maxWidth: .infinity)
            .frame(height: heroHeight)
            .allowsHitTesting(false)

            VStack(alignment: .leading, spacing: AppSpacing.sm) {
                Spacer(minLength: 0)
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
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .shadow(color: .black.opacity(0.35), radius: 6, x: 0, y: 2)

                Text("\(trip.startDate.shortFormatted) – \(trip.endDate.shortFormatted)")
                    .font(.appCaption)
                    .foregroundStyle(.white.opacity(0.92))
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .shadow(color: .black.opacity(0.3), radius: 4, x: 0, y: 1)
            }
            .padding(AppSpacing.lg)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
        .frame(height: heroHeight)
        .frame(maxWidth: .infinity)
        .clipped()
    }

    @ViewBuilder
    private func heroCoverSurface(width: CGFloat, height: CGFloat) -> some View {
        if let urlString = trip.coverImageUrl, let url = URL(string: urlString) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .empty:
                    ZStack {
                        TripDetailOverlayMetrics.heroImageLoadingBackground
                        ProgressView()
                            .tint(.white)
                    }
                    .frame(width: width, height: height)
                    .clipped()
                case .success(let image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: width, height: height)
                        .clipped()
                case .failure:
                    PlaceholderGradientView(destinationName: trip.destination)
                        .frame(width: width, height: height)
                        .clipped()
                @unknown default:
                    PlaceholderGradientView(destinationName: trip.destination)
                        .frame(width: width, height: height)
                        .clipped()
                }
            }
        } else {
            PlaceholderGradientView(destinationName: trip.destination)
                .frame(width: width, height: height)
                .clipped()
        }
    }
}

private enum TripDetailOverlayMetrics {
    /// Taller than the previous 240pt strip for a more cinematic, travel‑premium cover proportion.
    static let visibleHeroHeight: CGFloat = 304
    static let heroImageLoadingBackground = Color(red: 0.12, green: 0.12, blue: 0.14)
}

