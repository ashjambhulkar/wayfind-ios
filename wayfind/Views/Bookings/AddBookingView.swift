import SwiftUI

/// User-entered cost surfaced through `AddBookingView.onSave`. The parent
/// view is responsible for routing it to the budget service so a tracked
/// `trip_expense` is created alongside the booking. We intentionally use
/// `Decimal` (not `Double`) so locale parsing in `MoneyField.parse` keeps
/// full precision through the database round-trip.
struct BookingCost: Hashable, Sendable {
    let amount: Decimal
    let currency: String
}

struct AddBookingView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var selectedType: BookingCategory = .flight
    @State private var confirmationNumber = ""

    @State private var flightAirline = ""
    @State private var flightNumber = ""
    @State private var flightDepartureAirport = ""
    @State private var flightArrivalAirport = ""
    @State private var flightDepartureDate = Date()
    @State private var flightArrivalDate = Date()
    @State private var flightTerminal = ""
    @State private var flightGate = ""
    @State private var flightSeat = ""

    @State private var hotelName = ""
    @State private var hotelCheckIn = Date()
    @State private var hotelCheckOut = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
    @State private var hotelRoomType = ""
    @State private var hotelCheckInTime = ""
    @State private var hotelCheckOutTime = ""

    @State private var restaurantName = ""
    @State private var restaurantReservationDate = Date()
    @State private var restaurantPartySize = 2

    @State private var carCompany = ""
    @State private var carPickupLocation = ""
    @State private var carDropoffLocation = ""
    @State private var carPickupDate = Date()
    @State private var carDropoffDate = Date()
    @State private var carType = ""

    @State private var activityName = ""
    @State private var activityLocation = ""
    @State private var activityDate = Date()
    @State private var activityDuration = ""
    @State private var activityProvider = ""
    @State private var activityTicketNumber = ""

    @State private var transportOperator = ""
    @State private var transportServiceNumber = ""
    @State private var transportDepartureStation = ""
    @State private var transportArrivalStation = ""
    @State private var transportDepartureDate = Date()
    @State private var transportArrivalDate = Date()
    @State private var transportSeat = ""

    /// Phase 7 — optional cost the user types into `MoneyField`. When
    /// non-empty, the parent uses it to upsert a tracked `trip_expense`
    /// alongside the booking. Locale-friendly text storage matches the
    /// behaviour of `AddExpenseSheet` (also a `MoneyField` consumer).
    @State private var costAmountText: String = ""
    @State private var costCurrency: String = "USD"

    var editingPlace: Place? = nil
    var onSave: ((Place, BookingCost?) -> Void)? = nil
    let targetDayId: UUID

    private var isEditMode: Bool { editingPlace != nil }

    init(
        editingPlace: Place? = nil,
        initialType: BookingCategory = .flight,
        onSave: ((Place, BookingCost?) -> Void)? = nil,
        targetDayId: UUID
    ) {
        self.editingPlace = editingPlace
        self.onSave = onSave
        self.targetDayId = targetDayId
        if let typeStr = editingPlace?.bookingType, let category = BookingCategory(rawValue: typeStr) {
            _selectedType = State(initialValue: category)
        } else {
            _selectedType = State(initialValue: initialType)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.xl) {
                bookingForm
                    .padding(.horizontal, AppSpacing.lg)

                BookingMapDetailsSection(
                    accent: selectedType.color,
                    amountText: $costAmountText,
                    currency: $costCurrency,
                    confirmationNumber: $confirmationNumber
                )
                .padding(.horizontal, AppSpacing.lg)

                if selectedType == .flight {
                    FlightOptionalDetailsSection(
                        terminal: $flightTerminal,
                        gate: $flightGate,
                        seat: $flightSeat
                    )
                    .padding(.horizontal, AppSpacing.lg)
                } else if selectedType == .hotel {
                    HotelOptionalDetailsSection(roomType: $hotelRoomType)
                        .padding(.horizontal, AppSpacing.lg)
                } else if selectedType == .carRental {
                    CarRentalOptionalDetailsSection(carType: $carType)
                        .padding(.horizontal, AppSpacing.lg)
                } else if selectedType == .activity {
                    ActivityOptionalDetailsSection(
                        provider: $activityProvider,
                        ticketNumber: $activityTicketNumber
                    )
                    .padding(.horizontal, AppSpacing.lg)
                } else if selectedType == .transport {
                    TransportOptionalDetailsSection(seat: $transportSeat)
                        .padding(.horizontal, AppSpacing.lg)
                }
            }
            .padding(.vertical, AppSpacing.lg)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(AppColors.appBackground)
        .navigationTitle(isEditMode ? "Edit \(selectedType.label)" : "Add \(selectedType.label)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(isEditMode ? "Save" : "Add") {
                    save()
                }
                .font(.appButton)
                .foregroundStyle(AppColors.appPrimary)
                .accessibilityLabel(isEditMode ? "Save booking" : "Add \(selectedType.label)")
            }
        }
        .onAppear { prefillFromEditingPlace() }
    }

    private func prefillFromEditingPlace() {
        guard let place = editingPlace else { return }
        confirmationNumber = place.confirmationNumber ?? ""
        if let typeStr = place.bookingType, let cat = BookingCategory(rawValue: typeStr) {
            selectedType = cat
        }
        if let amount = place.bookingAmount {
            costAmountText = NSDecimalNumber(decimal: amount).stringValue
        }
        if let currency = place.bookingCurrencyCode, !currency.isEmpty {
            costCurrency = currency.uppercased()
        }
        guard let details = place.bookingDetails else { return }
        switch details {
        case .flight(let f):
            flightAirline = f.airline ?? ""
            flightNumber = f.flightNumber ?? ""
            flightDepartureAirport = f.departureAirport ?? ""
            flightArrivalAirport = f.arrivalAirport ?? ""
            if let d = f.departureTime { flightDepartureDate = d }
            if let d = f.arrivalTime { flightArrivalDate = d }
            flightTerminal = f.terminal ?? ""
            flightGate = f.gate ?? ""
            flightSeat = f.seat ?? ""
        case .hotel(let h):
            hotelName = place.name
            if let d = h.checkInDate { hotelCheckIn = d }
            if let d = h.checkOutDate { hotelCheckOut = d }
            hotelRoomType = h.roomType ?? ""
            hotelCheckInTime = h.checkInTime ?? ""
            hotelCheckOutTime = h.checkOutTime ?? ""
        case .restaurant(let r):
            restaurantName = place.name
            if let d = r.reservationTime { restaurantReservationDate = d }
            restaurantPartySize = r.partySize ?? 2
        case .carRental(let c):
            carCompany = c.company ?? ""
            carPickupLocation = c.pickupLocation ?? ""
            carDropoffLocation = c.dropoffLocation ?? ""
            if let d = c.pickupTime { carPickupDate = d }
            if let d = c.dropoffTime { carDropoffDate = d }
            carType = c.carType ?? ""
        case .activity(let a):
            activityName = place.name
            activityProvider = a.provider ?? ""
            activityDuration = a.duration ?? ""
            activityTicketNumber = a.ticketNumber ?? ""
            if let d = place.startTime { activityDate = d }
        case .transport(let t):
            transportOperator = t.operatorName ?? ""
            transportServiceNumber = t.serviceNumber ?? ""
            transportDepartureStation = t.departureStation ?? ""
            transportArrivalStation = t.arrivalStation ?? ""
            if let d = t.departureTime { transportDepartureDate = d }
            if let d = t.arrivalTime { transportArrivalDate = d }
            transportSeat = t.seat ?? ""
        }
    }

    @ViewBuilder
    private var bookingForm: some View {
        Group {
            switch selectedType {
            case .flight:
                FlightFormView(
                    airline: $flightAirline,
                    flightNumber: $flightNumber,
                    departureAirport: $flightDepartureAirport,
                    arrivalAirport: $flightArrivalAirport,
                    departureDate: $flightDepartureDate,
                    arrivalDate: $flightArrivalDate,
                    terminal: $flightTerminal,
                    gate: $flightGate,
                    seat: $flightSeat
                )
            case .hotel:
                HotelFormView(
                    hotelName: $hotelName,
                    checkInDate: $hotelCheckIn,
                    checkOutDate: $hotelCheckOut
                )
            case .restaurant:
                RestaurantFormView(
                    restaurantName: $restaurantName,
                    reservationDate: $restaurantReservationDate,
                    partySize: $restaurantPartySize
                )
            case .carRental:
                CarRentalFormView(
                    company: $carCompany,
                    pickupLocation: $carPickupLocation,
                    dropoffLocation: $carDropoffLocation,
                    pickupDate: $carPickupDate,
                    dropoffDate: $carDropoffDate
                )
            case .activity:
                ActivityFormView(
                    activityName: $activityName,
                    location: $activityLocation,
                    activityDate: $activityDate,
                    duration: $activityDuration
                )
            case .transport:
                TransportFormView(
                    operatorName: $transportOperator,
                    serviceNumber: $transportServiceNumber,
                    departureStation: $transportDepartureStation,
                    arrivalStation: $transportArrivalStation,
                    departureDate: $transportDepartureDate,
                    arrivalDate: $transportArrivalDate
                )
            }
        }
        .transition(.opacity)
    }

    private func save() {
        let place = makePlace()
        HapticManager.success()
        let cost = parsedCost()
        onSave?(place, cost)
        dismiss()
    }

    /// Parsed `(amount, currency)` pair, or `nil` when the user left the
    /// cost field empty. Currency normalises to upper-case ISO 4217 to
    /// keep the database row consistent with the budget snapshot.
    private func parsedCost() -> BookingCost? {
        guard let amount = MoneyField.parse(costAmountText), amount > 0 else {
            return nil
        }
        let code = costCurrency.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return BookingCost(amount: amount, currency: code.isEmpty ? "USD" : code)
    }

    private func makePlace() -> Place {
        let trimmedConfirmation = confirmationNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        let confirmation = trimmedConfirmation.isEmpty ? nil : trimmedConfirmation
        let placeId = editingPlace?.id ?? UUID()

        switch selectedType {
        case .flight:
            let details = FlightDetails(
                airline: flightAirline,
                flightNumber: flightNumber,
                departureAirport: flightDepartureAirport,
                arrivalAirport: flightArrivalAirport,
                departureTime: flightDepartureDate,
                arrivalTime: flightArrivalDate,
                terminal: flightTerminal,
                gate: flightGate,
                seat: flightSeat
            )
            return Place(
                id: placeId,
                itineraryDayId: targetDayId,
                name: flightDisplayName(),
                address: flightDepartureAirport.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                lat: nil,
                lng: nil,
                category: "transport",
                notes: nil,
                sortOrder: 0,
                startTime: flightDepartureDate,
                endTime: flightArrivalDate,
                isBooking: true,
                bookingType: BookingCategory.flight.rawValue,
                confirmationNumber: confirmation,
                bookingDetails: .flight(details)
            )
        case .hotel:
            let details = HotelDetails(
                checkInDate: hotelCheckIn,
                checkInTime: hotelCheckInTime.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                checkOutDate: hotelCheckOut,
                checkOutTime: hotelCheckOutTime.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                roomType: hotelRoomType,
                nights: hotelNights(from: hotelCheckIn, to: hotelCheckOut)
            )
            return Place(
                id: placeId,
                itineraryDayId: targetDayId,
                name: hotelName.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "Hotel",
                address: nil,
                lat: nil,
                lng: nil,
                category: "hotel",
                notes: nil,
                sortOrder: 0,
                startTime: nil,
                endTime: nil,
                isBooking: true,
                bookingType: BookingCategory.hotel.rawValue,
                confirmationNumber: confirmation,
                bookingDetails: .hotel(details)
            )
        case .restaurant:
            let details = RestaurantDetails(
                reservationTime: restaurantReservationDate,
                partySize: restaurantPartySize
            )
            return Place(
                id: placeId,
                itineraryDayId: targetDayId,
                name: restaurantName.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "Restaurant",
                address: nil,
                lat: nil,
                lng: nil,
                category: "restaurant",
                notes: nil,
                sortOrder: 0,
                startTime: restaurantReservationDate,
                endTime: nil,
                isBooking: true,
                bookingType: BookingCategory.restaurant.rawValue,
                confirmationNumber: confirmation,
                bookingDetails: .restaurant(details)
            )
        case .carRental:
            let details = CarRentalDetails(
                company: carCompany,
                pickupLocation: carPickupLocation,
                dropoffLocation: carDropoffLocation,
                pickupTime: carPickupDate,
                dropoffTime: carDropoffDate,
                carType: carType
            )
            return Place(
                id: placeId,
                itineraryDayId: targetDayId,
                name: carCompany.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "Car Rental",
                address: carPickupLocation.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                lat: nil,
                lng: nil,
                category: "transport",
                notes: nil,
                sortOrder: 0,
                startTime: carPickupDate,
                endTime: carDropoffDate,
                isBooking: true,
                bookingType: BookingCategory.carRental.rawValue,
                confirmationNumber: confirmation,
                bookingDetails: .carRental(details)
            )
        case .activity:
            let details = ActivityDetails(
                provider: activityProvider,
                duration: activityDuration.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                ticketNumber: activityTicketNumber
            )
            return Place(
                id: placeId,
                itineraryDayId: targetDayId,
                name: activityName.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "Activity",
                address: activityLocation.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                lat: nil,
                lng: nil,
                category: "attraction",
                notes: nil,
                sortOrder: 0,
                startTime: activityDate,
                endTime: nil,
                isBooking: true,
                bookingType: BookingCategory.activity.rawValue,
                confirmationNumber: confirmation,
                bookingDetails: .activity(details)
            )
        case .transport:
            let details = TransportDetails(
                operatorName: transportOperator,
                serviceNumber: transportServiceNumber,
                departureStation: transportDepartureStation,
                arrivalStation: transportArrivalStation,
                departureTime: transportDepartureDate,
                arrivalTime: transportArrivalDate,
                seat: transportSeat
            )
            return Place(
                id: placeId,
                itineraryDayId: targetDayId,
                name: transportDisplayName(),
                address: transportDepartureStation.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                lat: nil,
                lng: nil,
                category: "transport",
                notes: nil,
                sortOrder: 0,
                startTime: transportDepartureDate,
                endTime: transportArrivalDate,
                isBooking: true,
                bookingType: BookingCategory.transport.rawValue,
                confirmationNumber: confirmation,
                bookingDetails: .transport(details)
            )
        }
    }

    private func flightDisplayName() -> String {
        let route = "\(flightAirline) \(flightNumber)"
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !route.isEmpty {
            return route
        }
        let airports = "\(flightDepartureAirport) → \(flightArrivalAirport)"
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !airports.isEmpty && airports != "→" {
            return airports
        }
        return "Flight"
    }

    private func transportDisplayName() -> String {
        let combined = "\(transportOperator) \(transportServiceNumber)"
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !combined.isEmpty {
            return combined
        }
        return "Transport"
    }

    private func hotelNights(from checkIn: Date, to checkOut: Date) -> Int? {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: checkIn)
        let end = calendar.startOfDay(for: checkOut)
        let days = calendar.dateComponents([.day], from: start, to: end).day
        return days
    }
}

