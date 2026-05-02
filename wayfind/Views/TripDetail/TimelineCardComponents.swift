//
//  TimelineCardComponents.swift
//  wayfind
//
//  Shared visual primitives for timeline cards (activities + bookings):
//  the double-teardrop spine time pin, the unscheduled marker, and the card chassis
//  modifier that gives every card the same shape, padding, stripe and
//  shadow. Keeping these in one place ensures activity and booking cards
//  evolve as siblings rather than drifting visually.
//

import SwiftUI

// MARK: - Apple Maps–style double teardrop (timeline spine)

/// Visual constants for symmetric map-pin style chips on the itinerary spine (circle + top/bottom points).
private enum MapsStyleTimelinePinMetrics {
    static let borderOpacity: Double = 0.5
    static let borderLineWidth: CGFloat = 0.5
    static let shadowOpacityTight: Double = 0.07
    static let shadowOpacitySoft: Double = 0.14
    static let shadowRadiusSoft: CGFloat = 10
    static let shadowYOffsetSoft: CGFloat = 4
    /// Length of each tangent “tail” beyond the circular body (see `DoubleTeardropSpinePinShape`).
    static let tailLength: CGFloat = 5
    static var pinFrameSide: CGFloat { TimelineSpineMetrics.timePinCircleDiameter }
    /// Extra diameter so the inner disc reads slightly larger than the strict body circle (more air around the label).
    static let bodyDiscExpansion: CGFloat = 5
    /// Diameter of the inner disc over the teardrop body (slightly expanded; fill matches `appSurface`).
    static var bodyDiscDiameter: CGFloat { pinFrameSide - 2 * tailLength + bodyDiscExpansion }
    static let timeLabelHorizontalInset: CGFloat = 3
}

/// Circular body with symmetric top + bottom tangent points (Apple Maps pin geometry, mirrored vertically for the rail).
private struct DoubleTeardropSpinePinShape: InsettableShape {
    var tailLength: CGFloat
    var insetAmount: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let box = rect.insetBy(dx: insetAmount, dy: insetAmount)
        guard box.width > 4, box.height > 4, tailLength >= 0 else { return path }

        let cx = box.midX
        let cy = box.midY
        let side = min(box.width, box.height)
        let tl = min(tailLength, max(0, (side - 4) / 4))
        let bodyRadius = max(1, (side - 2 * tl) / 2)
        let dist = bodyRadius + tl
        let cosGamma = min(1, max(-1, bodyRadius / dist))
        let gamma = CGFloat(acos(Double(cosGamma)))

        let topTip = CGPoint(x: cx, y: cy - bodyRadius - tl)
        let bottomTip = CGPoint(x: cx, y: cy + bodyRadius + tl)

        func pointOnCircle(_ angle: CGFloat) -> CGPoint {
            CGPoint(x: cx + bodyRadius * cos(angle), y: cy + bodyRadius * sin(angle))
        }

        /// Tangent where a line from the top tip meets the circle (upper-right quadrant edge).
        let upperRight: CGFloat = -.pi / 2 + gamma
        /// Lower-right tangent (lower-right quadrant).
        let lowerRight: CGFloat = .pi / 2 - gamma
        let lowerLeft: CGFloat = .pi / 2 + gamma
        let upperLeft: CGFloat = -.pi / 2 - gamma

        path.move(to: topTip)
        path.addLine(to: pointOnCircle(upperRight))
        path.addArc(
            center: CGPoint(x: cx, y: cy),
            radius: bodyRadius,
            startAngle: Angle(radians: Double(upperRight)),
            endAngle: Angle(radians: Double(lowerRight)),
            clockwise: true
        )
        path.addLine(to: bottomTip)
        path.addLine(to: pointOnCircle(lowerLeft))
        path.addArc(
            center: CGPoint(x: cx, y: cy),
            radius: bodyRadius,
            startAngle: Angle(radians: Double(lowerLeft)),
            endAngle: Angle(radians: Double(upperLeft)),
            clockwise: false
        )
        path.addLine(to: topTip)
        path.closeSubpath()
        return path
    }

    func inset(by amount: CGFloat) -> DoubleTeardropSpinePinShape {
        var copy = self
        copy.insetAmount += amount
        return copy
    }
}

