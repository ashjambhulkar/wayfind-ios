import SwiftUI

/// Sparkle FAB that opens the AI Day Planner wizard.
///
/// Designed to live inside `.safeAreaInset(edge: .bottom)` so it sits above
/// the iOS 26 floating tab bar (and above the Map tab's docked accessory
/// bar) without overlapping scroll content. Right-aligned by an HStack
/// spacer so it reads as a floating action, not a full-width banner.
///
/// Visual: filled `appPrimary` circular icon button with subtle drop shadow.
struct AIPlannerLaunchButton: View {
    let action: () -> Void

    var body: some View {
        HStack {
            Spacer(minLength: 0)
            Button(action: handleTap) {
                Image(systemName: "sparkles")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .background(
                        Circle()
                            .fill(AppColors.appPrimary)
                    )
                    .shadow(color: Color.black.opacity(0.18), radius: 10, x: 0, y: 4)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Plan a day with AI")
            .accessibilityHint("Opens the AI Day Planner")
        }
        .padding(.horizontal, AppSpacing.lg)
        .padding(.bottom, AppSpacing.sm)
    }

    private func handleTap() {
        HapticManager.light()
        action()
    }
}

#Preview {
    ZStack(alignment: .bottom) {
        AppColors.appBackground.ignoresSafeArea()
        AIPlannerLaunchButton(action: {})
    }
}
