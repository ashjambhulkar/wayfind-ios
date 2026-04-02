import SwiftUI
import UIKit

struct ForwardingEmailCardView: View {
    let trip: Trip

    private let forwardEmail = "user@wayfind.app"

    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            Text("FORWARD A BOOKING")
                .font(.appSmall)
                .foregroundStyle(AppColors.textTertiary)

            Text("Forward confirmation emails to add them automatically:")
                .font(.appBody)
                .foregroundStyle(AppColors.textSecondary)

            HStack(spacing: AppSpacing.sm) {
                Text(forwardEmail)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(AppColors.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, AppSpacing.md)
                    .padding(.vertical, AppSpacing.sm)
                    .background(AppColors.appSurface)
                    .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous)
                            .strokeBorder(AppColors.appPrimary, style: StrokeStyle(lineWidth: 1, dash: [6, 4]))
                    )

                Button {
                    UIPasteboard.general.string = forwardEmail
                    HapticManager.success()
                    copied = true
                    Task {
                        try? await Task.sleep(nanoseconds: 1_800_000_000)
                        await MainActor.run {
                            copied = false
                        }
                    }
                } label: {
                    Image(systemName: "doc.on.clipboard")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(AppColors.appPrimary)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(copied ? "Copied" : "Copy email")
            }

            Text("2 pending · 1 needs review")
                .font(.appCaption)
                .foregroundStyle(AppColors.textSecondary)

            NavigationLink {
                ReviewForwardedBookingsView(trip: trip)
            } label: {
                HStack {
                    Text("Review →")
                        .font(.appCaption)
                        .foregroundStyle(AppColors.appPrimary)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(AppSpacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColors.appPrimaryLight)
        .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous))
        .overlay(alignment: .topTrailing) {
            if copied {
                Text("Copied!")
                    .font(.appSmall)
                    .foregroundStyle(AppColors.appPrimary)
                    .padding(.horizontal, AppSpacing.sm)
                    .padding(.vertical, AppSpacing.xs)
                    .background(AppColors.appSurface)
                    .clipShape(Capsule())
                    .padding(AppSpacing.sm)
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }
        }
        .animation(AppSpring.snappy, value: copied)
    }
}