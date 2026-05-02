import SwiftUI
import UIKit

/// Vertical density for booking-forward promo cards (e.g. bookings hub vs. detail).
enum ForwardingEmailCardDensity {
    case standard
    case compact
}

struct ForwardingEmailCardView: View {
    @Environment(DataService.self) private var dataService

    let trip: Trip
    var density: ForwardingEmailCardDensity = .standard

    @State private var forwardingEmail: String?
    @State private var forwardingSummary: ForwardedBookingSummary = .empty
    @State private var didFailLoadingAddress = false
    @State private var copied = false

    private var displayedEmail: String {
        if let forwardingEmail { return forwardingEmail }
        return didFailLoadingAddress ? "Could not load forwarding address" : "Loading forwarding address..."
    }

    private var cardVSpacing: CGFloat {
        switch density {
        case .standard: return AppSpacing.md
        case .compact: return AppSpacing.sm
        }
    }

    private var cardPadding: CGFloat {
        switch density {
        case .standard: return AppSpacing.lg
        case .compact: return AppSpacing.md
        }
    }

    private var emailFieldVerticalPadding: CGFloat {
        switch density {
        case .standard: return AppSpacing.sm
        case .compact: return AppSpacing.xs
        }
    }

    private var cardCornerRadius: CGFloat {
        switch density {
        case .standard: return AppCornerRadius.large
        case .compact: return AppCornerRadius.medium
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: cardVSpacing) {
            Text("FORWARD A BOOKING")
                .font(.appSmall)
                .foregroundStyle(AppColors.textTertiary)

            if density == .compact {
                Text("Forward confirmations to:")
                    .font(.appCaption)
                    .foregroundStyle(AppColors.textSecondary)
            } else {
                Text("Forward confirmation emails to add them automatically:")
                    .font(.appBody)
                    .foregroundStyle(AppColors.textSecondary)
            }

            HStack(spacing: AppSpacing.sm) {
                Text(displayedEmail)
                    .font(.subheadline)
                    .fontDesign(.monospaced)
                    .foregroundStyle(forwardingEmail == nil ? AppColors.textTertiary : AppColors.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, AppSpacing.md)
                    .padding(.vertical, emailFieldVerticalPadding)
                    .background(AppColors.appSurface)
                    .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous)
                            .strokeBorder(AppColors.appPrimary, style: StrokeStyle(lineWidth: 1, dash: [6, 4]))
                    )

                Button {
                    guard let forwardingEmail else { return }
                    UIPasteboard.general.string = forwardingEmail
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
                        .font(.body.weight(.medium))
                        .foregroundStyle(AppColors.appPrimary)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .disabled(forwardingEmail == nil)
                .opacity(forwardingEmail == nil ? 0.45 : 1)
                .accessibilityLabel(copied ? "Copied" : "Copy email")
            }

            if density == .compact {
                HStack(alignment: .firstTextBaseline, spacing: AppSpacing.sm) {
                    Text(forwardingSummary.displayText)
                        .font(.appCaption)
                        .foregroundStyle(AppColors.textSecondary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    NavigationLink {
                        ReviewForwardedBookingsView(trip: trip)
                    } label: {
                        Text("Review")
                            .font(.appCaption.weight(.semibold))
                            .foregroundStyle(AppColors.appPrimary)
                    }
                }
            } else {
                Text(forwardingSummary.displayText)
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
        }
        .padding(cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColors.appPrimaryLight)
        .clipShape(RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous))
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
        .task(id: trip.id) {
            await loadForwardingState()
        }
    }

    private func loadForwardingState() async {
        async let address = dataService.fetchForwardingEmailAddress(for: trip.id)
        async let summary = dataService.fetchForwardedBookingSummary(for: trip.id)
        let (loadedAddress, loadedSummary) = await (address, summary)
        forwardingEmail = loadedAddress
        forwardingSummary = loadedSummary
        didFailLoadingAddress = loadedAddress == nil
    }
}

// =============================================================================


#if DEBUG
#Preview("Forwarding email card") {
    ForwardingEmailCardView(trip: .preview)
        .padding()
        .background(AppColors.appBackground)
        .environment(DataService(previewMockData: true))
}
#endif
