import SwiftUI

struct InlineAddButtonView: View {
    let dayNumber: Int
    var showForwardingHint: Bool = false
    var forwardingEmail: String = ""
    var onTap: () -> Void

    @State private var copiedEmail = false

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: AppSpacing.xs) {
                Text("+ Add to Day \(dayNumber)")
                    .font(.appCaption)
                    .foregroundStyle(AppColors.textTertiary)

                if showForwardingHint {
                    Button {
                        UIPasteboard.general.string = forwardingEmail
                        HapticManager.success()
                        copiedEmail = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            copiedEmail = false
                        }
                    } label: {
                        HStack(spacing: AppSpacing.xs) {
                            Image(systemName: "envelope")
                                .font(.system(size: 10))
                            Text(copiedEmail ? "Copied!" : "or forward bookings")
                                .font(.appSmall)
                        }
                        .foregroundStyle(copiedEmail ? AppColors.appSuccess : AppColors.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .animation(AppSpring.snappy, value: copiedEmail)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: 40)
            .overlay(
                RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous)
                    .stroke(AppColors.appDivider, style: StrokeStyle(lineWidth: 1, dash: [6, 4]))
            )
        }
        .buttonStyle(.plain)
    }
}


// =============================================================================

