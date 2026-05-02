import Observation
import SwiftUI

private enum TripsListLayout {
    /// Fixed width for each active trip card when multiple trips overlap "today".
    static let activeTripCardWidth: CGFloat = 300
    /// Leading toolbar profile control matches common bar button target sizing.
    static let profileToolbarAvatarSize: CGFloat = 28
}

struct TripsListView: View {
    @Environment(AuthViewModel.self) private var authViewModel
    @Environment(DataService.self) private var dataService
    @Environment(UserPreferencesStore.self) private var userPreferences
    @Environment(ToastManager.self) private var toastManager
    @Environment(TabNavigationCoordinator.self) private var coordinator

    @State private var viewModel: TripsViewModel?
    @State private var showCreateTrip = false

    var body: some View {
        Group {
            if let viewModel {
                TripsListBody(
                    viewModel: viewModel,
                    showCreateTrip: $showCreateTrip,
                    toastManager: toastManager
                )
            } else {
                AppColors.appBackground
            }
        }
        .task {
            if viewModel == nil {
                viewModel = TripsViewModel(dataService: dataService, preferences: userPreferences)
            }
            await viewModel?.loadTrips()
        }
    }
}

private struct TripsListBody: View {
    @Bindable var viewModel: TripsViewModel
    @Environment(AuthViewModel.self) private var authViewModel
    @Environment(UserPreferencesStore.self) private var userPreferences
    @Environment(TabNavigationCoordinator.self) private var coordinator

    @Binding var showCreateTrip: Bool
    var toastManager: ToastManager

    private var showMainEmpty: Bool {
        !viewModel.isLoading && viewModel.trips.isEmpty
    }

    private var showNoSearchResults: Bool {
        !viewModel.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && viewModel.filteredTrips.isEmpty
            && !viewModel.trips.isEmpty
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                let _ = userPreferences.tripSortMode
                TripsListContentSections(
                    viewModel: viewModel,
                    showCreateTrip: $showCreateTrip,
                    showMainEmpty: showMainEmpty,
                    showNoSearchResults: showNoSearchResults
                )
                .padding(.horizontal, AppSpacing.lg)
                .padding(.top, AppSpacing.sm)
                .padding(.bottom, AppSpacing.xl)
            }
            .background(AppColors.appBackground)
            .refreshable {
                await viewModel.loadTrips(preservingExistingOnFailure: true)
            }
            .navigationTitle("My Trips")
            .searchable(text: $viewModel.searchText, prompt: "Search trips...")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        ForEach(TripListSortMode.allCases) { mode in
                            Button {
                                userPreferences.tripSortMode = mode
                            } label: {
                                HStack {
                                    Text(mode.menuTitle)
                                    if userPreferences.tripSortMode == mode {
                                        Spacer(minLength: 8)
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                            .font(.system(size: 15))
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    NavigationLink {
                        NotificationsView()
                    } label: {
                        Image(systemName: "bell")
                            .font(.system(size: 17))
                    }
                    .accessibilityLabel("Notifications")

                    NavigationLink {
                        ProfileView()
                    } label: {
                        AvatarView(
                            displayName: authViewModel.currentUserName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                ? nil : authViewModel.currentUserName,
                            imageURL: authViewModel.profileAvatarURL,
                            stableID: authViewModel.userAvatarStableID,
                            size: TripsListLayout.profileToolbarAvatarSize
                        )
                    }
                    .accessibilityLabel("Profile")
                }
            }
            .safeAreaInset(edge: .bottom, alignment: .trailing) {
                Button {
                    HapticManager.medium()
                    showCreateTrip = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 56, height: 56)
                        .background(AppColors.appPrimary)
                        .clipShape(Circle())
                        .shadow(color: Color.black.opacity(0.15), radius: 8, x: 0, y: 4)
                }
                .accessibilityLabel("Plan a new trip")
                .padding(.trailing, AppSpacing.lg)
                .padding(.bottom, AppSpacing.sm)
            }
            .sheet(isPresented: $showCreateTrip) {
                CreateTripView { newTrip in
                    showCreateTrip = false
                    coordinator.openTrip(newTrip)
                }
            }
        }
    }
}

