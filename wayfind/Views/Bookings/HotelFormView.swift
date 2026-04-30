import SwiftUI

struct HotelFormView: View {
    @Binding var hotelName: String
    @Binding var checkInDate: Date
    @Binding var checkOutDate: Date

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.lg) {
            HotelMapSectionCard(title: "Stay") {
                HotelMapTextRow(
                    icon: "bed.double.fill",
                    title: "Hotel",
                    placeholder: "Le Marais Hotel",
                    text: $hotelName
                )
            }

            HotelMapSectionCard(title: "Schedule") {
                HotelMapDateRow(
                    icon: "calendar.badge.plus",
                    title: "Check-in",
                    selection: $checkInDate
                )

                HotelMapDivider()

                HotelMapDateRow(
                    icon: "calendar.badge.minus",
                    title: "Check-out",
                    selection: $checkOutDate
                )
            }
        }
    }
}

// =============================================================================

struct HotelOptionalDetailsSection: View {
    @Binding var roomType: String

    var body: some View {
        DisclosureGroup {
            HotelMapSectionCard(title: nil) {
                HotelMapTextRow(
                    icon: "door.left.hand.open",
                    title: "Room Type",
                    placeholder: "Deluxe Queen",
                    text: $roomType
                )
            }
            .padding(.top, AppSpacing.md)
        } label: {
            HStack(spacing: AppSpacing.sm) {
                MapStyleIcon(
                    systemName: "ellipsis.circle.fill",
                    size: .small,
                    accent: BookingCategory.hotel.color,
                    accessibilityLabel: "Optional hotel details"
                )

                Text("Optional Details")
                    .font(.appBody.weight(.semibold))
                    .foregroundStyle(AppColors.textPrimary)
            }
        }
        .tint(AppColors.appPrimary)
    }
}

private struct HotelMapSectionCard<Content: View>: View {
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

private struct HotelMapTextRow: View {
    let icon: String
    let title: String
    let placeholder: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: AppSpacing.md) {
            MapStyleIcon(
                systemName: icon,
                size: .small,
                accent: BookingCategory.hotel.color,
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
                .frame(minWidth: HotelMapFormMetrics.trailingFieldMinWidth)
        }
        .padding(.horizontal, AppSpacing.md)
        .frame(minHeight: HotelMapFormMetrics.rowMinHeight)
        .contentShape(Rectangle())
    }
}

private struct HotelMapDateRow: View {
    let icon: String
    let title: String
    @Binding var selection: Date

    var body: some View {
        HStack(spacing: AppSpacing.md) {
            MapStyleIcon(
                systemName: icon,
                size: .small,
                accent: BookingCategory.hotel.color,
                accessibilityLabel: title
            )

            DatePicker(title, selection: $selection, displayedComponents: [.date, .hourAndMinute])
                .font(.appBody)
                .datePickerStyle(.compact)
                .tint(AppColors.appPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, AppSpacing.md)
        .frame(minHeight: HotelMapFormMetrics.rowMinHeight)
        .contentShape(Rectangle())
    }
}

private struct HotelMapDivider: View {
    var body: some View {
        Divider()
            .background(AppColors.appDivider)
            .padding(.leading, AppSpacing.xxxl + AppSpacing.md)
    }
}

private enum HotelMapFormMetrics {
    static let rowMinHeight: CGFloat = 56
    static let trailingFieldMinWidth: CGFloat = 128
}

