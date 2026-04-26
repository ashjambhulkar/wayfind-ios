import SwiftUI

struct ParsedBookingCardView: View {
    let booking: ParsedBooking
    var onAdd: (() -> Void)?
    var onEdit: (() -> Void)?

    private var parsedSummary: String {
        guard let data = booking.parsedData, !data.isEmpty else {
            return "Booking details ready."
        }
        return data
            .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
            .map { "\($0.key): \($0.value)" }
            .joined(separator: "\n")
    }

    var body: some View {
        Group {
            switch booking.status {
            case .pending:
                HStack(spacing: AppSpacing.md) {
                    ProgressView()
                    Text("Processing...")
                        .font(.appCaption)
                        .foregroundStyle(AppColors.textSecondary)
                    Spacer(minLength: 0)
                }
            case .parsed:
                VStack(alignment: .leading, spacing: AppSpacing.md) {
                    HStack(alignment: .top, spacing: AppSpacing.sm) {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(AppColors.appPrimary)
                        Text(parsedSummary)
                            .font(.appBody)
                            .foregroundStyle(AppColors.textPrimary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    VStack(spacing: AppSpacing.sm) {
                        AppButton(title: "Add to Trip", style: .primary, action: { onAdd?() })
                        AppButton(title: "Edit & Add", style: .outline, action: { onEdit?() })
                    }
                }
            case .confirmed:
                HStack(spacing: AppSpacing.sm) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(AppColors.appSuccess)
                    Text("Added")
                        .font(.appCaption)
                        .foregroundStyle(AppColors.textTertiary)
                    Spacer(minLength: 0)
                }
                .opacity(0.75)
            case .failed:
                VStack(alignment: .leading, spacing: AppSpacing.md) {
                    HStack(spacing: AppSpacing.sm) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(AppColors.appWarning)
                        Text("Couldn't parse")
                            .font(.appBody)
                            .foregroundStyle(AppColors.textPrimary)
                    }
                    AppButton(title: "Enter Manually", style: .outline, action: { onEdit?() })
                }
            }
        }
        .padding(AppSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColors.appSurface)
        .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous))
        .shadow(color: .black.opacity(0.06), radius: 8, x: 0, y: 3)
    }
}

// =============================================================================


#if DEBUG
#Preview("Parsed booking card") {
    ParsedBookingCardView(
        booking: .preview,
        onAdd: {},
        onEdit: {}
    )
    .padding()
    .background(AppColors.appBackground)
}
#endif
