import SwiftUI

@main
struct WayfindApp: App {
    @State private var authViewModel = AuthViewModel()
    @State private var dataService = DataService()
    @State private var userPreferences = UserPreferencesStore()
    @State private var toastManager = ToastManager()

    init() {
        AuthSessionService.shared.configure()
    }

    var body: some Scene {
        WindowGroup {
            Group {
                switch authViewModel.authState {
                case .loading:
                    VStack(spacing: AppSpacing.lg) {
                        Image(systemName: "globe.americas.fill")
                            .font(.system(size: 60))
                            .foregroundStyle(AppColors.appPrimary)
                        Text("Wayfind")
                            .font(.screenTitle)
                            .foregroundStyle(AppColors.textPrimary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(AppColors.appBackground.ignoresSafeArea())

                case .signedIn:
                    AppRootTabView()
                        .sheet(isPresented: .init(
                            get: { authViewModel.needsDisplayName },
                            set: { _ in }
                        )) {
                            DisplayNamePromptView()
                        }

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
            .toastOverlay(manager: toastManager)
            .onOpenURL { url in
                if AuthSessionService.shared.handleGoogleURL(url) { return }
                Task { await authViewModel.handleIncomingAuthURL(url) }
            }
        }
    }
}

// MARK: - Root tab bar

private struct AppRootTabView: View {
    @Environment(AuthViewModel.self) private var authViewModel
    @State private var coordinator = TabNavigationCoordinator()

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
    }

    // MARK: iOS 18+ — uses Tab() API

    @available(iOS 18.0, *)
    @ViewBuilder
    private var dynamicTabView_iOS18: some View {
        if let trip = coordinator.activeTrip {
            // DETAIL MODE
            TabView {
                Tab("Home", systemImage: "house.fill") {
                    tripListReturnView
                }

                TabSection("Trip") {
                    Tab("Map", systemImage: "map.fill") {
                        if #available(iOS 26.0, *) {
                            MapTabWrapper(trip: trip)
                        } else {
                            NavigationStack {
                                TripMapView(trip: trip)
                            }
                        }
                    }

                    Tab("Budget", systemImage: "creditcard") {
                        NavigationStack {
                            TripBudgetTabView()
                                .navigationTitle("Budget")
                        }
                    }

                    Tab("Bookings", systemImage: "airplane") {
                        NavigationStack {
                            BookingsScreenView(trip: trip)
                        }
                    }
                }

                Tab("+ai", systemImage: "sparkles", role: .search) {
                    NavigationStack {
                        TripAiTabView()
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
            TabView {
                tripListReturnView
                    .tabItem { Label("Home", systemImage: "house.fill") }
                    .tag(0)

                NavigationStack {
                    TripMapView(trip: trip)
                }
                .tabItem { Label("Map", systemImage: "map.fill") }
                .tag(1)
                // iOS 17 fallback doesn't have tabViewBottomAccessory

                NavigationStack {
                    TripBudgetTabView()
                        .navigationTitle("Budget")
                }
                .tabItem { Label("Budget", systemImage: "creditcard") }
                .tag(2)

                NavigationStack {
                    BookingsScreenView(trip: trip)
                }
                .tabItem { Label("Bookings", systemImage: "airplane") }
                .tag(3)

                NavigationStack {
                    TripAiTabView()
                }
                .tabItem { Label("+ai", systemImage: "sparkles") }
                .tag(4)
            }
        } else {
            TripsListView()
        }
    }

    // MARK: Home tab in detail mode — returns to trip list

    private var tripListReturnView: some View {
        NavigationStack {
            TripDetailView(trip: coordinator.activeTrip!)
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

// MARK: - Map Tab Wrapper (tabViewBottomAccessory)

/// Wraps the map view and applies `tabViewBottomAccessory` at the Tab content level
/// so the day filter bar sits above the tab bar.
@available(iOS 26.0, *)
private struct MapTabWrapper: View {
    let trip: Trip
    @State private var mapState = MapTabSharedState()

    var body: some View {
        NavigationStack {
            TripMapView(trip: trip, sharedState: mapState)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            MapDockedAccessoryBar(
                trip: trip,
                selectedDayFilter: $mapState.selectedDayFilter,
                mappablePlaces: mapState.mappablePlaces,
                dayNumberByDayId: mapState.dayNumberByDayId,
                onExpand: { mapState.showPlacesSheet = true }
            )
            .background(.regularMaterial)
        }
        .sheet(isPresented: $mapState.showPlacesSheet) {
            TripMapPlacesExpandedSheet(
                trip: trip,
                selectedDayFilter: $mapState.selectedDayFilter,
                activeCategoryFilter: .init(
                    get: { mapState.activeCategoryFilter },
                    set: { mapState.activeCategoryFilter = $0 }
                ),
                allPlacesForList: mapState.mappablePlaces,
                dayNumberByDayId: mapState.dayNumberByDayId,
                onSelectPlace: { place in
                    mapState.showPlacesSheet = false
                    mapState.selectedPlaceToFocus = place
                },
                onSearchResultSelected: { name, lat, lng in
                    mapState.showPlacesSheet = false
                    mapState.searchResultToFocus = (name, lat, lng)
                },
                searchText: .init(
                    get: { mapState.searchText },
                    set: { mapState.searchText = $0 }
                )
            )
            .presentationDetents([.medium, .large])
            .presentationBackground(.regularMaterial)
            .presentationDragIndicator(.visible)
            .tint(AppColors.appPrimary)
        }
    }
}

/// Shared state between the map view, the tab accessory bar, and the expanded sheet.
@Observable @MainActor
final class MapTabSharedState {
    var selectedDayFilter: Int?
    var mappablePlaces: [Place] = []
    var searchText: String = ""
    var activeCategoryFilter: String?
    var selectedPlaceToFocus: Place?
    var searchResultToFocus: (String, Double, Double)?
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
