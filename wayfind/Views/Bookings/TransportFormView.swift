import SwiftUI

struct TransportFormView: View {
    @Binding var operatorName: String
    @Binding var serviceNumber: String
    @Binding var departureStation: String
    @Binding var arrivalStation: String
    @Binding var departureDate: Date
    @Binding var arrivalDate: Date
    @Binding var seat: String

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.lg) {
            FormSectionTitle("TRANSPORT DETAILS")
            FormField(label: "Operator", placeholder: "e.g. Eurostar", text: $operatorName)
            FormField(label: "Service Number", placeholder: "e.g. 9014", text: $serviceNumber)

            HStack(alignment: .top, spacing: AppSpacing.md) {
                FormField(label: "From", placeholder: "Station", text: $departureStation)
                FormField(label: "To", placeholder: "Station", text: $arrivalStation)
            }

            FormDateRow(label: "Departure", selection: $departureDate)
            FormDateRow(label: "Arrival", selection: $arrivalDate)

            DisclosureGroup {
                FormField(label: "Seat", placeholder: "e.g. Car 4, Seat 12", text: $seat)
                    .padding(.top, AppSpacing.md)
            } label: {
                FormSectionTitle("OPTIONAL")
            }
            .tint(AppColors.appPrimary)
        }
    }
}

// =============================================================================

