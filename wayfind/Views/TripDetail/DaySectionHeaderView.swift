import SwiftUI

struct DaySectionHeaderView: View {
    let day: ItineraryDay
    let dayLabel: String
    let dateLabel: String
    let isCollapsed: Bool
    let contentPreview: String
    /// No places and no cross-day ongoing banners — show muted chrome + "No plans yet".
    let isQuietEmptyDay: Bool
    var onToggle: () -> Void

    private var dayColor: Color {
        AppColors.dayColor(for: day.dayNumber)
    }

    private var accentStripe: Color {
        isQuietEmptyDay ? dayColor.opacity(0.38) : dayColor
    }

    private var chevronColor: Color {
        isQuietEmptyDay ? AppColors.textTertiary : AppColors.textSecondary
    }

    @ViewBuilder
    private var collapsedSubtitle: some View {
        if isQuietEmptyDay {
            Text("No plans yet")
                .font(.appCaption)
                .foregroundStyle(AppColors.textTertiary)
                .lineLimit(2)
        } else if !contentPreview.isEmpty {
            Text(contentPreview)
                .font(.appCaption)
                .foregroundStyle(AppColors.textSecondary)
                .lineLimit(2)
        }
    }

    @ViewBuilder
    private var titleLine: some View {
        if isQuietEmptyDay {
            (
                Text(dayLabel)
                    .fontWeight(.medium)
                    .foregroundStyle(AppColors.textSecondary)
                + Text(" · ")
                    .fontWeight(.regular)
                    .foregroundStyle(AppColors.textTertiary.opacity(0.9))
                + Text(dateLabel)
                    .fontWeight(.regular)
                    .foregroundStyle(AppColors.textTertiary)
            )
            .font(.cardTitle)
            .lineLimit(1)
            .accessibilityLabel("\(dayLabel) · \(dateLabel)")
        } else {
            (
                Text(dayLabel)
                    .fontWeight(.semibold)
                    .foregroundStyle(AppColors.textPrimary)
                + Text(" · ")
                    .fontWeight(.regular)
                    .foregroundStyle(AppColors.textTertiary)
                + Text(dateLabel)
                    .fontWeight(.regular)
                    .foregroundStyle(AppColors.textSecondary)
            )
            .font(.cardTitle)
            .lineLimit(1)
            .accessibilityLabel("\(dayLabel) · \(dateLabel)")
        }
    }

    var body: some View {
        Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                onToggle()
            }
            HapticManager.selection()
        } label: {
            HStack(alignment: .center, spacing: AppSpacing.sm) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(chevronColor)
                    // Collapsed: ∨ (expand). Expanded: ∧ (collapse).
                    .rotationEffect(.degrees(isCollapsed ? 0 : 180))
                    .frame(width: 18, alignment: .center)

                VStack(alignment: .leading, spacing: AppSpacing.xs) {
                    titleLine

                    if isCollapsed {
                        collapsedSubtitle
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Spacer(minLength: 0)
            }
            // Match `AppSpacing.lg` so the chevron's leading edge sits in the
            // same column as the time-pin balloons rendered below in the
            // expanded day body — one column, one ruler.
            .padding(.leading, AppSpacing.lg)
            .padding(.trailing, AppSpacing.lg)
            .padding(.vertical, AppSpacing.sm)
            .frame(height: isCollapsed ? 48 : 52)
            .background(AppColors.appBackground)
            .background(alignment: .leading) {
                accentStripe
                    .frame(width: 4)
                    .frame(maxHeight: .infinity)
            }
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(AppColors.appDivider)
                    .frame(height: 1)
            }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}


// =============================================================================


#if DEBUG
#Preview("Day headers") {
    VStack(spacing: 0) {
        DaySectionHeaderView(
            day: .preview1,
            dayLabel: "Day 1",
            dateLabel: "Mon, May 12",
            isCollapsed: false,
            contentPreview: "Eiffel Tower, Lunch, Louvre…",
            isQuietEmptyDay: false,
            onToggle: {}
        )
        DaySectionHeaderView(
            day: .preview2,
            dayLabel: "Day 2",
            dateLabel: "Tue, May 13",
            isCollapsed: true,
            contentPreview: "Versailles, Dinner…",
            isQuietEmptyDay: false,
            onToggle: {}
        )
        DaySectionHeaderView(
            day: .preview2,
            dayLabel: "Day 4",
            dateLabel: "Fri, Apr 24",
            isCollapsed: true,
            contentPreview: "",
            isQuietEmptyDay: true,
            onToggle: {}
        )
    }
    .padding()
    .background(AppColors.appBackground)
}
#endif
