//
//  TimelineCardComponents.swift
//  wayfind
//
//  Shared visual primitives for timeline cards (activities + bookings):
//  the map-style spine time pin (rail), the Flex marker, and the card chassis
//  modifier that gives every card the same shape, padding, stripe and
//  shadow. Keeping these in one place ensures activity and booking cards
//  evolve as siblings rather than drifting visually.
//

import SwiftUI

// MARK: - Timeline spine marker

/// Visual constants for circular chips on the itinerary spine.
private enum TimelineSpinePinMetrics {
    static let shadowOpacityTight: Double = 0.07
    static let shadowOpacitySoft: Double = 0.14
    static let shadowRadiusSoft: CGFloat = 10
    static let shadowYOffsetSoft: CGFloat = 4

    static var bodyRadius: CGFloat { TimelineSpineMetrics.timePinBodyRadius }
    static var tailLength: CGFloat { TimelineSpineMetrics.timePinTailLength }
    static var pinFrameWidth: CGFloat { TimelineSpineMetrics.timePinFrameWidth }
    static var pinFrameHeight: CGFloat { TimelineSpineMetrics.timePinFrameHeight }

    /// Horizontal inset for clock / “Flex” fallback labels inside the circle.
    static let timeLabelHorizontalInset: CGFloat = AppSpacing.xs
}

/// Lower point for an Apple Maps-style callout pin. It is layered under the
/// circular body so the marker reads as a clean circle with a tucked tail.
private struct AppleMapsCalloutTailShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

private extension View {
    /// Apple Maps-style pin shell filled with the row accent; layered shadow.
    func timelineCalloutPinChrome(
        bodyRadius: CGFloat,
        tailLength: CGFloat,
        bodyAccent: Color?
    ) -> some View {
        let fillColor = bodyAccent ?? AppColors.appSurface
        let bodySide = bodyRadius * 2
        let tailWidth = max(8, bodySide * 0.22)
        let dotSide = max(5, bodySide * 0.16)
        return self
            .background {
                ZStack(alignment: .top) {
                    AppleMapsCalloutTailShape()
                        .fill(fillColor)
                        .frame(width: tailWidth, height: tailLength + 3)
                        .offset(y: bodySide * 0.72)

                    Circle()
                        .fill(fillColor)
                        .frame(width: dotSide, height: dotSide)
                        .offset(y: bodySide + tailLength - 5)

                    Circle()
                        .fill(fillColor)
                        .frame(width: bodySide, height: bodySide)
                }
                .frame(width: bodySide, height: bodySide + tailLength + 5, alignment: .top)
            }
            .shadow(color: Color.black.opacity(TimelineSpinePinMetrics.shadowOpacityTight), radius: 1, x: 0, y: 1)
            .shadow(
                color: Color.black.opacity(TimelineSpinePinMetrics.shadowOpacitySoft),
                radius: TimelineSpinePinMetrics.shadowRadiusSoft,
                x: 0,
                y: TimelineSpinePinMetrics.shadowYOffsetSoft
            )
    }
}

/// 12-hour parts for the spine time pin (clock line + meridiem); respects `timeZone` and current locale.
private enum TimePinClockFormatting {
    private static let hourMinute: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm"
        formatter.locale = .autoupdatingCurrent
        return formatter
    }()

    private static let meridiem: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "a"
        formatter.locale = .autoupdatingCurrent
        return formatter
    }()

    static func hourMinuteString(_ date: Date, timeZone: TimeZone) -> String {
        hourMinute.timeZone = timeZone
        return hourMinute.string(from: date)
    }

    static func meridiemString(_ date: Date, timeZone: TimeZone) -> String {
        meridiem.timeZone = timeZone
        return meridiem.string(from: date)
    }
}

/// Circular spine pin. Activity/booking rows pass a category symbol; legacy
/// callers without a symbol fall back to the previous clock label.
struct TimePinView: View {
    let time: Date
    let tint: Color
    var symbol: String?
    var timeZone: TimeZone = .current

