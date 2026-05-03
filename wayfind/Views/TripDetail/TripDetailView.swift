import CoreLocation
import MapKit
import Observation
import SwiftUI

/// Vertical offset of the itinerary `VStack` in `tripDetailScroll` — turns negative as the user scrolls up.
private struct TripDetailScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct TripDetailDayHeaderNavigationCandidate: Equatable {
    let id: UUID
    let title: String
    let minY: CGFloat
    let maxY: CGFloat
}

private struct TripDetailDayHeaderNavigationKey: PreferenceKey {
    static var defaultValue: [TripDetailDayHeaderNavigationCandidate] = []
    static func reduce(
        value: inout [TripDetailDayHeaderNavigationCandidate],
        nextValue: () -> [TripDetailDayHeaderNavigationCandidate]
    ) {
        value.append(contentsOf: nextValue())
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
    @State private var showBudgetSheet = false
    @State private var showBookingsSheet = false
    @State private var showAddPlace = false
    @State private var showAddBooking = false
    @State private var addPlaceTargetDay: Int = 1
    @State private var hasAutoScrolled = false
    @State private var discoveryManager = ForwardingDiscoveryManager()
    @State private var forwardingEmailAddress: String?
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
    @Environment(\.colorScheme) private var colorScheme
    @State private var activeItineraryNavigationTitle: String?
    /// Hide the inline nav title while the hero shows the trip name; reveal after scrolling.
    @State private var showInlineTripTitle = false

    let trip: Trip

    /// Phase 3 — fires once the viewmodel has been instantiated so the
    /// host (`AppRootTabView`) can hand it to `TripRealtimeService`. The
    /// realtime service needs a direct viewmodel reference because the
    /// kick handler refetches `loadTripData()` on a meaningful change.
    var onViewModelCreated: ((TripDetailViewModel) -> Void)? = nil
    var onCloseTrip: (() -> Void)? = nil
    /// Optional handle from the parent tab view used by the Budget pill in
    /// the pills row to switch to the dedicated Budget tab. When `nil` the
    /// pill is hidden — keeps this view standalone-renderable in previews.
    var onOpenMap: (() -> Void)? = nil
    var onOpenBudgetTab: (() -> Void)? = nil
    var onOpenBookingsTab: (() -> Void)? = nil
    var onOpenDocumentsTab: (() -> Void)? = nil
    var onOpenAIPlanner: (() -> Void)? = nil
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
        !tripDetailShowsHeroWithContent || shouldShowOpaqueNavigationBar
    }

    private var shouldShowOpaqueNavigationBar: Bool {
        !tripDetailShowsHeroWithContent || showInlineTripTitle || activeItineraryNavigationTitle != nil
    }

    private var shouldCollapseNavigationToolbarActions: Bool {
        shouldShowOpaqueNavigationBar
    }

    private var navigationBarTitle: String {
        if let activeItineraryNavigationTitle {
            return activeItineraryNavigationTitle
        }
        return shouldShowOpaqueNavigationBar ? (viewModel?.trip.title ?? trip.title) : ""
    }

    private var navigationToolbarColorScheme: ColorScheme {
        shouldShowOpaqueNavigationBar ? colorScheme : .dark
    }

    private var checklistProgressText: String {
        guard let viewModel else { return "0/0" }
        return "\(viewModel.checklistDoneCount)/\(viewModel.checklistTotalCount)"
    }

    @ViewBuilder
    private var checklistToolbarButton: some View {
        Button {
            HapticManager.light()
            showTripChecklists = true
        } label: {
            Image(systemName: "checklist")
        }
        .accessibilityLabel(checklistToolbarAccessibilityLabel)
        .accessibilityHint("Opens the checklist for this trip.")
    }

    @ViewBuilder
    private var notesToolbarButton: some View {
        if collaborationStore.canViewNotes {
            Button {
                HapticManager.light()
                showTripNotes = true
            } label: {
                Image(systemName: "note.text")
            }
            .accessibilityLabel(notesToolbarAccessibilityLabel)
            .accessibilityHint("Opens notes for this trip.")
        }
    }

