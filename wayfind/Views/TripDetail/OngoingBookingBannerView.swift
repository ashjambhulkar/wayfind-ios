import SwiftUI

struct OngoingBookingBannerView: View {
    let bookingName: String
    let bookingType: BookingCategory

    private var headline: String {
        bookingType.ongoingSpanHeadline(bookingName: bookingName)
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


#if DEBUG
#Preview("Ongoing booking banners") {
    VStack(spacing: 12) {
        OngoingBookingBannerView(bookingName: "Air France AF264", bookingType: .flight)
        OngoingBookingBannerView(bookingName: "Hôtel Plaza Athénée", bookingType: .hotel)
        OngoingBookingBannerView(bookingName: "Eurostar 9024", bookingType: .transport)
    }
    .padding()
    .background(AppColors.appBackground)
}
#endif