    private var pinWidth: CGFloat { TimelineSpinePinMetrics.pinFrameWidth }
    private var pinHeight: CGFloat { TimelineSpinePinMetrics.pinFrameHeight }
    private var bodyRadius: CGFloat { TimelineSpinePinMetrics.bodyRadius }
    private var tailLength: CGFloat { TimelineSpinePinMetrics.tailLength }
    private var iconCenterYOffset: CGFloat { bodyRadius - pinHeight / 2 }

    var body: some View {
        ZStack {
            Color.clear
                .frame(width: pinWidth, height: pinHeight)
                .timelineCalloutPinChrome(
                    bodyRadius: bodyRadius,
                    tailLength: tailLength,
                    bodyAccent: tint
                )
            if let symbol {
                Image(systemName: symbol)
                    .font(.appCaption.weight(.bold))
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(AppColors.iconOnColoredSurface)
                    .accessibilityHidden(true)
                    .offset(y: iconCenterYOffset)
            } else {
                VStack(spacing: 0) {
                    Text(TimePinClockFormatting.hourMinuteString(time, timeZone: timeZone))
                        .font(.appSmall.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(AppColors.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.68)
                    Text(TimePinClockFormatting.meridiemString(time, timeZone: timeZone))
                        .font(.timelinePinMeridiem)
                        .foregroundStyle(AppColors.textPrimary.opacity(0.78))
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                }
                .multilineTextAlignment(.center)
                .padding(.horizontal, TimelineSpinePinMetrics.timeLabelHorizontalInset)
                .offset(y: iconCenterYOffset)
            }
        }
        .frame(width: pinWidth, height: pinHeight)
    }
}

/// Flex marker — same circular silhouette as `TimePinView`.
struct UnscheduledMarkerView: View {
    let tint: Color
    var symbol: String?

    private var pinWidth: CGFloat { TimelineSpinePinMetrics.pinFrameWidth }
    private var pinHeight: CGFloat { TimelineSpinePinMetrics.pinFrameHeight }
    private var bodyRadius: CGFloat { TimelineSpinePinMetrics.bodyRadius }
    private var tailLength: CGFloat { TimelineSpinePinMetrics.tailLength }
    private var iconCenterYOffset: CGFloat { bodyRadius - pinHeight / 2 }

    var body: some View {
        ZStack {
            Color.clear
                .frame(width: pinWidth, height: pinHeight)
                .timelineCalloutPinChrome(
                    bodyRadius: bodyRadius,
                    tailLength: tailLength,
                    bodyAccent: tint
                )
            if let symbol {
                Image(systemName: symbol)
                    .font(.appCaption.weight(.bold))
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(AppColors.iconOnColoredSurface)
                    .accessibilityHidden(true)
                    .offset(y: iconCenterYOffset)
            } else {
                Text(String(localized: "Flex"))
                    .font(.appSmall.weight(.medium))
                    .foregroundStyle(AppColors.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, TimelineSpinePinMetrics.timeLabelHorizontalInset)
                    .offset(y: iconCenterYOffset)
            }
        }
        .frame(width: pinWidth, height: pinHeight)
        .accessibilityLabel(String(localized: "Flex"))
    }
}

// MARK: - Card chassis

/// Shared timeline row layout tokens (activity + booking pass bodies).
enum TimelineCardLayoutMetrics {
    static let contentHorizontalPadding: CGFloat = AppSpacing.sm
    static let contentVerticalPadding: CGFloat = AppSpacing.sm

    /// Raised timeline cards — soften shadow footprint so stacks read closer than before.
    static let cardShadowOpacity: Double = 0.048
    static let cardShadowRadius: CGFloat = 5
    static let cardShadowYOffset: CGFloat = 2
}

/// Wraps timeline card content in the shared chassis: a slim family-tinted
/// top rail, the standard padding, surface color, corner radius and shadow.
/// Both `TimelinePlaceCardView` and `TimelineBookingCardView` apply this so
/// they read as siblings differentiated by *content*, not by layout.
private struct TimelineCardChassisModifier: ViewModifier {
    let stripeColor: Color
    var showsTopRail: Bool = true
    /// Default matches older list-style cards; timeline activities/bookings pass `TimelineCardLayoutMetrics` insets.
    var horizontalContentPadding: CGFloat = AppSpacing.lg
    var verticalContentPadding: CGFloat = AppSpacing.lg

