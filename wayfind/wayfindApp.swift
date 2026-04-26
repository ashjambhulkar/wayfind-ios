import Auth
import MapKit
import SwiftUI

@main
struct WayfindApp: App {
    /// Phase 5 — UIKit lifecycle bridge. `@UIApplicationDelegateAdaptor`
    /// hands SwiftUI a managed `AppDelegate` instance that fires
    /// `application(_:didFinishLaunchingWithOptions:)` *before* this
    /// scene is constructed, which is the only correct place to call
    /// `FirebaseApp.configure()` and to capture cold-start notification
    /// payloads off `launchOptions`.
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
        AuthSessionService.shared.configure()
    }

    var body: some Scene {
        WindowGroup {
            Group {
                switch authViewModel.authState {
                case .loading:
                    VStack(spacing: AppSpacing.lg) {
                        Image("AppLogo")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 72, height: 72)
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
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
                            await EntitlementService.shared.bind(userId: session.user.id)
                        }
                    }
                case .signedOut:
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

// MARK: - Root tab bar

/// Hashable tab identifier for the trip-detail TabView. Drives both the
/// iOS 18+ `Tab(value:)` API and the iOS 17 fallback's `.tag`, and lets
/// the AI Day Planner handoff route the user to `.map` after Apply.
enum TripDetailTab: Hashable {
    case home, map, budget, bookings, ai
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
    /// Hoisted to the trip tab-view root so the AI Day Planner sheet can be
    /// launched identically from both the Itinerary and Map tabs and survives
    /// tab switches without each tab re-instantiating its own copy.
    @State private var showAIPlanner = false
    /// Bound to the trip-detail TabView so the Phase C apply-handoff can
    /// programmatically switch the user to the Map tab.
    @State private var selectedTab: TripDetailTab = .home
    /// The AI tab is a launch affordance, not a destination. Keep track of
    /// the real tab so tapping AI can present the sheet without leaving the
    /// user on an empty tab.
    @State private var lastContentTab: TripDetailTab = .home
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
            if #available(iOS 18.0, *) {
                dynamicTabView_iOS18
            } else {
                dynamicTabView_fallback
            }
        }
        .tint(AppColors.appPrimary)
        .environment(coordinator)
        .environment(collaborationStore)
        .environment(collaborationUi)
        .environment(realtimeService)
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
        // Phase 3 — soft fade overlay that lands above the trip view but
        // below the toast, so the kick toast remains crisp while the
        // trip content dims out behind it. Reduce Motion: opacity-only
        // (no blur) — see `KickFadeOverlay`.
        .overlay(KickFadeOverlay(isActive: isKickFading))
        .onChange(of: coordinator.activeTrip?.id, initial: true) { _, newTripId in
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
                Task { await budget.reload() }
                // Realtime binds lazily — wait for the detail viewmodel
                // to land via `activeTripDetailViewModel` (set below).
            } else {
                collaborationStore.clear()
                collaborationUi.clear()
                realtimeService.unbind()
                activeTripDetailViewModel = nil
                activeBudgetViewModel = nil
                lastContentTab = .home
                isKickFading = false
            }
        }
        // Phase 3 — once the trip detail viewmodel exists for the active
        // trip, finish wiring the realtime service. We wait for the vm
        // because the kick handler refetches `loadTripData()` directly.
        .onChange(of: activeTripDetailViewModel?.trip.id) { _, _ in
            attachRealtimeIfReady()
        }
        // Per-surface access revocation (Phase 1.5): if the owner removes
        // a collaborator's access to expenses while they're sitting on the
        // Budget tab, hop them to .home FIRST. SwiftUI evaluates the tab
        // body *before* the conditional removal, so without this hop we'd
        // briefly render an "empty selection" state. Owners always pass
        // `canViewExpenses` so this is a no-op for them.
        .onChange(of: collaborationStore.canViewExpenses) { _, canView in
            if !canView, selectedTab == .budget {
                selectedTab = .home
            }
        }
        .onChange(of: selectedTab) { oldValue, newValue in
            if newValue == .ai {
                if collaborationStore.canEdit {
                    HapticManager.light()
                    showAIPlanner = true
                }
                selectedTab = lastContentTab
            } else {
                lastContentTab = newValue
                if oldValue == .ai {
                    selectedTab = newValue
                }
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

    /// Phase C handoff. Server has already committed the ops by the time
    /// this fires; we just need to (1) tear down the sheet, (2) route the
    /// user to the Map tab so they can see their new stops in spatial
    /// context, and (3) confirm with a toast. Order matters — set the
    /// tab BEFORE dismissing so the user lands on Map (not the previous
    /// tab while the sheet is still animating away).
    private func handleAIPlanApplied(_ count: Int) {
        selectedTab = .map
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

    // MARK: iOS 18+ — uses Tab() API

    @available(iOS 18.0, *)
    @ViewBuilder
    private var dynamicTabView_iOS18: some View {
        if let trip = coordinator.activeTrip {
            // DETAIL MODE
            TabView(selection: $selectedTab) {
                Tab("Home", systemImage: "house.fill", value: TripDetailTab.home) {
                    tripListReturnView
                }

                TabSection("Trip") {
                    // Budget tab is per-surface gated (Phase 1.5). Owner
                    // always sees it; viewers / editors only see it when
                    // their `can_access_expenses` flag is on. We omit the
                    // entire Tab from the TabView so SwiftUI's selection
                    // routing never lands on a tab the user can't open.
                    if collaborationStore.canViewExpenses {
                        Tab("Budget", systemImage: "creditcard", value: TripDetailTab.budget) {
                            NavigationStack {
                                TripBudgetTabView(
                                    trip: trip,
                                    viewModel: activeBudgetViewModel
                                )
                                .navigationTitle("Budget")
                            }
                        }
                    }

                    Tab("Bookings", systemImage: "airplane", value: TripDetailTab.bookings) {
                        NavigationStack {
                            BookingsScreenView(
                                trip: trip,
                                onOpenBudgetTab: collaborationStore.canViewExpenses ? { selectedTab = .budget } : nil
                            )
                        }
                    }

                    Tab("Map", systemImage: "map.fill", value: TripDetailTab.map, role: .search) {
                        if #available(iOS 26.0, *) {
                            MapTabWrapper(trip: trip, mapState: mapTabState)
                        } else {
                            NavigationStack {
                                TripMapView(trip: trip)
                            }
                        }
                    }
                }

                if collaborationStore.canEdit {
                    Tab("AI", systemImage: "sparkles", value: TripDetailTab.ai) {
                        Color.clear
                    }
                }
            }
            .modifier(ScrollDownMinimizeTabBarModifier())
        } else {
            // LIST MODE — no tab bar; create button lives in the nav toolbar
            TripsListView()
        }
    }

    // MARK: iOS 17 fallback

    @ViewBuilder
    private var dynamicTabView_fallback: some View {
        if let trip = coordinator.activeTrip {
            TabView(selection: $selectedTab) {
                tripListReturnView
                    .tabItem { Label("Home", systemImage: "house.fill") }
                    .tag(TripDetailTab.home)

                if collaborationStore.canViewExpenses {
                    NavigationStack {
                        TripBudgetTabView(
                            trip: trip,
                            viewModel: activeBudgetViewModel
                        )
                        .navigationTitle("Budget")
                    }
                    .tabItem { Label("Budget", systemImage: "creditcard") }
                    .tag(TripDetailTab.budget)
                }

                NavigationStack {
                    BookingsScreenView(
                        trip: trip,
                        onOpenBudgetTab: collaborationStore.canViewExpenses ? { selectedTab = .budget } : nil
                    )
                }
                .tabItem { Label("Bookings", systemImage: "airplane") }
                .tag(TripDetailTab.bookings)

                NavigationStack {
                    TripMapView(trip: trip)
                }
                .tabItem { Label("Map", systemImage: "map.fill") }
                .tag(TripDetailTab.map)

                if collaborationStore.canEdit {
                    Color.clear
                        .tabItem { Label("AI", systemImage: "sparkles") }
                        .tag(TripDetailTab.ai)
                }
            }
        } else {
            TripsListView()
        }
    }

    // MARK: Home tab in detail mode — returns to trip list

    private var tripListReturnView: some View {
        NavigationStack {
            TripDetailView(
                trip: coordinator.activeTrip!,
                onViewModelCreated: { viewModel in
                    activeTripDetailViewModel = viewModel
                    attachRealtimeIfReady()
                },
                onOpenBudgetTab: { selectedTab = .budget },
                budgetViewModel: activeBudgetViewModel
            )
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            coordinator.returnToList()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "chevron.left")
                                Text("Trips")
                            }
                            .foregroundStyle(AppColors.appPrimary)
                        }
                    }
                }
        }
    }
}

