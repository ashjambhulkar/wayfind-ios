import SwiftUI

/// Placeholder for trip-scoped AI; shown on the dedicated +ai tab (separate tab bar role on iOS 18+).
struct TripAiTabView: View {
    var body: some View {
        ContentUnavailableView {
            VStack(spacing: AppSpacing.sm) {
                Image(systemName: "sparkles")
                    .font(.system(size: 36))
                    .foregroundStyle(AppColors.appPrimary)
                Text("+ai")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(AppColors.textPrimary)
            }
        } description: {
            Text("Trip intelligence is coming soon—suggestions, summaries, and smart planning in one place.")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppColors.appBackground)
    }
}

