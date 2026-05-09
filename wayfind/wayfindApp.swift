import Auth
import MapKit
import SwiftUI

#if canImport(FirebaseCore)
import FirebaseCore
#endif

@main
struct WayfindApp: App {
    /// Phase 5 — UIKit lifecycle bridge. `@UIApplicationDelegateAdaptor`
    /// connects the SwiftUI lifecycle to UIKit so `AppDelegate` receives
    /// push-notification callbacks, APNs device-token delivery, and
    /// cold-start launch-option parsing.
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @State private var authViewModel = AuthViewModel()
    @State private var dataService = DataService()
    @State private var userPreferences = UserPreferencesStore()
    @State private var toastManager = ToastManager()
    /// Phase 5 — buffer for incoming deep links (cold-start notification
    /// taps, taps that arrive while the user is on `SignInView`, etc.).
    /// `AppRootTabView` drains this once the coordinator is settable.
    @State private var pendingDeepLinkStore = PendingDeepLinkStore()
    /// Phase 2 — set whenever an invite deep link arrives (via `onOpenURL`
    /// or post-auth drain of `PendingInviteStorage`). Drives the
    /// `.fullScreenCover` that presents `InviteAcceptView` over whatever
    /// the user is doing. Cleared by both the success and dismiss paths.
    @State private var pendingInviteToken: String?
    /// Phase 2 — set after a successful accept so the next `AppRootTabView`
    /// render can dispatch `coordinator.openTrip(_:)` and present the
    /// `InviteeWelcomeSheet` for first-time joiners.
    @State private var inviteJoinResult: InviteJoinResult?

    init() {
        // Configure Firebase here — the App struct is instantiated before
        // AppDelegate.didFinishLaunchingWithOptions fires, so this is the
        // earliest user-code hook. AppDelegate repeats the call guarded by
        // `FirebaseApp.app() == nil` as a belt-and-suspenders fallback.
        #if canImport(FirebaseCore)
        if FirebaseApp.app() == nil {
            FirebaseApp.configure()
        }
        #endif
        AuthSessionService.shared.configure()
    }