// MARK: - Map Tab Wrapper

/// Wraps the map view and owns the native places sheet. The sheet uses
/// small / medium / large detents so the compact state behaves like the
/// former docked day-pill bar while expanded states follow system sheet UX.
@available(iOS 26.0, *)
private struct MapTabWrapper: View {
    let trip: Trip
    let mapState: MapTabSharedState

    var body: some View {
        NavigationStack {
            TripMapView(trip: trip, sharedState: mapState)
        }
        .onDisappear {
            mapState.showPlacesSheet = false
        }
        .sheet(isPresented: Binding(
            get: { mapState.showPlacesSheet },
            set: { mapState.showPlacesSheet = $0 }
        )) {
            TripMapPlacesExpandedSheet(
                trip: trip,
                selectedDayFilter: Binding(
                    get: { mapState.selectedDayFilter },
                    set: { mapState.selectedDayFilter = $0 }
                ),
                allPlacesForList: mapState.mappablePlaces,
                dayNumberByDayId: mapState.dayNumberByDayId,
                onSelectPlace: { place in
                    mapState.showPlacesSheet = false
                    mapState.selectedPlaceToFocus = place
                }
            )
            .presentationDetents([.medium, .large])
            .presentationContentInteraction(.scrolls)
            .presentationBackground(.regularMaterial)
            .presentationDragIndicator(.visible)
            .tint(AppColors.appPrimary)
        }
    }
}

/// Shared state between the map view, the minimized safe-area accessory,
/// and the expanded places sheet.
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
    var showPlacesSheet = false
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

// MARK: - Tab bar minimize on scroll (iOS 26+)

private struct ScrollDownMinimizeTabBarModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.tabBarMinimizeBehavior(.onScrollDown)
        } else {
            content
        }
    }
}
