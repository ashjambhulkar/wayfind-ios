import SwiftUI

struct EmptyStateView: View {
    let sfSymbol: String
    let title: String
    let subtitle: String
    var buttonTitle: String?
    var buttonAction: (() -> Void)?

    var body: some View {
        VStack(spacing: AppSpacing.lg) {
            Spacer(minLength: 0)
            Image(systemName: sfSymbol)
                .font(.system(size: 60))
                .foregroundStyle(AppColors.textTertiary)
            Text(title)
                .font(.sectionHeader)
                .foregroundStyle(AppColors.textPrimary)
                .multilineTextAlignment(.center)
            Text(subtitle)
                .font(.appBody)
                .foregroundStyle(AppColors.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 260)
            if let buttonTitle, let buttonAction {
                AppButton(title: buttonTitle, style: .outline, action: buttonAction)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.top, AppSpacing.sm)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}