import SwiftUI

/// Train / bus / transport booking fields — native grouped-Form sections.
/// Rendered inside a `Form {}` in `AddBookingView`.
struct TransportFormView: View {
    @Binding var operatorName: String
    @Binding var serviceNumber: String
    @Binding var departureStation: String
    @Binding var departureLat: Double?
    @Binding var departureLng: Double?
    @Binding var arrivalStation: String
    @Binding var departureDate: Date?
    @Binding var arrivalDate: Date?
    @Binding var seat: String

    @Environment(\.calendar) private var calendar

    private var accent: Color { BookingCategory.transport.color }

    var body: some View {
        Section(String(localized: "Transport")) {
            LabeledContent(String(localized: "Operator")) {
                TextField(String(localized: "e.g. Eurostar"), text: $operatorName)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
            }
            LabeledContent(String(localized: "Service number")) {
                TextField(String(localized: "e.g. 9014"), text: $serviceNumber)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
            }
        }

        Section(String(localized: "Route")) {
            AddressAutocompleteRow(
                label: String(localized: "Departure station"),
                placeholder: String(localized: "Station name"),
                text: $departureStation,
                latBinding: $departureLat,
                lngBinding: $departureLng
            )
            // Arrival maps to TransportDetails.arrivalStation (string only).
            // No end_lat/end_lng write path from the iOS client today.
            AddressAutocompleteRow(
                label: String(localized: "Arrival station"),
                placeholder: String(localized: "Station name"),
                text: $arrivalStation
            )
        }

        Section {
            DatePicker(
                String(localized: "Departs"),
                selection: Binding(
                    get: { departureDate ?? defaultAnchor() },
                    set: { departureDate = $0 }
                ),
                displayedComponents: [.date, .hourAndMinute]
            )
            .tint(accent)

            DatePicker(
                String(localized: "Arrives"),
                selection: Binding(
                    get: { arrivalDate ?? arrivalAnchor() },
                    set: { arrivalDate = $0 }
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
            LabeledContent(String(localized: "Seat")) {
                TextField(String(localized: "e.g. Car 4, Seat 12"), text: $seat)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
            }
        } header: {
            Text(String(localized: "Optional details"))
        }
    }

    private func defaultAnchor() -> Date {
        calendar.date(bySettingHour: 9, minute: 0, second: 0, of: Date()) ?? Date()
    }

    private func arrivalAnchor() -> Date {
        let base = departureDate ?? defaultAnchor()
        return calendar.date(byAdding: .hour, value: 2, to: base) ?? base
    }
}
