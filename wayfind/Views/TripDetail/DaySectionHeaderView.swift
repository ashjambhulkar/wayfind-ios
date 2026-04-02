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
            HStack(alignment: .center, spacing: 0) {
                Color.clear
                    .frame(width: 4)

                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(AppColors.textSecondary)
                    .rotationEffect(.degrees(isCollapsed ? -90 : 0))
                    .frame(width: 24)

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
                    } else {
                        Text("\(itemCount) items")
                            .font(.appCaption)
                            .foregroundStyle(AppColors.textTertiary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Spacer(minLength: 0)
            }
            .padding(.leading, AppSpacing.sm)
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
    }
}
