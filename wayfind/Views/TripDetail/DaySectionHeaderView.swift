import SwiftUI

struct DaySectionHeaderView: View {
    let day: ItineraryDay
    let titleText: String
    let itemCount: Int
    let isCollapsed: Bool
    let contentPreview: String
    var onToggle: () -> Void

    private var dayColor: Color {
        AppColors.dayColor(for: day.dayNumber)
    }

    var body: some View {
        Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                onToggle()
            }
            HapticManager.selection()
        } label: {
            HStack(alignment: .center, spacing: AppSpacing.sm) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(AppColors.textSecondary)
                    .rotationEffect(.degrees(isCollapsed ? -90 : 0))
                    .frame(width: 18, alignment: .center)

                VStack(alignment: .leading, spacing: AppSpacing.xs) {
                    Text(titleText)
                        .font(.cardTitle)
                        .foregroundStyle(AppColors.textPrimary)
                        .lineLimit(1)

                    if isCollapsed {
                        Text("\(itemCount) items · \(contentPreview)")
                            .font(.appCaption)
                            .foregroundStyle(AppColors.textSecondary)
                            .lineLimit(2)
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
                dayColor
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
            titleText: "Day 1 · Monday, May 12",
            itemCount: 4,
            isCollapsed: false,
            contentPreview: "Eiffel Tower, Lunch, Louvre…",
            onToggle: {}
        )
        DaySectionHeaderView(
            day: .preview2,
            titleText: "Day 2 · Tuesday, May 13",
            itemCount: 3,
            isCollapsed: true,
            contentPreview: "Versailles, Dinner…",
            onToggle: {}
        )
    }
    .padding()
    .background(AppColors.appBackground)
}
#endif
