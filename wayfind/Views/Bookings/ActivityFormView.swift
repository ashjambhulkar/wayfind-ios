import SwiftUI

struct ActivityFormView: View {
    @Binding var activityName: String
    @Binding var location: String
    @Binding var activityDate: Date
    @Binding var duration: String
    @Binding var provider: String
    @Binding var ticketNumber: String

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.lg) {
            FormSectionTitle("ACTIVITY DETAILS")
            FormField(label: "Activity Name", placeholder: "e.g. Seine River Cruise", text: $activityName)
            FormField(label: "Location", placeholder: "Address or venue", text: $location)
            FormDateRow(label: "Date & Time", selection: $activityDate)
            FormField(label: "Duration", placeholder: "e.g. 2 hours", text: $duration)

            DisclosureGroup {
                VStack(alignment: .leading, spacing: AppSpacing.lg) {
                    FormField(label: "Provider", placeholder: "e.g. Viator", text: $provider)
                    FormField(label: "Ticket Number", placeholder: "Ticket #", text: $ticketNumber)
                }
                .padding(.top, AppSpacing.md)
            } label: {
                FormSectionTitle("OPTIONAL")
            }
            .tint(AppColors.appPrimary)
        }
    }
}