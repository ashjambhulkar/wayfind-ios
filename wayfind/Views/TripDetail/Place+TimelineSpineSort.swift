import Foundation

extension Place {
    /// Wall-clock instant used to **order** timeline rows; matches
    /// `TimelineBookingCardView` / `TimelinePlaceCardView` spine times for
    /// stored data (flight uses `FlightDetails.departureTime` only — no live
    /// status override, so list order stays stable).
    func timelineSpineSortInstant(hotelTimelineRole: HotelTimelineDisplayRole?) -> Date? {
        if let start = startTime { return start }

        guard isBooking else { return nil }

        switch bookingDetails {
        case .flight(let details):
            return details.departureTime
        case .hotel(let hotel):
            if hotelTimelineRole == .checkOut {
                return hotel.checkOutDate
            }
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
