import SwiftUI

struct CarRentalFormView: View {
    @Binding var company: String
    @Binding var pickupLocation: String
    @Binding var dropoffLocation: String
    @Binding var pickupDate: Date
    @Binding var dropoffDate: Date
    @Binding var carType: String

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.lg) {
            FormSectionTitle("RENTAL DETAILS")
            FormField(label: "Company", placeholder: "e.g. Hertz", text: $company)
            FormField(label: "Pickup Location", placeholder: "Airport or address", text: $pickupLocation)
            FormField(label: "Dropoff Location", placeholder: "Airport or address", text: $dropoffLocation)
            FormDateRow(label: "Pickup", selection: $pickupDate)
            FormDateRow(label: "Dropoff", selection: $dropoffDate)

            DisclosureGroup {
                FormField(label: "Car Type", placeholder: "e.g. Compact SUV", text: $carType)
                    .padding(.top, AppSpacing.md)
            } label: {
                FormSectionTitle("OPTIONAL")
            }
            .tint(AppColors.appPrimary)
        }
    }
}
