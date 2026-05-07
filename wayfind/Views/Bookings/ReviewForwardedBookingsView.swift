import CoreLocation
import SwiftUI

struct ReviewForwardedBookingsView: View {
    let trip: Trip

    @Environment(DataService.self) private var dataService
    @State private var parsedBookings: [ParsedBooking] = []
    @State private var dismissedIds: Set<UUID> = []
    @State private var timedOutIds: Set<UUID> = []
    @State private var targetDayId: UUID? = nil
    @State private var showingAddBooking = false
    /// Set to `true` after the first fetch so subsequent polls can animate
    /// newly-confirmed items; on first load all pre-existing confirmed items
    /// are silently hidden to avoid the flash-then-disappear effect.
    @State private var initialLoadComplete = false

    /// Maximum time (seconds) to keep polling before surfacing stuck-pending
    /// items as timed-out so the user sees the "Enter Manually" fallback.
    private static let pollingTimeoutSeconds: TimeInterval = 10 * 60

    private var visibleBookings: [ParsedBooking] {
        parsedBookings.filter { !dismissedIds.contains($0.id) }
    }

    private var hasPending: Bool {
        visibleBookings.contains { $0.status == .pending }
    }

    var body: some View {
        Group {
            if visibleBookings.isEmpty && !parsedBookings.isEmpty {
                EmptyStateView(
                    sfSymbol: "checkmark.circle",
                    title: "All caught up",
                    subtitle: "All forwarded bookings have been processed.",
                    buttonTitle: nil,
                    buttonAction: nil
                )
            } else if visibleBookings.isEmpty {
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
                        ForEach(visibleBookings) { booking in
                            ParsedBookingCardView(
                                booking: booking,
                                isTimedOut: timedOutIds.contains(booking.id),
                                onAdd: { openAddBooking() },
                                onEdit: {
                                    // Dismiss failed / timed-out cards when the user
                                    // taps "Enter Manually" — they're handling it, so
                                    // the card has served its purpose.
                                    if booking.status == .failed || timedOutIds.contains(booking.id) {
                                        withAnimation(.easeOut(duration: 0.35)) {
                                            dismissedIds.insert(booking.id)
                                        }
                                    }
                                    openAddBooking()
                                }
                            )
                            .transition(.opacity.combined(with: .move(edge: .top)))
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
            scheduleDismissals()
        }
        .onDisappear {
            // Delete failed entries from the queue when the user closes this
            // screen. They've seen the errors; keeping stale failures visible
            // on the next visit would be confusing.
            let tripId = trip.id
            let ds = dataService
            Task.detached(priority: .utility) {
                await ds.deleteFailedQueueEntries(for: tripId)
            }
        }
        .task(id: hasPending) {
            guard hasPending else { return }
            let deadline = Date.now.addingTimeInterval(Self.pollingTimeoutSeconds)
            while !Task.isCancelled && Date.now < deadline {
                try? await Task.sleep(for: .seconds(5))
                await loadData()
                scheduleDismissals()
            }
            // Deadline reached — mark any remaining pending items as timed out
            // so the spinner is replaced with the "Enter Manually" fallback.
            let stuckIds = Set(parsedBookings.filter { $0.status == .pending }.map(\.id))
            if !stuckIds.isEmpty {
                withAnimation(.easeOut(duration: 0.25)) {
                    timedOutIds.formUnion(stuckIds)
                }
            }
        }
    }

    // MARK: - Actions

    private func openAddBooking() {
        guard targetDayId != nil else { return }
        showingAddBooking = true
    }

    // MARK: - Dismiss confirmed cards

    private func scheduleDismissals() {
        let confirmedIds = parsedBookings
            .filter { $0.status == .confirmed && !dismissedIds.contains($0.id) }
            .map(\.id)
        guard !confirmedIds.isEmpty else { return }

        Task {
            try? await Task.sleep(for: .seconds(2))
            withAnimation(.easeOut(duration: 0.35)) {
                dismissedIds.formUnion(confirmedIds)
            }
        }
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

        if !initialLoadComplete {
            // Silently pre-dismiss items that were already in a terminal state
            // before this screen session opened.
            // - confirmed: they flashed "Added" in a prior session; skip the replay.
            // - failed: stale errors from prior sessions are cleaned up by onDisappear,
            //   but pre-dismiss them here too so they never flash on a cold open.
            let preDismiss = Set(b.filter { $0.status == .confirmed || $0.status == .failed }.map(\.id))
            dismissedIds.formUnion(preDismiss)
            initialLoadComplete = true
        }
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
