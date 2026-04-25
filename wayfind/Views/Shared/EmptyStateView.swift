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
                emptyStateAction(title: buttonTitle, action: buttonAction)
                    .padding(.top, AppSpacing.sm)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func emptyStateAction(title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: AppSpacing.xs) {
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .bold))
                    .accessibilityHidden(true)

                Text(sanitizedActionTitle(title))
                    .font(.appButton)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, AppSpacing.lg)
            .frame(minHeight: 46)
            .background(
                Capsule(style: .continuous)
                    .fill(AppColors.appPrimary)
            )
            .shadow(color: AppColors.appPrimary.opacity(0.24), radius: 14, x: 0, y: 8)
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(WayfindEmptyStateButtonStyle())
        .accessibilityLabel(sanitizedActionTitle(title))
    }

    private func sanitizedActionTitle(_ title: String) -> String {
        var cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("+") {
            cleaned.removeFirst()
            cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return cleaned
    }
}

private struct WayfindEmptyStateButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.88 : 1)
            .animation(AppSpring.snappy, value: configuration.isPressed)
    }
}

// =============================================================================

