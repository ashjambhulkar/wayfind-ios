import SwiftUI

struct ForwardingBannerView: View {
    let email: String
    var onCopy: () -> Void
    var onDismiss: () -> Void

    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            HStack(alignment: .top) {
                HStack(spacing: AppSpacing.sm) {
                    Image(systemName: "envelope.fill")
                        .foregroundStyle(AppColors.appPrimary)
                    Text("Got booking emails?")
                        .font(.cardTitle)
                        .foregroundStyle(AppColors.textPrimary)
                }

                Spacer(minLength: 0)

                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(AppColors.textTertiary)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
            }

            Text("Forward them to")
                .font(.appBody)
                .foregroundStyle(AppColors.textSecondary)

            Button {
                UIPasteboard.general.string = email
                HapticManager.success()
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    copied = false
                }
                onCopy()
            } label: {
                HStack {
                    Text(email)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(AppColors.textPrimary)
                    Spacer(minLength: 0)
                    Image(systemName: copied ? "checkmark" : "doc.on.clipboard")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(AppColors.appPrimary)
                        .frame(width: 28, height: 28)
                }
                .padding(.horizontal, AppSpacing.md)
                .frame(height: 48)
                .background(AppColors.appSurface)
                .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous)
                        .stroke(AppColors.appPrimary, style: StrokeStyle(lineWidth: 1, dash: [6, 4]))
                )
            }
            .buttonStyle(.plain)

            if copied {
                Text("Great! We'll notify you 📬")
                    .font(.appCaption)
                    .foregroundStyle(AppColors.appSuccess)
                    .transition(.opacity)
            } else {
                Text("and they'll appear here automatically ✨")
                    .font(.appCaption)
                    .foregroundStyle(AppColors.textSecondary)
            }
        }
        .padding(AppSpacing.lg)
        .background(AppColors.appPrimaryLight)
        .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous))
        .animation(AppSpring.smooth, value: copied)
    }
}
