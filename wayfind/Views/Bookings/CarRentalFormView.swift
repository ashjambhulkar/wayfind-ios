import SwiftUI

struct CarRentalFormView: View {
    @Binding var company: String
    @Binding var pickupLocation: String
    @Binding var dropoffLocation: String
    @Binding var pickupDate: Date?
    @Binding var dropoffDate: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.lg) {
            CarRentalMapSectionCard(title: "Rental") {
                CarRentalMapTextRow(
                    icon: "car.fill",
                    title: "Company",
                    placeholder: "Hertz",
                    text: $company
                )
            }

            CarRentalMapSectionCard(title: "Route") {
                CarRentalMapTextRow(
                    icon: "location.fill",
                    title: "Pickup",
                    placeholder: "Airport or address",
                    text: $pickupLocation
                )

                CarRentalMapDivider()

                CarRentalMapTextRow(
                    icon: "mappin.circle.fill",
                    title: "Dropoff",
                    placeholder: "Airport or address",
                    text: $dropoffLocation
                )
            }

            CarRentalMapSectionCard(title: "Schedule") {
                OptionalBookingDateRow(
                    icon: "calendar.badge.plus",
                    rowTitle: String(localized: "Pick-up"),
                    accent: BookingCategory.carRental.color,
                    selection: $pickupDate,
                    displayedComponents: [.date, .hourAndMinute]
                )

                CarRentalMapDivider()

                OptionalBookingDateRow(
                    icon: "calendar.badge.minus",
                    rowTitle: String(localized: "Drop-off"),
                    accent: BookingCategory.carRental.color,
                    selection: $dropoffDate,
                    displayedComponents: [.date, .hourAndMinute]
                )
            }
        }
    }
}

// =============================================================================

struct CarRentalOptionalDetailsSection: View {
    @Binding var carType: String

    var body: some View {
        DisclosureGroup {
            CarRentalMapSectionCard(title: nil) {
                CarRentalMapTextRow(
                    icon: "car.side.fill",
                    title: "Car Type",
                    placeholder: "Compact SUV",
                    text: $carType
                )
            }
            .padding(.top, AppSpacing.md)
        } label: {
            HStack(spacing: AppSpacing.sm) {
                MapStyleIcon(
                    systemName: "ellipsis.circle.fill",
                    size: .small,
                    accent: BookingCategory.carRental.color,
                    accessibilityLabel: "Optional car rental details"
                )

                Text("Optional Details")
                    .font(.appBody.weight(.semibold))
                    .foregroundStyle(AppColors.textPrimary)
            }
        }
        .tint(AppColors.appPrimary)
    }
}

private struct CarRentalMapSectionCard<Content: View>: View {
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

private struct CarRentalMapTextRow: View {
    let icon: String
    let title: String
    let placeholder: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: AppSpacing.md) {
            MapStyleIcon(
                systemName: icon,
                size: .small,
                accent: BookingCategory.carRental.color,
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
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .frame(minWidth: CarRentalMapFormMetrics.trailingFieldMinWidth)
        }
        .padding(.horizontal, AppSpacing.md)
        .frame(minHeight: CarRentalMapFormMetrics.rowMinHeight)
        .contentShape(Rectangle())
    }
}

private struct CarRentalMapDivider: View {
    var body: some View {
        Divider()
            .background(AppColors.appDivider)
            .padding(.leading, AppSpacing.xxxl + AppSpacing.md)
    }
}

private enum CarRentalMapFormMetrics {
    static let rowMinHeight: CGFloat = 56
    static let trailingFieldMinWidth: CGFloat = 128
}

