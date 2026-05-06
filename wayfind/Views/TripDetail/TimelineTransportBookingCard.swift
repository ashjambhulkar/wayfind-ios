import SwiftUI

/// Transport booking on the trip timeline: confirmation header, route, date/time, then operator / service.
struct TimelineTransportBookingCard: View {
    let details: TransportDetails
    var placeStartTime: Date?
    var placeEndTime: Date?
    var displayTimeZone: TimeZone
    var stripeAccent: Color
    var confirmationChip: String?

    private var categoryTint: Color { BookingCategory.transport.color }

    private var confirmationTrailingDisplay: String {
        let raw = confirmationChip?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if raw.isEmpty { return String(localized: "Confirmation TBD") }
        return raw
    }

    private var fromToLine: String {
        let from = trimmed(details.departureStation)
        let to = trimmed(details.arrivalStation)
        let fromDisplay = from.isEmpty ? String(localized: "Departure TBD") : from
        let toDisplay = to.isEmpty ? String(localized: "Arrival TBD") : to
        return String(
            format: String(localized: "From %1$@ to %2$@"),
            locale: .current,
            fromDisplay,
            toDisplay
        )
    }

    private var timesRowText: String {
        Self.scheduleRowDisplay(
            details: details,
            placeStartTime: placeStartTime,
            placeEndTime: placeEndTime,
            displayTimeZone: displayTimeZone
        )
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

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: AppSpacing.xs) {
                Text(BookingCategory.transport.label)
                    .font(.appFootnote.weight(.semibold))
                    .foregroundStyle(categoryTint)
                    .lineLimit(1)
                Text("·")
                    .font(.appFootnote)
                    .foregroundStyle(AppColors.textTertiary)
                    .accessibilityHidden(true)
                Text(confirmationTrailingDisplay)
                    .font(.appFootnote.weight(.medium))
                    .foregroundStyle(AppColors.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Spacer(minLength: 0)
            }

            Text(fromToLine)
                .font(.timelineRowTitle)
                .foregroundStyle(AppColors.textPrimary)
                .lineLimit(3)
                .minimumScaleFactor(0.82)
                .fixedSize(horizontal: false, vertical: true)

            Text(timesRowText)
                .font(.appFootnote.weight(.medium))
                .foregroundStyle(AppColors.textSecondary)
                .monospacedDigit()
                .lineLimit(3)
                .minimumScaleFactor(0.82)

            Text(operatorServiceLine)
                .font(.appFootnote)
                .foregroundStyle(AppColors.textTertiary)
                .lineLimit(2)
                .minimumScaleFactor(0.88)
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

    private var accessibilitySummary: String {
        [
            "\(BookingCategory.transport.label) \(confirmationTrailingDisplay)",
            fromToLine,
            timesRowText,
            operatorServiceLine
        ].joined(separator: ", ")
    }

    private func trimmed(_ value: String?) -> String {
        value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// Date + time segments without "Departure"/"Arrival" labels so the row fits the card; shared with timeline accessibility.
    static func scheduleRowDisplay(
        details: TransportDetails,
        placeStartTime: Date?,
        placeEndTime: Date?,
        displayTimeZone tz: TimeZone
    ) -> String {
        let start = details.departureTime ?? placeStartTime
        let end = details.arrivalTime ?? placeEndTime

        func segment(_ d: Date) -> String {
            "\(d.shortFormatted(timeZone: tz)) · \(d.timeFormatted(timeZone: tz))"
        }

        switch (start, end) {
        case let (s?, e?) where e > s:
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = tz
            if cal.isDate(s, inSameDayAs: e) {
                return "\(s.shortFormatted(timeZone: tz)) · \(s.timeFormatted(timeZone: tz)) – \(e.timeFormatted(timeZone: tz))"
            }
            return "\(segment(s)) – \(segment(e))"
        case let (s?, e?):
            return "\(segment(s)) – \(segment(e))"
        case let (s?, _):
            return segment(s)
        case let (_, e?):
            return segment(e)
        default:
            return String(localized: "Times not set")
        }
    }
}
