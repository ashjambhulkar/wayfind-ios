import SwiftUI

struct TransportFormView: View {
    @Binding var operatorName: String
    @Binding var serviceNumber: String
    @Binding var departureStation: String
    @Binding var arrivalStation: String
    @Binding var departureDate: Date
    @Binding var arrivalDate: Date

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.lg) {
            TransportMapSectionCard(title: "Transport") {
                TransportMapTextRow(
                    icon: "tram.fill",
                    title: "Operator",
                    placeholder: "Eurostar",
                    text: $operatorName
                )

                TransportMapDivider()

                TransportMapTextRow(
                    icon: "number",
                    title: "Service Number",
                    placeholder: "9014",
                    capitalization: .characters,
                    text: $serviceNumber
                )
            }

            TransportMapSectionCard(title: "Route") {
                TransportMapTextRow(
                    icon: "location.fill",
                    title: "Departure Station",
                    placeholder: "Station",
                    text: $departureStation
                )

                TransportMapDivider()

                TransportMapTextRow(
                    icon: "mappin.circle.fill",
                    title: "Arrival Station",
                    placeholder: "Station",
                    text: $arrivalStation
                )
            }

            TransportMapSectionCard(title: "Schedule") {
                TransportMapDateRow(
                    icon: "tram.fill",
                    title: "Departs",
                    selection: $departureDate
                )

                TransportMapDivider()

                TransportMapDateRow(
                    icon: "checkmark.circle.fill",
                    title: "Arrives",
                    selection: $arrivalDate
                )
            }
        }
    }
}

// =============================================================================

struct TransportOptionalDetailsSection: View {
    @Binding var seat: String

    var body: some View {
        DisclosureGroup {
            TransportMapSectionCard(title: nil) {
                TransportMapTextRow(
                    icon: "rectangle.inset.filled.and.person.filled",
                    title: "Seat",
                    placeholder: "Car 4, Seat 12",
                    text: $seat
                )
            }
            .padding(.top, AppSpacing.md)
        } label: {
            HStack(spacing: AppSpacing.sm) {
                MapStyleIcon(
                    systemName: "ellipsis.circle.fill",
                    size: .small,
                    accent: BookingCategory.transport.color,
                    accessibilityLabel: "Optional transport details"
                )

                Text("Optional Details")
                    .font(.appBody.weight(.semibold))
                    .foregroundStyle(AppColors.textPrimary)
            }
        }
        .tint(AppColors.appPrimary)
    }
}

private struct TransportMapSectionCard<Content: View>: View {
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

private struct TransportMapTextRow: View {
    let icon: String
    let title: String
    let placeholder: String
    var capitalization: TextInputAutocapitalization = .words
    @Binding var text: String

    var body: some View {
        HStack(spacing: AppSpacing.md) {
            MapStyleIcon(
                systemName: icon,
                size: .small,
                accent: BookingCategory.transport.color,
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
                .frame(minWidth: TransportMapFormMetrics.trailingFieldMinWidth)
        }
        .padding(.horizontal, AppSpacing.md)
        .frame(minHeight: TransportMapFormMetrics.rowMinHeight)
        .contentShape(Rectangle())
    }
}

private struct TransportMapDateRow: View {
    let icon: String
    let title: String
    @Binding var selection: Date

    var body: some View {
        HStack(spacing: AppSpacing.md) {
            MapStyleIcon(
                systemName: icon,
                size: .small,
                accent: BookingCategory.transport.color,
                accessibilityLabel: title
            )

            DatePicker(title, selection: $selection, displayedComponents: [.date, .hourAndMinute])
                .font(.appBody)
                .datePickerStyle(.compact)
                .tint(AppColors.appPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, AppSpacing.md)
        .frame(minHeight: TransportMapFormMetrics.rowMinHeight)
        .contentShape(Rectangle())
    }
}

private struct TransportMapDivider: View {
    var body: some View {
        Divider()
            .background(AppColors.appDivider)
            .padding(.leading, AppSpacing.xxxl + AppSpacing.md)
    }
}

private enum TransportMapFormMetrics {
    static let rowMinHeight: CGFloat = 56
    static let trailingFieldMinWidth: CGFloat = 128
}

