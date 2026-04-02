import SwiftUI

struct NotificationPermissionView: View {
    @Environment(\.dismiss) private var dismiss

    let notificationManager: NotificationManager

    var body: some View {
        VStack(spacing: AppSpacing.lg) {
            Spacer(minLength: 0)
            Image(systemName: "envelope.badge")
                .font(.system(size: 60))
                .foregroundStyle(AppColors.appPrimary)
            Text("We'll notify you when your booking is ready")
                .font(.sectionHeader)
                .foregroundStyle(AppColors.textPrimary)
                .multilineTextAlignment(.center)
            Text("Get alerts when we parse your forwarded bookings, and when your trip is about to start.")
                .font(.appBody)
                .foregroundStyle(AppColors.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)
            AppButton(title: "Enable Notifications", style: .primary) {
                Task {
                    _ = await notificationManager.requestPermission()
                    dismiss()
                }
            }
            AppButton(title: "Remind Me Later", style: .text) {
                notificationManager.remindLaterCount += 1
                dismiss()
            }
            Button {
                notificationManager.hasBeenRequested = true
                dismiss()
            } label: {
                Text("Not Now")
                    .font(.appButton)
                    .foregroundStyle(AppColors.textTertiary)
            }
            .buttonStyle(.plain)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(AppSpacing.lg)
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .background(AppColors.appBackground)
    }
}
