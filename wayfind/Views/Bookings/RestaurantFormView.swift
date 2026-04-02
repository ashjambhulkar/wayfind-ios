import SwiftUI

struct RestaurantFormView: View {
    @Binding var restaurantName: String
    @Binding var reservationDate: Date
    @Binding var partySize: Int

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.lg) {
            FormSectionTitle("RESERVATION DETAILS")
            FormField(label: "Restaurant Name", placeholder: "e.g. Le Petit Cler", text: $restaurantName)
            FormDateRow(label: "Date & Time", selection: $reservationDate)

            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                Text("Party Size")
                    .font(.appCaption)
                    .foregroundStyle(AppColors.textSecondary)
                Stepper("\(partySize) \(partySize == 1 ? "guest" : "guests")", value: $partySize, in: 1...20)
                    .font(.appBody)
                    .padding(.horizontal, AppSpacing.md)
                    .frame(height: 48)
                    .background(AppColors.appSurface)
                    .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous)
                            .strokeBorder(AppColors.appDivider, lineWidth: 1)
                    )
            }
        }
    }
}