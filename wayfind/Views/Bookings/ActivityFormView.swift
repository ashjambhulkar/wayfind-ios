import SwiftUI

struct ActivityFormView: View {
    @Binding var activityName: String
    @Binding var location: String
    @Binding var activityDate: Date
    @Binding var duration: String

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.lg) {
            ActivityMapSectionCard(title: "Activity") {
                ActivityMapTextRow(
                    icon: "ticket.fill",
                    title: "Name",
                    placeholder: "Seine River Cruise",
                    text: $activityName
                )

                ActivityMapDivider()

                ActivityMapTextRow(
                    icon: "location.fill",
                    title: "Location",
                    placeholder: "Address or venue",
                    text: $location
                )
            }

            ActivityMapSectionCard(title: "Schedule") {
                ActivityMapDateRow(
                    icon: "calendar.badge.clock",
                    title: "Starts",
                    selection: $activityDate
                )

                ActivityMapDivider()

                ActivityMapTextRow(
                    icon: "clock.fill",
                    title: "Duration",
                    placeholder: "2 hours",
                    text: $duration
                )
            }
        }
    }
}

// =============================================================================

struct ActivityOptionalDetailsSection: View {
    @Binding var provider: String
    @Binding var ticketNumber: String

    var body: some View {
        DisclosureGroup {
            ActivityMapSectionCard(title: nil) {
                ActivityMapTextRow(
                    icon: "person.crop.circle.fill",
                    title: "Provider",
                    placeholder: "Viator",
                    text: $provider
                )

                ActivityMapDivider()

                ActivityMapTextRow(
                    icon: "number",
                    title: "Ticket Number",
                    placeholder: "Ticket #",
                    text: $ticketNumber
                )
            }
            .padding(.top, AppSpacing.md)
        } label: {
            HStack(spacing: AppSpacing.sm) {
                MapStyleIcon(
                    systemName: "ellipsis.circle.fill",
                    size: .small,
                    accent: BookingCategory.activity.color,
                    accessibilityLabel: "Optional activity details"
                )

                Text("Optional Details")
                    .font(.appBody.weight(.semibold))
                    .foregroundStyle(AppColors.textPrimary)
            }
        }
        .tint(AppColors.appPrimary)
    }
}

private struct ActivityMapSectionCard<Content: View>: View {
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

private struct ActivityMapTextRow: View {
    let icon: String
    let title: String
    let placeholder: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: AppSpacing.md) {
            MapStyleIcon(
                systemName: icon,
                size: .small,
                accent: BookingCategory.activity.color,
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
                .frame(minWidth: ActivityMapFormMetrics.trailingFieldMinWidth)
        }
        .padding(.horizontal, AppSpacing.md)
        .frame(minHeight: ActivityMapFormMetrics.rowMinHeight)
        .contentShape(Rectangle())
    }
}

private struct ActivityMapDateRow: View {
    let icon: String
    let title: String
    @Binding var selection: Date

    var body: some View {
        HStack(spacing: AppSpacing.md) {
            MapStyleIcon(
                systemName: icon,
                size: .small,
                accent: BookingCategory.activity.color,
                accessibilityLabel: title
            )

            DatePicker(title, selection: $selection, displayedComponents: [.date, .hourAndMinute])
                .font(.appBody)
                .datePickerStyle(.compact)
                .tint(AppColors.appPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, AppSpacing.md)
        .frame(minHeight: ActivityMapFormMetrics.rowMinHeight)
        .contentShape(Rectangle())
    }
}

private struct ActivityMapDivider: View {
    var body: some View {
        Divider()
            .background(AppColors.appDivider)
            .padding(.leading, AppSpacing.xxxl + AppSpacing.md)
    }
}

private enum ActivityMapFormMetrics {
    static let rowMinHeight: CGFloat = 56
    static let trailingFieldMinWidth: CGFloat = 128
}

