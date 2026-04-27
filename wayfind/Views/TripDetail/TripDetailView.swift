import CoreLocation
import Observation
import SwiftUI

/// Vertical offset of the itinerary `VStack` in `tripDetailScroll` — turns negative as the user scrolls up.
private struct TripDetailScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct TripDetailDayHeaderMinYKey: PreferenceKey {
    static var defaultValue: CGFloat = .infinity
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = min(value, nextValue())
    }
}

struct TripDetailView: View {
    @Environment(DataService.self) private var dataService
    @Environment(ToastManager.self) private var toastManager
    @Environment(CollaborationStore.self) private var collaborationStore
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
    @State private var showMembersSheet = false
    @State private var showRecentActivitySheet = false
    /// Activity photo stacks for non-booking timeline rows (`place.id` → thumbnails).
    @State private var itineraryPhotoStacks: [UUID: [ActivityFeedPhotoStackItem]] = [:]
    @State private var itineraryPhotosTarget: ActivityPhotosSheetTarget?
    @State private var placeToEdit: Place?
    @State private var placeToMove: Place?
    @State private var selectedPlace: Place?
    @State private var selectedPlacePrevious: Place?
    /// Wave 1.2 — when non-nil, presents `BookingAttachmentsSheet` for
    /// the booking row encoded in this `Place`.
    @State private var bookingForAttachments: Place?
    /// Wave 2.1 — calendar sync onboarding + status.
    @State private var showCalendarOnboarding: Bool = false
    @State private var calendarSyncService: CalendarSyncService = CalendarSyncService()
    @State private var calendarSyncInFlight: Bool = false
    /// Wave 3.3 — live-updating flight status cache for this trip's
    /// flight bookings. Bound on `.task`; unbound on `.onDisappear`.
    @State private var flightTracking: FlightTrackingService = FlightTrackingService()
    /// Fallback when `trip_days.timezone` is missing: trip-center geocode, else device.
    @State private var tripTimelineGeocodedTimeZone: TimeZone = .current

    @Environment(\.dismiss) private var dismiss
    @State private var isDayHeaderPinnedToNavigation = false
    /// Hide the inline nav title while the hero shows the trip name; reveal after scrolling.
    @State private var showInlineTripTitle = false

    let trip: Trip

    /// Phase 3 — fires once the viewmodel has been instantiated so the
    /// host (`AppRootTabView`) can hand it to `TripRealtimeService`. The
    /// realtime service needs a direct viewmodel reference because the
    /// kick handler refetches `loadTripData()` on a meaningful change.
    var onViewModelCreated: ((TripDetailViewModel) -> Void)? = nil
    /// Optional handle from the parent tab view used by the Budget pill in
    /// the pills row to switch to the dedicated Budget tab. When `nil` the
    /// pill is hidden — keeps this view standalone-renderable in previews.
    var onOpenBudgetTab: (() -> Void)? = nil
    /// Owned by `AppRootTabView` so the Budget tab and the pill on the home
    /// tab read from the same snapshot. The pill shows the current trip
    /// total when present; on a fresh trip we just show "Add Expense".
    var budgetViewModel: BudgetViewModel? = nil

    private var tripBookingCount: Int {
        viewModel?.totalBookingsCount ?? 0
    }

    private var checklistToolbarAccessibilityLabel: String {
        guard let viewModel, viewModel.checklistTotalCount > 0 else {
            return String(localized: "Checklist")
        }
        return String(
            localized: "Checklist, \(viewModel.checklistDoneCount) of \(viewModel.checklistTotalCount) complete"
        )
    }

    private var notesToolbarAccessibilityLabel: String {
        guard let viewModel, viewModel.noteCount > 0 else {
            return String(localized: "Notes")
        }
        return String(localized: "Notes, \(viewModel.noteCount)")
    }

    /// Hero (cover + title) is on-screen only after the initial timeline load.
    private var tripDetailShowsHeroWithContent: Bool {
        guard let viewModel else { return false }
        return !(viewModel.isLoading && viewModel.scheduledDays.isEmpty)
    }

