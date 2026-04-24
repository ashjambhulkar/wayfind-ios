import SwiftUI

struct FlightFormView: View {
    @Binding var airline: String
    @Binding var flightNumber: String
    @Binding var departureAirport: String
    @Binding var arrivalAirport: String
    @Binding var departureDate: Date
    @Binding var arrivalDate: Date
    @Binding var terminal: String
    @Binding var gate: String
    @Binding var seat: String

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.lg) {
            FormSectionTitle("FLIGHT DETAILS")

            FormField(label: "Airline", placeholder: "e.g. American Airlines", text: $airline)
            FormField(label: "Flight Number", placeholder: "e.g. AA 1234", text: $flightNumber)

            HStack(alignment: .top, spacing: AppSpacing.md) {
                FormField(label: "From", placeholder: "JFK", text: $departureAirport)
                FormField(label: "To", placeholder: "CDG", text: $arrivalAirport)
            }

            FormDateRow(label: "Departure", selection: $departureDate)
            FormDateRow(label: "Arrival", selection: $arrivalDate)

            DisclosureGroup {
                VStack(alignment: .leading, spacing: AppSpacing.lg) {
                    HStack(alignment: .top, spacing: AppSpacing.md) {
                        FormField(label: "Terminal", placeholder: "Terminal", text: $terminal)
                        FormField(label: "Gate", placeholder: "Gate", text: $gate)
                    }
                    FormField(label: "Seat", placeholder: "e.g. 12A", text: $seat)
                }
                .padding(.top, AppSpacing.md)
            } label: {
                FormSectionTitle("OPTIONAL")
            }
            .tint(AppColors.appPrimary)
        }
    }
}

// =============================================================================

