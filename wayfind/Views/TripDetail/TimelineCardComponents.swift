//
//  TimelineCardComponents.swift
//  wayfind
//
//  Shared visual primitives for timeline cards (activities + bookings):
//  the time-pin balloon, the unscheduled marker, and the card chassis
//  modifier that gives every card the same shape, padding, stripe and
//  shadow. Keeping these in one place ensures activity and booking cards
//  evolve as siblings rather than drifting visually.
//

import SwiftUI

// MARK: - Time pin (Apple-Maps callout balloon)

/// Compact rounded balloon with a right-pointing tail, evoking an Apple Maps
/// callout. Renders the start time as a single-line 24-hour `HH:mm` glyph so
/// every pin in a day is the same width — a clean leading column of times.
struct TimePinView: View {
    let time: Date
    let tint: Color
    var timeZone: TimeZone = .current

    private static let tailSize: CGFloat = 5
    private static let cornerRadius: CGFloat = 8

    var body: some View {
        Text(hourMinuteString(time, timeZone: timeZone))
            .font(.appSmall.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(AppColors.textPrimary)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.leading, 8)
            .padding(.trailing, 8 + Self.tailSize)
            .padding(.vertical, 5)
            .background(
                BalloonShape(tailSize: Self.tailSize, cornerRadius: Self.cornerRadius)
                    .fill(tint.opacity(0.16))
            )
            .overlay(
                BalloonShape(tailSize: Self.tailSize, cornerRadius: Self.cornerRadius)
                    .strokeBorder(tint.opacity(0.4), lineWidth: 0.6)
            )
    }
}

/// Quiet anchor for stops with no scheduled time — a small family-tinted dot
/// padded so its width approximates a `TimePinView` and the leading edge of
/// the day stays vertically aligned.
struct UnscheduledMarkerView: View {
    let tint: Color

    var body: some View {
        Circle()
            .fill(tint.opacity(0.55))
            .frame(width: 8, height: 8)
            .padding(.horizontal, 14)
    }
}

/// Rounded-rectangle balloon with a small triangular tail centered on the
/// trailing edge — like an iMessage bubble pointing right into the card.
struct BalloonShape: InsettableShape {
    var tailSize: CGFloat
    var cornerRadius: CGFloat
    var insetAmount: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: insetAmount, dy: insetAmount)
        let bodyRect = CGRect(
            x: r.minX,
            y: r.minY,
            width: max(0, r.width - tailSize),
            height: r.height
        )
        var path = Path(roundedRect: bodyRect, cornerRadius: cornerRadius, style: .continuous)

        let tipY = bodyRect.midY
        path.move(to: CGPoint(x: bodyRect.maxX, y: tipY - tailSize))
        path.addLine(to: CGPoint(x: bodyRect.maxX + tailSize, y: tipY))
        path.addLine(to: CGPoint(x: bodyRect.maxX, y: tipY + tailSize))
        path.closeSubpath()

        return path
    }

    func inset(by amount: CGFloat) -> some InsettableShape {
        var copy = self
        copy.insetAmount += amount
        return copy
    }
}

// MARK: - Card chassis

/// Wraps timeline card content in the shared chassis: a 3pt family-tinted
/// leading stripe, the standard padding, surface color, corner radius and
/// shadow. Both `TimelinePlaceCardView` and `TimelineBookingCardView` apply
/// this so they read as siblings differentiated by *content*, not by layout.
struct TimelineCardChassis: ViewModifier {
    let stripeColor: Color

    func body(content: Content) -> some View {
        HStack(alignment: .top, spacing: 0) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(stripeColor)
                .frame(width: 3)

            content
                .padding(AppSpacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(AppColors.appSurface)
        .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous))
        .shadow(color: Color.black.opacity(0.06), radius: 4, x: 0, y: 2)
    }
}

extension View {
    /// Apply the standard timeline-card chassis (stripe, padding, surface,
    /// corner radius, shadow). Pass the family color used for the stripe.
    func timelineCardChassis(stripeColor: Color) -> some View {
        modifier(TimelineCardChassis(stripeColor: stripeColor))
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


// =============================================================================

#if DEBUG
#Preview("Time pin variants") {
    VStack(spacing: 12) {
        TimePinView(time: Date(), tint: .blue)
        TimePinView(time: Date(), tint: .orange)
        UnscheduledMarkerView(tint: .purple)
    }
    .padding()
    .background(AppColors.appBackground)
}
#endif