    @ViewBuilder
    private var checklistNotesToolbarGroup: some View {
        HStack(spacing: 0) {
            Button {
                HapticManager.light()
                showTripChecklists = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "checklist")
                    Text(checklistProgressText)
                        .font(.appCaption.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(AppColors.textPrimary)
                }
                .frame(minHeight: 28)
                .padding(.leading, 7)
                .padding(.trailing, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(checklistToolbarAccessibilityLabel)
            .accessibilityHint("Opens the checklist for this trip.")

            Rectangle()
                .fill(AppColors.appDivider)
                .frame(width: 1, height: 18)

            if collaborationStore.canViewNotes {
                Button {
                    HapticManager.light()
                    showTripNotes = true
                } label: {
                    Image(systemName: "note.text")
                        .frame(width: 30)
                        .frame(minHeight: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(notesToolbarAccessibilityLabel)
                .accessibilityHint("Opens notes for this trip.")
            }
        }
        .padding(.vertical, 3)
        .environment(\.colorScheme, navigationToolbarColorScheme)
    }

    @ViewBuilder
    private var tripActionsMenuContent: some View {
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
    }

    @ViewBuilder
    private var compactTripToolbarMenuContent: some View {
        tripActionsMenuContent
    }

    @ViewBuilder
    private var tripBudgetSheetContent: some View {
        if collaborationStore.canViewExpenses {
            TripBudgetTabView(
                trip: viewModel?.trip ?? trip,
                viewModel: budgetViewModel,
                supportsPullToRefresh: false
            )
                .navigationTitle("Budget")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button {
                            showBudgetSheet = false
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .accessibilityLabel(String(localized: "Close"))
                    }
                }
        } else {
            ContentUnavailableView {
                Label("Budget locked", systemImage: "lock.fill")
            } description: {
                Text("You don’t have access to trip expenses. Ask the trip owner if you need access.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Budget")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        showBudgetSheet = false
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel(String(localized: "Close"))
                }
            }
        }
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
                Task { await refreshItineraryPhotoStacks(forceRefresh: true) }
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
                            guard await dataService.updatePlace(updatedPlace) else {
                                toastManager.show(ToastData(message: "Could not save booking", type: .error))
                                return false
                            }
                            await viewModel?.loadTripData()
                            await refreshItineraryPhotoStacks()
                            await trackBookingExpenseIfNeeded(place: updatedPlace, cost: cost)
                            toastManager.show(makeBookingSavedToast(cost: cost, isUpdate: true))
                            return true
                        },
                        targetDayId: place.itineraryDayId,
                        showsCloseButton: true
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
        .sheet(isPresented: $showTripNotes) {
            NavigationStack {
                TripNotesView(trip: viewModel?.trip ?? trip)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button {
                                showTripNotes = false
                            } label: {
                                Image(systemName: "xmark")
                            }
                            .accessibilityLabel(String(localized: "Close"))
                        }
                    }
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            .presentationBackground(AppColors.appBackground)
        }
        .navigationDestination(isPresented: $showTripChecklists) {
            TripChecklistsView(trip: viewModel?.trip ?? trip)
        }
        .sheet(isPresented: $showBudgetSheet) {
            NavigationStack {
                tripBudgetSheetContent
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showBookingsSheet) {
            NavigationStack {
                BookingsScreenView(
                    trip: viewModel?.trip ?? trip,
                    onOpenBudgetTab: { showBudgetSheet = true }
                )
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button {
                            showBookingsSheet = false
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .accessibilityLabel(String(localized: "Close"))
                    }
                }
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
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
        // (Phase 3) flips the gate and we dismiss the sheet +
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
        .sheet(isPresented: $showAddBooking) {
            if let vm = viewModel, let targetDayId = vm.scheduledDays.first(where: { $0.dayNumber == addPlaceTargetDay })?.id {
                NavigationStack {
                    AddBookingView(
                        onSave: { savedPlace, cost in
                            guard await dataService.addPlace(savedPlace) else {
                                toastManager.show(ToastData(message: "Could not save booking", type: .error))
                                return false
                            }
                            await vm.loadTripData()
                            await refreshItineraryPhotoStacks()
                            await trackBookingExpenseIfNeeded(place: savedPlace, cost: cost)
                            toastManager.show(makeBookingSavedToast(cost: cost, isUpdate: false))
                            return true
                        },
                        targetDayId: targetDayId,
                        showsCloseButton: true
                    )
                }
            }
        }
        .sheet(isPresented: $showAddPlace) {
            if let vm = viewModel {
                AddActivitySheet(
                    trip: vm.trip,
                    selectedDayNumber: addPlaceTargetDay,
                    days: vm.scheduledDays,
                    scheduledPlaces: vm.allScheduledPlaces(),
                    wishlistPlaces: vm.wishlistPlaces
                ) { savedPlace in
                    await vm.loadTripData()
                    await refreshItineraryPhotoStacks()
                    await MainActor.run {
                        HapticManager.success()
                        toastManager.show(ToastData(
                            message: "Added \(savedPlace.name) to your itinerary",
                            type: .success,
                            duration: 3
                        ))
                        showAddPlace = false
                    }
                } onCancel: {
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
            forwardingEmailAddress = await dataService.fetchForwardingEmailAddress(for: trip.id)
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
        .overlay(alignment: .top) {
            if shouldShowOpaqueNavigationBar {
                AppColors.appBackground
                    .frame(height: TripDetailOverlayMetrics.navigationChromeHeight)
                    .frame(maxWidth: .infinity, alignment: .top)
                    .ignoresSafeArea(edges: .top)
                    .allowsHitTesting(false)
            }
        }
        .navigationTitle(navigationBarTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(AppColors.appBackground, for: .navigationBar)
        .toolbarBackground(shouldShowOpaqueNavigationBar ? .visible : .hidden, for: .navigationBar)
        .toolbarColorScheme(navigationToolbarColorScheme, for: .navigationBar)
        .toolbar {
            if let onCloseTrip {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        onCloseTrip()
                    } label: {
                        Label("Trips", systemImage: "chevron.backward")
                    }
                }
            }

            if shouldCollapseNavigationToolbarActions {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        compactTripToolbarMenuContent
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("Trip actions")
                }
            } else {
                if showTripMembersInNavigationBar {
                    ToolbarItem(placement: .topBarTrailing) {
                        HStack(spacing: AppSpacing.sm) {
                            if hasAcceptedCollaborators {
                                TripMembersAvatarStack(onTap: {}, heroOnPhoto: false, allowsTap: false)
                            }
                            TripMembersInviteButton(heroOnPhoto: false) {
                                showMembersSheet = true
                            }
                        }
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        tripActionsMenuContent
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("Trip actions")
                }
            }

            TripDetailHubBottomBar(
                showsAI: collaborationStore.canEdit,
                showsDocuments: collaborationStore.canViewDocuments,
                showsNotes: collaborationStore.canViewNotes,
                onAddActivity: { openAddActivityFromToolbar() },
                onChecklist: {
                    HapticManager.light()
                    showTripChecklists = true
                },
                onNotes: {
                    HapticManager.light()
                    showTripNotes = true
                },
                onBudget: { showBudgetSheet = true },
                onBookings: { showBookingsSheet = true },
                onDocuments: { onOpenDocumentsTab?() },
                onAI: { onOpenAIPlanner?() }
            )
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
                case .manage(let entry):
                    ActivityPhotosSheet(
                        activityId: target.activityId,
                        tripId: viewModel?.trip.id ?? trip.id,
                        activityTitle: target.title,
                        manageEntry: entry,
                        canEditAttachments: collaborationStore.canEdit
                    )
                    .environment(dataService)
                }
            }
            .onDisappear {
                Task { await refreshItineraryPhotoStacks(forceRefresh: true) }
            }
        }
        .sheet(isPresented: $showCalendarOnboarding) {
            CalendarSyncOnboardingView(trip: viewModel?.trip ?? trip) {
                Task { await runCalendarSync() }
            }
        }
    }

    // MARK: - Activity photos (timeline)

    private func refreshItineraryPhotoStacks(forceRefresh: Bool = false) async {
        guard let vm = viewModel else { return }
        let ids = vm.nonBookingTimelineActivityIds()
        guard !ids.isEmpty else {
            itineraryPhotoStacks = [:]
            return
        }
        let stacks = await ActivityAttachmentService.fetchFeedPhotoStacks(
            activityIds: ids,
            forceRefresh: forceRefresh
        )
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

    private var hasAcceptedCollaborators: Bool {
        !collaborationStore.acceptedCollaborators.isEmpty
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
                        showMemberAvatars: hasAcceptedCollaborators,
                        onInviteMembers: { showMembersSheet = true }
                    )

                    TripDetailMapPreviewCard(
                        items: mapPreviewItems(viewModel: viewModel),
                        fallbackCoordinate: tripFallbackCoordinate(for: viewModel.trip),
                        onOpenMap: {
                            HapticManager.light()
                            onOpenMap?()
                        }
                    )
                    .padding(.horizontal, AppSpacing.lg)
                    .padding(.top, AppSpacing.lg)
                    .padding(.bottom, AppSpacing.sm)

                    LazyVStack(spacing: 0) {
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
                            .padding(.bottom, AppSpacing.xs)
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel(String(localized: "Itinerary"))
                        }

                        if let forwardingEmailAddress,
                           discoveryManager.shouldShowTimelineBanner(tripBookingCount: tripBookingCount, tripId: trip.id) && !bannerDismissed {
                            ForwardingBannerView(
                                email: forwardingEmailAddress,
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
            .onPreferenceChange(TripDetailDayHeaderNavigationKey.self) { candidates in
                let threshold = TripDetailOverlayMetrics.stickyDayHeaderTop + 1
                let next = candidates
                    .filter { $0.minY <= threshold && $0.maxY > threshold }
                    .max(by: { $0.minY < $1.minY })?
                    .title
                if next != activeItineraryNavigationTitle {
                    activeItineraryNavigationTitle = next
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

    private func openAddActivityFromToolbar() {
        guard let viewModel, let targetDay = defaultAddActivityDay(viewModel: viewModel) else {
            toastManager.show(ToastData(message: "Trip days are unavailable", type: .error))
            return
        }
        addPlaceTargetDay = targetDay.dayNumber
        HapticManager.light()
        showAddPlace = true
    }

    private func defaultAddActivityDay(viewModel: TripDetailViewModel) -> ItineraryDay? {
        if let currentDayNumber = viewModel.trip.currentDayNumber,
           let currentDay = viewModel.scheduledDays.first(where: { $0.dayNumber == currentDayNumber }) {
            return currentDay
        }
        return viewModel.scheduledDays.sorted { $0.dayNumber < $1.dayNumber }.first
    }

    private func mapPreviewItems(viewModel: TripDetailViewModel) -> [TripDetailMapPreviewItem] {
        var items: [TripDetailMapPreviewItem] = []
        let scheduledDays = viewModel.scheduledDays

        for day in scheduledDays {
            let places = viewModel.places(for: day)
                .filter { $0.hasUsableCoordinate }
            for (index, place) in places.enumerated() {
                items.append(TripDetailMapPreviewItem(
                    id: place.id,
                    coordinate: place.coordinate,
                    kind: place.isBooking ? .booking(place.bookingCategoryEnum) : .place(index + 1, day.dayNumber),
                    title: place.name
                ))
            }
        }

        let wishlistDayNumber = (scheduledDays.map(\.dayNumber).max() ?? 0) + 1
        let wishlistItems = viewModel.wishlistPlaces
            .filter { $0.hasUsableCoordinate }
            .enumerated()
            .map { index, place in
                TripDetailMapPreviewItem(
                    id: place.id,
                    coordinate: place.coordinate,
                    kind: place.isBooking ? .booking(place.bookingCategoryEnum) : .place(index + 1, wishlistDayNumber),
                    title: place.name
                )
            }
        items.append(contentsOf: wishlistItems)
        return items
    }

    private func tripFallbackCoordinate(for trip: Trip) -> CLLocationCoordinate2D? {
        guard let lat = trip.lat, let lng = trip.lng, CLLocationCoordinate2DIsValid(CLLocationCoordinate2D(latitude: lat, longitude: lng)) else {
            return nil
        }
        return CLLocationCoordinate2D(latitude: lat, longitude: lng)
    }

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

    /// `TimelineGapView` follows this row; use a tighter bottom inset when it’s the slim spine cue.
    private func timelineRowBottomSpacing(afterIndex index: Int, rows: [TripTimelineDisplayRow]) -> CGFloat {
        guard index < rows.count - 1 else { return TimelineSpineMetrics.rowBottomSpacing }
        let from = rows[index].place
        let to = rows[index + 1].place
        if from.hasUsableCoordinate && to.hasUsableCoordinate {
            return TimelineSpineMetrics.rowBottomSpacingWhenFollowedByTravelGap
        }
        return TimelineSpineMetrics.rowBottomSpacing
    }

    @ViewBuilder
    private func daySection(day: ItineraryDay, viewModel: TripDetailViewModel) -> some View {
        let dayTZ = displayTimeZone(for: day, viewModel: viewModel)
        let places = viewModel.places(for: day)
        let timelineRows = viewModel.timelineDisplayRows(for: day, timelineTimeZone: dayTZ)
        let ongoingForDay = viewModel.ongoingBookings(for: day)
        let isQuietEmptyDay = timelineRows.isEmpty && ongoingForDay.isEmpty
        let emptyDayPrompt = emptyDayPrompt(for: day, isQuietEmptyDay: isQuietEmptyDay, viewModel: viewModel)
        let preview = collapsedDayPreview(places: places, ongoingBookings: ongoingForDay.map(\.place))
        let dayNavigationTitle = "\(viewModel.dayHeaderDayLabel(for: day)) · \(viewModel.dayHeaderDateLabel(for: day, timelineTimeZone: dayTZ))"

        Section {
            if !viewModel.isDayCollapsed(day) {
                VStack(spacing: 0) {
                    Spacer()
                        .frame(height: AppSpacing.md)

                    DaySummaryView(
                        places: places,
                        showNoPlansYet: isQuietEmptyDay,
                        emptyDayPrompt: emptyDayPrompt
                    )

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

                    VStack(spacing: 0) {
                        ForEach(Array(timelineRows.enumerated()), id: \.element.id) { index, row in
                            let place = row.place

                            if index > 0,
                               timelineRows[index - 1].place.hasUsableCoordinate,
                               place.hasUsableCoordinate {
                                TimelineGapView(
                                    tripId: viewModel.trip.id,
                                    cityProfileId: viewModel.trip.cityProfileId,
                                    fromPlace: timelineRows[index - 1].place,
                                    toPlace: place
                                )
                                .id("itinerary-gap-\(timelineRows[index - 1].id)-\(row.id)")
                            }

                            Group {
                                if place.isBooking {
                                    TimelineBookingCardView(
                                        place: place,
                                        dayNumber: day.dayNumber,
                                        timelineDisplayTimeZone: dayTZ,
                                        hotelTimelineRole: row.hotelTimelineRole,
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
                                    .onTapGesture {
                                        selectedPlacePrevious = index > 0 ? timelineRows[index - 1].place : nil
                                        selectedPlace = place
                                    }
                                } else {
                                    TimelinePlaceCardView(
                                        place: place,
                                        dayNumber: day.dayNumber,
                                        timelineDisplayTimeZone: dayTZ,
                                        onEdit: { placeToEdit = place },
                                        onMoveToDay: { placeToMove = place },
                                        onMoveToIdeas: { moveToIdeas(place, viewModel: viewModel) },
                                        onDelete: { deletePlace(place, viewModel: viewModel) },
                                        onSelectRow: {
                                            selectedPlacePrevious = index > 0 ? timelineRows[index - 1].place : nil
                                            selectedPlace = place
                                        },
                                        activityPhotoStack: itineraryPhotoStacks[place.id] ?? [],
                                        canEditActivityPhotos: collaborationStore.canEdit,
                                        onOpenActivityPhotoGallery: { openItineraryActivityPhotos(for: place, presentation: .galleryOnly) },
                                        onOpenActivityPhotoManage: { entry in
                                            openItineraryActivityPhotos(for: place, presentation: .manage(entry))
                                        }
                                    )
                                }
                            }
                            .padding(.horizontal, AppSpacing.lg)
                            .padding(
                                .bottom,
                                timelineRowBottomSpacing(afterIndex: index, rows: timelineRows)
                            )
                        }
                    }
                    .timelineSpineContinuousRail()

                    Spacer().frame(height: AppSpacing.lg)
                }
            }
        } header: {
            DaySectionHeaderView(
                day: day,
                dayLabel: viewModel.dayHeaderDayLabel(for: day),
                dateLabel: viewModel.dayHeaderDateLabel(for: day, timelineTimeZone: dayTZ),
                isCollapsed: viewModel.isDayCollapsed(day),
                contentPreview: preview,
                isQuietEmptyDay: isQuietEmptyDay,
                emptyDayPrompt: emptyDayPrompt
            ) {
                viewModel.toggleDayCollapse(day)
            }
            .id(day.id)
        } footer: {
            Color.clear
                .frame(height: AppSpacing.lg)
                .accessibilityHidden(true)
        }
        .background(
            GeometryReader { geo in
                let frame = geo.frame(in: .global)
                Color.clear.preference(
                    key: TripDetailDayHeaderNavigationKey.self,
                    value: [
                        TripDetailDayHeaderNavigationCandidate(
                            id: day.id,
                            title: dayNavigationTitle,
                            minY: frame.minY,
                            maxY: frame.maxY
                        )
                    ]
                )
            }
        )
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

                VStack(spacing: 0) {
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
                                    onOpenActivityPhotoManage: { entry in
                                        openItineraryActivityPhotos(for: place, presentation: .manage(entry))
                                    }
                                )
                            }
                        }
                        .padding(.horizontal, AppSpacing.lg)
                        .padding(.bottom, TimelineSpineMetrics.rowBottomSpacing)
                    }
                }
                .timelineSpineContinuousRail()
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

    private func emptyDayPrompt(for day: ItineraryDay, isQuietEmptyDay: Bool, viewModel: TripDetailViewModel) -> String {
        guard isQuietEmptyDay else { return "" }
        let firstQuietEmptyDay = viewModel.scheduledDays.first { candidate in
            let tz = displayTimeZone(for: candidate, viewModel: viewModel)
            return viewModel.timelineDisplayRows(for: candidate, timelineTimeZone: tz).isEmpty
                && viewModel.ongoingBookings(for: candidate).isEmpty
        }
        return firstQuietEmptyDay?.id == day.id
            ? "Add an activity or plan this day with AI"
            : "No plans yet"
    }

    private func collapsedDayPreview(places: [Place], ongoingBookings: [Place]) -> String {
        let stops = places.filter { !$0.isBooking }
        let stopCount = stops.count
        guard stopCount > 0 else {
            guard let first = ongoingBookings.first else { return "" }
            let category = first.bookingCategoryEnum ?? .hotel
            return category.ongoingSpanHeadline(bookingName: first.name)
        }

        let themes = curatedDayThemes(for: stops)
        let stopText = "\(stopCount) \(stopCount == 1 ? "stop" : "stops")"
        guard !themes.isEmpty else { return stopText }
        return "\(joinedDayThemes(themes)) · \(stopText)"
    }

    private func curatedDayThemes(for stops: [Place]) -> [String] {
        let categories = Set(stops.map(\.categoryEnum))
        var themes: [String] = []

        if categories.contains(.attraction) {
            themes.append("Landmarks")
        }
        if categories.contains(.nature) {
            themes.append("parks")
        }
        if stops.contains(where: { containsAny($0.name, ["museum", "gallery", "goma", "art"]) }) {
            themes.append("galleries")
        }
        if stops.contains(where: { containsAny($0.name, ["cathedral", "church", "temple", "mosque", "synagogue"]) }) {
            themes.append("cathedral walk")
        }
        if categories.contains(.shopping) {
            themes.append("shopping")
        }
        if categories.contains(.restaurant) {
            themes.append(stops.contains { isLunchStop($0) } ? "lunch" : "dinner")
        }
        if categories.contains(.nightlife) {
            themes.append("pubs")
        }
        if categories.contains(.transport) {
            themes.append("transfers")
        }

        return Array(themes.prefix(3))
    }

    private func joinedDayThemes(_ themes: [String]) -> String {
        switch themes.count {
        case 0:
            return ""
        case 1:
            return themes[0]
        case 2:
            return "\(themes[0]) and \(themes[1])"
        default:
            return "\(themes[0]), \(themes[1]), and \(themes[2])"
        }
    }

    private func containsAny(_ text: String, _ needles: [String]) -> Bool {
        let lowercased = text.localizedLowercase
        return needles.contains { lowercased.contains($0) }
    }

    private func isLunchStop(_ place: Place) -> Bool {
        if containsAny(place.name, ["lunch", "brunch", "cafe", "coffee", "bakery"]) {
            return true
        }
        guard let startTime = place.startTime else { return false }
        let hour = Calendar.current.component(.hour, from: startTime)
        return (10..<16).contains(hour)
    }
}

private enum TripDetailMapPreviewKind: Hashable {
    case place(Int, Int)
    case booking(BookingCategory?)
}

private struct TripDetailMapPreviewItem: Identifiable, Hashable {
    let id: UUID
    let coordinate: CLLocationCoordinate2D
    let kind: TripDetailMapPreviewKind
    let title: String

    static func == (lhs: TripDetailMapPreviewItem, rhs: TripDetailMapPreviewItem) -> Bool {
        lhs.id == rhs.id
            && lhs.coordinate.latitude == rhs.coordinate.latitude
            && lhs.coordinate.longitude == rhs.coordinate.longitude
            && lhs.kind == rhs.kind
            && lhs.title == rhs.title
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(coordinate.latitude)
        hasher.combine(coordinate.longitude)
        hasher.combine(kind)
        hasher.combine(title)
    }
}

private struct TripDetailMapPreviewCard: View {
    let items: [TripDetailMapPreviewItem]
    let fallbackCoordinate: CLLocationCoordinate2D?
    let onOpenMap: () -> Void

    @State private var position: MapCameraPosition = .automatic

    var body: some View {
        Button(action: onOpenMap) {
            ZStack(alignment: .topLeading) {
                mapPreview

                LinearGradient(
                    colors: [
                        .black.opacity(0.58),
                        .black.opacity(0.28),
                        .clear
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )

                VStack(alignment: .leading, spacing: AppSpacing.xs) {
                    Text("Places")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.white)
                    Label("\(items.count)", systemImage: "mappin.circle.fill")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.white.opacity(0.82))
                        .labelStyle(.titleAndIcon)
                }
                .padding(.leading, AppSpacing.md)
                .padding(.top, AppSpacing.md)
            }
            .frame(height: TripDetailMapPreviewMetrics.height)
            .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.xLarge, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: AppCornerRadius.xLarge, style: .continuous)
                    .strokeBorder(.white.opacity(0.16), lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: AppCornerRadius.xLarge, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Places map, \(items.count) places")
        .accessibilityHint("Opens the map for this trip.")
        .onAppear { updateCamera() }
        .onChange(of: items) { _, _ in updateCamera() }
    }

    private var mapPreview: some View {
        Map(position: $position, interactionModes: []) {
            ForEach(items.prefix(TripDetailMapPreviewMetrics.maxPins)) { item in
                Annotation(item.title, coordinate: item.coordinate, anchor: .bottom) {
                    annotationView(for: item)
                }
            }
        }
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func annotationView(for item: TripDetailMapPreviewItem) -> some View {
        switch item.kind {
        case .place(let index, let dayNumber):
            Text("\(index)")
                .font(.appCaption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: TripDetailMapPreviewMetrics.placePinSize, height: TripDetailMapPreviewMetrics.placePinSize)
                .background(AppColors.dayColor(for: dayNumber), in: Circle())
                .overlay {
                    Circle()
                        .strokeBorder(.white, lineWidth: TripDetailMapPreviewMetrics.placePinStrokeWidth)
                }
                .shadow(
                    color: .black.opacity(0.22),
                    radius: TripDetailMapPreviewMetrics.placePinShadowRadius,
                    y: TripDetailMapPreviewMetrics.placePinShadowY
                )
        case .booking(let category):
            Image(systemName: category?.sfSymbol ?? "ticket.fill")
                .font(.appCaption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: TripDetailMapPreviewMetrics.bookingPinSize, height: TripDetailMapPreviewMetrics.bookingPinSize)
                .background(category?.color ?? AppColors.appPrimary, in: RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous))
                .overlay(alignment: .bottom) {
                    Image(systemName: "triangle.fill")
                        // Tail scale matches pin shrink; triangle is a UIKit-style map-marker tail, not available as a TextStyle token.
                        .font(.system(size: TripDetailMapPreviewMetrics.bookingTailGlyphSize, weight: .semibold))
                        .foregroundStyle(category?.color ?? AppColors.appPrimary)
                        .rotationEffect(.degrees(180))
                        .offset(y: TripDetailMapPreviewMetrics.bookingTailOffsetY)
                }
                .padding(.bottom, TripDetailMapPreviewMetrics.bookingMarkerBottomPadding)
                .shadow(
                    color: .black.opacity(0.22),
                    radius: TripDetailMapPreviewMetrics.placePinShadowRadius,
                    y: TripDetailMapPreviewMetrics.placePinShadowY
                )
        }
    }

    private func updateCamera() {
        let coordinates = items.map(\.coordinate)
        if coordinates.isEmpty, let fallbackCoordinate {
            position = .region(MKCoordinateRegion(
                center: fallbackCoordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.08, longitudeDelta: 0.08)
            ))
            return
        }

        guard let region = Self.region(for: coordinates) else {
            position = .automatic
            return
        }
        position = .region(region)
    }

    private static func region(for coordinates: [CLLocationCoordinate2D]) -> MKCoordinateRegion? {
        guard !coordinates.isEmpty else { return nil }
        if coordinates.count == 1 {
            return MKCoordinateRegion(
                center: coordinates[0],
                span: MKCoordinateSpan(latitudeDelta: 0.035, longitudeDelta: 0.035)
            )
        }

        let lats = coordinates.map(\.latitude)
        let lngs = coordinates.map(\.longitude)
        guard let minLat = lats.min(),
              let maxLat = lats.max(),
              let minLng = lngs.min(),
              let maxLng = lngs.max() else {
            return nil
        }

        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(
                latitude: (minLat + maxLat) / 2,
                longitude: (minLng + maxLng) / 2
            ),
            span: MKCoordinateSpan(
                latitudeDelta: max((maxLat - minLat) * 1.5, 0.025),
                longitudeDelta: max((maxLng - minLng) * 1.5, 0.025)
            )
        )
    }
}

private enum TripDetailMapPreviewMetrics {
    static let height: CGFloat = 134
    static let maxPins = 16

    /// Pins on the trip-detail preview map are ~30% smaller than the original 34pt baseline so more of the route reads at a glance.
    private static let mapPreviewPinScale: CGFloat = 0.7
    private static let baselinePinSize: CGFloat = 34
    private static let baselinePlaceStroke: CGFloat = 2.5
    private static let baselineShadowRadius: CGFloat = 5
    private static let baselineShadowY: CGFloat = 3
    private static let baselineBookingTailSize: CGFloat = 8
    private static let baselineBookingTailOffset: CGFloat = 5
    private static let baselineBookingBottomPad: CGFloat = 5

    static var placePinSize: CGFloat { baselinePinSize * mapPreviewPinScale }
    static var bookingPinSize: CGFloat { baselinePinSize * mapPreviewPinScale }
    static var placePinStrokeWidth: CGFloat { baselinePlaceStroke * mapPreviewPinScale }
    static var placePinShadowRadius: CGFloat { baselineShadowRadius * mapPreviewPinScale }
    static var placePinShadowY: CGFloat { baselineShadowY * mapPreviewPinScale }
    static var bookingTailGlyphSize: CGFloat { baselineBookingTailSize * mapPreviewPinScale }
    static var bookingTailOffsetY: CGFloat { baselineBookingTailOffset * mapPreviewPinScale }
    static var bookingMarkerBottomPadding: CGFloat { baselineBookingBottomPad * mapPreviewPinScale }
}

// MARK: - Hero header (cover image)

/// Full-bleed cover: image runs under the status bar; nav is transparent over the top (tinted via scrims in `TripDetailView`).
/// `topBleed` is added to the bitmap height so the same aspect crop reaches the top of the display.
private struct TripDetailHeroHeader: View {
    let trip: Trip
    var topBleed: CGFloat = 0
    var showMembersCluster: Bool = false
    var showMemberAvatars: Bool = false
    var onInviteMembers: () -> Void = {}

    private var dateSummary: String {
        "\(trip.startDate.shortFormatted) – \(trip.endDate.shortFormatted) · \(tripLengthLabel)"
    }

    private var tripLengthLabel: String {
        let days = max(
            1,
            Calendar.current.dateComponents([.day], from: trip.startDate, to: trip.endDate).day ?? 0
        )
        return days == 1 ? "1 day" : "\(days) days"
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

                VStack(alignment: .leading, spacing: AppSpacing.sm) {
                    Text(trip.title)
                        .font(.tripDetailHeroTitle)
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.leading)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .shadow(color: .black.opacity(0.35), radius: 6, x: 0, y: 2)

                    Text(dateSummary)
                        .font(.appCaption)
                        .foregroundStyle(.white.opacity(0.92))
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .shadow(color: .black.opacity(0.3), radius: 4, x: 0, y: 1)

                    if showMembersCluster {
                        HStack(alignment: .center, spacing: AppSpacing.sm) {
                            if showMemberAvatars {
                                TripMembersAvatarStack(onTap: {}, heroOnPhoto: true, allowsTap: false)
                            }
                            TripMembersInviteButton(heroOnPhoto: true, action: onInviteMembers)
                        }
                        .padding(.top, AppSpacing.xs)
                        .shadow(color: .black.opacity(0.4), radius: 8, x: 0, y: 2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
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
    static let visibleHeroHeight: CGFloat = 250
    static let heroImageLoadingBackground = Color(red: 0.12, green: 0.12, blue: 0.14)
    /// SwiftUI pins section headers to the scroll view's top edge. The
    /// itinerary scroll intentionally ignores the top safe area for the hero,
    /// so day headers need a visual clamp to the app navigation bar instead.
    static let navigationBarHeight: CGFloat = 44
    static var navigationChromeHeight: CGFloat {
        KeyWindowSafeArea.topInset + navigationBarHeight
    }
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
/// Native bottom utility toolbar for the trip itinerary root.
struct TripDetailHubBottomBar: ToolbarContent {
    var showsAI: Bool
    var showsDocuments: Bool
    var showsNotes: Bool
    var onAddActivity: () -> Void
    var onChecklist: () -> Void
    var onNotes: () -> Void
    var onBudget: () -> Void
    var onBookings: () -> Void
    var onDocuments: () -> Void
    var onAI: () -> Void

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .bottomBar) {
            budgetButton
            bookingsButton
            if showsAI {
                aiButton
            }
            moreButton
            Spacer()
            addActivityButton
        }
    }

    private var addActivityButton: some View {
        Button(action: onAddActivity) {
            Image(systemName: "plus")
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.circle)
        .tint(AppColors.appPrimary)
        .accessibilityLabel(String(localized: "Add Activity"))
        .accessibilityHint(
            String(localized: "Opens the add activity sheet for this trip.")
        )
    }

    private var budgetButton: some View {
        Button(action: onBudget) {
            Image(systemName: "creditcard")
        }
        .tint(.primary)
        .accessibilityLabel(String(localized: "Budget"))
        .accessibilityHint(
            String(localized: "Opens the budget for this trip. Tap Back to return to the itinerary.")
        )
    }

    private var bookingsButton: some View {
        Button(action: onBookings) {
            Image(systemName: "ticket")
        }
        .tint(.primary)
        .accessibilityLabel(String(localized: "Bookings"))
        .accessibilityHint(
            String(localized: "Opens bookings for this trip. Tap Back to return to the itinerary.")
        )
    }

    private var aiButton: some View {
        Button {
            HapticManager.light()
            onAI()
        } label: {
            Image(systemName: "sparkles")
        }
        .tint(.primary)
        .accessibilityLabel(String(localized: "Plan with AI"))
        .accessibilityHint(String(localized: "Opens the day planner for this trip."))
    }

    private var moreButton: some View {
        Menu {
            Button {
                onChecklist()
            } label: {
                Label("Checklist", systemImage: "checklist")
            }

            if showsNotes {
                Button {
                    onNotes()
                } label: {
                    Label("Notes", systemImage: "note.text")
                }
            }

            if showsDocuments {
                Button {
                    onDocuments()
                } label: {
                    Label("Documents", systemImage: "doc.text")
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .tint(.primary)
        .accessibilityLabel(String(localized: "More"))
    }
}

#if DEBUG
private enum TripDetailView_Previews {}

/// Hosts `TripDetailView` with the same environments as `AppRootTabView`.
/// Timeline data always comes from seeded mock data so Xcode's canvas remains
/// interactive even when the app is configured for the live Supabase backend.
private struct TripDetailPreviewHost: View {
    let trip: Trip
    @State private var dataService = DataService(previewMockData: true)
    @State private var toastManager = ToastManager()
    @State private var collaborationStore = CollaborationStore()
    @State private var collaborationUi = TripCollaborationUiStore()

    var body: some View {
        NavigationStack {
            TripDetailView(trip: trip)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Label("Trips", systemImage: "chevron.backward")
                            .allowsHitTesting(false)
                    }
                }
        }
        .environment(dataService)
        .environment(toastManager)
        .environment(collaborationStore)
        .environment(collaborationUi)
        .task(id: trip.id) {
            collaborationStore.seedPreviewOwner(tripId: trip.id)
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

