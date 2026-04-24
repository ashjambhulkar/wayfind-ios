import SwiftUI

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

    var editingPlace: Place? = nil
    var onSave: ((Place) -> Void)? = nil
    let targetDayId: UUID

    private var isEditMode: Bool { editingPlace != nil }

    private var ctaTitle: String {
        isEditMode ? "Save Changes" : "Add \(selectedType.label) →"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.xl) {
                BookingTypeChipSelector(selectedType: $selectedType)

                Divider()
                    .background(AppColors.appDivider)
                    .padding(.horizontal, AppSpacing.lg)

                bookingForm
                    .padding(.horizontal, AppSpacing.lg)
                    .animation(AppSpring.smooth, value: selectedType)

                VStack(alignment: .leading, spacing: AppSpacing.md) {
                    Text("CONFIRMATION")
                        .font(.appSmall)
                        .foregroundStyle(AppColors.textTertiary)
                        .tracking(1.5)
                        .textCase(.uppercase)
                    BookingFormField(
                        label: "Confirmation Number",
                        placeholder: "Optional",
                        text: $confirmationNumber
                    )
                }
                .padding(.horizontal, AppSpacing.lg)

                AppButton(
                    title: ctaTitle,
                    style: .primary,
                    action: save
                )
                .padding(.horizontal, AppSpacing.lg)
            }
            .padding(.vertical, AppSpacing.lg)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(AppColors.appBackground)
        .navigationTitle(isEditMode ? "Edit Booking" : "Add Booking")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { prefillFromEditingPlace() }
    }

    private func prefillFromEditingPlace() {
        guard let place = editingPlace else { return }
        confirmationNumber = place.confirmationNumber ?? ""
        if let typeStr = place.bookingType, let cat = BookingCategory(rawValue: typeStr) {
            selectedType = cat
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
                    checkOutDate: $hotelCheckOut,
                    roomType: $hotelRoomType,
                    checkInTime: $hotelCheckInTime,
                    checkOutTime: $hotelCheckOutTime
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
                    dropoffDate: $carDropoffDate,
                    carType: $carType
                )
            case .activity:
                ActivityFormView(
                    activityName: $activityName,
                    location: $activityLocation,
                    activityDate: $activityDate,
                    duration: $activityDuration,
                    provider: $activityProvider,
                    ticketNumber: $activityTicketNumber
                )
            case .transport:
                TransportFormView(
                    operatorName: $transportOperator,
                    serviceNumber: $transportServiceNumber,
                    departureStation: $transportDepartureStation,
                    arrivalStation: $transportArrivalStation,
                    departureDate: $transportDepartureDate,
                    arrivalDate: $transportArrivalDate,
                    seat: $transportSeat
                )
            }
        }
        .transition(.opacity)
    }

    private func save() {
        let place = makePlace()
        HapticManager.success()
        onSave?(place)
        dismiss()
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

private struct BookingFormField: View {
    let label: String
    let placeholder: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            Text(label)
                .font(.appCaption)
                .foregroundStyle(AppColors.textSecondary)
            TextField(placeholder, text: $text)
                .font(.appBody)
                .padding(.horizontal, AppSpacing.md)
                .frame(height: 48)
                .background(AppColors.appSurface)
                .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous)
                        .strokeBorder(AppColors.appDivider, lineWidth: 1)
                )
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// =============================================================================

