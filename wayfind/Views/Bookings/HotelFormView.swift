import SwiftUI

struct HotelFormView: View {
    @Binding var hotelName: String
    @Binding var checkInDate: Date
    @Binding var checkOutDate: Date
    @Binding var roomType: String
    @Binding var checkInTime: String
    @Binding var checkOutTime: String

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.lg) {
            FormSectionTitle("STAY DETAILS")
            FormField(label: "Hotel Name", placeholder: "e.g. Le Marais Hotel", text: $hotelName)
            FormDateRow(label: "Check-in", selection: $checkInDate, components: [.date, .hourAndMinute])
            FormDateRow(label: "Check-out", selection: $checkOutDate, components: [.date, .hourAndMinute])

            DisclosureGroup {
                FormField(label: "Room Type", placeholder: "e.g. Deluxe Queen", text: $roomType)
                    .padding(.top, AppSpacing.md)
            } label: {
                FormSectionTitle("OPTIONAL")
            }
            .tint(AppColors.appPrimary)
        }
    }
}