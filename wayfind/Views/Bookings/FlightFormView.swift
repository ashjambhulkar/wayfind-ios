import SwiftUI

enum FlightLookupFormState: Hashable {
    case lookupInput
    case lookingUp
    case verifiedResult
    case manualFallback
}

struct FlightFormView: View {
    @Binding var airline: String
    @Binding var carrierIATA: String
    @Binding var flightNumber: String
    @Binding var departureAirport: String
    @Binding var arrivalAirport: String
    @Binding var departureDate: Date
    @Binding var arrivalDate: Date
    @Binding var terminal: String
    @Binding var gate: String
    @Binding var seat: String
    let lookupState: FlightLookupFormState
    let verifiedFlight: VerifiedFlightLookup?
    let lookupMessage: String?
    let onUseManualEntry: () -> Void
    let onResetLookup: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.lg) {
            switch lookupState {
            case .lookupInput:
                lookupInputSection
                FlightMapSectionCard(title: "Live Tracking") {
                    FlightTrackingInfoRow()
                }
            case .lookingUp:
                lookupInputSection
                FlightMapSectionCard(title: "Finding Flight") {
                    FlightProgressRow()
                }
            case .verifiedResult:
                if let verifiedFlight {
                    FlightVerifiedResultCard(airline: airline, flight: verifiedFlight, onChange: onResetLookup)
                }
            case .manualFallback:
                lookupInputSection
                FlightManualFallbackSection(
                    message: lookupMessage,
                    departureAirport: $departureAirport,
                    arrivalAirport: $arrivalAirport,
                    departureDate: $departureDate,
                    arrivalDate: $arrivalDate
                )
            }
        }
    }

    private var lookupInputSection: some View {
        FlightMapSectionCard(title: "Find Your Flight") {
            FlightAirlinePickerRow(
                airline: $airline,
                carrierIATA: $carrierIATA
            )

            FlightMapDivider()

            FlightMapTextRow(
                icon: "number",
                title: "Flight Number",
                placeholder: "1234",
                capitalization: .characters,
                text: $flightNumber
            )

            FlightMapDivider()

            FlightMapDateRow(
                icon: "calendar",
                title: "Departure Date",
                displayedComponents: [.date],
                selection: $departureDate
            )

            if lookupState == .lookupInput {
                FlightMapDivider()
                FlightManualEntryButton(onTap: onUseManualEntry)
            }
        }
    }
}

struct FlightOptionalDetailsSection: View {
    @Binding var terminal: String
    @Binding var gate: String
    @Binding var seat: String

    var body: some View {
        DisclosureGroup {
            FlightMapSectionCard(title: nil) {
                FlightMapTextRow(
                    icon: "building.2.fill",
                    title: "Terminal",
                    placeholder: "Terminal",
                    text: $terminal
                )

                FlightMapDivider()

                FlightMapTextRow(
                    icon: "door.left.hand.open",
                    title: "Gate",
                    placeholder: "Gate",
                    capitalization: .characters,
                    text: $gate
                )

                FlightMapDivider()

                FlightMapTextRow(
                    icon: "rectangle.inset.filled.and.person.filled",
                    title: "Seat",
                    placeholder: "12A",
                    capitalization: .characters,
                    text: $seat
                )
            }
            .padding(.top, AppSpacing.md)
        } label: {
            HStack(spacing: AppSpacing.sm) {
                MapStyleIcon(
                    systemName: "ellipsis.circle.fill",
                    size: .small,
                    accent: BookingCategory.flight.color,
                    accessibilityLabel: "Optional flight details"
                )

                Text("Optional Details")
                    .font(.appBody.weight(.semibold))
                    .foregroundStyle(AppColors.textPrimary)
            }
        }
        .tint(AppColors.appPrimary)
    }
}

// =============================================================================

private struct FlightMapSectionCard<Content: View>: View {
    let title: String?
    let content: Content

