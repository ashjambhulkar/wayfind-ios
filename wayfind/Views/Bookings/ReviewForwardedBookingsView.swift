import SwiftUI

struct ReviewForwardedBookingsView: View {
    let trip: Trip

    @Environment(DataService.self) private var dataService
    @State private var parsedBookings: [ParsedBooking] = []

    var body: some View {
        Group {
            if parsedBookings.isEmpty {
                EmptyStateView(
                    sfSymbol: "tray",
                    title: "No forwarded bookings",
                    subtitle: "Forward confirmation emails to see them here after parsing.",
                    buttonTitle: nil,
                    buttonAction: nil
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: AppSpacing.md) {
                        ForEach(parsedBookings) { booking in
                            ParsedBookingCardView(
                                booking: booking,
                                onAdd: {},
                                onEdit: {}
                            )
                        }
                    }
                    .padding(.horizontal, AppSpacing.lg)
                    .padding(.vertical, AppSpacing.md)
                }
            }
        }
        .background(AppColors.appBackground)
        .navigationTitle("Forwarded Bookings")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            parsedBookings = await dataService.fetchParsedBookings(for: trip.id)
        }
    }
}
