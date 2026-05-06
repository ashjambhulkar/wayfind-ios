import SwiftUI

/// Car rental booking fields — native grouped-Form sections.
/// Rendered inside a `Form {}` in `AddBookingView`.
struct CarRentalFormView: View {
    @Binding var company: String
    @Binding var pickupLocation: String
    @Binding var dropoffLocation: String
    @Binding var pickupDate: Date?
    @Binding var dropoffDate: Date?
    @Binding var carType: String

    @Environment(\.calendar) private var calendar

    private var accent: Color { BookingCategory.carRental.color }

    var body: some View {
        Section(String(localized: "Rental")) {
            LabeledContent(String(localized: "Company")) {
                TextField(String(localized: "e.g. Hertz"), text: $company)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
            }
        }

        Section(String(localized: "Route")) {
            LabeledContent(String(localized: "Pick-up")) {
                TextField(String(localized: "Airport or address"), text: $pickupLocation)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
            }
            LabeledContent(String(localized: "Drop-off")) {
                TextField(String(localized: "Airport or address"), text: $dropoffLocation)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
            }
        }

        Section {
            DatePicker(
                String(localized: "Pick-up date"),
                selection: Binding(
                    get: { pickupDate ?? defaultAnchor() },
                    set: { pickupDate = $0 }
                ),
                displayedComponents: [.date, .hourAndMinute]
            )
            .tint(accent)

            DatePicker(
                String(localized: "Drop-off date"),
                selection: Binding(
                    get: { dropoffDate ?? dropoffAnchor() },
                    set: { dropoffDate = $0 }
                ),
                displayedComponents: [.date, .hourAndMinute]
            )
            .tint(accent)
        } header: {
            Text(String(localized: "Schedule"))
        } footer: {
            Text(String(localized: "Times shown in the trip's destination time zone."))
                .font(.appFootnote)
        }

        Section {
            LabeledContent(String(localized: "Car type")) {
                TextField(String(localized: "e.g. Compact SUV"), text: $carType)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
            }
        } header: {
            Text(String(localized: "Optional details"))
        }
    }

    private func defaultAnchor() -> Date {
        calendar.date(bySettingHour: 10, minute: 0, second: 0, of: Date()) ?? Date()
    }

    private func dropoffAnchor() -> Date {
        let base = pickupDate ?? defaultAnchor()
        return calendar.date(byAdding: .day, value: 3, to: base) ?? base
    }
}