    var body: some Scene {
        WindowGroup {
            Group {
                switch authViewModel.authState {
                case .loading:
                    VStack(spacing: AppSpacing.lg) {
                        AuthBrandMark()
                        Text("Wayfind")
                            .font(.screenTitle)
                            .foregroundStyle(AppColors.textPrimary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(AppColors.appBackground.ignoresSafeArea())

                case .signedIn:
                    AppRootTabView(
                        inviteJoinResult: $inviteJoinResult,
                        pendingDeepLinkStore: pendingDeepLinkStore
                    )
                        .sheet(isPresented: .init(
                            get: { authViewModel.needsDisplayName },
                            set: { _ in }
                        )) {
                            DisplayNamePromptView()
                        }
                        // Wave 4.3 — single paywall surface attached at
                        // the signed-in scene root so every gate (CSV,
                        // currency, flight tracking, documents, AI cap,
                        // Settings) presents into the same sheet via
                        // `PaywallPresenter.shared.present(...)`.
                        .paywallSurface()

                case .signedOut:
                    NavigationStack {
                        SignInView()
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(AppColors.appBackground.ignoresSafeArea())
            .preferredColorScheme(userPreferences.appearancePreference.preferredColorScheme)
            .environment(authViewModel)
            .environment(dataService)
            .environment(userPreferences)
            .environment(toastManager)
            .environment(pendingDeepLinkStore)
            .toastOverlay(manager: toastManager)
            // Phase 5 — drain the AppDelegate's cold-start launch payload
            // and wire NotificationManager to the live coordinator/data
            // service references it needs to route a tap. `task` runs
            // exactly once per scene appearance which is what we want
            // (no duplicate seeding on hot tab switches).
            .task {
                await MainActor.run {
                    appDelegate.seedColdStartLink(into: pendingDeepLinkStore)
                    NotificationManager.shared.dataService = dataService
                    NotificationManager.shared.pendingDeepLinkStore = pendingDeepLinkStore
                }
                // Wave 4.2 — cold-start bind. `onChange(authState:)`
                // doesn't fire for the initial value, so on launches
                // where the previous session is restored to .signedIn
                // before this scene mounts we'd never hand the Supabase
                // user id to RevenueCat. This task path covers it.
                if case .signedIn = authViewModel.authState,
                   let session = await AuthSessionService.shared.currentSession() {
                    ObservabilityService.setUser(id: session.user.id)
                    await EntitlementService.shared.bind(userId: session.user.id)
                }
            }
            .onOpenURL { url in
                // Phase 2 invite-first branch: if this is a wayfind://invite/<token>
                // URL we capture the token immediately, BEFORE the auth handlers
                // get a chance to misclassify it as an OAuth callback. The
                // invite scheme has its own host ("invite") so collision is
                // impossible, but we keep the order explicit.
                if let token = InviteDeepLink.token(from: url) {
                    pendingInviteToken = token
                    return
                }
                if AuthSessionService.shared.handleGoogleURL(url) { return }
                Task { await authViewModel.handleIncomingAuthURL(url) }
            }
            // Post-auth drain: when the user transitions from signed-out to
            // signed-in, replay any token that was stashed before sign-in.
            // We poll the Keychain — the value is small, the read is fast,
            // and it survives an app crash mid-flow. If a token already
            // sits in `pendingInviteToken` (live tap) we leave it.
            .onChange(of: authViewModel.authState) { _, newState in
                switch newState {
                case .signedIn:
                    ObservabilityService.breadcrumb(
                        "signed_in",
                        category: "auth",
                        context: ["restored": true]
                    )
                    // Drain any invite token stashed before sign-in so
                    // the join sheet can fire on this same session.
                    if pendingInviteToken == nil, let stored = PendingInviteStorage.get() {
                        pendingInviteToken = stored
                    }
                    // Wave 4.2 — sync the Supabase user id into
                    // RevenueCat so any purchases (anonymous or
                    // otherwise) reconcile to the right entitlement
                    // record. Also seeds the AI usage cache that the
                    // wizard's "X of 3 free remaining" badge reads.
                    Task { @MainActor in
                        if let session = await AuthSessionService.shared.currentSession() {
                            ObservabilityService.setUser(id: session.user.id)
                            await EntitlementService.shared.bind(userId: session.user.id)
                        }
                    }
                case .signedOut:
                    ObservabilityService.breadcrumb("signed_out", category: "auth")
                    ObservabilityService.clearUser()
                    // Drop the RevenueCat appUserID back to anonymous
                    // so the next account on this shared device starts
                    // clean instead of inheriting the previous user's
                    // receipt state.
                    Task { @MainActor in
                        await EntitlementService.shared.unbind()
                    }
                case .loading:
                    break
                }
            }
            .fullScreenCover(item: Binding(
                get: { pendingInviteToken.map(InviteToken.init(value:)) },
                set: { wrapper in pendingInviteToken = wrapper?.value }
            )) { tokenWrapper in
                InviteAcceptView(
                    token: tokenWrapper.value,
                    onJoinSuccess: { tripId, preview in
                        // Cache for the AppRootTabView to consume on next
                        // render — it has access to `coordinator` and
                        // `dataService` which we need to navigate.
                        inviteJoinResult = InviteJoinResult(
                            tripId: tripId,
                            inviterName: preview.resolvedInviterName,
                            tripName: preview.tripName,
                            role: preview.role
                        )
                        PendingInviteStorage.clear()
                        pendingInviteToken = nil
                    },
                    onDismiss: {
                        PendingInviteStorage.clear()
                        pendingInviteToken = nil
                    },
                    isSignedIn: authViewModel.authState == .signedIn,
                    onSignInRequested: {
                        // Persist for the post-auth drain; the
                        // `.fullScreenCover` will re-present once the user
                        // signs in (driven by `onChange` above).
                        PendingInviteStorage.set(token: tokenWrapper.value)
                        pendingInviteToken = nil
                        // The `signedOut` UI is already showing — closing
                        // the cover hands focus back to the SignInView.
                    }
                )
                .environment(authViewModel)
                .environment(toastManager)
            }
        }
    }
}

/// Identifiable token wrapper so we can drive `.fullScreenCover(item:)`
/// from a plain `String?`.
private struct InviteToken: Identifiable, Hashable {
    var id: String { value }
    let value: String
}

/// Bridges the invite-accept success state from `WayfindApp` (which owns
/// the cover) to `AppRootTabView` (which owns `coordinator`, `dataService`,
/// and the `InviteeWelcomeSheet` presentation).
struct InviteJoinResult: Identifiable, Hashable, Sendable {
    let id = UUID()
    let tripId: UUID
    let inviterName: String
    let tripName: String
    let role: TripRole
}

// MARK: - Trip detail hub (single stack + root bottom actions)

/// Pushed modules from trip itinerary (`TripDetailView` root). Budget stays
/// on the root bar even when `canViewExpenses` is false — the destination
/// shows a native `ContentUnavailableView` explainers.
private enum TripDetailModule: Hashable {
    case budget, bookings, documents, map
}

private struct AppRootTabView: View {
    @Environment(AuthViewModel.self) private var authViewModel
    @Environment(ToastManager.self) private var toastManager
    @Environment(DataService.self) private var dataService
    @State private var coordinator = TabNavigationCoordinator()
    /// Single per-active-trip collaboration store. Bound to
    /// `coordinator.activeTrip?.id` here (NOT inside `TripDetailView` — that
    /// view's lifecycle fires too aggressively across tab switches and would
    /// thrash the channel). Child views read from `@Environment` only.
    @State private var collaborationStore = CollaborationStore()
    /// Phase 3 — flash UX state (per-place "Alex · just now" pills + one-shot
    /// pulse). Sibling of `collaborationStore`; same trip-id lifecycle.
    @State private var collaborationUi = TripCollaborationUiStore()
    /// Phase 3 — single owned realtime channel, scoped to the active trip.
    /// Bound below in the same `onChange` that binds the collaboration store
    /// so all three lifecycles stay synchronized.
    @State private var realtimeService = TripRealtimeService()
    /// Wave 3.3 — single shared flight status cache for the active trip.
    /// Owned here (not inside TripDetailView or BookingsScreenView) so both
    /// views read from the same instance without opening duplicate realtime
    /// channels. TripDetailView manages bind/unbind; BookingsScreenView
    /// reads the published dictionary via @Environment.
    @State private var flightTrackingService = FlightTrackingService()
    /// Phase 3 — held so the realtime kick handler can ask the active
    /// `TripDetailViewModel` to refetch (and so we can pull the title for
    /// the kick toast). Updated by `TripDetailView.onAppear` once it
    /// instantiates its viewmodel.
    @State private var activeTripDetailViewModel: TripDetailViewModel?
    /// Per-active-trip Budget tab viewmodel. Created in the same
    /// `onChange(of: coordinator.activeTrip?.id)` that binds the
    /// collaboration store, so its lifetime mirrors the trip's. The
    /// realtime service holds a `weak` reference; the strong owner here
    /// keeps it alive across tab switches inside the trip.
    @State private var activeBudgetViewModel: BudgetViewModel?
    /// AI Day Planner sheet — presented from the root bottom bar (not a tab).
    @State private var showAIPlanner = false
    /// Hub-and-spoke navigation: empty at itinerary root; one element when a
    /// module (Budget / Bookings / Map) is pushed.
    @State private var tripModulePath: [TripDetailModule] = []
    /// iOS 26 map places-sheet state is hoisted so the map, sheet, and
    /// tab-level wrapper can coordinate selection and detent changes.
    @State private var mapTabState = MapTabSharedState()
    /// Owned by the parent `WayfindApp` and passed in via Binding so
    /// `InviteAcceptView` (which is presented above this view) can ask
    /// us to navigate to a freshly-joined trip and surface the
    /// `InviteeWelcomeSheet`.
    @Binding var inviteJoinResult: InviteJoinResult?

    /// Phase 5 — host-owned deep link buffer. Drained from the
    /// `onChange(of: coordinator)` initial pass so cold-start
    /// notifications navigate to the right trip on first render.
    let pendingDeepLinkStore: PendingDeepLinkStore
    /// Drives the `InviteeWelcomeSheet` after a successful join. Set
    /// from the `inviteJoinResult` consumer once we've confirmed this is
    /// the user's first time on this trip (per `InviteWelcomeStorage`).
    @State private var welcomeForJoin: InviteJoinResult?
    /// Phase 3 — drives the kick fade overlay. When realtime fires the
    /// "you were removed" path, we render a soft dim+blur over the trip
    /// content for 0.4s before tearing the trip down so the user has a
    /// visual cue that matches the toast.
    @State private var isKickFading = false

    var body: some View {
        Group {
            if let trip = coordinator.activeTrip {
                NavigationStack(path: $tripModulePath) {
                    TripDetailView(
                        trip: trip,
                        onViewModelCreated: { viewModel in
                            activeTripDetailViewModel = viewModel
                            attachRealtimeIfReady()
                        },
                        onCloseTrip: { coordinator.returnToList() },
                        onOpenMap: { openTripMapWithPlacesSheetHalfOpen() },
                        onOpenBudgetTab: { tripModulePath = [.budget] },
                        onOpenBookingsTab: { tripModulePath = [.bookings] },
                        onOpenDocumentsTab: { tripModulePath = [.documents] },
                        onOpenAIPlanner: { showAIPlanner = true },
                        budgetViewModel: activeBudgetViewModel
                    )
                    .navigationDestination(for: TripDetailModule.self) { module in
                        tripModuleDestination(module: module, trip: trip)
                    }
                }
            } else {
                TripsListView()
            }
        }
        .tint(.primary)
        .environment(coordinator)
        .environment(collaborationStore)
        .environment(collaborationUi)
        .environment(realtimeService)
        .environment(flightTrackingService)
        // Phase 5 — wire NotificationManager to the live coordinator
        // and install the pre-sign-out cleanup. Both are driven off
        // `task` so they survive scene re-creation cleanly without
        // racing against initial sign-in.
        .task {
            NotificationManager.shared.attach(
                coordinator: coordinator,
                pendingDeepLinkStore: pendingDeepLinkStore,
                dataService: dataService
            )
            authViewModel.preSignOutCleanup = {
                // Plan-mandated order: token row first (RLS still
                // valid), then realtime channel, then collaboration
                // store. PendingInviteStorage is intentionally NOT
                // touched — invite tokens must survive sign-out.
                await PushNotificationService.shared.clearTokenForCurrentDevice()
                await flightTrackingService.unbind()
                await MainActor.run {
                    realtimeService.unbind()
                    collaborationStore.clear()
                    collaborationUi.clear()
                }
            }
            // Drain any cold-start tap captured before SwiftUI was up.
            if let pending = pendingDeepLinkStore.consume() {
                await handlePendingDeepLink(pending)
            }
        }
        .onChange(of: pendingDeepLinkStore.pending) { _, newValue in
            guard newValue != nil else { return }
            if let pending = pendingDeepLinkStore.consume() {
                Task { await handlePendingDeepLink(pending) }
            }
        }
        .onChange(of: tripModulePath) { oldPath, newPath in
            if oldPath.contains(.map), !newPath.contains(.map) {
                mapTabState.showPlacesSheet = false
                mapTabState.placesSheetLayout = .docked
            }
        }
        // Phase 3 — soft fade overlay that lands above the trip view but
        // below the toast, so the kick toast remains crisp while the
        // trip content dims out behind it. Reduce Motion: opacity-only
        // (no blur) — see `KickFadeOverlay`.
        .overlay(KickFadeOverlay(isActive: isKickFading))
        .onChange(of: coordinator.activeTrip?.id, initial: true) { _, newTripId in
            tripModulePath = []
            if let newTripId {
                collaborationStore.bind(to: newTripId)
                collaborationUi.bind(to: newTripId)
                // Spin up the Budget viewmodel up-front so the tab switch
                // is instant — the first render uses its empty snapshot
                // and the parallel fetch in `reload()` paints over it
                // within a frame or two.
                let budget = BudgetViewModel(
                    tripId: newTripId,
                    currentUserId: collaborationStore.currentUserId,
                    dataService: dataService
                )
                activeBudgetViewModel = budget
                // `reloadIfNeeded()` is a no-op if the realtime `.subscribed`
                // handler fires first and has already populated the snapshot.
                // It provides a fallback first-load for cases where the
                // realtime channel is slow or the subscription never fires
                // (e.g. offline, reconnect delay).
                Task { await budget.reloadIfNeeded() }
                // Realtime binds lazily — wait for the detail viewmodel
                // to land via `activeTripDetailViewModel` (set below).
            } else {
                collaborationStore.clear()
                collaborationUi.clear()
                realtimeService.unbind()
                Task { await flightTrackingService.unbind() }
                activeTripDetailViewModel = nil
                activeBudgetViewModel = nil
                isKickFading = false
            }
        }
        // Phase 3 — once the trip detail viewmodel exists for the active
        // trip, finish wiring the realtime service. We wait for the vm
        // because the kick handler refetches `loadTripData()` directly.
        .onChange(of: activeTripDetailViewModel?.trip.id) { _, _ in
            attachRealtimeIfReady()
        }
        // Per-surface access revocation: pop back to itinerary if Budget was
        // pushed and expense access is removed.
        .onChange(of: collaborationStore.canViewExpenses) { _, canView in
            if !canView, tripModulePath.contains(.budget) {
                tripModulePath = []
            }
        }
        .onChange(of: collaborationStore.canViewDocuments) { _, canView in
            if !canView, tripModulePath.contains(.documents) {
                tripModulePath = []
                toastManager.show(ToastData(
                    message: "The owner removed your access to documents",
                    type: .warning,
                    duration: 3
                ))
            }
        }
        .sheet(isPresented: $showAIPlanner) {
            if let trip = coordinator.activeTrip {
                // Drag indicator is intentionally NOT set here — the
                // sheet itself toggles it state-driven so a live preview
                // (which costs an AI credit to recreate) doesn't display
                // a swipe-down affordance the OS will then refuse.
                AIPlanWizardSheet(trip: trip, onApplied: handleAIPlanApplied)
                    .presentationDetents([.large])
            }
        }
        // Phase 2 — consume any pending invite-join handoff from the
        // root cover. Order matters: refresh trips → find the new trip
        // → openTrip(_:) → present welcome sheet (if first time).
        .onChange(of: inviteJoinResult) { _, newValue in
            guard let result = newValue else { return }
            Task { await handleInviteJoin(result) }
        }
        .sheet(item: $welcomeForJoin) { result in
            InviteeWelcomeSheet(
                tripTitle: result.tripName,
                inviterName: result.inviterName,
                role: result.role,
                onRequestNotifications: {
                    // Phase 5 — only ask here, never on launch. The
                    // user just joined a collaborative trip so the
                    // permission ask is contextually obvious. Toast
                    // copy avoids "Successfully" / "Error" per the
                    // copy guidelines.
                    Task {
                        let granted = await NotificationManager.shared.requestPermission()
                        await MainActor.run {
                            if granted {
                                toastManager.show(ToastData(
                                    message: "Notifications on. We'll keep you posted.",
                                    type: .success,
                                    duration: 2.5
                                ))
                            } else {
                                toastManager.show(ToastData(
                                    message: "You can turn on notifications later in Settings.",
                                    type: .warning,
                                    duration: 3
                                ))
                            }
                        }
                    }
                },
                onDismiss: {
                    welcomeForJoin = nil
                }
            )
            .presentationDetents([.large])
            .presentationBackgroundInteraction(.disabled)
        }
    }

    /// Phase 5 — opens the trip referenced by a pending deep link if it
    /// can be found in the user's trips list. Falls through silently
    /// if the trip isn't visible (e.g. RLS race after a kick / leave) —
    /// no error toast because the user didn't initiate this navigation
    /// and the buffered link is already consumed.
    private func handlePendingDeepLink(_ link: PendingDeepLinkStore.Pending) async {
        switch link {
        case .openTrip(let tripId):
            // If we're already on the right trip, no-op — avoids a
            // jarring re-navigation when the user taps a notification
            // for the trip they're currently viewing.
            if coordinator.activeTrip?.id == tripId { return }
            let trips = await dataService.fetchTrips()
            if let trip = trips.first(where: { $0.id == tripId }) {
                coordinator.openTrip(trip)
            }
        }
    }

    /// Phase 3 — bind the realtime service once both the trip-id and the
    /// trip-detail viewmodel are available. The viewmodel lands a beat
    /// after the trip-id (TripDetailView spins it up in `.task`), which
    /// is why we attach in two passes.
    private func attachRealtimeIfReady() {
        guard let trip = coordinator.activeTrip,
              let viewModel = activeTripDetailViewModel,
              viewModel.trip.id == trip.id
        else { return }
        realtimeService.bind(
            to: trip.id,
            viewModel: viewModel,
            collaborationStore: collaborationStore,
            collaborationUi: collaborationUi,
            toastManager: toastManager,
            tripTitleProvider: { [weak viewModel] in
                viewModel?.trip.title ?? trip.title
            },
            navigateAfterKick: {
                Task { @MainActor in
                    await runKickAnimationAndExit()
                }
            }
        )
        if let budget = activeBudgetViewModel {
            realtimeService.bindBudget(budget)
        }
    }

    @MainActor
    private func runKickAnimationAndExit() async {
        // Soft dim + blur fade over the trip content, then tear down. The
        // toast that fired alongside this stays visible for its 2.5s
        // duration after we're back on the trip list.
        withAnimation(.easeInOut(duration: 0.4)) {
            isKickFading = true
        }
        try? await Task.sleep(nanoseconds: 450_000_000)
        coordinator.returnToList()
        isKickFading = false
    }

    /// Refreshes the trip list, finds the freshly-joined trip, opens it,
    /// and surfaces the `InviteeWelcomeSheet` if this is the user's
    /// first time on this trip. Falls through silently with a toast if
    /// the trip never appears (RLS race / replication lag).
    private func handleInviteJoin(_ result: InviteJoinResult) async {
        // Clear the parent binding immediately so we don't loop.
        inviteJoinResult = nil
        // Optional friendly toast while we resolve the actual trip row.
        let trips = await dataService.fetchTrips()
        if let trip = trips.first(where: { $0.id == result.tripId }) {
            coordinator.openTrip(trip)
            // Welcome sheet only on first open per trip.
            if !InviteWelcomeStorage.hasShown(tripId: trip.id) {
                InviteWelcomeStorage.markShown(tripId: trip.id)
                welcomeForJoin = result
            } else {
                toastManager.show(ToastData(
                    message: "Welcome back to \(result.tripName).",
                    type: .success,
                    duration: 2.5
                ))
            }
        } else {
            // Trip didn't show up in the post-accept fetch — surface a
            // gentle toast and let realtime / next refresh catch it.
            toastManager.show(ToastData(
                message: "You're in \(result.tripName). It'll show up in your trips list shortly.",
                type: .success,
                duration: 3
            ))
        }
    }

    /// Phase C handoff: dismiss the wizard and push Map so new stops are
    /// visible in spatial context, then toast.
    private func handleAIPlanApplied(_ count: Int) {
        openTripMapWithPlacesSheetHalfOpen()
        showAIPlanner = false
        let message: String
        switch count {
        case 0:
            message = "Day plan added to your itinerary"
        case 1:
            message = "Added 1 stop to your itinerary"
        default:
            message = "Added \(count) stops to your itinerary"
        }
        toastManager.show(ToastData(message: message, type: .success, duration: 3.5))
    }

    /// Push Map and present the iOS 26 places sheet at the half (medium) detent.
    private func openTripMapWithPlacesSheetHalfOpen() {
        if #available(iOS 26.0, *) {
            mapTabState.placesSheetLayout = .half
            mapTabState.showPlacesSheet = true
        }
        tripModulePath = [.map]
    }

    // MARK: - Trip detail pushed destinations

    @ViewBuilder
    private func tripModuleDestination(module: TripDetailModule, trip: Trip) -> some View {
        switch module {
        case .budget:
            if collaborationStore.canViewExpenses {
                TripBudgetTabView(trip: trip, viewModel: activeBudgetViewModel)
                    .navigationTitle("Budget")
            } else {
                ContentUnavailableView {
                    Label("Budget locked", systemImage: "lock.fill")
                } description: {
                    Text("You don’t have access to trip expenses. Ask the trip owner if you need access.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle("Budget")
            }
        case .bookings:
            BookingsScreenView(
                trip: trip,
                onOpenBudgetTab: { tripModulePath = [.budget] }
            )
        case .documents:
            TripDocumentsView(trip: trip)
        case .map:
            if #available(iOS 26.0, *) {
                MapTabWrapper(trip: trip, mapState: mapTabState)
            } else {
                TripMapView(trip: trip)
            }
        }
    }
}

/// Shared state between the map view and the single persistent places sheet.
///
/// Search state lives in `TripMapState` (Phase 2) and is owned by
/// `TripMapView`; this object now carries only the data that the day
/// list / day filter / places accessory need.
@Observable @MainActor
final class MapTabSharedState {
    var selectedDayFilter: Int?
    var mappablePlaces: [Place] = []
    var selectedPlaceToFocus: Place?
    var dayNumberByDayId: [UUID: Int] = [:]
    /// Kept in sync as `true` while the map tab is active (sheet visibility is `sharedState != nil`).
    var showPlacesSheet = true
    /// Docked vs half vs full — the sheet is always presented; this only changes detent.
    var placesSheetLayout: PlacesSheetLayout = .docked
    /// Map-tab search field text (sheet search bar on iOS 26+; inline searchable pre-26).
    var mapTabSearchText: String = ""
    var mapTabSearchPresented: Bool = false
    /// When true, the places sheet expands search **inside** the same presentation (no standalone overlay).
    var openInlineMapSearch = false
}

// MARK: - Search Tab (list mode)

/// Dedicated search tab shown in list mode via `Tab(role: .search)`.
private struct TripsSearchTabView: View {
    @Environment(DataService.self) private var dataService
    @Environment(UserPreferencesStore.self) private var userPreferences
    @Environment(TabNavigationCoordinator.self) private var coordinator
    @State private var viewModel: TripsViewModel?
    @State private var searchText = ""

    var body: some View {
        ScrollView {
            if let viewModel {
                let filtered = viewModel.trips.filter { trip in
                    searchText.isEmpty || trip.title.localizedCaseInsensitiveContains(searchText)
                        || trip.destination.localizedCaseInsensitiveContains(searchText)
                }

                if filtered.isEmpty && !searchText.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                } else if filtered.isEmpty {
                    ContentUnavailableView("Search Trips", systemImage: "magnifyingglass", description: Text("Type to find your trips"))
                } else {
                    LazyVStack(spacing: AppSpacing.sm) {
                        ForEach(filtered) { trip in
                            Button {
                                coordinator.openTrip(trip)
                            } label: {
                                SearchTripRow(trip: trip)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, AppSpacing.lg)
                    .padding(.top, AppSpacing.sm)
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 200)
            }
        }
        .background(AppColors.appBackground)
        .navigationTitle("Search")
        .searchable(text: $searchText, prompt: "Search trips...")
        .task {
            if viewModel == nil {
                viewModel = TripsViewModel(dataService: dataService, preferences: userPreferences)
            }
            await viewModel?.loadTrips()
        }
    }
}

private struct SearchTripRow: View {
    let trip: Trip

    var body: some View {
        HStack(spacing: AppSpacing.md) {
            Group {
                if let urlString = trip.coverImageUrl, let url = URL(string: urlString) {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .empty, .failure:
                            PlaceholderGradientView(destinationName: trip.destination)
                        case .success(let image):
                            image.resizable().scaledToFill()
                        @unknown default:
                            PlaceholderGradientView(destinationName: trip.destination)
                        }
                    }
                } else {
                    PlaceholderGradientView(destinationName: trip.destination)
                }
            }
            .frame(width: 52, height: 52)
            .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.small, style: .continuous))

            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                Text(trip.title)
                    .font(.cardTitle)
                    .foregroundStyle(AppColors.textPrimary)
                    .lineLimit(1)
                Text(trip.destination)
                    .font(.appCaption)
                    .foregroundStyle(AppColors.textSecondary)
                Text("\(trip.startDate.shortFormatted) – \(trip.endDate.shortFormatted)")
                    .font(.appCaption)
                    .foregroundStyle(AppColors.textTertiary)
            }

            Spacer(minLength: 0)
        }
        .padding(AppSpacing.md)
        .background(AppColors.appSurface)
        .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous)
                .strokeBorder(AppColors.appDivider, lineWidth: 1)
        )
    }
}

