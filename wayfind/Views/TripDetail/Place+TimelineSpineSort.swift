import Foundation

extension Place {
    /// Wall-clock instant used to **order** timeline rows; matches
    /// `TimelineBookingCardView` / `TimelinePlaceCardView` spine times for
    /// stored data (flight uses `FlightDetails.departureTime` only — no live
    /// status override, so list order stays stable).
    func timelineSpineSortInstant(
        hotelTimelineRole: HotelTimelineDisplayRole? = nil,
        carRentalTimelineRole: CarRentalTimelineDisplayRole? = nil
    ) -> Date? {
        // Split hotel / car legs: use the leg-specific instant, not the generic `startTime`.
        if isBooking {
            if case .hotel(let h) = bookingDetails, let role = hotelTimelineRole {
                switch role {
                case .checkIn: return h.checkInDate ?? startTime
                case .checkOut: return h.checkOutDate ?? startTime
                }
            }
            if case .carRental(let r) = bookingDetails, let role = carRentalTimelineRole {
                switch role {
                case .pickup: return r.pickupTime ?? startTime
                case .dropoff: return r.dropoffTime ?? r.pickupTime ?? startTime
                }
            }
        }

        if let start = startTime { return start }

        guard isBooking else { return nil }

        switch bookingDetails {
        case .flight(let details):
            return details.departureTime
        case .hotel(let hotel):
            return hotel.checkInDate
        case .restaurant(let restaurant):
            return restaurant.reservationTime
        case .carRental(let rental):
            return rental.pickupTime
        case .transport(let transport):
            return transport.departureTime
        case .activity, nil:
            return nil
        }
    }
}
