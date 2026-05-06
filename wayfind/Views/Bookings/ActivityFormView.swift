import SwiftUI

/// Activity booking fields — native grouped-Form sections.
/// Rendered inside a `Form {}` in `AddBookingView`.
struct ActivityFormView: View {
    @Binding var activityName: String
    @Binding var location: String
    @Binding var activityDate: Date?
    @Binding var duration: String
    @Binding var provider: String
    @Binding var ticketNumber: String

    @Environment(\.calendar) private var calendar

    private var accent: Color { BookingCategory.activity.color }

    var body: some View {
        Section(String(localized: "Activity")) {
            LabeledContent(String(localized: "Name")) {
                TextField(String(localized: "e.g. Seine River Cruise"), text: $activityName)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
            }
            LabeledContent(String(localized: "Location")) {
                TextField(String(localized: "Address or venue"), text: $location)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
            }
        }

        Section {
            DatePicker(
                String(localized: "Starts"),
                selection: Binding(
                    get: { activityDate ?? defaultAnchor() },
                    set: { activityDate = $0 }
                ),
                displayedComponents: [.date, .hourAndMinute]
            )
            .tint(accent)

            LabeledContent(String(localized: "Duration")) {
                TextField(String(localized: "e.g. 2 hours"), text: $duration)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.sentences)
                    .autocorrectionDisabled()
            }
        } header: {
            Text(String(localized: "Schedule"))
        } 

        Section {
            LabeledContent(String(localized: "Provider")) {
                TextField(String(localized: "e.g. Viator"), text: $provider)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
            }
            LabeledContent(String(localized: "Ticket number")) {
                TextField(String(localized: "e.g. TKT-12345"), text: $ticketNumber)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
            }
        } header: {
            Text(String(localized: "Optional details"))
        } footer: {
            Text(String(localized: "Provider and ticket number are optional."))
                .font(.appFootnote)
        }
    }

    private func defaultAnchor() -> Date {
        calendar.date(bySettingHour: 10, minute: 0, second: 0, of: Date()) ?? Date()
    }
}
