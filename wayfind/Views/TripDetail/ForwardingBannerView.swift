import SwiftUI

struct ForwardingBannerView: View {
    let email: String
    var onCopy: () -> Void
    var onDismiss: () -> Void

    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            HStack(alignment: .center, spacing: AppSpacing.sm) {
                Image(systemName: "envelope.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(AppColors.appPrimary)
                Text("Got booking emails?")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(AppColors.textPrimary)

                Spacer(minLength: 0)

                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(AppColors.textTertiary)
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
            }

            Button {
                UIPasteboard.general.string = email
                HapticManager.success()
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    copied = false
                }
                onCopy()
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Forward them to")
                        .font(.caption2)
                        .foregroundStyle(AppColors.textSecondary)

                    HStack(spacing: AppSpacing.sm) {
                        Text(email)
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                            .foregroundStyle(AppColors.textPrimary)
                        Spacer(minLength: 0)
                        Image(systemName: copied ? "checkmark" : "doc.on.clipboard")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(AppColors.appPrimary)
                            .frame(width: 24, height: 24)
                    }
                }
                .padding(.horizontal, AppSpacing.sm)
                .padding(.vertical, AppSpacing.xs + 2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AppColors.appSurface)
                .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous)
                        .stroke(AppColors.appDivider, style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                )
            }
            .buttonStyle(.plain)

            if copied {
                Text("Great! We'll notify you 📬")
                    .font(.caption2)
                    .foregroundStyle(AppColors.appSuccess)
                    .transition(.opacity)
            } else {
                Text("and they'll appear here automatically ✨")
                    .font(.caption2)
                    .foregroundStyle(AppColors.textTertiary)
            }
        }
        .padding(.horizontal, AppSpacing.sm)
        .padding(.vertical, AppSpacing.xs)
        .background(AppColors.appPrimaryLight)
        .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous))
        .animation(AppSpring.smooth, value: copied)
    }
}


// =============================================================================


#if DEBUG
#Preview("Forwarding banner") {
    ForwardingBannerView(
        email: "paris-trip@mail.wayfind.app",
        onCopy: {},
        onDismiss: {}
    )
    .padding()
    .background(AppColors.appBackground)
}
#endif