private extension View {
    /// Elevated double-teardrop fill + hairline + layered shadow (Apple Maps pin silhouette on the spine).
    func mapsStyleTimelineDoubleTeardropPinChrome(tailLength: CGFloat) -> some View {
        let strokeColor = AppColors.appDivider.opacity(MapsStyleTimelinePinMetrics.borderOpacity)
        let shape = DoubleTeardropSpinePinShape(tailLength: tailLength)
        return self
            .background {
                shape.fill(AppColors.appSurface)
            }
            .overlay {
                shape.strokeBorder(strokeColor, lineWidth: MapsStyleTimelinePinMetrics.borderLineWidth)
            }
            .shadow(color: Color.black.opacity(MapsStyleTimelinePinMetrics.shadowOpacityTight), radius: 1, x: 0, y: 1)
            .shadow(
                color: Color.black.opacity(MapsStyleTimelinePinMetrics.shadowOpacitySoft),
                radius: MapsStyleTimelinePinMetrics.shadowRadiusSoft,
                x: 0,
                y: MapsStyleTimelinePinMetrics.shadowYOffsetSoft
            )
    }
}

/// Double-teardrop pin with centered `HH:mm`; fits in `timePinCircleDiameter` with tangent tails top/bottom.
/// `tint` is kept for API compatibility (category color stays on the card).
struct TimePinView: View {
    let time: Date
    let tint: Color
    var timeZone: TimeZone = .current

    private var pinSize: CGFloat { MapsStyleTimelinePinMetrics.pinFrameSide }
    private var tailLength: CGFloat { MapsStyleTimelinePinMetrics.tailLength }
    private var bodyDiscDiameter: CGFloat { MapsStyleTimelinePinMetrics.bodyDiscDiameter }

