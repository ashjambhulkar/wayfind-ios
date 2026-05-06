import CoreLocation
import SwiftUI

struct ReviewForwardedBookingsView: View {
    let trip: Trip

    @Environment(DataService.self) private var dataService
    @State private var parsedBookings: [ParsedBooking] = []
    @State private var targetDayId: UUID? = nil
    @State private var showingAddBooking = false

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
                                onAdd: { openAddBooking() },
                                onEdit: { openAddBooking() }
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
        .sheet(isPresented: $showingAddBooking) {
            if let dayId = targetDayId {
                NavigationStack {
                    AddBookingView(
                        onSave: { savedPlace, _ in
                            geocodeInBackground(savedPlace)
                            return true
                        },
                        targetDayId: dayId,
                        showsCloseButton: true,
                        tripId: trip.id
                    )
                }
            }
        }
        .task {
            await loadData()
        }
    }

    // MARK: - Actions

    private func openAddBooking() {
        guard targetDayId != nil else { return }
        showingAddBooking = true
    }

    // MARK: - Data loading

    private func loadData() async {
        async let bookings = dataService.fetchParsedBookings(for: trip.id)
        async let days = dataService.fetchDays(for: trip.id)
        let (b, d) = await (bookings, days)
        parsedBookings = b
        targetDayId = d
            .filter { !$0.isWishlist }
            .sorted { $0.dayNumber < $1.dayNumber }
            .first?.id
    }

    // MARK: - Background geocoding

    /// Geocodes the saved Place's address string and patches the stored
    /// coordinates. This runs detached at utility priority so it never
    /// blocks the UI or the save completion handler.
    private func geocodeInBackground(_ place: Place) {
        guard let address = place.address, !address.isEmpty else { return }
        let dataService = dataService
        Task.detached(priority: .utility) {
            guard let placemark = try? await CLGeocoder()
                .geocodeAddressString(address)
                .first,
                  let coord = placemark.location?.coordinate
            else { return }

            var updated = place
            updated.lat = coord.latitude
            updated.lng = coord.longitude
            await dataService.updatePlace(updated)
        }
    }
}
