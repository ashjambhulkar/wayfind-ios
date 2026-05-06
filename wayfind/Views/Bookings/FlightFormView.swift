import SwiftUI

enum FlightLookupFormState: Hashable {
    case lookupInput
    case lookingUp
    case verifiedResult
    case manualFallback
}

/// Flight booking fields using native **grouped form** sections (Calendar / Reminders style).
/// Flow: airline → flight number → departure date; parent triggers lookup when all are set.
struct FlightFormView: View {
    @Binding var airline: String
    @Binding var carrierIATA: String
    @Binding var flightNumber: String
    @Binding var departureAirport: String
    @Binding var arrivalAirport: String
    @Binding var departureDate: Date?
    @Binding var arrivalDate: Date?
    @Binding var terminal: String
    @Binding var gate: String
    @Binding var seat: String
    let lookupState: FlightLookupFormState
    let verifiedFlight: VerifiedFlightLookup?
    let lookupMessage: String?
    let onShowAirlinePicker: () -> Void
    let onUseManualEntry: () -> Void
    let onResetLookup: () -> Void

    @Environment(\.calendar) private var calendar
    @Environment(\.timeZone) private var timeZone

    private var accent: Color { BookingCategory.flight.color }

    private var hasCarrier: Bool {
        let iata = carrierIATA.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return iata.count >= 2 && iata.count <= 3
    }

    private var hasFlightNumber: Bool {
        !normalizedFlightNumber().isEmpty
    }

    private var airlineSummary: String {
        let trimmedName = airline.trimmingCharacters(in: .whitespacesAndNewlines)
        let iata = carrierIATA.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if !iata.isEmpty, !trimmedName.isEmpty {
            return "\(iata) · \(trimmedName)"
        }
        if !trimmedName.isEmpty { return trimmedName }
        if !iata.isEmpty { return iata }
        return String(localized: "Not set")
    }

    var body: some View {
        switch lookupState {
        case .lookupInput, .lookingUp:
            lookupFlowSections
        case .verifiedResult:
            if let verifiedFlight {
                verifiedSections(verifiedFlight)
            }
        case .manualFallback:
            manualFallbackSections
        }
    }

    // MARK: - Lookup flow (grouped)

    @ViewBuilder
    private var lookupFlowSections: some View {
        let isLooking = lookupState == .lookingUp

        Section {
            // Row 1: Airline — always enabled
            Button {
                onShowAirlinePicker()
            } label: {
                LabeledContent(String(localized: "Airline")) {
                    Text(airlineSummary)
                        .foregroundStyle(hasCarrier ? AppColors.textPrimary : AppColors.textSecondary)
                }
            }
            .foregroundStyle(AppColors.textPrimary)
            .disabled(isLooking)

            // Row 2: Flight number — disabled until airline chosen
            LabeledContent(String(localized: "Flight number")) {
                TextField(String(localized: "e.g. 101"), text: $flightNumber)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
            }
            .disabled(!hasCarrier || isLooking)

            // Row 3: Departure date — disabled until both airline + flight number set
            DatePicker(
                String(localized: "Departure date"),
                selection: Binding(
                    get: { departureDate ?? defaultDepartureAnchor() },
                    set: { departureDate = $0 }
                ),
                displayedComponents: [.date]
            )
            .disabled(!hasCarrier || !hasFlightNumber || isLooking)
        } footer: {
            if !hasCarrier {
                Text(String(localized: "Choose your airline to continue."))
                    .font(.appFootnote)
                    .foregroundStyle(AppColors.textSecondary)
            } else if !hasFlightNumber {
                Text(String(localized: "Enter a flight number to continue."))
                    .font(.appFootnote)
                    .foregroundStyle(AppColors.textSecondary)
            } else if departureDate == nil {
                Text(String(localized: "Pick a departure date and we'll look up your flight."))
                    .font(.appFootnote)
                    .foregroundStyle(AppColors.textSecondary)
            } else {
                Text(String(localized: "We'll look up your flight automatically."))
                    .font(.appFootnote)
                    .foregroundStyle(AppColors.textSecondary)
            }
        }

        if isLooking {
            Section {
                HStack(spacing: AppSpacing.md) {
                    ProgressView()
                        .tint(accent)
                    VStack(alignment: .leading, spacing: AppSpacing.xs) {
                        Text(String(localized: "Looking up flight…"))
                            .font(.appBody.weight(.semibold))
                            .foregroundStyle(AppColors.textPrimary)
                        Text(String(localized: "Matching airline, flight number, and departure date."))
                            .font(.appFootnote)
                            .foregroundStyle(AppColors.textSecondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, AppSpacing.xs)
            }
        }

        if lookupState == .lookupInput {
            Section {
                Button(String(localized: "Enter flight manually"), role: .none, action: onUseManualEntry)
                    .foregroundStyle(AppColors.appPrimary)
            } footer: {
                Text(String(localized: "Skip lookup and type airports and times yourself."))
                    .font(.appFootnote)
                    .foregroundStyle(AppColors.textSecondary)
            }
        }
    }

    // MARK: - Verified

    @ViewBuilder
    private func verifiedSections(_ flight: VerifiedFlightLookup) -> some View {
        Section {
            HStack {
                Text(String(localized: "Flight found"))
                    .font(.appBody.weight(.semibold))
                Spacer(minLength: AppSpacing.sm)
                Button(String(localized: "Change"), action: onResetLookup)
                    .font(.appFootnote.weight(.semibold))
                    .foregroundStyle(AppColors.appPrimary)
            }
            LabeledContent(String(localized: "Flight"), value: verifiedTitle(flight))
            LabeledContent(
                String(localized: "Route"),
                value: "\(flight.originAirportIATA ?? "—") → \(flight.destinationAirportIATA ?? "—")"
            )
            LabeledContent(
                String(localized: "Departure"),
                value: "\(flight.scheduledDepartureUTC.shortFormatted(timeZone: timeZone)) · \(flight.scheduledDepartureUTC.timeFormatted(timeZone: timeZone))"
            )
            LabeledContent(
                String(localized: "Arrival"),
                value: "\(flight.scheduledArrivalUTC.shortFormatted(timeZone: timeZone)) · \(flight.scheduledArrivalUTC.timeFormatted(timeZone: timeZone))"
            )
        } footer: {
            Text(String(localized: "Provider verified — you can add optional terminal, gate, and seat below."))
                .font(.appFootnote)
                .foregroundStyle(AppColors.textSecondary)
        }

        optionalFlightDetailsSection
    }

    // MARK: - Manual fallback

    private var manualFallbackSections: some View {
        Group {
            Section {
                HStack(alignment: .top, spacing: AppSpacing.md) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(AppColors.appWarning)
                        .font(.title3)
                        .accessibilityHidden(true)
                    Text(lookupMessage ?? String(localized: "Flight not found. Enter details manually."))
                        .font(.appFootnote)
                        .foregroundStyle(AppColors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, AppSpacing.xs)
            }

            Section(String(localized: "Flight")) {
                LabeledContent(String(localized: "From")) {
                    TextField(String(localized: "Airport code, e.g. JFK"), text: $departureAirport)
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.characters)
                }
                LabeledContent(String(localized: "To")) {
                    TextField(String(localized: "Airport code, e.g. LAX"), text: $arrivalAirport)
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.characters)
                }
            }

            Section(String(localized: "Schedule")) {
                DatePicker(
                    String(localized: "Departure"),
                    selection: Binding(
                        get: { departureDate ?? defaultDepartureAnchor() },
                        set: { departureDate = $0 }
                    ),
                    displayedComponents: [.date, .hourAndMinute]
                )
                DatePicker(
                    String(localized: "Arrival"),
                    selection: Binding(
                        get: { arrivalDate ?? departureDate ?? defaultDepartureAnchor() },
                        set: { arrivalDate = $0 }
                    ),
                    displayedComponents: [.date, .hourAndMinute]
                )
            }

            optionalFlightDetailsSection
        }
    }

