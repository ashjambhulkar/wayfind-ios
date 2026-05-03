import SwiftUI

// MARK: - Category chroma

/// Muted, category-specific colors for activity node pins and card stripe accents.
/// Replaces the time-of-day system for place cards so the palette identifies category
/// at a glance without decorating the whole screen.
enum TimelineCategoryChroma {
    /// Deep muted fill for the spine pin circle — white icon stays readable in both modes.
    static func pinColor(for category: PlaceCategory) -> Color {
        switch category {
        case .restaurant, .nightlife: return AppColors.timelineCategoryFoodPin
        case .shopping:               return AppColors.timelineCategoryMarketPin
        case .attraction:             return AppColors.timelineCategoryCulturePin
        case .hotel:                  return AppColors.timelineCategoryStayPin
        case .nature:                 return AppColors.timelineCategoryNaturePin
        case .transport, .custom:     return AppColors.timelineCategoryTransitPin
        }
    }

    /// Pale tint in light mode, matching deep muted in dark mode — used for the 4pt card stripe rail.
    static func stripeColor(for category: PlaceCategory) -> Color {
        switch category {
        case .restaurant, .nightlife: return AppColors.timelineCategoryFoodStripe
        case .shopping:               return AppColors.timelineCategoryMarketStripe
        case .attraction:             return AppColors.timelineCategoryCultureStripe
        case .hotel:                  return AppColors.timelineCategoryStayStripe
        case .nature:                 return AppColors.timelineCategoryNatureStripe
        case .transport, .custom:     return AppColors.timelineCategoryTransitStripe
        }
    }
}

// MARK: - Schedule chroma (time-of-day — used by booking cards)

/// Spine, stripe, and leading accents on the trip timeline encode **local time of day**, not category.
/// No schedule → neutral (“flexible”); issue is reserved for future conflict/closed-state detection.
enum TimelineScheduleChroma {
    enum TimeOfDayTone: Equatable {
        case morning
        case afternoon
        case evening
        case night
        case flexible
        case issue
    }

    /// Local wall-clock buckets in `timeZone`:
    /// 05:00–11:59 morning, 12:00–16:59 afternoon, 17:00–20:59 evening, 21:00–04:59 night.
    static func tone(scheduleInstant: Date?, timeZone: TimeZone) -> TimeOfDayTone {
        guard let scheduleInstant else { return .flexible }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let hour = calendar.component(.hour, from: scheduleInstant)
        switch hour {
        case 5..<12: return .morning
        case 12..<17: return .afternoon
        case 17..<21: return .evening
        default: return .night
        }
    }

    static func accentColor(scheduleInstant: Date?, timeZone: TimeZone) -> Color {
        switch tone(scheduleInstant: scheduleInstant, timeZone: timeZone) {
        case .morning: return AppColors.timelineScheduleMorning
        case .afternoon: return AppColors.timelineScheduleAfternoon
        case .evening: return AppColors.timelineScheduleEvening
        case .night: return AppColors.timelineScheduleNight
        case .flexible: return AppColors.timelineScheduleFlexible
        case .issue: return AppColors.timelineScheduleIssue
        }
    }

    /// Softer semantic fill for the spine pin circle/teardrop. The stronger
    /// accent stays available for card rails and leading icons.
    static func spinePinColor(scheduleInstant: Date?, timeZone: TimeZone) -> Color {
        switch tone(scheduleInstant: scheduleInstant, timeZone: timeZone) {
        case .morning: return AppColors.timelineScheduleMorningMuted
        case .afternoon: return AppColors.timelineScheduleAfternoonMuted
        case .evening: return AppColors.timelineScheduleEveningMuted
        case .night: return AppColors.timelineScheduleNightMuted
        case .flexible: return AppColors.timelineScheduleFlexibleMuted
        case .issue: return AppColors.timelineScheduleIssueMuted
        }
    }

    /// VoiceOver suffix aligned with tinted chrome (timeline encodes time of day).
    static func accessibilitySchedulingBucket(scheduleInstant: Date?, timeZone: TimeZone) -> String {
        switch tone(scheduleInstant: scheduleInstant, timeZone: timeZone) {
        case .morning: return String(localized: "Morning time")
        case .afternoon: return String(localized: "Afternoon time")
        case .evening: return String(localized: "Evening time")
        case .night: return String(localized: "Night time")
        case .flexible: return String(localized: "Flexible time")
        case .issue: return String(localized: "Schedule issue")
        }
    }
}