private struct BookingMapDetailsSection: View {
    let accent: Color
    @Binding var amountText: String
    @Binding var currency: String
    @Binding var confirmationNumber: String

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            FormSectionTitle("Booking Details")

            VStack(spacing: 0) {
                BookingMapAmountRow(
                    accent: accent,
                    amountText: $amountText,
                    currency: $currency
                )

                BookingMapDivider()

                BookingMapTextRow(
                    icon: "checkmark.seal.fill",
                    title: "Confirmation",
                    placeholder: "Optional",
                    accent: accent,
                    text: $confirmationNumber
                )
            }
            .background(AppColors.appSurface)
            .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous)
                    .strokeBorder(AppColors.appDivider, lineWidth: 1)
            }
        }
    }
}

private struct BookingMapAmountRow: View {
    let accent: Color
    @Binding var amountText: String
    @Binding var currency: String

    var body: some View {
        HStack(spacing: AppSpacing.md) {
            MapStyleIcon(
                systemName: "creditcard.fill",
                size: .small,
                accent: accent,
                accessibilityLabel: "Amount"
            )

            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                Text("Amount")
                    .font(.appBody)
                    .foregroundStyle(AppColors.textPrimary)
                Text("Tracks as expense")
                    .font(.appSmall)
                    .foregroundStyle(AppColors.textTertiary)
            }

            Spacer(minLength: AppSpacing.md)

            TextField("0.00", text: $amountText)
                .font(.appBody)
                .foregroundStyle(AppColors.textPrimary)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .onChange(of: amountText) { _, newValue in
                    amountText = MoneyField.sanitize(newValue)
                }
                .frame(minWidth: BookingMapFormMetrics.amountFieldMinWidth)

            Menu {
                ForEach(MoneyField.commonCurrencies, id: \.self) { code in
                    Button(code) { currency = code }
                }
            } label: {
                HStack(spacing: AppSpacing.xs) {
                    Text(currency.uppercased())
                        .font(.appCaption.weight(.semibold))
                        .foregroundStyle(AppColors.textPrimary)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.appSmall.weight(.semibold))
                        .foregroundStyle(AppColors.textSecondary)
                }
                .padding(.horizontal, AppSpacing.sm)
                .padding(.vertical, AppSpacing.xs)
                .background(AppColors.appBackground)
                .clipShape(Capsule())
            }
            .accessibilityLabel("Currency: \(currency.uppercased())")
        }
        .padding(.horizontal, AppSpacing.md)
        .frame(minHeight: BookingMapFormMetrics.rowMinHeight)
        .contentShape(Rectangle())
    }
}

