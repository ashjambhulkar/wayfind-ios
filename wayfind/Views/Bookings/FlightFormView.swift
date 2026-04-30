import SwiftUI

struct FlightFormView: View {
    @Binding var airline: String
    @Binding var flightNumber: String
    @Binding var departureAirport: String
    @Binding var arrivalAirport: String
    @Binding var departureDate: Date
    @Binding var arrivalDate: Date
    @Binding var terminal: String
    @Binding var gate: String
    @Binding var seat: String

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.lg) {
            FlightMapSectionCard(title: "Flight") {
                FlightMapTextRow(
                    icon: "airplane",
                    title: "Airline",
                    placeholder: "American Airlines",
                    capitalization: .words,
                    text: $airline
                )

                FlightMapDivider()

                FlightMapTextRow(
                    icon: "number",
                    title: "Flight Number",
                    placeholder: "AA 1234",
                    capitalization: .characters,
                    text: $flightNumber
                )
            }

            FlightMapSectionCard(title: "Route") {
                FlightMapTextRow(
                    icon: "airplane.departure",
                    title: "Departure Airport",
                    placeholder: "JFK",
                    capitalization: .characters,
                    text: $departureAirport
                )

                FlightMapDivider()

                FlightMapTextRow(
                    icon: "airplane.arrival",
                    title: "Arrival Airport",
                    placeholder: "CDG",
                    capitalization: .characters,
                    text: $arrivalAirport
                )
            }

            FlightMapSectionCard(title: "Schedule") {
                FlightMapDateRow(
                    icon: "airplane.departure",
                    title: "Departs",
                    selection: $departureDate
                )

                FlightMapDivider()

                FlightMapDateRow(
                    icon: "airplane.arrival",
                    title: "Arrives",
                    selection: $arrivalDate
                )
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

private struct FlightMapDateRow: View {
    let icon: String
    let title: String
    @Binding var selection: Date

    var body: some View {
        HStack(spacing: AppSpacing.md) {
            MapStyleIcon(
                systemName: icon,
                size: .small,
                accent: BookingCategory.flight.color,
                accessibilityLabel: title
            )

            DatePicker(title, selection: $selection, displayedComponents: [.date, .hourAndMinute])
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

private struct FlightMapDivider: View {
    var body: some View {
        Divider()
            .background(AppColors.appDivider)
            .padding(.leading, AppSpacing.xxxl + AppSpacing.md)
    }
}

private enum FlightMapFormMetrics {
    static let rowMinHeight: CGFloat = 56
    static let trailingFieldMinWidth: CGFloat = 96
}

