import Foundation

/// Lightweight bridge for "trip activities have changed" events. Phase 3
/// shipped a real Supabase Realtime channel for `trip_activities` so this
/// is now a *backstop*: the AI Day Planner posts it after a successful
/// apply so the Itinerary refetches immediately on the same device,
/// without waiting for the realtime UPDATE round-trip. Realtime is the
/// canonical path for cross-device sync.
///
/// Removal candidate (Phase 7 / production gate): once the realtime
/// channel has been observed reliable in production for a release cycle,
/// drop both the post-site (`AIDayPlannerViewModel`) and the observer
/// (`TripDetailView`) — realtime will pick up the same-device case via
/// the standard subscription. Leaving in place for now to avoid a
/// regression window where same-device feedback could feel sluggish if
/// realtime is degraded.
extension Notification.Name {
    static let tripActivitiesDidChange = Notification.Name("tripActivitiesDidChange")
}

enum TripActivitiesNotificationKeys {
    /// Value is `UUID` — the trip whose activities changed. Observers should
    /// filter on this so a notification for trip A doesn't refresh trip B.
    static let tripId = "tripId"
}
