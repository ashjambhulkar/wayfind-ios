import SwiftUI

struct OngoingBookingBannerView: View {
    let bookingName: String
    let bookingType: BookingCategory

    private var headline: String {
        switch bookingType {
        case .carRental:
            "Renting from \(bookingName)"
        default:
            "Staying at \(bookingName)"
        }
    }

    var body: some View {
        HStack(spacing: AppSpacing.sm) {
            Image(systemName: bookingType.sfSymbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(AppColors.textSecondary)

            Text(headline)
                .font(.appCaption)
                .foregroundStyle(AppColors.textSecondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 36)
        .padding(.horizontal, AppSpacing.md)
        .background(AppColors.appPrimaryLight)
        .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.small, style: .continuous))
    }
}


// =============================================================================

