import SwiftUI

/// Restaurant reservation fields — native grouped-Form sections.
/// Rendered inside a `Form {}` in `AddBookingView`.
struct RestaurantFormView: View {
    @Binding var restaurantName: String
    @Binding var address: String
    @Binding var reservationDate: Date?
    @Binding var partySize: Int

    @Environment(\.calendar) private var calendar

    private var accent: Color { BookingCategory.restaurant.color }

    private var guestLabel: String {
        partySize == 1 ? String(localized: "1 guest") : String(localized: "\(partySize) guests")
    }

    var body: some View {
        Section {
            LabeledContent(String(localized: "Restaurant")) {
                TextField(String(localized: "e.g. Le Petit Cler"), text: $restaurantName)
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

            DatePicker(
                String(localized: "Reservation"),
                selection: Binding(
                    get: { reservationDate ?? defaultAnchor() },
                    set: { reservationDate = $0 }
                ),
                displayedComponents: [.date, .hourAndMinute]
            )
            .tint(accent)

            Stepper(value: $partySize, in: 1...20) {
                LabeledContent(String(localized: "Party size")) {
                    Text(guestLabel)
                        .foregroundStyle(AppColors.textSecondary)
                }
            }
        } header: {
            Text(String(localized: "Reservation"))
        } footer: {
            Text(String(localized: "Times shown in the trip's destination time zone."))
                .font(.appFootnote)
        }
        .onAppear {
            if reservationDate == nil { reservationDate = defaultAnchor() }
        }
    }

    private func defaultAnchor() -> Date {
        calendar.date(bySettingHour: 19, minute: 30, second: 0, of: Date()) ?? Date()
    }
}
