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
    static let columnWidth: CGFloat = 48

    /// Horizontal gap between the pin column’s trailing edge and the card’s leading edge (breathing room from the teardrop).
    static let pinColumnToCardSpacing: CGFloat = AppSpacing.xs

    /// Radius of the circular middle of the map-style pin. Tail extends below this.
    static let timePinBodyRadius: CGFloat = 18
    /// Apple Maps-style lower pointer. There is intentionally no top tail.
    static let timePinTailLength: CGFloat = 10

    static var timePinFrameWidth: CGFloat { 2 * timePinBodyRadius }
    static var timePinFrameHeight: CGFloat { 2 * timePinBodyRadius + timePinTailLength + 5 }
    static let timePinColumnTopPadding: CGFloat = 0

    /// Distance from the top of `TimelineSpineTimeColumn` to the circular hub center.
    /// Used with `alignmentGuide(.center)` so the hub lines up with the card’s vertical center in the row `HStack`.
    static var timePinHubYFromColumnOrigin: CGFloat {
        timePinColumnTopPadding + timePinBodyRadius
    }

    /// Bottom padding after each stacked timeline row (day itinerary + Ideas list).
    static let rowBottomSpacing: CGFloat = AppSpacing.sm

    /// When the next row inserts `TimelineGapView`; spine-only travel cue needs almost no runway above it.
    static let rowBottomSpacingWhenFollowedByTravelGap: CGFloat = 0

    private static let continuousRailDividerOpacity: Double = 0.42
    /// Vertical rail behind time pins — wide enough to read as a continuous spine (not a hairline).
    static let continuousRailLineWidth: CGFloat = 3.5

    /// Historical teardrop metric retained for compatibility with older callers.
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
