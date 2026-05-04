import SwiftUI

struct RestaurantFormView: View {
    @Binding var restaurantName: String
    @Binding var reservationDate: Date?
    @Binding var partySize: Int

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.lg) {
            RestaurantMapSectionCard(title: "Reservation") {
                RestaurantMapTextRow(
                    icon: "fork.knife",
                    title: "Restaurant",
                    placeholder: "Le Petit Cler",
                    text: $restaurantName
                )

                RestaurantMapDivider()

                OptionalBookingDateRow(
                    icon: "calendar.badge.clock",
                    rowTitle: String(localized: "Reservation"),
                    accent: BookingCategory.restaurant.color,
                    selection: $reservationDate,
                    displayedComponents: [.date, .hourAndMinute]
                )

                RestaurantMapDivider()

                RestaurantMapStepperRow(
                    icon: "person.2.fill",
                    title: "Party Size",
                    value: $partySize
                )
            }
        }
    }
}

// =============================================================================

private struct RestaurantMapSectionCard<Content: View>: View {
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

private struct RestaurantMapTextRow: View {
    let icon: String
    let title: String
    let placeholder: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: AppSpacing.md) {
            MapStyleIcon(
                systemName: icon,
                size: .small,
                accent: BookingCategory.restaurant.color,
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
                .frame(minWidth: RestaurantMapFormMetrics.trailingFieldMinWidth)
        }
        .padding(.horizontal, AppSpacing.md)
        .frame(minHeight: RestaurantMapFormMetrics.rowMinHeight)
        .contentShape(Rectangle())
    }
}

private struct RestaurantMapStepperRow: View {
    let icon: String
    let title: String
    @Binding var value: Int

    private var guestLabel: String {
        "\(value) \(value == 1 ? "guest" : "guests")"
    }

    var body: some View {
        HStack(spacing: AppSpacing.md) {
            MapStyleIcon(
                systemName: icon,
                size: .small,
                accent: BookingCategory.restaurant.color,
                accessibilityLabel: title
            )

            Stepper(value: $value, in: 1...20) {
                HStack {
                    Text(title)
                        .font(.appBody)
                        .foregroundStyle(AppColors.textPrimary)
                    Spacer(minLength: AppSpacing.md)
                    Text(guestLabel)
                        .font(.appBody)
                        .foregroundStyle(AppColors.textSecondary)
                }
            }
        }
        .padding(.horizontal, AppSpacing.md)
        .frame(minHeight: RestaurantMapFormMetrics.rowMinHeight)
        .contentShape(Rectangle())
    }
}

private struct RestaurantMapDivider: View {
    var body: some View {
        Divider()
            .background(AppColors.appDivider)
            .padding(.leading, AppSpacing.xxxl + AppSpacing.md)
    }
}

private enum RestaurantMapFormMetrics {
    static let rowMinHeight: CGFloat = 56
    static let trailingFieldMinWidth: CGFloat = 128
}

