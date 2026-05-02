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

// MARK: - Apple Maps–style double teardrop (timeline spine)

/// Visual constants for map-pin style chips on the itinerary spine (circle + top/bottom tails).
private enum MapsStyleTimelinePinMetrics {
    static let shadowOpacityTight: Double = 0.07
    static let shadowOpacitySoft: Double = 0.14
    static let shadowRadiusSoft: CGFloat = 10
    static let shadowYOffsetSoft: CGFloat = 4

    static var bodyRadius: CGFloat { TimelineSpineMetrics.timePinBodyRadius }
    static var tailLength: CGFloat { TimelineSpineMetrics.timePinTailLength }
    static var pinFrameWidth: CGFloat { TimelineSpineMetrics.timePinFrameWidth }
    static var pinFrameHeight: CGFloat { TimelineSpineMetrics.timePinFrameHeight }

    /// Horizontal inset for clock / “Flex” label inside the teardrop body.
    static let timeLabelHorizontalInset: CGFloat = AppSpacing.xs
}

/// Circular body with symmetric top + bottom tangent tails (spine rail).
/// Tail tips are slightly blunt so their width never drops below the spine stroke — avoids hairline seams.
private struct DoubleTeardropSpinePinShape: InsettableShape {
    var bodyRadius: CGFloat
    var tailLength: CGFloat
    /// Horizontal half-width of the flat at each tail tip (`TimelineSpineMetrics.teardropTailTipHalfWidth`).
    var tailTipHalfWidth: CGFloat
    var insetAmount: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let box = rect.insetBy(dx: insetAmount, dy: insetAmount)
        guard box.width > 4, box.height > 4, bodyRadius >= 1, tailLength >= 0 else { return path }

        let cx = box.midX
        let cy = box.midY
        let r = bodyRadius
        let vtl = tailLength
        let tipHW = max(0, tailTipHalfWidth)
        let distV = r + vtl
        let cosGammaV = min(1, max(-1, r / distV))
        let gammaV = CGFloat(acos(Double(cosGammaV)))

        let yTop = cy - r - vtl
        let yBottom = cy + r + vtl

        func pointOnCircle(_ angle: CGFloat) -> CGPoint {
            CGPoint(x: cx + r * cos(angle), y: cy + r * sin(angle))
        }

        let upperRight = -CGFloat.pi / 2 + gammaV
        let lowerRight = CGFloat.pi / 2 - gammaV
        let lowerLeft = CGFloat.pi / 2 + gammaV
        let upperLeft = -CGFloat.pi / 2 - gammaV