    var body: some View {
        ZStack {
            Color.clear
                .frame(width: pinSize, height: pinSize)
                .mapsStyleTimelineDoubleTeardropPinChrome(tailLength: tailLength)
            Circle()
                .fill(AppColors.appSurface)
                .frame(width: bodyDiscDiameter, height: bodyDiscDiameter)
            Text(hourMinuteString(time, timeZone: timeZone))
                .font(.appSmall.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(AppColors.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .multilineTextAlignment(.center)
                .padding(.horizontal, MapsStyleTimelinePinMetrics.timeLabelHorizontalInset)
        }
        .frame(width: pinSize, height: pinSize)
    }
}

/// Flex marker — same silhouette as `TimePinView` (label only, no icon).
struct UnscheduledMarkerView: View {
    let tint: Color

    private var pinSize: CGFloat { MapsStyleTimelinePinMetrics.pinFrameSide }
    private var tailLength: CGFloat { MapsStyleTimelinePinMetrics.tailLength }
    private var bodyDiscDiameter: CGFloat { MapsStyleTimelinePinMetrics.bodyDiscDiameter }

    var body: some View {
        ZStack {
            Color.clear
                .frame(width: pinSize, height: pinSize)
                .mapsStyleTimelineDoubleTeardropPinChrome(tailLength: tailLength)
            Circle()
                .fill(AppColors.appSurface)
                .frame(width: bodyDiscDiameter, height: bodyDiscDiameter)
            Text(String(localized: "Flex"))
                .font(.appSmall.weight(.medium))
                .foregroundStyle(AppColors.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .multilineTextAlignment(.center)
                .padding(.horizontal, MapsStyleTimelinePinMetrics.timeLabelHorizontalInset)
        }
        .frame(width: pinSize, height: pinSize)
        .accessibilityLabel(String(localized: "Flex"))
    }
}

// MARK: - Card chassis

/// Shared timeline row layout tokens (activity + booking pass bodies).
enum TimelineCardLayoutMetrics {
    static let contentHorizontalPadding: CGFloat = AppSpacing.md
    static let contentVerticalPadding: CGFloat = AppSpacing.md
}

/// Wraps timeline card content in the shared chassis: a slim family-tinted
/// top rail, the standard padding, surface color, corner radius and shadow.
/// Both `TimelinePlaceCardView` and `TimelineBookingCardView` apply this so
/// they read as siblings differentiated by *content*, not by layout.
struct TimelineCardChassis: ViewModifier {
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
        .shadow(color: Color.black.opacity(0.07), radius: 8, x: 0, y: 4)
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
            TimelineCardChassis(
                stripeColor: stripeColor,
                showsTopRail: showsTopRail,
                horizontalContentPadding: horizontalContentPadding,
                verticalContentPadding: verticalContentPadding
            )
        )
    }
}

// MARK: - Helpers

/// 24-hour `HH:mm` time string with leading zeros so every pin in a timeline
/// column has identical width. Locale-independent on purpose — the visual
/// timeline reads better with a single, predictable format. Locale-aware
/// strings live in accessibility labels via `Date.timeFormatted`.
func hourMinuteString(_ date: Date, timeZone: TimeZone = .current) -> String {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = timeZone
    let comps = cal.dateComponents([.hour, .minute], from: date)
    let hour = comps.hour ?? 0
    let minute = comps.minute ?? 0
    return String(format: "%02d:%02d", hour, minute)
}

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

/// Start-time pin (`TimePinView`) or Flex marker — map-style double teardrop centered on the spine column,
/// aligned with `timelineSpineContinuousRail()` for a continuous “rail + stops” read.
struct TimelineSpineTimeColumn: View {
    let startTime: Date?
    let accentColor: Color
    var timeZone: TimeZone = .current
    let accessibilityLabel: String

    var body: some View {
        VStack(alignment: .center, spacing: 0) {
            if let startTime {
                TimePinView(time: startTime, tint: accentColor, timeZone: timeZone)
            } else {
                UnscheduledMarkerView(tint: accentColor)
            }
        }
        .offset(x: -TimelineSpineMetrics.spineCenterlineNudgeLeft)
        .frame(width: TimelineSpineMetrics.columnWidth, alignment: .center)
        .padding(.top, AppSpacing.lg)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }
}

enum TimelineCardLeadingIconMetrics {
    private static let solidSquareSideLengthValue: CGFloat = 64

    /// Typography / symbol scale tier for glyphs inside the leading square (follows `solidSquareSideLength`).
    static var solidSquareSize: MapStyleIconSize {
        MapStyleIconSize.suggestedThumbnailGlyphBucket(side: solidSquareSideLengthValue)
    }

    /// Leading square — activity / booking category tile, catalog thumbnail, photo-stack tiles, and flight logo tile.
    static var solidSquareSideLength: CGFloat { solidSquareSideLengthValue }
    private static let solidSquareSymbolScale: CGFloat = 0.92

    /// Suggested-places style: flat category fill, white glyph, rounded square.
    @ViewBuilder
    static func categoryBadge(symbol: String, accent: Color, accessibilityLabel: String) -> some View {
        MapStyleIcon(
            systemName: symbol,
            size: solidSquareSize,
            accent: accent,
            backgroundStyle: .solidAccent,
            shape: .roundedRectangle,
            frameSide: solidSquareSideLength,
            symbolScale: solidSquareSymbolScale,
            accessibilityLabel: accessibilityLabel
        )
    }
}


// =============================================================================

#if DEBUG
#Preview("Time pin — double teardrop") {
    VStack(spacing: 12) {
        TimePinView(time: Date(), tint: .blue)
        TimePinView(time: Date(), tint: .orange)
        UnscheduledMarkerView(tint: .purple)
    }
    .padding()
    .background(AppColors.appBackground)
}
#endif
