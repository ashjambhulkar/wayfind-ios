import SwiftUI

struct BookingsScreenView: View {
    @Environment(MockDataService.self) var dataService

    let trip: Trip

    @State private var allBookings: [Place] = []
    @State private var bookingToEdit: Place?
    @State private var pendingUndo: Place?
    @State private var undoTask: Task<Void, Never>?
    @State private var showAddBooking = false
    @State private var addBookingTargetDayId: UUID?

    private var groupedBookings: [(category: BookingCategory, places: [Place])] {
        BookingCategory.allCases.compactMap { category in
            let items = allBookings.filter { resolvedCategory(for: $0) == category }
            return items.isEmpty ? nil : (category, items.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending })
        }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                if allBookings.isEmpty {
                    EmptyStateView(
                        sfSymbol: "airplane",
                        title: "No bookings yet",
                        subtitle: "Add flights, hotels, and reservations to keep everything in one place.",
                        buttonTitle: "+ Add a Booking",
                        buttonAction: { showAddBooking = true }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    ForwardingEmailCardView(trip: trip)
                        .padding(.horizontal, AppSpacing.lg)
                        .padding(.bottom, AppSpacing.lg)
                } else {
                    List {
                        ForEach(groupedBookings, id: \.category) { group in
                            Section {
                                ForEach(group.places) { place in
                                    Button {
                                        bookingToEdit = place
                                    } label: {
                                        BookingListRow(place: place, category: group.category)
                                    }
                                    .buttonStyle(.plain)
                                        .listRowInsets(EdgeInsets(top: AppSpacing.sm, leading: AppSpacing.lg, bottom: AppSpacing.sm, trailing: AppSpacing.lg))
                                        .listRowSeparator(.hidden)
                                        .listRowBackground(Color.clear)
                                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                            Button(role: .destructive) {
                                                deleteBooking(place)
                                            } label: {
                                                Label("Delete", systemImage: "trash")
                                            }
                                        }
                                }
                            } header: {
                                categorySectionHeader(group.category)
                            }
                        }

                        Section {
                            ForwardingEmailCardView(trip: trip)
                                .listRowInsets(EdgeInsets(top: AppSpacing.md, leading: AppSpacing.lg, bottom: AppSpacing.lg, trailing: AppSpacing.lg))
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .background(AppColors.appBackground)

            if pendingUndo != nil {
                undoBanner
                    .padding(.horizontal, AppSpacing.lg)
                    .padding(.bottom, AppSpacing.lg)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .navigationTitle("Bookings")
        .navigationBarTitleDisplayMode(.inline)
        .animation(AppSpring.smooth, value: pendingUndo != nil)
        .task {
            await loadBookings()
        }
        .navigationDestination(isPresented: $showAddBooking) {
            AddBookingView(
                onSave: { _ in Task { await loadBookings() } },
                targetDayId: addBookingTargetDayId ?? UUID()
            )
        }
        .sheet(item: $bookingToEdit) { place in
            NavigationStack {
                AddBookingView(
                    editingPlace: place,
                    onSave: { updated in
                        Task {
                            await dataService.updatePlace(updated)
                            await loadBookings()
                        }
                    },
                    targetDayId: place.itineraryDayId
                )
            }
        }
    }

    private var undoBanner: some View {
        HStack(spacing: AppSpacing.md) {
            Text("Booking removed")
                .font(.appCaption)
                .foregroundStyle(AppColors.textPrimary)
            Spacer(minLength: 0)
            Button("Undo") {
                undoDelete()
            }
            .font(.appButton)
            .foregroundStyle(AppColors.appPrimary)
        }
        .padding(AppSpacing.md)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
    }

    private func categorySectionHeader(_ category: BookingCategory) -> some View {
        HStack(spacing: AppSpacing.xs) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(category.color)
                .frame(width: 4, height: 14)
            Text(category.label.uppercased())
                .font(.appSmall)
                .foregroundStyle(AppColors.textTertiary)
        }
        .textCase(nil)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, AppSpacing.sm)
    }

    private func resolvedCategory(for place: Place) -> BookingCategory {
        place.bookingCategoryEnum ?? .activity
    }

    private func loadBookings() async {
        let days = await dataService.fetchDays(for: trip.id)
        if addBookingTargetDayId == nil {
            addBookingTargetDayId = days.filter { !$0.isWishlist }.sorted { $0.dayNumber < $1.dayNumber }.first?.id
        }
        var collected: [Place] = []
        for day in days {
            let places = await dataService.fetchPlaces(for: day.id)
            collected.append(contentsOf: places.filter(\.isBooking))
        }
        allBookings = collected
    }

    private func deleteBooking(_ place: Place) {
        undoTask?.cancel()
        undoTask = nil
        pendingUndo = place
        Task {
            await dataService.deletePlace(id: place.id)
            await loadBookings()
        }
        undoTask = Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            await MainActor.run {
                pendingUndo = nil
            }
        }
    }

    private func undoDelete() {
        guard let place = pendingUndo else { return }
        undoTask?.cancel()
        undoTask = nil
        pendingUndo = nil
        Task {
            await dataService.addPlace(place)
            await loadBookings()
            HapticManager.success()
        }
    }
}

private struct BookingListRow: View {
    let place: Place
    let category: BookingCategory

    private var dateLine: String {
        switch (place.startTime, place.endTime) {
        case let (s?, e?):
            if Calendar.current.isDate(s, inSameDayAs: e) {
                return "\(s.shortFormatted) · \(s.timeFormatted) – \(e.timeFormatted)"
            }
            return "\(s.shortFormatted) \(s.timeFormatted) – \(e.shortFormatted) \(e.timeFormatted)"
        case let (s?, nil):
            return "\(s.shortFormatted) · \(s.timeFormatted)"
        case let (nil, e?):
            return "\(e.shortFormatted) · \(e.timeFormatted)"
        default:
            return "Date TBD"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: AppSpacing.md) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(category.color)
                .frame(width: 4)
            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                HStack(alignment: .firstTextBaseline, spacing: AppSpacing.sm) {
                    Image(systemName: category.sfSymbol)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(category.color)
                    Text(place.name)
                        .font(.cardTitle)
                        .foregroundStyle(AppColors.textPrimary)
                }
                Text(dateLine)
                    .font(.appCaption)
                    .foregroundStyle(AppColors.textSecondary)
                if let conf = place.confirmationNumber, !conf.isEmpty {
                    Text(conf)
                        .font(.appSmall)
                        .foregroundStyle(AppColors.appPrimary)
                        .padding(.horizontal, AppSpacing.sm)
                        .padding(.vertical, AppSpacing.xs)
                        .background(AppColors.appPrimaryLight)
                        .clipShape(Capsule())
                }
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