        path.move(to: CGPoint(x: cx - tipHW, y: yTop))
        path.addLine(to: CGPoint(x: cx + tipHW, y: yTop))
        path.addLine(to: pointOnCircle(upperRight))
        path.addArc(
            center: CGPoint(x: cx, y: cy),
            radius: r,
            startAngle: Angle(radians: Double(upperRight)),
            endAngle: Angle(radians: Double(lowerRight)),
            clockwise: true
        )
        path.addLine(to: CGPoint(x: cx + tipHW, y: yBottom))
        path.addLine(to: CGPoint(x: cx - tipHW, y: yBottom))
        path.addLine(to: pointOnCircle(lowerLeft))
        path.addArc(
            center: CGPoint(x: cx, y: cy),
            radius: r,
            startAngle: Angle(radians: Double(lowerLeft)),
            endAngle: Angle(radians: Double(upperLeft)),
            clockwise: false
        )
        path.addLine(to: CGPoint(x: cx - tipHW, y: yTop))
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
    /// Teardrop shell (spine tails only) filled with the row accent; layered shadow.
    func mapsStyleTimelineDoubleTeardropPinChrome(
        bodyRadius: CGFloat,
        tailLength: CGFloat,
        bodyAccent: Color?
    ) -> some View {
        let shape = DoubleTeardropSpinePinShape(
            bodyRadius: bodyRadius,
            tailLength: tailLength,
            tailTipHalfWidth: TimelineSpineMetrics.teardropTailTipHalfWidth
        )
        let fillColor = bodyAccent ?? AppColors.appSurface
        return self
            .background {
                ZStack {
                    // Underfill guarantees the clock “hub” stays solid even if the teardrop path
                    // winding ever fails to cover the disc after path tweaks (blunt tails, etc.).
                    Circle()
                        .fill(fillColor)
                        .frame(width: bodyRadius * 2, height: bodyRadius * 2)
                    shape.fill(fillColor)
                }
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

/// Map-style spine pin with 12-hour clock and meridiem stacked in the body; geometry follows `TimelineSpineMetrics`.
/// The teardrop fill matches the row’s category/booking tint; labels use light type for contrast on the accent.
struct TimePinView: View {
    let time: Date
    let tint: Color
    var timeZone: TimeZone = .current

    private var pinWidth: CGFloat { MapsStyleTimelinePinMetrics.pinFrameWidth }
    private var pinHeight: CGFloat { MapsStyleTimelinePinMetrics.pinFrameHeight }
    private var bodyRadius: CGFloat { MapsStyleTimelinePinMetrics.bodyRadius }
    private var tailLength: CGFloat { MapsStyleTimelinePinMetrics.tailLength }

    var body: some View {
        ZStack {
            Color.clear
                .frame(width: pinWidth, height: pinHeight)
                .mapsStyleTimelineDoubleTeardropPinChrome(
                    bodyRadius: bodyRadius,
                    tailLength: tailLength,
                    bodyAccent: tint
                )
            VStack(spacing: 0) {
                Text(TimePinClockFormatting.hourMinuteString(time, timeZone: timeZone))
                    .font(.appSmall.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(AppColors.iconOnColoredSurface)
                    .lineLimit(1)
                    .minimumScaleFactor(0.68)
                Text(TimePinClockFormatting.meridiemString(time, timeZone: timeZone))
                    .font(.appSmall.weight(.regular))
                    .foregroundStyle(AppColors.iconOnColoredSurface.opacity(0.88))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
            .multilineTextAlignment(.center)
            .padding(.horizontal, MapsStyleTimelinePinMetrics.timeLabelHorizontalInset)
            .shadow(color: .black.opacity(0.22), radius: 0, x: 0, y: 0.5)
        }
        .frame(width: pinWidth, height: pinHeight)
    }
}

/// Flex marker — same silhouette as `TimePinView` (label only, no icon).
struct UnscheduledMarkerView: View {
    let tint: Color

    private var pinWidth: CGFloat { MapsStyleTimelinePinMetrics.pinFrameWidth }
    private var pinHeight: CGFloat { MapsStyleTimelinePinMetrics.pinFrameHeight }
    private var bodyRadius: CGFloat { MapsStyleTimelinePinMetrics.bodyRadius }
    private var tailLength: CGFloat { MapsStyleTimelinePinMetrics.tailLength }

    var body: some View {
        ZStack {
            Color.clear
                .frame(width: pinWidth, height: pinHeight)
                .mapsStyleTimelineDoubleTeardropPinChrome(
                    bodyRadius: bodyRadius,
                    tailLength: tailLength,
                    bodyAccent: tint
                )
            Text(String(localized: "Flex"))
                .font(.appSmall.weight(.medium))
                .foregroundStyle(AppColors.iconOnColoredSurface.opacity(0.95))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .multilineTextAlignment(.center)
                .padding(.horizontal, MapsStyleTimelinePinMetrics.timeLabelHorizontalInset)
                .shadow(color: .black.opacity(0.22), radius: 0, x: 0, y: 0.5)
        }
        .frame(width: pinWidth, height: pinHeight)
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

/// Start-time pin (`TimePinView`) or Flex marker — symmetric teardrop on the spine rail,
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
        .padding(.top, TimelineSpineMetrics.timePinColumnTopPadding)
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