    // MARK: - Optional terminal / gate / seat

    private var optionalFlightDetailsSection: some View {
        Section {
            LabeledContent(String(localized: "Terminal")) {
                TextField(String(localized: "e.g. A"), text: $terminal)
                    .multilineTextAlignment(.trailing)
            }
            LabeledContent(String(localized: "Gate")) {
                TextField(String(localized: "e.g. 12B"), text: $gate)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.characters)
            }
            LabeledContent(String(localized: "Seat")) {
                TextField(String(localized: "e.g. 14C"), text: $seat)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.characters)
            }
        } header: {
            Text(String(localized: "Optional details"))
        } footer: {
            Text(String(localized: "Terminal, gate, and seat are optional."))
                .font(.appFootnote)
                .foregroundStyle(AppColors.textSecondary)
        }
    }

    // MARK: - Helpers

    private func normalizedFlightNumber() -> String {
        var raw = flightNumber.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let carrier = carrierIATA.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if !carrier.isEmpty, raw.hasPrefix(carrier) {
            raw.removeFirst(carrier.count)
            raw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return raw
    }

    private func defaultDepartureAnchor() -> Date {
        let anchor = Date()
        return calendar.date(bySettingHour: 12, minute: 0, second: 0, of: anchor)
            ?? calendar.startOfDay(for: anchor)
    }

    private func verifiedTitle(_ flight: VerifiedFlightLookup) -> String {
        let name = airline.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = name.isEmpty ? flight.carrierIATA : name
        return "\(prefix) \(flight.flightNumber)".trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Airline picker sheet (searchable list)

struct FlightAirlinePickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var airline: String
    @Binding var carrierIATA: String
    @State private var query = ""

    private var results: [FlightAirline] {
        FlightAirlineCatalog.search(query.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(results) { item in
                    Button {
                        airline = item.name
                        carrierIATA = item.iataCode
                        dismiss()
                    } label: {
                        HStack(spacing: AppSpacing.md) {
                            Text(item.iataCode)
                                .font(.appCaption.weight(.semibold))
                                .foregroundStyle(.white)
                                .frame(width: 40, alignment: .center)
                                .padding(.vertical, AppSpacing.xs)
                                .background(BookingCategory.flight.color)
                                .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.small, style: .continuous))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.name)
                                    .font(.appBody)
                                    .foregroundStyle(AppColors.textPrimary)
                                Text(String(localized: "IATA code for live tracking"))
                                    .font(.appFootnote)
                                    .foregroundStyle(AppColors.textTertiary)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(String(localized: "Airline"))
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: String(localized: "Search airlines"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel")) { dismiss() }
                }
            }
        }
    }
}
