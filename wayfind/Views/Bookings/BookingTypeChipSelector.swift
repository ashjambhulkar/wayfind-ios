import SwiftUI

struct BookingTypeChipSelector: View {
    @Binding var selectedType: BookingCategory

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: AppSpacing.sm) {
                ForEach(BookingCategory.allCases, id: \.self) { category in
                    chip(for: category)
                }
            }
            .padding(.horizontal, AppSpacing.lg)
            .padding(.vertical, AppSpacing.xs)
        }
    }

    private func chip(for category: BookingCategory) -> some View {
        let isSelected = selectedType == category
        return Button {
            withAnimation(AppSpring.snappy) {
                selectedType = category
            }
            HapticManager.selection()
        } label: {
            HStack(spacing: AppSpacing.sm) {
                Image(systemName: category.sfSymbol)
                    .font(.system(size: 14, weight: .semibold))
                Text(category.label)
                    .font(.appSmall)
                    .lineLimit(1)
            }
            .foregroundStyle(isSelected ? Color.white : AppColors.textSecondary)
            .padding(.horizontal, AppSpacing.md)
            .frame(height: 40)
            .background(isSelected ? category.color : AppColors.appSurface)
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(isSelected ? Color.clear : AppColors.appDivider, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

// =============================================================================

