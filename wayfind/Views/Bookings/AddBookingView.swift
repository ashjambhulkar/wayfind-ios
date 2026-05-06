import Observation
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
    @State private var flightCarrierIATA = ""
    @State private var flightNumber = ""
    @State private var flightDepartureAirport = ""
    @State private var flightArrivalAirport = ""
    @State private var flightDepartureDate: Date? = nil
    @State private var flightArrivalDate: Date? = nil
    @State private var flightTerminal = ""
    @State private var flightGate = ""
    @State private var flightSeat = ""
    @State private var flightLookupState: FlightLookupFormState = .lookupInput
    @State private var verifiedFlightLookup: VerifiedFlightLookup?
    @State private var flightLookupMessage: String?
    @State private var isLookingUpFlight = false
    /// Dedupes automatic flight lookup when airline / number / date settle.
    @State private var flightAutoLookupSignature: String?
    @State private var showFlightAirlinePicker = false

    @State private var hotelName = ""
    @State private var hotelCheckIn: Date? = nil
    @State private var hotelCheckOut: Date? = nil
    @State private var hotelRoomType = ""
    @State private var hotelAddress = ""
    @State private var hotelCheckInTime = ""
    @State private var hotelCheckOutTime = ""

    @State private var restaurantName = ""
    @State private var restaurantAddress = ""
    @State private var restaurantReservationDate: Date? = nil
    @State private var restaurantPartySize = 2

    @State private var carCompany = ""
    @State private var carPickupLocation = ""
    @State private var carDropoffLocation = ""
    @State private var carPickupDate: Date? = nil
    @State private var carDropoffDate: Date? = nil
    @State private var carType = ""

    @State private var activityName = ""
    @State private var activityLocation = ""
    @State private var activityDate: Date? = nil
    @State private var activityDuration = ""
    @State private var activityProvider = ""
    @State private var activityTicketNumber = ""

    @State private var transportOperator = ""
    @State private var transportServiceNumber = ""
    @State private var transportDepartureStation = ""
    @State private var transportArrivalStation = ""
    @State private var transportDepartureDate: Date? = nil
    @State private var transportArrivalDate: Date? = nil
    @State private var transportSeat = ""

    /// Phase 7 — optional cost the user types into `MoneyField`. When
    /// non-empty, the parent uses it to upsert a tracked `trip_expense`
    /// alongside the booking. Locale-friendly text storage matches the
    /// behaviour of `AddExpenseSheet` (also a `MoneyField` consumer).
    @State private var costAmountText: String = ""
    @State private var costCurrency: String = "USD"

    var editingPlace: Place? = nil
    var onSave: ((Place, BookingCost?) async -> Bool)? = nil
    let targetDayId: UUID
    /// Whether to draw a leading X close button. Callers presenting the
    /// view as a sheet should pass `true` so the user has a clear dismiss
    /// affordance; navigation pushes (which have a system back chevron)
    /// can leave it `false` to avoid duplicating the action.
    let showsCloseButton: Bool
    /// Trip destination timezone — applied as `\.timeZone` environment so all
    /// child `DatePicker`s display in the same destination clock as the
    /// timeline and detail sheet. Falls back to device TZ when no trip context
    /// is available (legacy callers / previews).
    var displayTimeZone: TimeZone = .current
    /// When set, booking documents can attach via `BookingDocumentsInlineSection`
    /// (same pipeline as detail + timeline). Add mode inserts a placeholder
    /// `trip_bookings` row so uploads satisfy FK before the user taps Add.
    var tripId: UUID? = nil
    @Environment(DataService.self) private var dataService
    /// Stable `trip_bookings.id` for this form session (matches `editingPlace.id` in edit).
    @State private var bookingRowId: UUID
    @State private var didPersistBookingSuccessfully = false
    @State private var isSaving = false
    @State private var saveError: String?
    /// Snapshot of the form taken once after prefill in edit mode. Used to
    /// gate the Save button so it is only active when the user has actually
    /// changed something. Stays `nil` for new bookings (Save is purely
    /// driven by `canSave` validation in that case).
    @State private var initialSnapshot: BookingFormSnapshot?

    private var isEditMode: Bool { editingPlace != nil }

    init(
        editingPlace: Place? = nil,
        initialType: BookingCategory = .flight,
        onSave: ((Place, BookingCost?) async -> Bool)? = nil,
        targetDayId: UUID,
        showsCloseButton: Bool = false,
        displayTimeZone: TimeZone = .current,
        tripId: UUID? = nil
    ) {
        self.editingPlace = editingPlace
        self.onSave = onSave
        self.targetDayId = targetDayId
        self.showsCloseButton = showsCloseButton
        self.displayTimeZone = displayTimeZone
        self.tripId = tripId
        if let typeStr = editingPlace?.bookingType, let category = BookingCategory(rawValue: typeStr) {
            _selectedType = State(initialValue: category)
        } else {
            _selectedType = State(initialValue: initialType)
        }
        _bookingRowId = State(initialValue: editingPlace?.id ?? UUID())
    }

    var body: some View {
        Group {
            Form {
                switch selectedType {
                case .flight:
                    FlightFormView(
                        airline: $flightAirline,
                        carrierIATA: $flightCarrierIATA,
                        flightNumber: $flightNumber,
                        departureAirport: $flightDepartureAirport,
                        arrivalAirport: $flightArrivalAirport,
                        departureDate: $flightDepartureDate,
                        arrivalDate: $flightArrivalDate,
                        terminal: $flightTerminal,
                        gate: $flightGate,
                        seat: $flightSeat,
                        lookupState: flightLookupState,
                        verifiedFlight: verifiedFlightLookup,
                        lookupMessage: flightLookupMessage,
                        onShowAirlinePicker: { showFlightAirlinePicker = true },
                        onUseManualEntry: {
                            flightLookupState = .manualFallback
                            flightLookupMessage = nil
                        },
                        onResetLookup: resetFlightLookup
                    )
                case .hotel:
                    HotelFormView(
                        hotelName: $hotelName,
                        address: $hotelAddress,
                        checkInDate: $hotelCheckIn,
                        checkOutDate: $hotelCheckOut,
                        roomType: $hotelRoomType
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
                case .restaurant:
                    RestaurantFormView(
                        restaurantName: $restaurantName,
                        address: $restaurantAddress,
                        reservationDate: $restaurantReservationDate,
                        partySize: $restaurantPartySize
                    )
                }

                if let saveError {
                    Section {
                        Text(saveError)
                            .font(.appFootnote)
                            .foregroundStyle(AppColors.appError)
                    }
                }

                bookingCostAndConfirmationFormSection

                if let tripId {
                    BookingDocumentsInlineSection(
                        bookingId: bookingRowId,
                        tripId: tripId,
                        bookingTitle: documentsSectionBookingTitle
                    )
                }
            }
            .scrollContentBackground(.hidden)
            .background(AppColors.appBackground)
            .tint(selectedType.color)
            .scrollDismissesKeyboard(.interactively)
        }
        .navigationTitle(isEditMode ? "Edit \(selectedType.label)" : "Add \(selectedType.label)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if showsCloseButton {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.appButton.weight(.semibold))
                    }
                    .accessibilityLabel("Close")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await save() }
                } label: {
                    if isSaving || isLookingUpFlight {
                        ProgressView()
                    } else {
                        Text(toolbarActionTitle)
                    }
                }
                .font(.appButton)
                .disabled(isSaving || isLookingUpFlight || !canPerformToolbarAction)
                .accessibilityIdentifier("addBooking.primaryAction")
                .accessibilityLabel(isEditMode ? "Save booking" : "Add \(selectedType.label)")
            }
        }
        .onAppear {
            prefillFromEditingPlace()
            if isEditMode, initialSnapshot == nil {
                initialSnapshot = currentSnapshot()
            }
        }
        .onChange(of: flightCarrierIATA) { _, _ in tryAutoFlightLookup() }
        .onChange(of: flightNumber) { _, _ in tryAutoFlightLookup() }
        .onChange(of: flightDepartureDate) { _, _ in tryAutoFlightLookup() }
        .environment(\.timeZone, displayTimeZone)
        .environment(\.calendar, tripCalendar)
        .sheet(isPresented: $showFlightAirlinePicker) {
            FlightAirlinePickerSheet(
                airline: $flightAirline,
                carrierIATA: $flightCarrierIATA
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .task(id: bookingRowId) {
            guard !isEditMode, tripId != nil else { return }
            await dataService.ensureBookingPlaceholderForAdd(bookingShellPlace())
        }
        .onDisappear {
            guard !isEditMode, tripId != nil, !didPersistBookingSuccessfully else { return }
            Task {
                await dataService.deletePlace(id: bookingRowId)
            }
        }
    }

    private var bookingCostAndConfirmationFormSection: some View {
        Section {
            HStack {
                Text(String(localized: "Amount"))
                    .foregroundStyle(AppColors.textPrimary)
                TextField(String(localized: "0.00"), text: $costAmountText)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .onChange(of: costAmountText) { _, newValue in
                        costAmountText = MoneyField.sanitize(newValue)
                    }
                Menu {
                    ForEach(MoneyField.commonCurrencies, id: \.self) { code in
                        Button(code) { costCurrency = code }
                    }
                } label: {
                    HStack(spacing: AppSpacing.xs) {
                        Text(costCurrency.uppercased())
                            .font(.appBody.weight(.semibold))
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.appCaption.weight(.semibold))
                            .foregroundStyle(AppColors.textSecondary)
                    }
                }
                .accessibilityLabel(String(localized: "Currency"))
            }

            TextField(String(localized: "Confirmation (optional)"), text: $confirmationNumber)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        } header: {
            Text(String(localized: "Booking details"))
        } footer: {
            Text(String(localized: "Cost tracks as a trip expense when amount is set."))
                .font(.appFootnote)
        }
    }

    private func tryAutoFlightLookup() {
        guard selectedType == .flight else { return }
        guard flightLookupState == .lookupInput else { return }
        guard !isLookingUpFlight else { return }
        guard canLookupFlight else { return }
        let sig = flightLookupAutoSignature()
        guard sig != flightAutoLookupSignature else { return }
        flightAutoLookupSignature = sig
        Task { await lookupFlight() }
    }

    private func flightLookupAutoSignature() -> String {
        let carrier = normalizedCarrierIATA() ?? ""
        let num = normalizedFlightNumberDisplay()
        let dep = flightDepartureDate.map { "\($0.timeIntervalSince1970)" } ?? ""
        return "\(carrier)|\(num)|\(dep)"
    }

    /// Calendar pinned to the trip's destination TZ. Surfaced so internal
    /// `Date()` initialisers inside child `DatePicker`s and any `Calendar`
    /// reads via `\.calendar` align with what the user sees on the timeline.
    private var tripCalendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = displayTimeZone
        return cal
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
            flightAirline = f.airline
            flightCarrierIATA = f.carrierIATA ?? Self.inferredCarrierIATA(from: f.airline, flightNumber: f.flightNumber) ?? ""
            flightNumber = f.flightNumber
            flightDepartureAirport = f.departureAirport
            flightArrivalAirport = f.arrivalAirport
            if let d = f.departureTime { flightDepartureDate = d }
            if let d = f.arrivalTime { flightArrivalDate = d }
            flightTerminal = f.terminal
            flightGate = f.gate
            flightSeat = f.seat
            if f.lookupVerified, let dep = f.departureTime, let arr = f.arrivalTime {
                flightLookupState = .verifiedResult
                verifiedFlightLookup = VerifiedFlightLookup(
                    carrierIATA: f.carrierIATA ?? "",
                    flightNumber: f.flightNumber,
                    departureDate: "",
                    originAirportIATA: f.departureAirport.nilIfEmpty,
                    destinationAirportIATA: f.arrivalAirport.nilIfEmpty,
                    scheduledDepartureUTC: dep,
                    scheduledArrivalUTC: arr,
                    terminalOrigin: f.terminal.nilIfEmpty,
                    terminalDestination: f.terminalDestination,
                    gateOrigin: f.gate.nilIfEmpty,
                    gateDestination: f.gateDestination,
                    baggageClaim: f.baggageClaim,
                    provider: nil
                )
            } else {
                verifiedFlightLookup = nil
                flightLookupState = .manualFallback
            }
        case .hotel(let h):
            hotelName = place.name
            hotelAddress = place.address ?? ""
            if let d = h.checkInDate { hotelCheckIn = d }
            if let d = h.checkOutDate { hotelCheckOut = d }
            hotelRoomType = h.roomType
            hotelCheckInTime = h.checkInTime ?? ""
            hotelCheckOutTime = h.checkOutTime ?? ""
        case .restaurant(let r):
            restaurantName = place.name
            restaurantAddress = r.address ?? place.address ?? ""
            if let d = r.reservationTime { restaurantReservationDate = d }
            restaurantPartySize = r.partySize ?? 2
        case .carRental(let c):
            carCompany = c.company
            carPickupLocation = c.pickupLocation
            carDropoffLocation = c.dropoffLocation
            if let d = c.pickupTime { carPickupDate = d }
            if let d = c.dropoffTime { carDropoffDate = d }
            carType = c.carType
        case .activity(let a):
            activityName = place.name
            activityProvider = a.provider
            activityDuration = a.duration ?? ""
            activityTicketNumber = a.ticketNumber
            if let d = place.startTime { activityDate = d }
        case .transport(let t):
            transportOperator = t.operatorName
            transportServiceNumber = t.serviceNumber
            transportDepartureStation = t.departureStation
            transportArrivalStation = t.arrivalStation
            if let d = t.departureTime { transportDepartureDate = d }
            if let d = t.arrivalTime { transportArrivalDate = d }
            transportSeat = t.seat
        }
    }

    @ViewBuilder
    private var bookingForm: some View {
        Group {
            switch selectedType {
            case .flight:
                FlightFormView(
                    airline: $flightAirline,
                    carrierIATA: $flightCarrierIATA,
                    flightNumber: $flightNumber,
                    departureAirport: $flightDepartureAirport,
                    arrivalAirport: $flightArrivalAirport,
                    departureDate: $flightDepartureDate,
                    arrivalDate: $flightArrivalDate,
                    terminal: $flightTerminal,
                    gate: $flightGate,
                    seat: $flightSeat,
                    lookupState: flightLookupState,
                    verifiedFlight: verifiedFlightLookup,
                    lookupMessage: flightLookupMessage,
                    onShowAirlinePicker: { showFlightAirlinePicker = true },
                    onUseManualEntry: {
                        flightLookupState = .manualFallback
                        flightLookupMessage = nil
                    },
                    onResetLookup: resetFlightLookup
                )
            case .hotel:
                HotelFormView(
                    hotelName: $hotelName,
                    address: $hotelAddress,
                    checkInDate: $hotelCheckIn,
                    checkOutDate: $hotelCheckOut,
                    roomType: $hotelRoomType
                )
            case .restaurant:
                RestaurantFormView(
                    restaurantName: $restaurantName,
                    address: $restaurantAddress,
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

    private var canSave: Bool {
        switch selectedType {
        case .flight:
            switch flightLookupState {
            case .verifiedResult:
                return verifiedFlightLookup != nil
            case .manualFallback:
                return !flightAirline.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && !flightNumber.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && !flightDepartureAirport.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && !flightArrivalAirport.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .lookupInput, .lookingUp:
                return false
            }
        case .hotel:
            return !hotelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .restaurant:
            return !restaurantName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .carRental:
            return !carCompany.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .activity:
            return !activityName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .transport:
            return !transportOperator.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private var canPerformToolbarAction: Bool {
        guard canSave else { return false }
        if isEditMode {
            return hasChanges
        }
        return true
    }

    /// In edit mode we only want Save to light up after the user mutates
    /// something. Compare the live form to the snapshot captured right
    /// after prefill — any difference (text, dates, lookup state, cost)
    /// counts as a change.
    private var hasChanges: Bool {
        guard let initialSnapshot else { return true }
        return initialSnapshot != currentSnapshot()
    }

    private func currentSnapshot() -> BookingFormSnapshot {
        BookingFormSnapshot(
            selectedType: selectedType,
            confirmationNumber: confirmationNumber,
            costAmountText: costAmountText,
            costCurrency: costCurrency,
            flightAirline: flightAirline,
            flightCarrierIATA: flightCarrierIATA,
            flightNumber: flightNumber,
            flightDepartureAirport: flightDepartureAirport,
            flightArrivalAirport: flightArrivalAirport,
            flightDepartureDate: flightDepartureDate,
            flightArrivalDate: flightArrivalDate,
            flightTerminal: flightTerminal,
            flightGate: flightGate,
            flightSeat: flightSeat,
            flightLookupState: flightLookupState,
            verifiedFlightLookup: verifiedFlightLookup,
            hotelName: hotelName,
            hotelAddress: hotelAddress,
            hotelCheckIn: hotelCheckIn,
            hotelCheckOut: hotelCheckOut,
            hotelRoomType: hotelRoomType,
            hotelCheckInTime: hotelCheckInTime,
            hotelCheckOutTime: hotelCheckOutTime,
            restaurantName: restaurantName,
            restaurantAddress: restaurantAddress,
            restaurantReservationDate: restaurantReservationDate,
            restaurantPartySize: restaurantPartySize,
            carCompany: carCompany,
            carPickupLocation: carPickupLocation,
            carDropoffLocation: carDropoffLocation,
            carPickupDate: carPickupDate,
            carDropoffDate: carDropoffDate,
            carType: carType,
            activityName: activityName,
            activityLocation: activityLocation,
            activityDate: activityDate,
            activityDuration: activityDuration,
            activityProvider: activityProvider,
            activityTicketNumber: activityTicketNumber,
            transportOperator: transportOperator,
            transportServiceNumber: transportServiceNumber,
            transportDepartureStation: transportDepartureStation,
            transportArrivalStation: transportArrivalStation,
            transportDepartureDate: transportDepartureDate,
            transportArrivalDate: transportArrivalDate,
            transportSeat: transportSeat
        )
    }

    private var toolbarActionTitle: String {
        isEditMode ? "Save" : "Add"
    }

    private var canLookupFlight: Bool {
        normalizedCarrierIATA() != nil
            && !normalizedFlightNumberDisplay().isEmpty
            && flightDepartureDate != nil
            && flightLookupState != .lookingUp
    }

    private func lookupFlight() async {
        guard let carrier = normalizedCarrierIATA(), let departureDate = flightDepartureDate, canLookupFlight else {
            flightLookupMessage = "Choose an airline, flight number, and departure date first."
            return
        }
        isLookingUpFlight = true
        flightLookupState = .lookingUp
        flightLookupMessage = nil

        let result = await FlightLookupService.shared.lookup(FlightLookupRequest(
            carrierIATA: carrier,
            flightNumber: normalizedFlightNumberDisplay(),
            departureDate: departureDate
        ))

        isLookingUpFlight = false
        switch result {
        case .found(let verified):
            applyVerifiedFlight(verified)
            flightLookupState = .verifiedResult
            flightLookupMessage = nil
            HapticManager.success()
        case .notFound:
            verifiedFlightLookup = nil
            flightLookupState = .manualFallback
            flightLookupMessage = String(localized: "Flight not found. Please enter details manually.")
            HapticManager.warning()
        case .failed:
            verifiedFlightLookup = nil
            flightLookupState = .manualFallback
            flightLookupMessage = String(localized: "Could not check right now. Enter details manually — live tracking will not start until verified.")
            HapticManager.warning()
        }
    }

    private func applyVerifiedFlight(_ verified: VerifiedFlightLookup) {
        verifiedFlightLookup = verified
        flightCarrierIATA = verified.carrierIATA
        flightNumber = verified.flightNumber
        flightDepartureAirport = verified.originAirportIATA ?? ""
        flightArrivalAirport = verified.destinationAirportIATA ?? ""
        flightDepartureDate = verified.scheduledDepartureUTC
        flightArrivalDate = verified.scheduledArrivalUTC
        flightTerminal = verified.terminalOrigin ?? ""
        flightGate = verified.gateOrigin ?? ""
    }

    private func resetFlightLookup() {
        verifiedFlightLookup = nil
        flightLookupMessage = nil
        flightLookupState = .lookupInput
        flightAutoLookupSignature = nil
    }

    private func save() async {
        guard !isSaving else { return }
        guard canSave else {
            saveError = "Add the required booking details before saving."
            return
        }
        let place = makePlace()
        let cost = parsedCost()
        isSaving = true
        saveError = nil
        let didSave = await onSave?(place, cost) ?? true
        isSaving = false
        if didSave {
            didPersistBookingSuccessfully = true
            HapticManager.success()
            dismiss()
        } else {
            HapticManager.warning()
            saveError = "Could not save booking. Please try again."
        }
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
        let placeId = bookingRowId

        switch selectedType {
        case .flight:
            let arrivalForSave: Date? = flightArrivalForSave()
            let verified = verifiedFlightLookup
            let isVerified = flightLookupState == .verifiedResult && verified != nil
            let details = FlightDetails(
                airline: flightAirline,
                carrierIATA: verified?.carrierIATA ?? normalizedCarrierIATA(),
                flightNumber: verified?.flightNumber ?? flightNumber,
                departureAirport: verified?.originAirportIATA ?? flightDepartureAirport,
                arrivalAirport: verified?.destinationAirportIATA ?? flightArrivalAirport,
                departureTime: verified?.scheduledDepartureUTC ?? flightDepartureDate,
                arrivalTime: arrivalForSave,
                terminal: flightTerminal,
                gate: flightGate,
                seat: flightSeat,
                lookupVerified: isVerified,
                lookupStatus: isVerified ? "verified" : "manual",
                terminalDestination: verified?.terminalDestination,
                gateDestination: verified?.gateDestination,
                baggageClaim: verified?.baggageClaim
            )
            return Place(
                id: placeId,
                itineraryDayId: targetDayId,
                name: flightDisplayName(),
                address: (verified?.originAirportIATA ?? flightDepartureAirport).trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                lat: nil,
                lng: nil,
                category: "transport",
                notes: nil,
                sortOrder: 0,
                startTime: verified?.scheduledDepartureUTC ?? flightDepartureDate,
                endTime: arrivalForSave,
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
                address: hotelAddress.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                lat: nil,
                lng: nil,
                category: "hotel",
                notes: nil,
                sortOrder: 0,
                startTime: hotelCheckIn,
                endTime: hotelCheckOut,
                isBooking: true,
                bookingType: BookingCategory.hotel.rawValue,
                confirmationNumber: confirmation,
                bookingDetails: .hotel(details)
            )
        case .restaurant:
            let trimmedStreet = restaurantAddress.trimmingCharacters(in: .whitespacesAndNewlines)
            let details = RestaurantDetails(
                reservationTime: restaurantReservationDate,
                partySize: restaurantPartySize,
                address: trimmedStreet.nilIfEmpty
            )
            return Place(
                id: placeId,
                itineraryDayId: targetDayId,
                name: restaurantName.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "Restaurant",
                address: trimmedStreet.nilIfEmpty,
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
        let route = "\(normalizedCarrierIATA() ?? flightAirline) \(normalizedFlightNumberDisplay())"
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

    private func normalizedCarrierIATA() -> String? {
        let picked = flightCarrierIATA.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if picked.count >= 2 && picked.count <= 3 { return picked }
        return Self.inferredCarrierIATA(from: flightAirline, flightNumber: flightNumber)
    }

    private func flightArrivalForSave() -> Date? {
        if let verifiedFlightLookup {
            return verifiedFlightLookup.scheduledArrivalUTC
        }
        if flightLookupState == .manualFallback {
            return flightArrivalDate
        }
        guard let dep = flightDepartureDate else { return nil }
        return tripCalendar.date(byAdding: .hour, value: 2, to: dep) ?? dep
    }

    private func normalizedFlightNumberDisplay() -> String {
        var raw = flightNumber.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if let carrier = normalizedCarrierIATA(), raw.hasPrefix(carrier) {
            raw.removeFirst(carrier.count)
            raw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return raw
    }

    private static func inferredCarrierIATA(from airline: String, flightNumber: String) -> String? {
        if let code = FlightAirlineCatalog.airline(matchingName: airline)?.iataCode {
            return code
        }
        let normalizedFlight = flightNumber
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
            .replacingOccurrences(of: " ", with: "")
        let prefix = normalizedFlight.prefix { $0.isLetter }
        guard prefix.count >= 2 && prefix.count <= 3 else { return nil }
        return String(prefix)
    }

    private func transportDisplayName() -> String {
        let combined = "\(transportOperator) \(transportServiceNumber)"
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !combined.isEmpty {
            return combined
        }
        return "Transport"
    }

    private func hotelNights(from checkIn: Date?, to checkOut: Date?) -> Int? {
        guard let checkIn, let checkOut else { return nil }
        let start = tripCalendar.startOfDay(for: checkIn)
        let end = tripCalendar.startOfDay(for: checkOut)
        return tripCalendar.dateComponents([.day], from: start, to: end).day
    }

    private var documentsSectionBookingTitle: String {
        if let ep = editingPlace { return ep.name }
        switch selectedType {
        case .flight:
            let airline = flightAirline.trimmingCharacters(in: .whitespacesAndNewlines)
            let number = flightNumber.trimmingCharacters(in: .whitespacesAndNewlines)
            if airline.isEmpty && number.isEmpty { return String(localized: "New booking") }
            return flightDisplayName()
        case .hotel:
            let n = hotelName.trimmingCharacters(in: .whitespacesAndNewlines)
            return n.isEmpty ? String(localized: "New booking") : n
        case .restaurant:
            let n = restaurantName.trimmingCharacters(in: .whitespacesAndNewlines)
            return n.isEmpty ? String(localized: "New booking") : n
        case .carRental:
            let n = carCompany.trimmingCharacters(in: .whitespacesAndNewlines)
            return n.isEmpty ? String(localized: "New booking") : n
        case .activity:
            let n = activityName.trimmingCharacters(in: .whitespacesAndNewlines)
            return n.isEmpty ? String(localized: "New booking") : n
        case .transport:
            let op = transportOperator.trimmingCharacters(in: .whitespacesAndNewlines)
            let svc = transportServiceNumber.trimmingCharacters(in: .whitespacesAndNewlines)
            if op.isEmpty && svc.isEmpty { return String(localized: "New booking") }
            return transportDisplayName()
        }
    }

    /// Minimal `Place` used only to insert the placeholder `trip_bookings` row for add-mode attachments.
    private func bookingShellPlace() -> Place {
        Place(
            id: bookingRowId,
            itineraryDayId: targetDayId,
            name: String(localized: "New booking"),
            address: nil,
            lat: nil,
            lng: nil,
            category: shellCategoryForSelectedBookingType(),
            notes: nil,
            sortOrder: 0,
            startTime: nil,
            endTime: nil,
            isBooking: true,
            bookingType: selectedType.rawValue,
            confirmationNumber: nil,
            bookingDetails: nil,
            googlePlaceId: nil,
            bookingAmount: nil,
            bookingCurrencyCode: nil,
            heroImageUrl: nil,
            rating: nil,
            userRatingsTotal: nil,
            priceLevel: nil,
            website: nil,
            phoneNumber: nil,
            isOpenNow: nil,
            openingHoursText: nil,
            aiSummary: nil,
            aiShortSummary: nil,
            whyGo: nil,
            knowBeforeYouGo: nil,
            reviewsTags: nil,
            durationMinutes: nil,
            subtypes: nil,
            travelFromPreviousMinutes: nil,
            travelMode: nil,
            thumbnailUrl: nil
        )
    }

    private func shellCategoryForSelectedBookingType() -> String? {
        switch selectedType {
        case .flight, .carRental, .transport:
            return "transport"
        case .hotel:
            return "hotel"
        case .restaurant:
            return "restaurant"
        case .activity:
            return "attraction"
        }
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

private struct BookingSaveErrorBanner: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.appSmall.weight(.semibold))
            .foregroundStyle(AppColors.appError)
            .padding(AppSpacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppColors.appError.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous))
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

/// Snapshot of every editable field surfaced by `AddBookingView`. Captured
/// once after prefill so we can answer "did the user change anything?" with
/// a single Equatable comparison instead of dozens of bespoke checks.
private struct BookingFormSnapshot: Equatable {
    let selectedType: BookingCategory
    let confirmationNumber: String
    let costAmountText: String
    let costCurrency: String

    let flightAirline: String
    let flightCarrierIATA: String
    let flightNumber: String
    let flightDepartureAirport: String
    let flightArrivalAirport: String
    let flightDepartureDate: Date?
    let flightArrivalDate: Date?
    let flightTerminal: String
    let flightGate: String
    let flightSeat: String
    let flightLookupState: FlightLookupFormState
    let verifiedFlightLookup: VerifiedFlightLookup?

    let hotelName: String
    let hotelAddress: String
    let hotelCheckIn: Date?
    let hotelCheckOut: Date?
    let hotelRoomType: String
    let hotelCheckInTime: String
    let hotelCheckOutTime: String

    let restaurantName: String
    let restaurantAddress: String
    let restaurantReservationDate: Date?
    let restaurantPartySize: Int

    let carCompany: String
    let carPickupLocation: String
    let carDropoffLocation: String
    let carPickupDate: Date?
    let carDropoffDate: Date?
    let carType: String

    let activityName: String
    let activityLocation: String
    let activityDate: Date?
    let activityDuration: String
    let activityProvider: String
    let activityTicketNumber: String

    let transportOperator: String
    let transportServiceNumber: String
    let transportDepartureStation: String
    let transportArrivalStation: String
    let transportDepartureDate: Date?
    let transportArrivalDate: Date?
    let transportSeat: String
}

// =============================================================================

