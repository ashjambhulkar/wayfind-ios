import CoreLocation
import SwiftUI

/// Connector between two consecutive itinerary rows: route summary (time + distance), optional multi-mode picker, and Maps directions A → B.
struct TimelineGapView: View {
    let tripId: UUID
    let cityProfileId: UUID?
    let fromPlace: Place
    let toPlace: Place

    @State private var isComputing = false
    @State private var isExpanded = false
    @State private var userPickedMode: AppleTravelTimesService.Mode?
    @State private var legRenderTick = 0

    private var fromCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: fromPlace.lat!, longitude: fromPlace.lng!)
    }

    private var toCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: toPlace.lat!, longitude: toPlace.lng!)
    }

    var body: some View {
        collapsedRow
            .animation(AppSpring.smooth, value: isExpanded)
            .animation(AppSpring.smooth, value: effectiveMode)
            .padding(.vertical, TimelineBetweenStopsMetrics.gapRowVerticalPadding)
            .padding(.horizontal, AppSpacing.lg)
            .accessibilityElement(children: .contain)
            .task(id: taskIdentity) {
                await warmTravelCaches()
            }
    }

    private var taskIdentity: String {
        "\(fromPlace.id.uuidString)|\(toPlace.id.uuidString)"
    }

    // MARK: - Rows

    private var collapsedRow: some View {
        HStack(alignment: .center, spacing: AppSpacing.sm) {
            modeSpineCircle

            summaryCluster

            if isExpanded {
                ScrollView(.horizontal, showsIndicators: false) {
                    inlineModeChips
                }
                .transition(.opacity.combined(with: .move(edge: .leading)))
            }

            Spacer(minLength: AppSpacing.xs)
        }
        .frame(minHeight: TimelineBetweenStopsMetrics.minRowHeight)
    }

    private var modeSpineCircle: some View {
        let circleSide: CGFloat = 30
        return ZStack {
            Circle()
                .fill(AppColors.appBackground)
                .frame(width: circleSide, height: circleSide)
                .overlay {
                    Circle()
                        .strokeBorder(
                            TimelineSpineMetrics.continuousRailColor,
                            lineWidth: TimelineSpineMetrics.continuousRailLineWidth
                        )
                }

            if isComputing && !hasAnySummaryToShow {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: TimelineBetweenStopsPresentation.sfSymbol(for: effectiveMode))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(AppColors.textSecondary)
                    .accessibilityHidden(true)
            }
        }
        .offset(x: -TimelineSpineMetrics.spineCenterlineNudgeLeft)
        .frame(width: TimelineBetweenStopsMetrics.timePinGutterWidth, alignment: .center)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var summaryCluster: some View {
        let label = summaryClusterLabel
        if modesForExpansion.count > 1 {
            Button {
                withAnimation(AppSpring.smooth) { isExpanded.toggle() }
                HapticManager.light()
            } label: {
                label
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                isExpanded
                    ? String(localized: "Travel segment, modes visible")
                    : String(localized: "Travel segment, show modes")
            )
            .accessibilityValue(summaryLine)
        } else {
            label
                .accessibilityElement(children: .combine)
                .accessibilityLabel(String(localized: "Travel segment"))
                .accessibilityValue(summaryLine)
        }
    }

    private var summaryClusterLabel: some View {
        HStack(spacing: AppSpacing.xs) {
            Text(summaryLine)
                .font(.appCaption)
                .foregroundStyle(AppColors.textTertiary)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.82)

            if modesForExpansion.count > 1 {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(AppColors.textTertiary.opacity(0.85))
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
                    .animation(AppSpring.smooth, value: isExpanded)
                    .accessibilityHidden(true)
            }
        }
    }

    private var inlineModeChips: some View {
        HStack(spacing: AppSpacing.xs) {
            ForEach(modesForExpansion, id: \.self) { mode in
                inlineModeChip(mode)
            }
        }
    }

    private func inlineModeChip(_ mode: AppleTravelTimesService.Mode) -> some View {
        let isSelected = effectiveMode == mode
        let durationText = expansionRowMinutes(for: mode).map { TimelineBetweenStopsPresentation.spineTravelDuration(minutes: $0) }

        return Button {
            userPickedMode = mode
            withAnimation(AppSpring.smooth) { isExpanded = false }
            HapticManager.light()
        } label: {
            HStack(spacing: AppSpacing.xs) {
                Image(systemName: TimelineBetweenStopsPresentation.sfSymbol(for: mode))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(isSelected ? AppColors.textSecondary : AppColors.textTertiary)

                if let durationText {
                    Text(durationText)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(isSelected ? AppColors.textSecondary : AppColors.textTertiary)
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, AppSpacing.sm)
            .padding(.vertical, AppSpacing.xs)
            .background(isSelected ? AppColors.textPrimary.opacity(0.06) : AppColors.textPrimary.opacity(0.035), in: Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(
                        isSelected ? AppColors.appDivider.opacity(0.95) : AppColors.appDivider.opacity(0.5),
                        lineWidth: isSelected ? 0.75 : 0.55
                    )
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(inlineModeChipAccessibilityLabel(mode: mode, durationMinutes: expansionRowMinutes(for: mode)))
        .accessibilityHint(String(localized: "Sets routing mode"))
    }

    private func inlineModeChipAccessibilityLabel(mode: AppleTravelTimesService.Mode, durationMinutes: Int?) -> String {
        let modeName = TimelineBetweenStopsPresentation.accessibilityLabel(for: mode)
        guard let m = durationMinutes, m >= 0 else { return modeName }
        return "\(modeName), \(TimelineBetweenStopsPresentation.spineTravelDuration(minutes: m))"
    }

    // MARK: - Leg data

    private var effectiveMode: AppleTravelTimesService.Mode {
        if let userPickedMode { return userPickedMode }
        if let best = fastestCachedAppleMode { return best }
        if let stored = storedTravelModeHint() { return stored }
        return heuristicFallbackMode
    }

    private var fastestCachedAppleMode: AppleTravelTimesService.Mode? {
        let pairs: [(AppleTravelTimesService.Mode, Int)] = AppleTravelTimesService.Mode.allCases.compactMap { mode in
            guard let minutes = appleMinutes(for: mode) else { return nil }
            return (mode, minutes)
        }
        guard !pairs.isEmpty else { return nil }
        let tiePriority: [AppleTravelTimesService.Mode: Int] = [
            .walking: 0, .driving: 1, .transit: 2,
        ]
        return pairs.min { a, b in
            if a.1 != b.1 { return a.1 < b.1 }
            return (tiePriority[a.0] ?? 99) < (tiePriority[b.0] ?? 99)
        }?.0
    }

    private var modesWithAppleETA: Set<AppleTravelTimesService.Mode> {
        Set(AppleTravelTimesService.Mode.allCases.filter { appleMinutes(for: $0) != nil })
    }

    private var modesForExpansion: [AppleTravelTimesService.Mode] {
        let modes = AppleTravelTimesService.Mode.allCases.filter { appleMinutes(for: $0) != nil }
        if modes.isEmpty {
            return [heuristicFallbackMode]
        }
        return modes
    }

    private var heuristicFallbackMode: AppleTravelTimesService.Mode {
        let km = HaversineDistance.distance(from: fromCoordinate, to: toCoordinate)
        return km < TimelineBetweenStopsMetrics.shortWalkThresholdKm ? .walking : .driving
    }

    private var summaryLine: String {
        let minutes = resolvedMinutesForSummary
        let distanceText = resolvedDistanceText
        let minutesText = minutes.map { TimelineBetweenStopsPresentation.spineTravelDuration(minutes: $0) } ?? "—"
        return TimelineBetweenStopsPresentation.summaryLine(minutesText: minutesText, distanceText: distanceText)
    }

    private var resolvedMinutesForSummary: Int? {
        if let apple = appleMinutes(for: effectiveMode) { return apple }
        if let stored = toPlace.travelFromPreviousMinutes, stored > 0 { return stored }
        let hMode = haversineTravelMode(for: effectiveMode)
        let est = HaversineDistance.estimateTravelTime(from: fromCoordinate, to: toCoordinate, mode: hMode)
        return est > 0 ? est : nil
    }

    private var resolvedDistanceText: String {
        if let meters = appleRouteDistanceMeters(for: effectiveMode) {
            return TimelineBetweenStopsPresentation.formatDistance(meters: meters)
        }
        let km = HaversineDistance.distance(from: fromCoordinate, to: toCoordinate)
        guard km > 0 else { return "—" }
        return TimelineBetweenStopsPresentation.formatDistance(meters: Int((km * 1_000).rounded()))
    }

    private func appleRouteDistanceMeters(for mode: AppleTravelTimesService.Mode) -> Int? {
        let svc = AppleTravelTimesService.shared
        let fp = TimelineBetweenStopsPresentation.normalizedGooglePlaceId(fromPlace.googlePlaceId)
        let tp = TimelineBetweenStopsPresentation.normalizedGooglePlaceId(toPlace.googlePlaceId)
        if let cid = cityProfileId, let fp, let tp,
           let scoped = svc.cachedRouteDistanceMeters(
               cityProfileId: cid,
               fromPlaceId: fp,
               toPlaceId: tp,
               mode: mode
           ) {
            return scoped
        }
        if let fp, let tp,
           let anyScope = svc.cachedRouteDistanceMetersForAnyScope(fromPlaceId: fp, toPlaceId: tp, mode: mode) {
            return anyScope
        }
        if let coord = svc.cachedCoordRouteDistance(from: fromCoordinate, to: toCoordinate, mode: mode) {
            return coord
        }
        return legAggregateDistanceMetersFallback
    }

    private var legAggregateDistanceMetersFallback: Int? {
        let svc = AppleTravelTimesService.shared
        let fp = TimelineBetweenStopsPresentation.normalizedGooglePlaceId(fromPlace.googlePlaceId)
        let tp = TimelineBetweenStopsPresentation.normalizedGooglePlaceId(toPlace.googlePlaceId)
        if let cid = cityProfileId, let fp, let tp,
           let scoped = svc.cachedDistanceMeters(
               cityProfileId: cid,
               fromPlaceId: fp,
               toPlaceId: tp
           ) {
            return scoped
        }
        if let fp, let tp, let anyScope = svc.cachedDistanceMetersForAnyScope(fromPlaceId: fp, toPlaceId: tp) {
            return anyScope
        }
        return svc.cachedCoordDistance(from: fromCoordinate, to: toCoordinate)
    }

    private func appleMinutes(for mode: AppleTravelTimesService.Mode) -> Int? {
        let svc = AppleTravelTimesService.shared
        let fp = TimelineBetweenStopsPresentation.normalizedGooglePlaceId(fromPlace.googlePlaceId)
        let tp = TimelineBetweenStopsPresentation.normalizedGooglePlaceId(toPlace.googlePlaceId)
        if let cid = cityProfileId, let fp, let tp,
           let m = svc.cachedMinutes(cityProfileId: cid, fromPlaceId: fp, toPlaceId: tp, mode: mode) {
            return m
        }
        if let fp, let tp, let m = svc.cachedMinutesForAnyScope(fromPlaceId: fp, toPlaceId: tp, mode: mode) {
            return m
        }
        return svc.cachedCoordMinutes(from: fromCoordinate, to: toCoordinate, mode: mode)
    }

    private func expansionRowMinutes(for mode: AppleTravelTimesService.Mode) -> Int? {
        if let apple = appleMinutes(for: mode) { return apple }
        guard modesWithAppleETA.isEmpty, mode == heuristicFallbackMode else { return nil }
        let hMode = haversineTravelMode(for: mode)
        let est = HaversineDistance.estimateTravelTime(from: fromCoordinate, to: toCoordinate, mode: hMode)
        return est > 0 ? est : nil
    }

    private var hasAnySummaryToShow: Bool {
        resolvedMinutesForSummary != nil
            || appleRouteDistanceMeters(for: effectiveMode) != nil
            || HaversineDistance.distance(from: fromCoordinate, to: toCoordinate) > 0
    }

    private func haversineTravelMode(for mode: AppleTravelTimesService.Mode) -> HaversineDistance.TravelMode {
        switch mode {
        case .walking: return .walking
        case .driving: return .driving
        case .transit: return .transit
        }
    }

    private func warmTravelCaches() async {
        isComputing = true
        defer {
            isComputing = false
            legRenderTick &+= 1
        }

        if let cid = cityProfileId,
           let fp = TimelineBetweenStopsPresentation.normalizedGooglePlaceId(fromPlace.googlePlaceId),
           let tp = TimelineBetweenStopsPresentation.normalizedGooglePlaceId(toPlace.googlePlaceId) {
            AppleTravelTimesService.shared.enqueueIfMissing(
                tripId: tripId,
                cityProfileId: cid,
                legs: [
                    AppleTravelTimesService.LegRequest(
                        fromPlaceId: fp,
                        fromCoordinate: fromCoordinate,
                        toPlaceId: tp,
                        toCoordinate: toCoordinate
                    ),
                ]
            )
        }

        _ = await AppleTravelTimesService.shared.computeAndCacheCoordLeg(
            from: fromCoordinate,
            to: toCoordinate
        )
    }

    private func storedTravelModeHint() -> AppleTravelTimesService.Mode? {
        let normalized = toPlace.travelMode?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        guard !normalized.isEmpty else { return nil }
        if normalized.contains("walk") { return .walking }
        if normalized.contains("drive") || normalized.contains("car") || normalized.contains("automobile") {
            return .driving
        }
        if normalized.contains("transit")
            || normalized.contains("train")
            || normalized.contains("bus")
            || normalized.contains("subway")
            || normalized.contains("public") {
            return .transit
        }
        return nil
    }
}

#if DEBUG
#Preview("Travel gap") {
    VStack {
        TimelineGapView(
            tripId: UUID(),
            cityProfileId: nil,
            fromPlace: .previewAttraction,
            toPlace: .previewRestaurant
        )
        TimelineGapView(
            tripId: UUID(),
            cityProfileId: nil,
            fromPlace: .previewRestaurant,
            toPlace: .previewHotel
        )
    }
    .padding()
    .background(AppColors.appBackground)
}
#endif
