import SwiftUI

private struct AddBookingRoute: Identifiable, Hashable {
    let category: BookingCategory
    let targetDayId: UUID

    var id: String {
        "\(category.rawValue)-\(targetDayId.uuidString)"
    }
}

struct BookingsScreenView: View {
    @Environment(DataService.self) var dataService
    @Environment(ToastManager.self) private var toastManager
    @Environment(CollaborationStore.self) private var collaborationStore

    let trip: Trip
    /// Optional callback so the post-save toast's "View" action can jump
    /// into the trip's Budget tab. The dedicated bookings screen lives in
    /// the trip-detail navigation stack, so the parent injects the same
    /// handle it gives `TripDetailView`.
    var onOpenBudgetTab: (() -> Void)? = nil

    @State private var allBookings: [Place] = []
    @State private var bookingToEdit: Place?
    @State private var pendingUndo: Place?
    @State private var undoTask: Task<Void, Never>?
    @State private var addBookingRoute: AddBookingRoute?

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
                        subtitle: "Use the Add menu to create a flight, hotel, restaurant, car rental, activity, or transport booking."
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
        .toolbar {
            ToolbarItemGroup(placement: .bottomBar) {
                ForEach(BookingCategory.allCases) { category in
                    Button {
                        Task { await openAddBooking(for: category) }
                    } label: {
                        Label("Add \(category.label)", systemImage: category.sfSymbol)
                    }
                    .tint(AppColors.textPrimary)
                }
            }
        }
        .animation(AppSpring.smooth, value: pendingUndo != nil)
        .task {
            await loadBookings()
        }
        .sheet(item: $addBookingRoute) { route in
            NavigationStack {
                AddBookingView(
                    initialType: route.category,
                    onSave: { savedPlace, cost in
                        guard await dataService.addPlace(savedPlace) else {
                            toastManager.show(ToastData(message: "Could not save booking", type: .error))
                            return false
                        }
                        await loadBookings()
                        await trackBookingExpenseIfNeeded(place: savedPlace, cost: cost)
                        toastManager.show(makeBookingSavedToast(cost: cost, isUpdate: false))
                        return true
                    },
                    targetDayId: route.targetDayId,
                    showsCloseButton: true
                )
            }
        }
        .sheet(item: $bookingToEdit) { place in
            NavigationStack {
                AddBookingView(
                    editingPlace: place,
                    onSave: { updated, cost in
                        guard await dataService.updatePlace(updated) else {
                            toastManager.show(ToastData(message: "Could not save booking", type: .error))
                            return false
                        }
                        await loadBookings()
                        await trackBookingExpenseIfNeeded(place: updated, cost: cost)
                        toastManager.show(makeBookingSavedToast(cost: cost, isUpdate: true))
                        return true
                    },
                    targetDayId: place.itineraryDayId,
                    showsCloseButton: true
                )
            }
        }
    }

    /// Mirror of `TripDetailView.trackBookingExpenseIfNeeded` — kept inline
    /// so this screen works standalone (it's also reachable from the home
    /// dashboard via the bookings tab). When a cost is supplied we file a
    /// `full`-split expense for the current user; the budget hub picks it
    /// up via realtime as soon as the user navigates to that tab.
    private func trackBookingExpenseIfNeeded(place: Place, cost: BookingCost?) async {
        guard let cost else { return }
        guard let userId = collaborationStore.currentUserId else { return }
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
        _ = await dataService.addExpense(expense, splits: [split])
    }

    /// Same toast factory used by `TripDetailView` — surfaces the
    /// "Booking added · Tracked as $X expense" copy with a "View" action
    /// when an `onOpenBudgetTab` handle was injected, otherwise falls back
    /// to a plain success toast.
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
        let bookings = await dataService.fetchBookings(for: trip.id)
        allBookings = bookings
    }

    @MainActor
    private func openAddBooking(for category: BookingCategory) async {
        guard let targetDayId = await resolvedAddBookingTargetDayId() else {
            toastManager.show(ToastData(message: "Could not load trip days", type: .error))
            return
        }
        HapticManager.light()
        addBookingRoute = AddBookingRoute(category: category, targetDayId: targetDayId)
    }

    private func resolvedAddBookingTargetDayId() async -> UUID? {
        var days = await dataService.fetchDays(for: trip.id)
        if days.filter({ !$0.isWishlist }).isEmpty {
            await dataService.regenerateDays(for: trip.id, startDate: trip.startDate, endDate: trip.endDate)
            days = await dataService.fetchDays(for: trip.id)
        }

        return days
            .filter { !$0.isWishlist }
            .sorted { $0.dayNumber < $1.dayNumber }
            .first?
            .id
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

// =============================================================================