    func body(content: Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsTopRail {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(stripeColor)
                    .frame(height: 4)
            }

            content
                .padding(.horizontal, horizontalContentPadding)
                .padding(.vertical, verticalContentPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(AppColors.appSurface)
        .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous)
                .strokeBorder(AppColors.appDivider, lineWidth: 0.6)
        }
        .shadow(
            color: Color.black.opacity(TimelineCardLayoutMetrics.cardShadowOpacity),
            radius: TimelineCardLayoutMetrics.cardShadowRadius,
            x: 0,
            y: TimelineCardLayoutMetrics.cardShadowYOffset
        )
    }
}

extension View {
    /// Apply the standard timeline-card chassis (stripe, padding, surface,
    /// corner radius, shadow). Pass the family color used for the stripe.
    func timelineCardChassis(
        stripeColor: Color,
        showsTopRail: Bool = true,
        horizontalContentPadding: CGFloat = AppSpacing.lg,
        verticalContentPadding: CGFloat = AppSpacing.lg
    ) -> some View {
        modifier(
            TimelineCardChassisModifier(
                stripeColor: stripeColor,
                showsTopRail: showsTopRail,
                horizontalContentPadding: horizontalContentPadding,
                verticalContentPadding: verticalContentPadding
            )
        )
    }
}

// MARK: - Helpers

struct TimelineCardTimeChip: View {
    let start: Date?
    let end: Date?
    let tint: Color
    var timeZone: TimeZone = .current

    var body: some View {
        Label(timeText, systemImage: start == nil ? "sparkles" : "clock.fill")
            .font(.appSmall.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(AppColors.textSecondary)
            .lineLimit(1)
            .padding(.horizontal, AppSpacing.sm)
            .padding(.vertical, AppSpacing.xs)
            .background(tint.opacity(0.12), in: Capsule())
            .overlay {
                Capsule()
                    .strokeBorder(tint.opacity(0.22), lineWidth: 0.6)
            }
    }

    private var timeText: String {
        guard let start else { return String(localized: "Flexible") }
        guard let end, end > start else {
            return start.timeFormatted(timeZone: timeZone)
        }
        return "\(start.timeFormatted(timeZone: timeZone)) – \(end.timeFormatted(timeZone: timeZone))"
    }
}

struct TimelineCardTimeText: View {
    let start: Date?
    let end: Date?
    var timeZone: TimeZone = .current

    var body: some View {
        Text(timeText)
            .font(.appSmall.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(AppColors.textSecondary)
            .lineLimit(1)
    }

    private var timeText: String {
        guard let start else { return String(localized: "Flexible") }
        guard let end, end > start else {
            return start.timeFormatted(timeZone: timeZone)
        }
        return "\(start.timeFormatted(timeZone: timeZone)) – \(end.timeFormatted(timeZone: timeZone))"
    }
}

/// Start-time pin (`TimePinView`) or Flex marker — circular stop on the spine rail,
/// aligned with `timelineSpineContinuousRail()` for a continuous “rail + stops” read.
struct TimelineSpineTimeColumn: View {
    let startTime: Date?
    let accentColor: Color
    var symbol: String?
    var timeZone: TimeZone = .current
    let accessibilityLabel: String

    var body: some View {
        VStack(alignment: .center, spacing: 0) {
            if let startTime {
                TimePinView(time: startTime, tint: accentColor, symbol: symbol, timeZone: timeZone)
            } else {
                UnscheduledMarkerView(tint: accentColor, symbol: symbol)
            }
        }
        .offset(x: -TimelineSpineMetrics.spineCenterlineNudgeLeft)
        .frame(width: TimelineSpineMetrics.columnWidth, alignment: .center)
        .padding(.top, TimelineSpineMetrics.timePinColumnTopPadding)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }
}

// =============================================================================

#if DEBUG
#Preview("Time pin — circle") {
    VStack(spacing: 12) {
        TimePinView(time: Date(), tint: .blue, symbol: "star.fill")
        TimePinView(time: Date(), tint: .orange)
        UnscheduledMarkerView(tint: .purple, symbol: "fork.knife")
    }
    .padding()
    .background(AppColors.appBackground)
}
#endif