private struct BookingMapTextRow: View {
    let icon: String
    let title: String
    let placeholder: String
    let accent: Color
    @Binding var text: String

    var body: some View {
        HStack(spacing: AppSpacing.md) {
            MapStyleIcon(
                systemName: icon,
                size: .small,
                accent: accent,
                accessibilityLabel: title
            )

            Text(title)
                .font(.appBody)
                .foregroundStyle(AppColors.textPrimary)

            Spacer(minLength: AppSpacing.md)

            TextField(placeholder, text: $text)
                .font(.appBody)
                .foregroundStyle(AppColors.textPrimary)
                .multilineTextAlignment(.trailing)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .frame(minWidth: BookingMapFormMetrics.trailingFieldMinWidth)
        }
        .padding(.horizontal, AppSpacing.md)
        .frame(minHeight: BookingMapFormMetrics.rowMinHeight)
        .contentShape(Rectangle())
    }
}

private struct BookingMapDivider: View {
    var body: some View {
        Divider()
            .background(AppColors.appDivider)
            .padding(.leading, AppSpacing.xxxl + AppSpacing.md)
    }
}

private enum BookingMapFormMetrics {
    static let rowMinHeight: CGFloat = 64
    static let amountFieldMinWidth: CGFloat = 72
    static let trailingFieldMinWidth: CGFloat = 120
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// =============================================================================

