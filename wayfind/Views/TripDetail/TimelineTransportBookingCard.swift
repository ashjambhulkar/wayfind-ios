import SwiftUI

/// Transport booking on the trip timeline: route, operator + service, then start/end times.
struct TimelineTransportBookingCard: View {
    let details: TransportDetails
    var placeStartTime: Date?
    var placeEndTime: Date?
    var displayTimeZone: TimeZone
    var stripeAccent: Color
    var confirmationChip: String?

    private var categoryTint: Color {
        TimelineCategoryChroma.pinColor(for: .transport)
    }

    private var routeLine: String {
        let from = trimmed(details.departureStation)
        let to = trimmed(details.arrivalStation)
        let fromDisplay = from.isEmpty ? String(localized: "Departure TBD") : from
        let toDisplay = to.isEmpty ? String(localized: "Arrival TBD") : to
        return "\(fromDisplay) → \(toDisplay)"
    }

    private var operatorServiceLine: String {
        let op = trimmed(details.operatorName)
        let svc = trimmed(details.serviceNumber)
        if op.isEmpty, svc.isEmpty {
            return String(localized: "Operator and service not set")
        }
        if op.isEmpty { return svc }
        if svc.isEmpty { return op }
        return "\(op) · \(svc)"
    }

    private var scheduleLine: String {
        let start = details.departureTime ?? placeStartTime
        let end = details.arrivalTime ?? placeEndTime
        if let start, let end, end > start {
            return "\(start.timeFormatted(timeZone: displayTimeZone)) – \(end.timeFormatted(timeZone: displayTimeZone))"
        }
        if let start {
            return start.timeFormatted(timeZone: displayTimeZone)
        }
        if let end {
            return end.timeFormatted(timeZone: displayTimeZone)
        }
        return String(localized: "Times not set")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            eyebrowRow

            Text(routeLine)
                .font(.timelineRowTitle)
                .foregroundStyle(Color.primary)
                .lineLimit(2)
                .minimumScaleFactor(0.85)
                .fixedSize(horizontal: false, vertical: true)

            Text(operatorServiceLine)
                .font(.appBody)
                .foregroundStyle(AppColors.textSecondary)
                .lineLimit(2)
                .minimumScaleFactor(0.88)

            Text(scheduleLine)
                .font(.footnote.weight(.medium))
                .foregroundStyle(AppColors.textTertiary)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .timelineCardChassis(
            stripeColor: stripeAccent,
            showsTopRail: false,
            horizontalContentPadding: TimelineCardLayoutMetrics.contentHorizontalPadding,
            verticalContentPadding: TimelineCardLayoutMetrics.contentHorizontalPadding
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
    }

    private var eyebrowRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: AppSpacing.xs) {
            Text(BookingCategory.transport.label)
                .font(.appSmall.weight(.semibold))
                .foregroundStyle(categoryTint)
                .lineLimit(1)

            if let chip = confirmationChip?.trimmingCharacters(in: .whitespacesAndNewlines), !chip.isEmpty {
                Text("·")
                    .font(.appSmall)
                    .foregroundStyle(AppColors.textTertiary)
                    .accessibilityHidden(true)
                Text(chip)
                    .font(.appSmall.weight(.medium))
                    .foregroundStyle(AppColors.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }

    private var accessibilitySummary: String {
        let conf = confirmationChip.map { ", \($0)" } ?? ""
        return "\(BookingCategory.transport.label)\(conf): \(routeLine). \(operatorServiceLine). \(scheduleLine)"
    }

    private func trimmed(_ value: String?) -> String {
        value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
