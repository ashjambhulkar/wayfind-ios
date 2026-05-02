//
//  TimelineSpineRail.swift
//  wayfind
//
//  Shared spine metrics and a subtle full-height vertical rail that connects
//  time pins across itinerary rows within a day (and Ideas when present).
//

import SwiftUI

// MARK: - Metrics

enum TimelineSpineMetrics {
    /// Width of the leading column that holds `TimePinView` / `UnscheduledMarkerView`.
    /// Kept tight to `timePinCircleDiameter` so booking/activity cards sit farther left; `pinColumnToCardSpacing` adds air before the card.
    static let columnWidth: CGFloat = 54

    /// Horizontal gap between the pin column’s trailing edge and the card’s leading edge (breathing room from the teardrop).
    static let pinColumnToCardSpacing: CGFloat = AppSpacing.xs

    /// Square frame side for time / Flex pins (body + top/bottom tails); smaller than `columnWidth` so chips don’t crowd the card.
    static let timePinCircleDiameter: CGFloat = 50

    private static let continuousRailDividerOpacity: Double = 0.42
    /// Thicker than a hairline so the spine reads as a continuous rail behind the pins.
    static let continuousRailLineWidth: CGFloat = 2.25

    /// Pulls rail + pin centerline slightly toward the leading edge so the spine lines up with the pins.
    static let spineCenterlineNudgeLeft: CGFloat = 6

    static var continuousRailColor: Color {
        AppColors.appDivider.opacity(continuousRailDividerOpacity)
    }

    /// Horizontal offset from a timeline row’s outer leading edge (after `AppSpacing.lg`)
    /// to the vertical rail’s centerline — matches the center of `TimelineSpineTimeColumn`
    /// and the map-style double-teardrop time pins centered on that line.
    static var railCenterXFromTimelineRowLeading: CGFloat {
        columnWidth / 2 - spineCenterlineNudgeLeft
    }
}

// MARK: - Continuous rail

private struct TimelineSpineContinuousRailLayer: View {
    var body: some View {
        GeometryReader { proxy in
            let railX = AppSpacing.lg + TimelineSpineMetrics.railCenterXFromTimelineRowLeading
            Path { path in
                path.move(to: CGPoint(x: railX, y: 0))
                path.addLine(to: CGPoint(x: railX, y: proxy.size.height))
            }
            .stroke(
                TimelineSpineMetrics.continuousRailColor,
                style: StrokeStyle(
                    lineWidth: TimelineSpineMetrics.continuousRailLineWidth,
                    lineCap: .round
                )
            )
            .allowsHitTesting(false)
        }
    }
}

extension View {
    /// Subtle vertical line through the time-pin column, spanning all stacked views that use
    /// the same horizontal padding as timeline cards (`AppSpacing.lg` + `TimelineSpineMetrics.columnWidth`).
    func timelineSpineContinuousRail() -> some View {
        background(alignment: .topLeading) {
            TimelineSpineContinuousRailLayer()
        }
    }
}