    /// Avatars live in the nav bar while loading, when the hero is hidden, or after the user scrolls past the hero.
    private var showTripMembersInNavigationBar: Bool {
        !tripDetailShowsHeroWithContent || showInlineTripTitle
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
                    await refreshItineraryPhotoStacks()
                }
                toastManager.show(ToastData(message: "Trip updated", type: .success))
            }
        }
        .sheet(item: $selectedPlace) { place in
            PlaceDetailSheet(
                place: place,
                previousPlace: selectedPlacePrevious,
                tripId: viewModel?.trip.id ?? trip.id,
                onEdit: { placeToEdit = place },
                onMove: { placeToMove = place },
                onDelete: {
                    if let vm = viewModel {
                        deletePlace(place, viewModel: vm)
                    }
                    selectedPlace = nil
                }
            )
            .onDisappear {
                Task { await refreshItineraryPhotoStacks() }
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
                        await refreshItineraryPhotoStacks()
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
                                await refreshItineraryPhotoStacks()
                            }
                        }
                    ))
                }
            }
        }
        .sheet(item: $placeToEdit) { place in
            if place.isBooking {
                NavigationStack {
                    AddBookingView(
                        editingPlace: place,
                        onSave: { updatedPlace, cost in
                            Task {
                                await dataService.updatePlace(updatedPlace)
                                await viewModel?.loadTripData()
                                await refreshItineraryPhotoStacks()
                                await trackBookingExpenseIfNeeded(place: updatedPlace, cost: cost)
                            }
                            toastManager.show(makeBookingSavedToast(cost: cost, isUpdate: true))
                        },
                        targetDayId: place.itineraryDayId
                    )
                }
            } else {
                EditPlaceView(place: place) { updatedPlace in
                    Task {
                        await dataService.updatePlace(updatedPlace)
                        await viewModel?.loadTripData()
                        await refreshItineraryPhotoStacks()
                    }
                    toastManager.show(ToastData(message: "Updated", type: .success))
                }
            }
        }
        .sheet(item: $bookingForAttachments) { place in
            BookingAttachmentsSheet(
                bookingId: place.id,
                tripId: viewModel?.trip.id ?? trip.id,
                bookingTitle: place.name
            )
        }
        .navigationDestination(isPresented: $showTripNotes) {
            TripNotesView(trip: viewModel?.trip ?? trip)
        }
        .navigationDestination(isPresented: $showTripChecklists) {
            TripChecklistsView(trip: viewModel?.trip ?? trip)
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
        // Per-surface access revocation (Phase 1.5): if the owner removes
        // access while a member is currently in Notes, the realtime layer
        // (Phase 3) flips the gate and we bail out of the pushed view +
        // toast. Documents is popped from the hub stack in `AppRootTabView`.
        .onChange(of: collaborationStore.canViewNotes) { _, canView in
            if !canView, showTripNotes {
                showTripNotes = false
                toastManager.show(ToastData(
                    message: "The owner removed your access to notes",
                    type: .warning,
                    duration: 3
                ))
            }
        }
        .navigationDestination(isPresented: $showAddBooking) {
            if let vm = viewModel, let targetDayId = vm.scheduledDays.first(where: { $0.dayNumber == addPlaceTargetDay })?.id {
                AddBookingView(
                    onSave: { savedPlace, cost in
                        Task {
                            await vm.loadTripData()
                            await refreshItineraryPhotoStacks()
                            await trackBookingExpenseIfNeeded(place: savedPlace, cost: cost)
                        }
                        toastManager.show(makeBookingSavedToast(cost: cost, isUpdate: false))
                    },
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
                        await refreshItineraryPhotoStacks()
                    }
                    HapticManager.success()
                    showAddPlace = false
                }
            }
        }
        .task {
            if viewModel == nil {
                let created = TripDetailViewModel(trip: trip, dataService: dataService)
                viewModel = created
                onViewModelCreated?(created)
            }
            await viewModel?.loadTripData()
            await refreshItineraryPhotoStacks()
            bannerDismissed = discoveryManager.isBannerDismissed(for: trip.id)
            await flightTracking.bind(tripId: trip.id)
        }
        .onDisappear {
            // Drop the realtime channel so a backgrounded session
            // doesn't keep eating realtime quota.
            Task { await flightTracking.unbind() }
        }
        // The +ai tab posts this notification after applying an AI Day Planner
        // result. `TabView` keeps this view alive between switches, so `.task`
        // doesn't re-run — we explicitly trigger a reload here.
        .onReceive(NotificationCenter.default.publisher(for: .tripActivitiesDidChange)) { note in
            guard let id = note.userInfo?[TripActivitiesNotificationKeys.tripId] as? UUID,
                  id == trip.id else { return }
            Task {
                await viewModel?.loadTripData()
                await refreshItineraryPhotoStacks()
            }
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
                    itineraryTab(viewModel: viewModel)
                }
            } else {
                AppColors.appBackground
                    .overlay { ProgressView() }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppColors.appBackground)
        .navigationTitle(showInlineTripTitle ? (viewModel?.trip.title ?? trip.title) : "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if showTripMembersInNavigationBar {
                    TripMembersAvatarStack(onTap: {}, heroOnPhoto: false, allowsTap: false)
                    TripMembersInviteButton(heroOnPhoto: false) {
                        showMembersSheet = true
                    }
                }

                Button {
                    HapticManager.light()
                    showTripChecklists = true
                } label: {
                    Image(systemName: "checklist")
                }
                .tint(.primary)
                .accessibilityLabel(checklistToolbarAccessibilityLabel)
                .accessibilityHint("Opens the checklist for this trip.")

                if collaborationStore.canViewNotes {
                    Button {
                        HapticManager.light()
                        showTripNotes = true
                    } label: {
                        Image(systemName: "note.text")
                    }
                    .tint(.primary)
                    .accessibilityLabel(notesToolbarAccessibilityLabel)
                    .accessibilityHint("Opens notes for this trip.")
                }

                Menu {
                    if collaborationStore.canManage {
                        // Owner-only: Edit Trip wraps a destructive cascade
                        // (it can shrink the date range and drop activities
                        // on those days). Editors can change activities
                        // through the inline UI but not the trip itself in
                        // Phase 1.
                        Button {
                            showEditTrip = true
                        } label: {
                            Label("Edit Trip", systemImage: "pencil")
                        }
                        Divider()
                    }
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
                    // Recent activity feed (Phase 4) — secondary surface,
                    // intentionally lives in the menu rather than the
                    // toolbar avatar slot which is reserved for Members.
                    Divider()
                    Button {
                        HapticManager.light()
                        showRecentActivitySheet = true
                    } label: {
                        Label("Recent activity", systemImage: "clock.arrow.circlepath")
                    }
                    Divider()
                    if CalendarSyncService.isEnabled(tripId: (viewModel?.trip.id ?? trip.id)) {
                        Button {
                            HapticManager.light()
                            Task { await runCalendarSync() }
                        } label: {
                            Label("Resync to Calendar", systemImage: "arrow.triangle.2.circlepath")
                        }
                        .disabled(calendarSyncInFlight)
                        Button(role: .destructive) {
                            HapticManager.light()
                            Task { await stopCalendarSync() }
                        } label: {
                            Label("Stop syncing to Calendar", systemImage: "calendar.badge.minus")
                        }
                    } else {
                        Button {
                            HapticManager.light()
                            showCalendarOnboarding = true
                        } label: {
                            Label("Sync to Apple Calendar", systemImage: "calendar.badge.plus")
                        }
                    }
                    if collaborationStore.canManage {
                        Divider()
                        Button(role: .destructive) {
                            showDeleteConfirmation = true
                        } label: {
                            Label("Delete Trip", systemImage: "trash")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("Trip actions")
            }
        }
        .sheet(isPresented: $showMembersSheet) {
            TripMembersSheet(trip: viewModel?.trip ?? trip)
        }
        .sheet(isPresented: $showRecentActivitySheet) {
            RecentActivitySheet(trip: viewModel?.trip ?? trip)
                .environment(dataService)
                .environment(collaborationStore)
        }
        .sheet(item: $itineraryPhotosTarget) { target in
            Group {
                switch target.presentation {
                case .galleryOnly:
                    ActivityPhotoGallerySheet(
                        activityId: target.activityId,
                        tripId: viewModel?.trip.id ?? trip.id,
                        activityTitle: target.title
                    )
                    .environment(dataService)
                case .manage:
                    ActivityPhotosSheet(
                        activityId: target.activityId,
                        tripId: viewModel?.trip.id ?? trip.id,
                        activityTitle: target.title,
                        canEditAttachments: collaborationStore.canEdit
                    )
                    .environment(dataService)
                }
            }
            .onDisappear {
                Task { await refreshItineraryPhotoStacks() }
            }
        }
        .sheet(isPresented: $showCalendarOnboarding) {
            CalendarSyncOnboardingView(trip: viewModel?.trip ?? trip) {
                Task { await runCalendarSync() }
            }
        }
    }

    // MARK: - Activity photos (timeline)

    private func refreshItineraryPhotoStacks() async {
        guard let vm = viewModel else { return }
        let ids = vm.nonBookingTimelineActivityIds()
        guard !ids.isEmpty else {
            itineraryPhotoStacks = [:]
            return
        }
        let stacks = await ActivityAttachmentService.fetchFeedPhotoStacks(activityIds: ids)
        itineraryPhotoStacks = stacks
    }

    private func openItineraryActivityPhotos(for place: Place, presentation: ActivityPhotosSheetTarget.Presentation) {
        itineraryPhotosTarget = ActivityPhotosSheetTarget(
            activityId: place.id,
            title: place.name,
            presentation: presentation
        )
    }

    // MARK: - Calendar sync helpers (Wave 2.1)

    private func runCalendarSync() async {
        guard let viewModel else { return }
        calendarSyncInFlight = true
        defer { calendarSyncInFlight = false }
        let trip = viewModel.trip
        let days = viewModel.scheduledDays
        var placesByDayId: [UUID: [Place]] = [:]
        var bookings: [Place] = []
        for day in days {
            let dayPlaces = viewModel.places(for: day)
            placesByDayId[day.id] = dayPlaces
            bookings.append(contentsOf: dayPlaces.filter { $0.isBooking })
        }
        bookings.append(contentsOf: viewModel.wishlistPlaces.filter { $0.isBooking })
        await calendarSyncService.sync(
            trip: trip,
            days: days,
            placesByDayId: placesByDayId,
            bookings: bookings
        )
        switch calendarSyncService.status {
        case .completed(let count):
            toastManager.show(ToastData(
                message: "Synced \(count) events to Calendar",
                type: .success
            ))
        case .failed(let m):
            toastManager.show(ToastData(message: m, type: .error))
        default:
            break
        }
    }

    private func stopCalendarSync() async {
        guard let viewModel else { return }
        calendarSyncInFlight = true
        defer { calendarSyncInFlight = false }
        await calendarSyncService.unsync(trip: viewModel.trip)
        toastManager.show(ToastData(message: "Stopped syncing to Calendar", type: .success))
    }

    // MARK: - Itinerary Content

    @ViewBuilder
    private func itineraryTab(viewModel: TripDetailViewModel) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    TripDetailHeroHeader(
                        trip: viewModel.trip,
                        topBleed: KeyWindowSafeArea.topInset,
                        showMembersCluster: !showInlineTripTitle,
                        onInviteMembers: { showMembersSheet = true }
                    )

                    LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                        if !viewModel.scheduledDays.isEmpty {
                            HStack(alignment: .center, spacing: AppSpacing.md) {
                                Text(String(localized: "Itinerary"))
                                    .font(.title3.weight(.bold))
                                    .foregroundStyle(AppColors.textPrimary)

                                Spacer(minLength: 0)

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
                                        .fontWeight(.medium)
                                        .foregroundStyle(AppColors.appPrimary)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, AppSpacing.lg)
                            .padding(.top, AppSpacing.sm + AppSpacing.md)
                            .padding(.bottom, AppSpacing.md)
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel(String(localized: "Itinerary"))
                        }

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
                            .padding(.bottom, AppSpacing.sm)
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
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(
                            key: TripDetailScrollOffsetKey.self,
                            value: geo.frame(in: .named("tripDetailScroll")).minY
                        )
                    }
                )
            }
            .coordinateSpace(name: "tripDetailScroll")
            .ignoresSafeArea(edges: .top)
            // Reserve enough end-of-scroll clearance so the last day card and
            // "+ Add to Day" button rest above iOS 26's floating glass tab bar
            // even when fully scrolled. Mid-scroll occlusion under the bar is
            // intentional iOS 26 behavior (backdrop blur handles legibility).
            .contentMargins(
                .bottom,
                110,
                for: .scrollContent
            )
            .onPreferenceChange(TripDetailScrollOffsetKey.self) { minY in
                let threshold = TripDetailOverlayMetrics.inlineNavTitleRevealScrollMinY(
                    topSafeInset: KeyWindowSafeArea.topInset
                )
                let next = minY < threshold
                if next != showInlineTripTitle {
                    showInlineTripTitle = next
                }
            }
            .onPreferenceChange(TripDetailDayHeaderMinYKey.self) { minY in
                let next = minY <= TripDetailOverlayMetrics.stickyDayHeaderTop + 1
                if next != isDayHeaderPinnedToNavigation {
                    isDayHeaderPinnedToNavigation = next
                }
            }
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
            .task(id: tripTimelineTimeZoneRefreshKey(viewModel)) {
                await refreshTripTimelineGeocodedTimeZone(for: viewModel)
            }
        }
    }

    // MARK: - Day Section

    private func displayTimeZone(for day: ItineraryDay, viewModel: TripDetailViewModel) -> TimeZone {
        if let raw = day.timeZoneIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty,
           let tz = TimeZone(identifier: raw) {
            return tz
        }
        return tripTimelineGeocodedTimeZone
    }

    private func tripTimelineTimeZoneRefreshKey(_ vm: TripDetailViewModel) -> String {
        let tzKey = vm.scheduledDays
            .filter { $0.dayNumber > 0 }
            .map { "\($0.id.uuidString):\($0.timeZoneIdentifier ?? "")" }
            .joined(separator: ";")
        let c = "\(vm.trip.lat ?? 0),\(vm.trip.lng ?? 0)"
        return "\(vm.trip.id.uuidString)|\(tzKey)|\(c)|\(vm.scheduledDays.count)"
    }

    private func refreshTripTimelineGeocodedTimeZone(for vm: TripDetailViewModel) async {
        if let raw = vm.scheduledDays.first(where: { $0.dayNumber > 0 })?.timeZoneIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty,
           let tz = TimeZone(identifier: raw) {
            await MainActor.run { tripTimelineGeocodedTimeZone = tz }
            return
        }
        guard let lat = vm.trip.lat, let lng = vm.trip.lng, !lat.isNaN, !lng.isNaN else {
            await MainActor.run { tripTimelineGeocodedTimeZone = .current }
            return
        }
        let geocoder = CLGeocoder()
        do {
            let marks = try await geocoder.reverseGeocodeLocation(CLLocation(latitude: lat, longitude: lng))
            let tz = marks.first?.timeZone ?? .current
            await MainActor.run { tripTimelineGeocodedTimeZone = tz }
        } catch {
            await MainActor.run { tripTimelineGeocodedTimeZone = .current }
        }
    }

    @ViewBuilder
    private func daySection(day: ItineraryDay, viewModel: TripDetailViewModel) -> some View {
        let dayTZ = displayTimeZone(for: day, viewModel: viewModel)
        let places = viewModel.places(for: day)
        let ongoingForDay = viewModel.ongoingBookings(for: day)
        let isQuietEmptyDay = places.isEmpty && ongoingForDay.isEmpty
        let preview: String = {
            if !places.isEmpty {
                return places.prefix(3).map(\.name).joined(separator: ", ")
            }
            return ongoingForDay.first.map(\.place.name) ?? ""
        }()

        Section {
            if !viewModel.isDayCollapsed(day) {
                VStack(spacing: 0) {
                    Spacer()
                        .frame(height: AppSpacing.md)

                    DaySummaryView(places: places, showNoPlansYet: isQuietEmptyDay)

                    if isTodayDay(day) {
                        NowIndicatorView()
                            .padding(.horizontal, AppSpacing.lg)
                            .padding(.bottom, AppSpacing.sm)
                    }

                    ForEach(ongoingForDay, id: \.place.id) { item in
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
                        // Chapter break (Morning / Afternoon / Evening / Night)
                        // takes precedence over the travel-time gap when the
                        // time-of-day bucket changes. Within the same chapter
                        // we keep the lightweight gap row.
                        let prevChapter = index > 0
                            ? TimeOfDayChapter.from(places[index - 1].startTime, timeZone: dayTZ)
                            : nil
                        let currChapter = TimeOfDayChapter.from(place.startTime, timeZone: dayTZ)

                        if let chapter = currChapter, chapter != prevChapter {
                            TimeOfDayDividerView(chapter: chapter)
                                .padding(.bottom, AppSpacing.xs)
                        } else if index > 0 {
                            TimelineGapView(fromPlace: places[index - 1], toPlace: place)
                        }

                        Group {
                            if place.isBooking {
                                TimelineBookingCardView(
                                    place: place,
                                    dayNumber: day.dayNumber,
                                    timelineDisplayTimeZone: dayTZ,
                                    onEdit: { placeToEdit = place },
                                    onMoveToDay: { placeToMove = place },
                                    onDelete: { deletePlace(place, viewModel: viewModel) },
                                    onAttachments: { bookingForAttachments = place },
                                    flightStatus: flightStatus(for: place),
                                    isFlightStale: flightStaleness(for: place),
                                    flightTint: flightTint(for: place),
                                    isProUser: isProUserForFlightTracking,
                                    onUpgradeTap: { presentFlightPaywall() }
                                )
                            } else {
                                TimelinePlaceCardView(
                                    place: place,
                                    dayNumber: day.dayNumber,
                                    timelineDisplayTimeZone: dayTZ,
                                    onEdit: { placeToEdit = place },
                                    onMoveToDay: { placeToMove = place },
                                    onMoveToIdeas: { moveToIdeas(place, viewModel: viewModel) },
                                    onDelete: { deletePlace(place, viewModel: viewModel) },
                                    activityPhotoStack: itineraryPhotoStacks[place.id] ?? [],
                                    canEditActivityPhotos: collaborationStore.canEdit,
                                    onOpenActivityPhotoGallery: { openItineraryActivityPhotos(for: place, presentation: .galleryOnly) },
                                    onOpenActivityPhotoManage: { openItineraryActivityPhotos(for: place, presentation: .manage) }
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

                    if collaborationStore.canEdit {
                        InlineAddButtonView(
                            dayNumber: day.dayNumber
                        ) {
                            addPlaceTargetDay = day.dayNumber
                            showAddPlace = true
                        }
                        .padding(.horizontal, AppSpacing.lg)
                        .padding(.top, AppSpacing.xs)
                        .padding(.bottom, AppSpacing.lg)
                    } else {
                        // Viewers see normal trailing breathing room without
                        // an add-affordance they can't act on.
                        Spacer().frame(height: AppSpacing.lg)
                    }
                }
            }
        } header: {
            DaySectionHeaderView(
                day: day,
                dayLabel: viewModel.dayHeaderDayLabel(for: day),
                dateLabel: viewModel.dayHeaderDateLabel(for: day, timelineTimeZone: dayTZ),
                isCollapsed: viewModel.isDayCollapsed(day),
                contentPreview: preview,
                isQuietEmptyDay: isQuietEmptyDay
            ) {
                viewModel.toggleDayCollapse(day)
            }
            .background(
                GeometryReader { geo in
                    Color.clear.preference(
                        key: TripDetailDayHeaderMinYKey.self,
                        value: geo.frame(in: .global).minY
                    )
                }
            )
            .visualEffect { content, proxy in
                content.offset(
                    y: max(
                        0,
                        TripDetailOverlayMetrics.stickyDayHeaderTop - proxy.frame(in: .global).minY
                    )
                )
            }
            .id(day.id)
        } footer: {
            Color.clear
                .frame(height: AppSpacing.lg)
                .accessibilityHidden(true)
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
            await refreshItineraryPhotoStacks()
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
                    await refreshItineraryPhotoStacks()
                }
            }
        ))
    }

    private func deletePlace(_ place: Place, viewModel: TripDetailViewModel) {
        let deleted = place
        Task {
            await dataService.deletePlace(id: place.id)
            await viewModel.loadTripData()
            await refreshItineraryPhotoStacks()
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
                    await refreshItineraryPhotoStacks()
                }
            }
        ))
    }

    /// Phase 7 — when the booking form supplies a non-zero amount we mirror
    /// it into a tracked `trip_expense` so the budget hub picks it up
    /// immediately. The DB trigger `tg_sync_booking_expense` already does
    /// this for backend-imported bookings on `trip_bookings` insert/update;
    /// the iOS add-booking path writes to `trip_activities` (no trigger
    /// fires there), so we run the equivalent insert here. We default to a
    /// `full` split so the user's own ledger reflects the cost without
    /// surprising other collaborators with an unsolicited share — they can
    /// open the new expense in the budget tab and switch to Equal/Exact if
    /// they want to divide it.
    private func trackBookingExpenseIfNeeded(place: Place, cost: BookingCost?) async {
        guard let cost else { return }
        guard let userId = budgetViewModel?.currentUserId ?? collaborationStore.currentUserId else { return }
        let expense = TripExpense(
            id: UUID(),
            tripId: trip.id,
            userId: userId,
            payerUserId: userId,
            bookingId: place.isBooking ? place.id : nil,
            title: place.name,
            amount: cost.amount,
            currencyCode: cost.currency,
            category: ExpenseCategory.fromBookingKind(place.bookingType),
            splitType: .full,
            expenseDate: place.startTime ?? Date(),
            notes: nil,
            isAutoSynced: false,
            createdAt: nil,
            updatedAt: nil
        )
        let split = ExpenseSplit(
            id: UUID(),
            expenseId: expense.id,
            tripId: trip.id,
            userId: userId,
            amount: cost.amount,
            currencyCode: cost.currency,
            isAccepted: true,
            createdAt: nil,
            updatedAt: nil
        )
        if let budgetVM = budgetViewModel {
            _ = await budgetVM.addExpense(expense, splits: [split])
        } else {
            _ = await dataService.addExpense(expense, splits: [split])
        }
    }

    /// Builds the post-save toast for the booking form. When a cost was
    /// supplied we surface the tracked-as-expense confirmation with a "View"
    /// affordance to jump into the budget tab; otherwise we fall back to the
    /// generic "Booking added / updated" message so the toast still
    /// confirms the save.
    private func makeBookingSavedToast(cost: BookingCost?, isUpdate: Bool) -> ToastData {
        let saveMessage = isUpdate ? "Booking updated" : "Booking added"
        guard let cost else {
            return ToastData(message: saveMessage, type: .success)
        }
        let formattedAmount = MoneyFormatter.string(cost.amount, currency: cost.currency)
        let message = "\(saveMessage) · Tracked as \(formattedAmount) expense"
        if let openBudget = onOpenBudgetTab {
            return ToastData(
                message: message,
                type: .success,
                duration: 5,
                actionLabel: "View",
                actionHandler: { openBudget() }
            )
        }
        return ToastData(message: message, type: .success, duration: 5)
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
                                timelineDisplayTimeZone: tripTimelineGeocodedTimeZone,
                                onEdit: { placeToEdit = place },
                                onMoveToDay: { placeToMove = place },
                                onDelete: { deletePlace(place, viewModel: viewModel) },
                                onAttachments: { bookingForAttachments = place },
                                flightStatus: flightStatus(for: place),
                                isFlightStale: flightStaleness(for: place),
                                flightTint: flightTint(for: place),
                                isProUser: isProUserForFlightTracking,
                                onUpgradeTap: { presentFlightPaywall() }
                            )
                        } else {
                            TimelinePlaceCardView(
                                place: place,
                                dayNumber: 0,
                                timelineDisplayTimeZone: tripTimelineGeocodedTimeZone,
                                onEdit: { placeToEdit = place },
                                onMoveToDay: { placeToMove = place },
                                onDelete: { deletePlace(place, viewModel: viewModel) },
                                activityPhotoStack: itineraryPhotoStacks[place.id] ?? [],
                                canEditActivityPhotos: collaborationStore.canEdit,
                                onOpenActivityPhotoGallery: { openItineraryActivityPhotos(for: place, presentation: .galleryOnly) },
                                onOpenActivityPhotoManage: { openItineraryActivityPhotos(for: place, presentation: .manage) }
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

// MARK: - Hero header (cover image)

/// Full-bleed cover: image runs under the status bar; nav is transparent over the top (tinted via scrims in `TripDetailView`).
/// `topBleed` is added to the bitmap height so the same aspect crop reaches the top of the display.
private struct TripDetailHeroHeader: View {
    let trip: Trip
    var topBleed: CGFloat = 0
    var showMembersCluster: Bool = false
    var onInviteMembers: () -> Void = {}

    private var statusLabel: String {
        switch trip.status {
        case .upcoming: return "Upcoming"
        case .active: return "Active"
        case .past: return "Past"
        }
    }

    private var totalHeight: CGFloat {
        TripDetailOverlayMetrics.visibleHeroHeight + topBleed
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            GeometryReader { proxy in
                let width = max(proxy.size.width, 1)
                heroCoverSurface(width: width, height: totalHeight)
                    .frame(width: width, height: totalHeight, alignment: .top)
                    .clipped()
            }
            .frame(height: totalHeight)
            .frame(maxWidth: .infinity, alignment: .top)
            .allowsHitTesting(false)

            // Top + bottom dark scrims so the nav chrome and the hero text stay legible.
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.55), location: 0.0),
                    .init(color: .black.opacity(0.2), location: 0.16),
                    .init(color: .clear, location: 0.32),
                    .init(color: .clear, location: 0.42),
                    .init(color: .black.opacity(0.2), location: 0.62),
                    .init(color: .black.opacity(0.55), location: 0.86),
                    .init(color: .black.opacity(0.78), location: 1.0),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .allowsHitTesting(false)

            VStack(alignment: .leading, spacing: AppSpacing.sm) {
                Spacer(minLength: 0)

                HStack(alignment: .bottom, spacing: AppSpacing.md) {
                    VStack(alignment: .leading, spacing: AppSpacing.sm) {
                        Text(trip.title)
                            .font(.tripDetailHeroTitle)
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

                        Text(statusLabel)
                            .font(.appSmall)
                            .foregroundStyle(.white)
                            .padding(.horizontal, AppSpacing.sm)
                            .padding(.vertical, AppSpacing.xs)
                            .background(Color.white.opacity(0.22))
                            .clipShape(Capsule())
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if showMembersCluster {
                        HStack(alignment: .center, spacing: AppSpacing.sm) {
                            TripMembersAvatarStack(onTap: {}, heroOnPhoto: true, allowsTap: false)
                            TripMembersInviteButton(heroOnPhoto: true, action: onInviteMembers)
                        }
                        .shadow(color: .black.opacity(0.4), radius: 8, x: 0, y: 2)
                    }
                }
            }
            .padding(AppSpacing.lg)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
        .frame(height: totalHeight)
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
    /// Design height of the **main** cover below the status inset (nav floats over the upper part of this band).
    static let visibleHeroHeight: CGFloat = 304
    static let heroImageLoadingBackground = Color(red: 0.12, green: 0.12, blue: 0.14)
    /// SwiftUI pins section headers to the scroll view's top edge. The
    /// itinerary scroll intentionally ignores the top safe area for the hero,
    /// so day headers need a visual clamp to the app navigation bar instead.
    static let navigationBarHeight: CGFloat = 44
    static var stickyDayHeaderTop: CGFloat {
        KeyWindowSafeArea.topInset + navigationBarHeight
    }

    /// `ScrollView` content top `minY` in `tripDetailScroll` below which the hero
    /// (including its title) has cleared the nav — show the inline navigation title.
    static func inlineNavTitleRevealScrollMinY(topSafeInset: CGFloat) -> CGFloat {
        let heroTotal = visibleHeroHeight + topSafeInset
        return -(heroTotal - navigationBarHeight - AppSpacing.lg)
    }
}

// MARK: - Wave 3.3 — Flight tracking helpers

extension TripDetailView {
    /// Look up a `FlightStatus` for the given booking row, if we have
    /// one cached. Booking IDs come from `Place.id` for booking rows
    /// (see `placeFromBooking` in the viewmodel).
    fileprivate func flightStatus(for place: Place) -> FlightStatus? {
        flightTracking.statusesByBookingId[place.id]
    }

    fileprivate func flightStaleness(for place: Place) -> Bool {
        guard let status = flightStatus(for: place) else { return false }
        return flightTracking.staleness(of: status)
    }

    fileprivate func flightTint(for place: Place) -> FlightStatus.DisplayState.Tint {
        guard let status = flightStatus(for: place) else { return .neutral }
        return flightTracking.tint(of: status)
    }

    /// Wave 4.5 — effective premium access check. Free-launch and paid
    /// users see the live status pill that pulses on update.
    fileprivate var isProUserForFlightTracking: Bool {
        EntitlementService.shared.hasPremiumAccess
    }

    /// Wave 4.5 — central paywall presentation for flight tracking.
    /// Routes through `PaywallPresenter` so the analytics shape and
    /// the offering selection match every other gate in the app.
    fileprivate func presentFlightPaywall() {
        PaywallPresenter.shared.present(
            .flightTracking,
            dataService: dataService,
            metadata: [
                "trip_id": trip.id.uuidString,
                "trigger": "flight_badge_tap",
            ]
        )
    }
}

// Lives in this file so SwiftUI canvas typechecking (single-file) always sees the hub next to `#Preview`.
/// iOS 26+: Map | spacer | Budget + Bookings + Documents | spacer | AI. Earlier OS: one `ToolbarItemGroup` (no spacers).
struct TripDetailHubBottomBar: ToolbarContent {
    var showsAI: Bool
    var showsDocuments: Bool
    var onMap: () -> Void
    var onBudget: () -> Void
    var onBookings: () -> Void
    var onDocuments: () -> Void
    var onAI: () -> Void

    var body: some ToolbarContent {
        if #available(iOS 26.0, *) {
            ToolbarItemGroup(placement: .bottomBar) {
                mapButton
            }
            ToolbarSpacer(.flexible, placement: .bottomBar)
            ToolbarItemGroup(placement: .bottomBar) {
                budgetBookingsDocumentsButtons
            }
            if showsAI {
                ToolbarSpacer(.flexible, placement: .bottomBar)
                ToolbarItem(placement: .bottomBar) {
                    aiButton
                }
            }
        } else {
            ToolbarItemGroup(placement: .bottomBar) {
                mapButton
                budgetBookingsDocumentsButtons
                if showsAI {
                    aiButton
                }
            }
        }
    }

    private var mapButton: some View {
        Button(action: onMap) {
            Image(systemName: "map.fill")
        }
        .tint(.primary)
        .accessibilityLabel(String(localized: "Map"))
        .accessibilityHint(
            String(localized: "Opens the map for this trip. Tap Back to return to the itinerary.")
        )
    }

    private var budgetBookingsDocumentsButtons: some View {
        Group {
            Button(action: onBudget) {
                Image(systemName: "creditcard")
            }
            .tint(.primary)
            .accessibilityLabel(String(localized: "Budget"))
            .accessibilityHint(
                String(localized: "Opens the budget for this trip. Tap Back to return to the itinerary.")
            )

            Button(action: onBookings) {
                Image(systemName: "suitcase.fill")
            }
            .tint(.primary)
            .accessibilityLabel(String(localized: "Bookings"))
            .accessibilityHint(
                String(localized: "Opens bookings for this trip. Tap Back to return to the itinerary.")
            )

            if showsDocuments {
                Button(action: onDocuments) {
                    Image(systemName: "doc.text")
                }
                .tint(.primary)
                .accessibilityLabel(String(localized: "Documents"))
                .accessibilityHint(
                    String(localized: "Opens documents for this trip. Tap Back to return to the itinerary.")
                )
            }
        }
    }

    private var aiButton: some View {
        Button {
            HapticManager.light()
            onAI()
        } label: {
            Image(systemName: "sparkles")
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(AppColors.appPrimary)
        }
        .tint(AppColors.appPrimary)
        .accessibilityLabel(String(localized: "AI"))
        .accessibilityHint(String(localized: "Opens the day planner for this trip."))
    }
}

#if DEBUG
private enum TripDetailView_Previews {}

/// Hosts `TripDetailView` with the same environments as `AppRootTabView`.
/// Timeline data comes from `MockDataService` when `AppConfig.useRealBackend` is `false`
/// (`Trip.preview.id` matches the mock Paris trip).
private struct TripDetailPreviewHost: View {
    let trip: Trip
    @State private var dataService = DataService()
    @State private var toastManager = ToastManager()
    @State private var collaborationStore = CollaborationStore()

    var body: some View {
        NavigationStack {
            TripDetailView(trip: trip)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Label("Trips", systemImage: "chevron.backward")
                            .allowsHitTesting(false)
                    }
                    TripDetailHubBottomBar(
                        showsAI: true,
                        showsDocuments: true,
                        onMap: {},
                        onBudget: {},
                        onBookings: {},
                        onDocuments: {},
                        onAI: {}
                    )
                }
        }
        .environment(dataService)
        .environment(toastManager)
        .environment(collaborationStore)
        .task(id: trip.id) {
            collaborationStore.bind(to: trip.id)
        }
    }
}

#Preview("Trip detail — Paris (mock timeline)") {
    TripDetailPreviewHost(trip: .preview)
        .frame(width: 402, height: 874)
}

#Preview("Trip detail — active dates") {
    TripDetailPreviewHost(trip: .previewActive)
        .frame(width: 402, height: 874)
}
#endif


// =============================================================================

