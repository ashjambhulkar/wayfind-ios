import Observation
import SwiftUI

struct TripsListView: View {
    @Environment(AuthViewModel.self) private var authViewModel
    @Environment(MockDataService.self) private var dataService
    @Environment(ToastManager.self) private var toastManager

    @State private var viewModel: TripsViewModel?
    @State private var showCreateTrip = false
    @State private var navigationPath = NavigationPath()

    var body: some View {
        Group {
            if let viewModel {
                TripsListBody(
                    viewModel: viewModel,
                    showCreateTrip: $showCreateTrip,
                    navigationPath: $navigationPath,
                    userInitials: authViewModel.userInitials,
                    toastManager: toastManager
                )
            } else {
                AppColors.appBackground
            }
        }
        .task {
            if viewModel == nil {
                viewModel = TripsViewModel(mockDataService: dataService)
            }
            await viewModel?.loadTrips()
        }
    }
}

private struct TripsListBody: View {
    @Bindable var viewModel: TripsViewModel

    @Binding var showCreateTrip: Bool
    @Binding var navigationPath: NavigationPath
    var userInitials: String
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
        NavigationStack(path: $navigationPath) {
            ScrollView {
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
                        if let active = viewModel.activeTrip {
                            VStack(alignment: .leading, spacing: AppSpacing.md) {
                                Text("YOUR CURRENT TRIP")
                                    .font(.appSmall)
                                    .foregroundStyle(AppColors.textTertiary)
                                    .textCase(.uppercase)
                                    .tracking(1.5)

                                ActiveTripHeroView(trip: active) {
                                    navigationPath.append(active)
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
                                                navigationPath.append(trip)
                                            }
                                        }
                                    }
                                }
                            }
                        }

                        if !viewModel.pastTrips.isEmpty {
                            DisclosureGroup {
                                VStack(alignment: .leading, spacing: AppSpacing.sm) {
                                    ForEach(viewModel.pastTrips) { trip in
                                        Button {
                                            navigationPath.append(trip)
                                        } label: {
                                            PastTripRowView(trip: trip)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            } label: {
                                Text("PAST TRIPS")
                                    .font(.appSmall)
                                    .foregroundStyle(AppColors.textTertiary)
                                    .textCase(.uppercase)
                                    .tracking(1.5)
                            }
                            .tint(AppColors.appPrimary)
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
                .padding(.horizontal, AppSpacing.lg)
                .padding(.top, AppSpacing.sm)
                .padding(.bottom, 100)
            }
            .background(AppColors.appBackground)
            .refreshable {
                await viewModel.loadTrips()
            }
            .navigationTitle("My Trips")
            .searchable(text: $viewModel.searchText, prompt: "Search trips...")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button {
                            viewModel.sortOrder = .date
                        } label: {
                            Label("Date", systemImage: viewModel.sortOrder == .date ? "checkmark" : "calendar")
                        }
                        Button {
                            viewModel.sortOrder = .name
                        } label: {
                            Label("Name", systemImage: viewModel.sortOrder == .name ? "checkmark" : "textformat")
                        }
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                            .font(.system(size: 15))
                            .foregroundStyle(AppColors.appPrimary)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        ProfileView()
                    } label: {
                        Text(userInitials)
                            .font(.appCaption)
                            .foregroundStyle(.white)
                            .frame(width: 28, height: 28)
                            .background(AppColors.appPrimary)
                            .clipShape(Circle())
                    }
                }
            }
            .safeAreaInset(edge: .bottom, alignment: .trailing) {
                Button {
                    HapticManager.light()
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
                .buttonStyle(FABPressStyle())
                .padding(.trailing, AppSpacing.lg)
                .padding(.bottom, AppSpacing.sm)
            }
            .sheet(isPresented: $showCreateTrip) {
                CreateTripView { newTrip in
                    showCreateTrip = false
                    navigationPath.append(newTrip)
                }
            }
            .navigationDestination(for: Trip.self) { trip in
                TripDetailView(trip: trip)
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

private struct FABPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(AppSpring.snappy, value: configuration.isPressed)
    }
}