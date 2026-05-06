import SwiftUI

/// Hotel booking fields — native grouped-Form sections matching Calendar / Reminders style.
/// Rendered inside a `Form {}` in `AddBookingView` so no wrapping container is needed here.
struct HotelFormView: View {
    @Binding var hotelName: String
    @Binding var address: String
    @Binding var checkInDate: Date?
    @Binding var checkOutDate: Date?
    @Binding var roomType: String

    @Environment(\.calendar) private var calendar

    private var accent: Color { BookingCategory.hotel.color }

    var body: some View {
        Section(String(localized: "Stay")) {
            LabeledContent(String(localized: "Hotel")) {
                TextField(String(localized: "e.g. Le Marais Hotel"), text: $hotelName)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
            }

            LabeledContent(String(localized: "Address")) {
                TextField(String(localized: "Street, city"), text: $address)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
            }
        }

        Section {
            DatePicker(
                String(localized: "Check-in"),
                selection: Binding(
                    get: { checkInDate ?? defaultAnchor() },
                    set: { checkInDate = $0 }
                ),
                displayedComponents: [.date, .hourAndMinute]
            )
            .tint(accent)

            DatePicker(
                String(localized: "Check-out"),
                selection: Binding(
                    get: { checkOutDate ?? checkOutAnchor() },
                    set: { checkOutDate = $0 }
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
            LabeledContent(String(localized: "Room type")) {
                TextField(String(localized: "e.g. Deluxe Queen"), text: $roomType)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
            }
        } header: {
            Text(String(localized: "Optional details"))
        }
        .onAppear {
            // The DatePicker already shows these defaults via the nil-coalescing get: closure.
            // Commit them into the binding immediately so saving without touching the picker
            // still writes a real date instead of nil.
            if checkInDate == nil { checkInDate = defaultAnchor() }
            if checkOutDate == nil { checkOutDate = checkOutAnchor() }
        }
    }

    private func defaultAnchor() -> Date {
        calendar.date(bySettingHour: 14, minute: 0, second: 0, of: Date()) ?? Date()
    }

    private func checkOutAnchor() -> Date {
        let base = checkInDate ?? defaultAnchor()
        return calendar.date(byAdding: .day, value: 1, to: base) ?? base
    }
}