    init(title: String?, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            if let title {
                FormSectionTitle(title)
            }

            VStack(spacing: 0) {
                content
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

private struct FlightMapTextRow: View {
    let icon: String
    let title: String
    let placeholder: String
    var capitalization: TextInputAutocapitalization = .sentences
    @Binding var text: String

    var body: some View {
        HStack(spacing: AppSpacing.md) {
            MapStyleIcon(
                systemName: icon,
                size: .small,
                accent: BookingCategory.flight.color,
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
                .textInputAutocapitalization(capitalization)
                .autocorrectionDisabled()
                .frame(minWidth: FlightMapFormMetrics.trailingFieldMinWidth)
        }
        .padding(.horizontal, AppSpacing.md)
        .frame(minHeight: FlightMapFormMetrics.rowMinHeight)
        .contentShape(Rectangle())
    }
}

private struct FlightAirlinePickerRow: View {
    @Binding var airline: String
    @Binding var carrierIATA: String
    @State private var query = ""
    @State private var isSearching = false

    private var selectedAirline: FlightAirline? {
        FlightAirlineCatalog.airline(matchingCode: carrierIATA)
            ?? FlightAirlineCatalog.airline(matchingName: airline)
    }

    private var suggestions: [FlightAirline] {
        FlightAirlineCatalog.search(query.isEmpty ? airline : query)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: AppSpacing.md) {
                MapStyleIcon(
                    systemName: "airplane.circle.fill",
                    size: .small,
                    accent: BookingCategory.flight.color,
                    accessibilityLabel: "Airline"
                )

                VStack(alignment: .leading, spacing: AppSpacing.xs) {
                    Text("Airline")
                        .font(.appBody)
                        .foregroundStyle(AppColors.textPrimary)
                    Text(selectedAirline.map { "\($0.iataCode) · \($0.name)" } ?? "Pick from airline results")
                        .font(.appSmall)
                        .foregroundStyle(AppColors.textTertiary)
                        .lineLimit(1)
                }

                Spacer(minLength: AppSpacing.md)

                TextField("Search", text: $query)
                    .font(.appBody)
                    .foregroundStyle(AppColors.textPrimary)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .frame(minWidth: FlightMapFormMetrics.trailingFieldMinWidth)
                    .onChange(of: query) { _, newValue in
                        isSearching = !newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    }
            }
            .padding(.horizontal, AppSpacing.md)
            .frame(minHeight: FlightMapFormMetrics.rowMinHeight)
            .contentShape(Rectangle())

            if isSearching {
                FlightMapDivider()

                VStack(spacing: 0) {
                    ForEach(suggestions.prefix(6)) { airlineOption in
                        Button {
                            airline = airlineOption.name
                            carrierIATA = airlineOption.iataCode
                            query = airlineOption.name
                            isSearching = false
                        } label: {
                            HStack(spacing: AppSpacing.md) {
                                Text(airlineOption.iataCode)
                                    .font(.appCaption.weight(.semibold))
                                    .foregroundStyle(.white)
                                    .frame(width: FlightMapFormMetrics.airlineCodeBadgeWidth)
                                    .padding(.vertical, AppSpacing.xs)
                                    .background(BookingCategory.flight.color)
                                    .clipShape(Capsule())

                                VStack(alignment: .leading, spacing: AppSpacing.xs) {
                                    Text(airlineOption.name)
                                        .font(.appBody)
                                        .foregroundStyle(AppColors.textPrimary)
                                    Text("Use \(airlineOption.iataCode) for live tracking")
                                        .font(.appSmall)
                                        .foregroundStyle(AppColors.textTertiary)
                                }

                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, AppSpacing.md)
                            .frame(minHeight: FlightMapFormMetrics.rowMinHeight)
                        }
                        .buttonStyle(.plain)

                        if airlineOption.id != suggestions.prefix(6).last?.id {
                            FlightMapDivider()
                        }
                    }
                }
            }
        }
        .onAppear {
            if query.isEmpty {
                query = airline
            }
        }
    }
}

private struct FlightMapDateRow: View {
    let icon: String
    let title: String
    var displayedComponents: DatePickerComponents = [.date, .hourAndMinute]
    @Binding var selection: Date

    var body: some View {
        HStack(spacing: AppSpacing.md) {
            MapStyleIcon(
                systemName: icon,
                size: .small,
                accent: BookingCategory.flight.color,
                accessibilityLabel: title
            )

            DatePicker(title, selection: $selection, displayedComponents: displayedComponents)
                .font(.appBody)
                .datePickerStyle(.compact)
                .tint(AppColors.appPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, AppSpacing.md)
        .frame(minHeight: FlightMapFormMetrics.rowMinHeight)
        .contentShape(Rectangle())
    }
}

private struct FlightProgressRow: View {
    var body: some View {
        HStack(spacing: AppSpacing.md) {
            ProgressView()
                .tint(AppColors.appPrimary)

            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                Text("Checking provider")
                    .font(.appBody.weight(.semibold))
                    .foregroundStyle(AppColors.textPrimary)
                Text("We are matching the airline, flight number, and departure date.")
                    .font(.appSmall)
                    .foregroundStyle(AppColors.textSecondary)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, AppSpacing.md)
        .frame(minHeight: FlightMapFormMetrics.infoRowMinHeight)
    }
}

private struct FlightVerifiedResultCard: View {
    let airline: String
    let flight: VerifiedFlightLookup
    let onChange: () -> Void

    var body: some View {
        FlightMapSectionCard(title: "Review Flight") {
            VStack(alignment: .leading, spacing: AppSpacing.md) {
                HStack(spacing: AppSpacing.md) {
                    MapStyleIcon(
                        systemName: "checkmark.seal.fill",
                        size: .small,
                        accent: BookingCategory.flight.color,
                        accessibilityLabel: "Verified flight"
                    )

                    VStack(alignment: .leading, spacing: AppSpacing.xs) {
                        Text(displayTitle)
                            .font(.cardTitle)
                            .foregroundStyle(AppColors.textPrimary)
                        Text("Provider verified")
                            .font(.appSmall)
                            .foregroundStyle(AppColors.appSuccess)
                    }

                    Spacer(minLength: 0)

                    Button("Change", action: onChange)
                        .font(.appCaption.weight(.semibold))
                        .foregroundStyle(AppColors.appPrimary)
                }

                FlightResultRouteRow(
                    origin: flight.originAirportIATA ?? "Origin",
                    destination: flight.destinationAirportIATA ?? "Destination"
                )

                FlightResultTimeRow(title: "Departure", date: flight.scheduledDepartureUTC)
                FlightResultTimeRow(title: "Arrival", date: flight.scheduledArrivalUTC)

                if let terminal = flight.terminalOrigin, !terminal.isEmpty {
                    FlightResultTextPill(title: "Terminal", value: terminal)
                }
                if let gate = flight.gateOrigin, !gate.isEmpty {
                    FlightResultTextPill(title: "Gate", value: gate)
                }

                Text("Live tracking will start automatically for premium access.")
                    .font(.appSmall)
                    .foregroundStyle(AppColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(AppSpacing.md)
        }
    }

    private var displayTitle: String {
        let name = airline.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = name.isEmpty ? flight.carrierIATA : name
        return "\(prefix) \(flight.flightNumber)"
    }
}

private struct FlightManualFallbackSection: View {
    let message: String?
    @Binding var departureAirport: String
    @Binding var arrivalAirport: String
    @Binding var departureDate: Date
    @Binding var arrivalDate: Date

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.lg) {
            FlightMapSectionCard(title: "Manual Flight") {
                FlightManualInfoRow(message: message)

                FlightMapDivider()

                FlightMapTextRow(
                    icon: "airplane.departure",
                    title: "From",
                    placeholder: "JFK",
                    capitalization: .characters,
                    text: $departureAirport
                )

                FlightMapDivider()

                FlightMapTextRow(
                    icon: "airplane.arrival",
                    title: "To",
                    placeholder: "LHR",
                    capitalization: .characters,
                    text: $arrivalAirport
                )

                FlightMapDivider()

                FlightMapDateRow(
                    icon: "clock.fill",
                    title: "Departure",
                    selection: $departureDate
                )

                FlightMapDivider()

                FlightMapDateRow(
                    icon: "clock.badge.checkmark.fill",
                    title: "Arrival",
                    selection: $arrivalDate
                )
            }
        }
    }
}

private struct FlightManualInfoRow: View {
    let message: String?

    var body: some View {
        HStack(alignment: .top, spacing: AppSpacing.md) {
            MapStyleIcon(
                systemName: "exclamationmark.triangle.fill",
                size: .small,
                accent: AppColors.appWarning,
                accessibilityLabel: "Manual flight"
            )
            Text(message ?? "Manual flights save to your trip, but live tracking will not start until a provider verifies the flight.")
                .font(.appSmall)
                .foregroundStyle(AppColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, AppSpacing.md)
        .padding(.vertical, AppSpacing.sm)
        .frame(minHeight: FlightMapFormMetrics.infoRowMinHeight)
    }
}

private struct FlightManualEntryButton: View {
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: AppSpacing.md) {
                MapStyleIcon(
                    systemName: "square.and.pencil",
                    size: .small,
                    accent: AppColors.textTertiary,
                    accessibilityLabel: "Manual entry"
                )
                VStack(alignment: .leading, spacing: AppSpacing.xs) {
                    Text("Enter manually")
                        .font(.appBody)
                        .foregroundStyle(AppColors.textPrimary)
                    Text("Save without live tracking")
                        .font(.appSmall)
                        .foregroundStyle(AppColors.textTertiary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.appCaption.weight(.semibold))
                    .foregroundStyle(AppColors.textTertiary)
            }
            .padding(.horizontal, AppSpacing.md)
            .frame(minHeight: FlightMapFormMetrics.rowMinHeight)
        }
        .buttonStyle(.plain)
    }
}

private struct FlightResultRouteRow: View {
    let origin: String
    let destination: String

    var body: some View {
        HStack(spacing: AppSpacing.sm) {
            Text(origin)
                .font(.cardTitle)
            Image(systemName: "arrow.right")
                .font(.appCaption.weight(.semibold))
            Text(destination)
                .font(.cardTitle)
            Spacer(minLength: 0)
        }
        .foregroundStyle(AppColors.textPrimary)
    }
}

private struct FlightResultTimeRow: View {
    let title: String
    let date: Date
    /// Reads the trip TZ that `AddBookingView` injects via `.environment(\.timeZone, ...)`.
    /// Defaults to the device TZ when shown outside that hierarchy.
    @Environment(\.timeZone) private var environmentTimeZone

    var body: some View {
        HStack {
            Text(title)
                .font(.appSmall)
                .foregroundStyle(AppColors.textTertiary)
            Spacer(minLength: AppSpacing.md)
            Text("\(date.shortFormatted(timeZone: environmentTimeZone)) · \(date.timeFormatted(timeZone: environmentTimeZone))")
                .font(.appSmall.weight(.semibold))
                .foregroundStyle(AppColors.textSecondary)
        }
    }
}

private struct FlightResultTextPill: View {
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: AppSpacing.xs) {
            Text(title)
                .font(.appSmall)
                .foregroundStyle(AppColors.textTertiary)
            Text(value)
                .font(.appSmall.weight(.semibold))
                .foregroundStyle(AppColors.textPrimary)
        }
        .padding(.horizontal, AppSpacing.sm)
        .padding(.vertical, AppSpacing.xs)
        .background(AppColors.appBackground)
        .clipShape(Capsule())
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct FlightTrackingInfoRow: View {
    var body: some View {
        HStack(alignment: .top, spacing: AppSpacing.md) {
            MapStyleIcon(
                systemName: "dot.radiowaves.left.and.right",
                size: .small,
                accent: BookingCategory.flight.color,
                accessibilityLabel: "Live flight tracking"
            )

            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                Text("We will fill in the rest")
                    .font(.appBody.weight(.semibold))
                    .foregroundStyle(AppColors.textPrimary)
                Text("Route, gate, terminal, arrival time, and delays update automatically once tracking starts.")
                    .font(.appSmall)
                    .foregroundStyle(AppColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, AppSpacing.md)
        .padding(.vertical, AppSpacing.sm)
        .frame(minHeight: FlightMapFormMetrics.infoRowMinHeight)
    }
}

private struct FlightMapDivider: View {
    var body: some View {
        Divider()
            .background(AppColors.appDivider)
            .padding(.leading, AppSpacing.xxxl + AppSpacing.md)
    }
}

private enum FlightMapFormMetrics {
    static let rowMinHeight: CGFloat = 56
    static let infoRowMinHeight: CGFloat = 72
    static let trailingFieldMinWidth: CGFloat = 96
    static let airlineCodeBadgeWidth: CGFloat = 42
}

