import SwiftUI

/// Coarse buckets used to chapter a day's timeline. Boundaries roughly mirror
/// how a traveler narrates their day (breakfast vs lunch vs dinner vs late
/// night) without splitting hairs over arbitrary clock minutes.
enum TimeOfDayChapter: String, CaseIterable {
    case morning, afternoon, evening, night

    var title: String {
        switch self {
        case .morning: "Morning"
        case .afternoon: "Afternoon"
        case .evening: "Evening"
        case .night: "Night"
        }
    }

    var icon: String {
        switch self {
        case .morning: "sun.horizon.fill"
        case .afternoon: "sun.max.fill"
        case .evening: "sunset.fill"
        case .night: "moon.stars.fill"
        }
    }

    var tint: Color {
        switch self {
        case .morning: Color(red: 0.95, green: 0.75, blue: 0.45)
        case .afternoon: Color(red: 0.95, green: 0.62, blue: 0.30)
        case .evening: Color(red: 0.85, green: 0.45, blue: 0.55)
        case .night: Color(red: 0.40, green: 0.45, blue: 0.70)
        }
    }

    /// Buckets `5–11`, `12–16`, `17–21`, `22–4`. Returns `nil` when the date is
    /// `nil` (unscheduled stops) so callers can skip rendering a chapter.
    static func from(_ date: Date?, timeZone: TimeZone = .current) -> TimeOfDayChapter? {
        guard let date else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let hour = cal.component(.hour, from: date)
        switch hour {
        case 5..<12: return .morning
        case 12..<17: return .afternoon
        case 17..<22: return .evening
        default: return .night
        }
    }
}

/// Soft chapter break inserted into the day timeline whenever the time-of-day
/// bucket changes. Keeps the day reading as a story (morning → afternoon →
/// evening) rather than a uniform list of stops.
struct TimeOfDayDividerView: View {
    let chapter: TimeOfDayChapter

    var body: some View {
        HStack(spacing: AppSpacing.sm) {
            HStack(spacing: 6) {
                Image(systemName: chapter.icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(chapter.tint)
                Text(chapter.title.uppercased())
                    .font(.appSmall)
                    .tracking(0.8)
                    .foregroundStyle(AppColors.textTertiary)
            }
            .fixedSize(horizontal: true, vertical: false)

            Rectangle()
                .fill(AppColors.appDivider)
                .frame(height: 1)
        }
        .padding(.horizontal, AppSpacing.lg)
        .padding(.top, AppSpacing.md)
        .padding(.bottom, AppSpacing.xs)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(chapter.title)
        .accessibilityAddTraits(.isHeader)
    }
}


// =============================================================================
