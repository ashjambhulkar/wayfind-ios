import SwiftUI
import UIKit

struct DayFilterChipsView: View {
    @Binding var selectedDay: Int?
    let dayCount: Int
    var unselectedBackground: Color = AppColors.appSurface
    /// When `true` (e.g. map bottom sheet on material), unselected chips use `tertiarySystemFill` for a system pill look.
    var unselectedSystemFill: Bool = false

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: AppSpacing.sm) {
                chip(title: "All", isSelected: selectedDay == nil) {
                    selectedDay = nil
                }
                if dayCount > 0 {
                    ForEach(1 ... dayCount, id: \.self) { day in
                        chip(title: "Day \(day)", isSelected: selectedDay == day) {
                            selectedDay = day
                        }
                    }
                }
            }
            .padding(.horizontal, AppSpacing.sm)
        }
        .frame(height: 32)
    }

    private func chip(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: {
            HapticManager.selection()
            action()
        }) {
            Text(title)
                .font(.appSmall)
                .foregroundStyle(isSelected ? Color.white : AppColors.textSecondary)
                .padding(.horizontal, AppSpacing.md)
                .frame(height: 32)
                .background {
                    if isSelected {
                        Capsule().fill(AppColors.appPrimary)
                    } else if unselectedSystemFill {
                        Capsule().fill(Color(UIColor.tertiarySystemFill))
                    } else {
                        Capsule().fill(unselectedBackground)
                    }
                }
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .strokeBorder(AppColors.appDivider, lineWidth: (isSelected || unselectedSystemFill) ? 0 : 1)
                )
        }
        .buttonStyle(.plain)
    }
}