// MARK: - Display name prompt

private struct DisplayNamePromptView: View {
    @Environment(AuthViewModel.self) private var authViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    var body: some View {
        VStack(spacing: AppSpacing.xl) {
            Spacer()

            Text("👋")
                .font(.system(size: 50))

            Text("Welcome!")
                .font(.sectionHeader)
                .foregroundStyle(AppColors.textPrimary)

            Text("What should we call you?")
                .font(.appBody)
                .foregroundStyle(AppColors.textSecondary)

            HStack(spacing: AppSpacing.md) {
                Image(systemName: "person.fill")
                    .foregroundStyle(AppColors.textTertiary)
                    .frame(width: 24)
                TextField("Your name", text: $name)
                    .font(.appBody)
                    .textContentType(.name)
                    .textInputAutocapitalization(.words)
                    .submitLabel(.done)
                    .onSubmit { saveName() }
            }
            .frame(height: 48)
            .padding(.horizontal, AppSpacing.md)
            .background(AppColors.appSurface)
            .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous)
                    .strokeBorder(AppColors.appDivider, lineWidth: 1)
            )
            .padding(.horizontal, AppSpacing.xxl)

            AppButton(
                title: "Continue →",
                style: .primary,
                isDisabled: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ) {
                saveName()
            }
            .padding(.horizontal, AppSpacing.xxl)

            Spacer()
        }
        .background(AppColors.appBackground)
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled()
        .onAppear {
            let prefix = authViewModel.currentUserEmail.split(separator: "@").first.map(String.init) ?? ""
            name = prefix.capitalized
        }
    }

    private func saveName() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Task {
            await authViewModel.setDisplayName(trimmed)
        }
        dismiss()
    }
}