// MARK: - List content

private struct TripsListContentSections: View {
    @Bindable var viewModel: TripsViewModel
    @Environment(TabNavigationCoordinator.self) private var coordinator
    @Binding var showCreateTrip: Bool
    var showMainEmpty: Bool
    var showNoSearchResults: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xl) {
            if viewModel.isLoading && viewModel.trips.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .frame(minHeight: 400)
            } else if showMainEmpty {
                EmptyStateView(
                    sfSymbol: "globe.americas.fill",
                    title: "Where to next?",
                    subtitle: "Plan your first trip and keep everything in one place.",
                    buttonTitle: "+ Plan a Trip",
                    buttonAction: { showCreateTrip = true }
                )
                .frame(minHeight: 400)
            } else {
                if !viewModel.activeTrips.isEmpty {
                    VStack(alignment: .leading, spacing: AppSpacing.md) {
                        Text(viewModel.activeTrips.count == 1 ? "YOUR CURRENT TRIP" : "YOUR CURRENT TRIPS")
                            .font(.appSmall)
                            .foregroundStyle(AppColors.textTertiary)
                            .textCase(.uppercase)
                            .tracking(1.5)

                        if viewModel.activeTrips.count == 1, let active = viewModel.activeTrips.first {
                            ActiveTripHeroView(trip: active) {
                                coordinator.openTrip(active)
                            }
                        } else {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: AppSpacing.md) {
                                    ForEach(viewModel.activeTrips) { trip in
                                        ActiveTripHeroView(trip: trip) {
                                            coordinator.openTrip(trip)
                                        }
                                        .frame(width: TripsListLayout.activeTripCardWidth)
                                    }
                                }
                            }
                        }
                    }
                }

                if !viewModel.upcomingTrips.isEmpty {
                    VStack(alignment: .leading, spacing: AppSpacing.md) {
                        Text("UPCOMING")
                            .font(.appSmall)
                            .foregroundStyle(AppColors.textTertiary)
                            .textCase(.uppercase)
                            .tracking(1.5)

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: AppSpacing.md) {
                                ForEach(viewModel.upcomingTrips) { trip in
                                    TripCardView(trip: trip) {
                                        coordinator.openTrip(trip)
                                    }
                                }
                            }
                        }
                    }
                }

                if !viewModel.pastTrips.isEmpty {
                    VStack(alignment: .leading, spacing: AppSpacing.md) {
                        Text("PAST TRIPS")
                            .font(.appSmall)
                            .foregroundStyle(AppColors.textTertiary)
                            .textCase(.uppercase)
                            .tracking(1.5)

                        VStack(alignment: .leading, spacing: AppSpacing.sm) {
                            ForEach(viewModel.pastTrips) { trip in
                                Button {
                                    coordinator.openTrip(trip)
                                } label: {
                                    PastTripRowView(trip: trip)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                if showNoSearchResults {
                    Text("No trips match your search.")
                        .font(.appBody)
                        .foregroundStyle(AppColors.textSecondary)
                        .frame(maxWidth: .infinity)
                        .multilineTextAlignment(.center)
                        .padding(.top, AppSpacing.xl)
                }
            }
        }
    }
}

private struct PastTripRowView: View {
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
            .frame(width: 52, height: 52)
            .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.small, style: .continuous))

            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                Text(trip.title)
                    .font(.cardTitle)
                    .foregroundStyle(AppColors.textPrimary)
                    .lineLimit(1)
                Text("\(trip.startDate.shortFormatted) – \(trip.endDate.shortFormatted)")
                    .font(.appCaption)
                    .foregroundStyle(AppColors.textSecondary)
                Text("Completed")
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

