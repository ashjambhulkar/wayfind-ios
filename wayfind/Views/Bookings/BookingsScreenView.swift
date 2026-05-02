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
    @State private var flightTracking = FlightTrackingService()

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
                    ForwardingEmailCardView(trip: trip, density: .compact)
                        .padding(.horizontal, AppSpacing.lg)
                        .padding(.top, AppSpacing.sm)
                        .padding(.bottom, AppSpacing.md)

                    EmptyStateView(
                        sfSymbol: "airplane",
                        title: "No bookings yet",
                        subtitle: "Use the Add menu to create a flight, hotel, restaurant, car rental, activity, or transport booking."
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        Section {
                            ForwardingEmailCardView(trip: trip, density: .compact)
                                .listRowInsets(EdgeInsets(top: AppSpacing.sm, leading: AppSpacing.lg, bottom: AppSpacing.sm, trailing: AppSpacing.lg))
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                        }

                        ForEach(groupedBookings, id: \.category) { group in
                            Section {
                                ForEach(group.places) { place in
                                    Button {
                                        bookingToEdit = place
                                    } label: {
                                        BookingListRow(
                                            place: place,
                                            category: group.category,
                                            flightStatus: flightTracking.statusesByBookingId[place.id],
                                            isFlightStale: flightStaleness(for: place),
                                            flightTint: flightTint(for: place)
                                        )
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
            await flightTracking.bind(tripId: trip.id)
        }
        .onDisappear {
            Task { await flightTracking.unbind() }
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

    private func flightStaleness(for place: Place) -> Bool {
        guard let status = flightTracking.statusesByBookingId[place.id] else { return false }
        return flightTracking.staleness(of: status)
    }

    private func flightTint(for place: Place) -> FlightStatus.DisplayState.Tint {
        guard let status = flightTracking.statusesByBookingId[place.id] else { return .neutral }
        return flightTracking.tint(of: status)
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
    var flightStatus: FlightStatus?
    var isFlightStale = false
    var flightTint: FlightStatus.DisplayState.Tint = .neutral

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
        switch place.bookingDetails {
        case .flight(let flightDetails):
            FlightBookingPassCard(
                place: place,
                details: flightDetails,
                status: flightStatus,
                isStale: isFlightStale,
                tint: flightTint
            )
        case .hotel(let details):
            BookingPassCard(
                category: category,
                eyebrow: "Stay Pass",
                symbol: "bed.double.fill",
                title: place.name,
                subtitle: hotelStaySubtitle(details),
                statusText: hotelStayStatus(details),
                metrics: [
                    BookingPassMetric(title: "Check-in", value: details.checkInDate?.shortFormatted ?? "TBD"),
                    BookingPassMetric(title: "Check-out", value: details.checkOutDate?.shortFormatted ?? "TBD"),
                    BookingPassMetric(title: "Room", value: clean(details.roomType, fallback: "—")),
                    confirmationMetric
                ]
            )
        case .restaurant(let details):
            BookingPassCard(
                category: category,
                eyebrow: "Table Card",
                symbol: "fork.knife",
                title: place.name,
                subtitle: details.reservationTime.map { "\($0.shortFormatted) · \($0.timeFormatted)" } ?? dateLine,
                statusText: partyLabel(details.partySize),
                metrics: [
                    BookingPassMetric(title: "Time", value: details.reservationTime?.timeFormatted ?? "TBD"),
                    BookingPassMetric(title: "Party", value: partyLabel(details.partySize)),
                    BookingPassMetric(title: "Area", value: neighborhood(from: place.address) ?? "—"),
                    confirmationMetric
                ]
            )
        case .carRental(let details):
            BookingPassCard(
                category: category,
                eyebrow: "Rental Pass",
                symbol: "car.fill",
                title: clean(details.company, fallback: place.name),
                subtitle: "\(clean(details.pickupLocation, fallback: "Pickup TBD")) → \(clean(details.dropoffLocation, fallback: "Dropoff TBD"))",
                statusText: details.pickupTime?.shortFormatted ?? "Pickup TBD",
                metrics: [
                    dateTimeMetric(title: "Pickup", date: details.pickupTime),
                    dateTimeMetric(title: "Return", date: details.dropoffTime),
                    BookingPassMetric(title: "Car", value: clean(details.carType, fallback: "—")),
                    confirmationMetric
                ]
            )
        case .activity(let details):
            BookingPassCard(
                category: category,
                eyebrow: "Event Ticket",
                symbol: "ticket.fill",
                title: place.name,
                subtitle: clean(place.address, fallback: details.provider.isEmpty ? "Venue TBD" : details.provider),
                statusText: place.startTime?.timeFormatted ?? "Time TBD",
                metrics: [
                    dateTimeMetric(title: "Starts", date: place.startTime),
                    BookingPassMetric(title: "Duration", value: clean(details.duration, fallback: "—")),
                    BookingPassMetric(title: "Provider", value: clean(details.provider, fallback: "—")),
                    BookingPassMetric(title: "Ticket", value: clean(details.ticketNumber, fallback: confirmationCode))
                ]
            )
        case .transport(let details):
            BookingPassCard(
                category: category,
                eyebrow: "Transit Pass",
                symbol: category.sfSymbol,
                title: transportTitle(details),
                subtitle: "\(clean(details.departureStation, fallback: "Departure TBD")) → \(clean(details.arrivalStation, fallback: "Arrival TBD"))",
                statusText: details.departureTime?.shortFormatted ?? "Departure TBD",
                metrics: [
                    dateTimeMetric(title: "Departs", date: details.departureTime),
                    dateTimeMetric(title: "Arrives", date: details.arrivalTime),
                    BookingPassMetric(title: "Seat", value: clean(details.seat, fallback: "—")),
                    confirmationMetric
                ]
            )
        case nil:
            BookingPassCard(
                category: category,
                eyebrow: "\(category.label) Pass",
                symbol: category.sfSymbol,
                title: place.name,
                subtitle: dateLine,
                statusText: category.label,
                metrics: [
                    dateTimeMetric(title: "When", date: place.startTime),
                    BookingPassMetric(title: "Where", value: neighborhood(from: place.address) ?? "—"),
                    confirmationMetric
                ]
            )
        }
    }

    private var confirmationMetric: BookingPassMetric {
        BookingPassMetric(title: "Confirm", value: confirmationCode)
    }

    private var confirmationCode: String {
        clean(place.confirmationNumber, fallback: "—")
    }

    private func hotelStaySubtitle(_ details: HotelDetails) -> String {
        switch (details.checkInDate, details.checkOutDate) {
        case let (checkIn?, checkOut?):
            return "\(checkIn.shortFormatted) → \(checkOut.shortFormatted)"
        case let (checkIn?, nil):
            return "Check-in \(checkIn.shortFormatted)"
        case let (nil, checkOut?):
            return "Check-out \(checkOut.shortFormatted)"
        default:
            return dateLine
        }
    }

    private func hotelStayStatus(_ details: HotelDetails) -> String {
        guard let nights = details.nights, nights > 0 else { return "Stay" }
        return nights == 1 ? "1 night" : "\(nights) nights"
    }

    private func partyLabel(_ partySize: Int?) -> String {
        guard let partySize, partySize > 0 else { return "Party TBD" }
        return partySize == 1 ? "1 guest" : "\(partySize) guests"
    }

    private func dateTimeMetric(title: String, date: Date?) -> BookingPassMetric {
        guard let date else { return BookingPassMetric(title: title, value: "TBD") }
        return BookingPassMetric(title: title, value: date.shortFormatted, detail: date.timeFormatted)
    }

    private func transportTitle(_ details: TransportDetails) -> String {
        let operatorName = clean(details.operatorName, fallback: "")
        let serviceNumber = clean(details.serviceNumber, fallback: "")
        let combined = "\(operatorName) \(serviceNumber)".trimmingCharacters(in: .whitespacesAndNewlines)
        return combined.isEmpty ? place.name : combined
    }

    private func clean(_ value: String?, fallback: String) -> String {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? fallback : trimmed
    }
}

private struct BookingPassMetric: Identifiable {
    let title: String
    let value: String
    var detail: String? = nil

    var id: String { title }
}

private struct BookingPassCard: View {
    let category: BookingCategory
    let eyebrow: String
    let symbol: String
    let title: String
    let subtitle: String
    let statusText: String
    let metrics: [BookingPassMetric]

    var body: some View {
        VStack(spacing: 0) {
            passHeader
            passFooter
        }
        .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.xLarge, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: AppCornerRadius.xLarge, style: .continuous)
                .strokeBorder(AppColors.appDivider, lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.08), radius: 10, y: 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(category.label), \(title), \(subtitle)")
    }

    private var passHeader: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            HStack(alignment: .top, spacing: AppSpacing.md) {
                categoryBadge

                VStack(alignment: .leading, spacing: AppSpacing.xs) {
                    Text(eyebrow.uppercased())
                        .font(.appSmall)
                        .foregroundStyle(.white.opacity(0.58))
                        .tracking(0.8)

                    Text(title)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.76)

                    Text(subtitle)
                        .font(.appCaption)
                        .foregroundStyle(.white.opacity(0.70))
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                Text(statusText)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .padding(.horizontal, AppSpacing.sm)
                    .padding(.vertical, AppSpacing.xs)
                    .background(.white.opacity(0.12), in: Capsule())
            }

            passPerforation
        }
        .padding(AppSpacing.lg)
        .background(passHeaderBackground)
    }

    private var passFooter: some View {
        HStack(alignment: .top, spacing: AppSpacing.sm) {
            ForEach(metrics.prefix(4)) { metric in
                metricColumn(metric)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, AppSpacing.lg)
        .padding(.vertical, AppSpacing.md)
        .background(passFooterBackground)
    }

    private var passHeaderBackground: some View {
        ZStack {
            LinearGradient(
                colors: [AppColors.bookingPassHeaderTop, AppColors.bookingPassHeaderBottom],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Color.black.opacity(0.08)
        }
    }

    private var passFooterBackground: some View {
        ZStack {
            LinearGradient(
                colors: [
                    category.color,
                    category.color.opacity(0.72)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            Color.black.opacity(0.18)
        }
    }

    private var categoryBadge: some View {
        Image(systemName: symbol)
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 42, height: 42)
            .background(category.color.opacity(0.90), in: Circle())
            .overlay {
                Circle()
                    .strokeBorder(.white.opacity(0.18), lineWidth: 0.5)
            }
    }

    private var passPerforation: some View {
        HStack(spacing: AppSpacing.xs) {
            ForEach(0..<18, id: \.self) { _ in
                Circle()
                    .fill(.white.opacity(0.16))
                    .frame(width: 3, height: 3)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityHidden(true)
    }

    private func metricColumn(_ metric: BookingPassMetric) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(metric.value)
                .font(.headline.weight(.bold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.70)
            if let detail = metric.detail {
                Text(detail)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.82))
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }
            Text(metric.title)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.68))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct FlightBookingPassCard: View {
    let place: Place
    let details: FlightDetails
    let status: FlightStatus?
    let isStale: Bool
    let tint: FlightStatus.DisplayState.Tint

    private var departureAirport: String {
        preferred(status?.originAirportIata, details.departureAirport, fallback: "TBD")
    }

    private var arrivalAirport: String {
        preferred(status?.destinationAirportIata, details.arrivalAirport, fallback: "TBD")
    }

    private var departureTime: Date? {
        status?.estimatedDepartureUTC ?? status?.actualDepartureUTC ?? status?.scheduledDepartureUTC ?? details.departureTime ?? place.startTime
    }

    private var arrivalTime: Date? {
        status?.estimatedArrivalUTC ?? status?.actualArrivalUTC ?? status?.scheduledArrivalUTC ?? details.arrivalTime ?? place.endTime
    }

    private var routeDuration: String? {
        guard let departureTime, let arrivalTime else { return nil }
        let minutes = max(0, Int(arrivalTime.timeIntervalSince(departureTime) / 60))
        guard minutes > 0 else { return nil }
        let hours = minutes / 60
        let mins = minutes % 60
        if hours == 0 { return "\(mins)m" }
        return mins == 0 ? "\(hours)h" : "\(hours)h \(mins)m"
    }

    private var effectiveCarrierCode: String? {
        let candidates = [details.carrierIATA, status?.carrierIata]
        for c in candidates {
            let t = c?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !t.isEmpty { return t }
        }
        return nil
    }

    private var airlineDisplayName: String {
        let trimmed = details.airline.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return flightCode
    }

    private var flightCode: String {
        let carrier = (details.carrierIATA ?? status?.carrierIata ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        let number = (status?.flightNumber ?? details.flightNumber)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        let combined = "\(carrier) \(number)".trimmingCharacters(in: .whitespacesAndNewlines)
        return combined.isEmpty ? "Flight" : combined
    }

    private var gate: String {
        preferred(status?.gateOrigin, details.gate, fallback: "—")
    }

    private var seat: String {
        preferred(nil, details.seat, fallback: "—")
    }

    private var confirmationCode: String {
        preferred(nil, place.confirmationNumber, fallback: "—")
    }

    private var statusTitle: String {
        guard let status else {
            return details.lookupVerified ? "Tracking pending" : "Manual entry"
        }
        if isStale { return "Update stale" }
        switch status.displayState {
        case .scheduled:
            if let delay = status.delayMinutes, delay >= 5 { return "Delayed \(delay)m" }
            return "On time"
        case .active: return "In flight"
        case .landed: return "Landed"
        case .cancelled: return "Cancelled"
        case .diverted: return "Diverted"
        case .unknown: return "Status unknown"
        }
    }

    private var statusSubtitle: String? {
        if let summary = status?.lastChangeSummary?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty {
            return summary
        }
        if let status, isStale {
            let minutes = max(1, Int(Date().timeIntervalSince(status.polledAt) / 60))
            return "Updated \(minutes)m ago"
        }
        if let baggage = status?.baggageClaim, status?.displayState == .landed {
            return "Belt \(baggage)"
        }
        return details.lookupVerified ? "Live tracking enabled" : nil
    }

    private var statusColor: Color {
        switch tint {
        case .green: return AppColors.appSuccess
        case .amber: return AppColors.appWarning
        case .red: return AppColors.appError
        case .neutral: return AppColors.textSecondary
        }
    }

    private var passHeaderTopColor: Color {
        AppColors.bookingPassHeaderTop
    }

    private var passHeaderBottomColor: Color {
        AppColors.bookingPassHeaderBottom
    }

    var body: some View {
        VStack(spacing: 0) {
            topPanel
            bottomPanel
        }
        .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.xLarge, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: AppCornerRadius.xLarge, style: .continuous)
                .strokeBorder(AppColors.appDivider, lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.10), radius: 12, y: 5)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
    }

    private var topPanel: some View {
        VStack(spacing: AppSpacing.md) {
            HStack(alignment: .top) {
                airportBlock(
                    airport: departureAirport,
                    city: departureCity,
                    time: departureTime?.timeFormatted
                )

                Spacer(minLength: AppSpacing.md)

                routeArc
                    .frame(maxWidth: 150)
                    .padding(.top, AppSpacing.xs)

                Spacer(minLength: AppSpacing.md)

                airportBlock(
                    airport: arrivalAirport,
                    city: arrivalCity,
                    time: arrivalTime?.timeFormatted,
                    alignment: .trailing
                )
            }

            HStack {
                flightStatusChip
                Spacer(minLength: AppSpacing.sm)
                if details.lookupVerified {
                    Label("Verified", systemImage: "checkmark.seal.fill")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.82))
                }
            }
        }
        .padding(AppSpacing.lg)
        .background(flightHeaderBackground)
    }

    private var bottomPanel: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            HStack(alignment: .center, spacing: AppSpacing.sm) {
                AirlineLogoView(
                    carrierIATA: effectiveCarrierCode,
                    airlineNameFallback: airlineDisplayName,
                    variant: .bookingPassFooter
                )
                Text(airlineDisplayName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .minimumScaleFactor(0.82)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(alignment: .top, spacing: AppSpacing.lg) {
                flightMetric(title: "Flight", value: flightCode)
                flightMetric(title: "Gate", value: gate)
                flightMetric(title: "Seat", value: seat)
                flightMetric(title: "Confirm", value: confirmationCode)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, AppSpacing.lg)
        .padding(.vertical, AppSpacing.md)
        .background(flightFooterBackground)
    }

    private var flightHeaderBackground: some View {
        ZStack {
            LinearGradient(
                colors: [
                    passHeaderTopColor,
                    passHeaderBottomColor
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Color.black.opacity(0.08)
        }
    }

    private var flightFooterBackground: some View {
        ZStack {
            LinearGradient(
                colors: [
                    AppColors.appPrimary,
                    AppColors.appAccent
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            Color.black.opacity(0.18)
        }
    }

    private var routeArc: some View {
        VStack(spacing: AppSpacing.xs) {
            ZStack(alignment: .top) {
                FlightRouteArc()
                    .stroke(.white.opacity(0.25), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .frame(height: 36)
                Image(systemName: "airplane")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.45))
                    .offset(y: -2)
            }
            Text(routeDuration ?? "Flight")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white.opacity(0.78))
                .lineLimit(1)
        }
    }

    private var flightStatusChip: some View {
        HStack(spacing: AppSpacing.xs) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 1) {
                Text(statusTitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                if let statusSubtitle {
                    Text(statusSubtitle)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.70))
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, AppSpacing.sm)
        .padding(.vertical, AppSpacing.xs)
        .background(.white.opacity(0.10), in: Capsule())
        .overlay {
            Capsule()
                .strokeBorder(.white.opacity(0.14), lineWidth: 0.5)
        }
    }

    private func airportBlock(
        airport: String,
        city: String?,
        time: String?,
        alignment: HorizontalAlignment = .leading
    ) -> some View {
        VStack(alignment: alignment, spacing: 3) {
            HStack(spacing: 4) {
                if alignment == .leading {
                    Image(systemName: "airplane.departure")
                }
                Text(time ?? "Time TBD")
                if alignment == .trailing {
                    Image(systemName: "airplane.arrival")
                }
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.white.opacity(0.60))

            Text(airport)
                .font(.title2.weight(.bold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.75)

            Text(city ?? "Airport")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.66))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: alignment == .leading ? .leading : .trailing)
    }

    private func flightMetric(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.headline.weight(.bold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            Text(title)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.65))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var departureCity: String? {
        airportCity(from: details.departureAirport)
    }

    private var arrivalCity: String? {
        airportCity(from: details.arrivalAirport)
    }

    private var accessibilitySummary: String {
        [
            airlineDisplayName,
            "\(flightCode), \(departureAirport) to \(arrivalAirport)",
            statusTitle,
            "confirmation \(confirmationCode)"
        ].joined(separator: ", ")
    }

    private func airportCity(from value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count > 3 else { return nil }
        return trimmed
    }

    private func preferred(_ first: String?, _ second: String?, fallback: String) -> String {
        let candidates = [first, second]
        for candidate in candidates {
            let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty { return trimmed }
        }
        return fallback
    }
}

private struct FlightRouteArc: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.maxY),
            control: CGPoint(x: rect.midX, y: rect.minY)
        )
        return path
    }
}

// =============================================================================

