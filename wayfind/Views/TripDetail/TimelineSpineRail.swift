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
    /// Sized from the pin’s layout bounds; `pinColumnToCardSpacing` adds air before the card.
    static let columnWidth: CGFloat = 60

    /// Horizontal gap between the pin column’s trailing edge and the card’s leading edge (breathing room from the teardrop).
    static let pinColumnToCardSpacing: CGFloat = AppSpacing.xs

    /// Radius of the circular middle of the map-style teardrop (time / Flex label area). Tails extend beyond this; keep constant when only lengthening tails.
    static let timePinBodyRadius: CGFloat = 23
    /// Length of each tangent tail from the circle to the tip (top and bottom).
    static let timePinTailLength: CGFloat = 8

    static var timePinFrameWidth: CGFloat { 2 * timePinBodyRadius }
    static var timePinFrameHeight: CGFloat { 2 * (timePinBodyRadius + timePinTailLength) }
    static let timePinColumnTopPadding: CGFloat = AppSpacing.sm

    /// Bottom padding after each stacked timeline row (day itinerary + Ideas list).
    static let rowBottomSpacing: CGFloat = AppSpacing.md

    /// When the next row inserts `TimelineGapView`, less trailing space above that segment reads tighter than full `rowBottomSpacing`.
    static let rowBottomSpacingWhenFollowedByTravelGap: CGFloat = AppSpacing.xs

    private static let continuousRailDividerOpacity: Double = 0.42
    /// Vertical rail behind time pins — wide enough to read as a continuous spine (not a hairline).
    static let continuousRailLineWidth: CGFloat = 3.5

    /// Each tail must stay at least this wide at the tip so the filled pin occludes the rail (tapering to a
    /// point leaves a sub-pixel gap where divider + canvas background read as a “white crack”).
    static var teardropTailTipHalfWidth: CGFloat { (continuousRailLineWidth + 1) / 2 }

    /// Pulls rail + pin centerline slightly toward the leading edge so the spine lines up with the pins.
    static let spineCenterlineNudgeLeft: CGFloat = 6

    static var continuousRailColor: Color {
        AppColors.appDivider.opacity(continuousRailDividerOpacity)
    }

    /// Horizontal offset from a timeline row’s outer leading edge (after `AppSpacing.lg`)
    /// to the vertical rail’s centerline — aligned with the circular hub of the map-style time pins in `TimelineSpineTimeColumn`.
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
