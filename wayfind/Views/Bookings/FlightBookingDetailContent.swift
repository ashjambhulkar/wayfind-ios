//
//  FlightBookingDetailContent.swift
//  wayfind
//
//  Flight booking detail for `PlaceDetailSheet` — identity header, route strip
//  with duration, then departure / arrival operational rows (terminal, gate,
//  seat, baggage) using trip-destination timezone for wall times.
//

import SwiftUI

struct FlightBookingDetailContent: View {
    let details: FlightDetails
    let timeZone: TimeZone
    /// From the parent `Place` — shown when the generic booking hero is hidden for flights.
    var confirmationNumber: String? = nil

    private var accent: Color { BookingCategory.flight.color }

    private var trimmedConfirmation: String? {
        let c = confirmationNumber?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return c.isEmpty ? nil : c
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.lg) {
            identityCard
            routeScheduleCard
            if hasDepartureOperationalDetails {
                operationalCard(
                    sectionTitle: String(localized: "Departure"),
                    systemImage: "airplane.departure",
                    rows: departureRows
                )
            }
            if hasArrivalOperationalDetails {
                operationalCard(
                    sectionTitle: String(localized: "Arrival"),
                    systemImage: "airplane.arrival",
                    rows: arrivalRows
                )
            }
            if let statusLine = lookupStatusLine {
                Text(statusLine)
                    .font(.appCaption)
                    .foregroundStyle(AppColors.textTertiary)
                    .padding(.horizontal, AppSpacing.lg)
                    .padding(.bottom, AppSpacing.sm)
            }
        }
        .padding(.top, AppSpacing.md)
    }

    // MARK: - Identity

    private var identityCard: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            HStack(alignment: .center, spacing: AppSpacing.md) {
                ZStack {
                    Circle()
                        .fill(accent.opacity(0.14))
                        .frame(width: 56, height: 56)
                    Image(systemName: "airplane")
                        .font(.sectionHeader)
                        .foregroundStyle(accent)
                        .rotationEffect(.degrees(-45))
                        .accessibilityHidden(true)
                }

                VStack(alignment: .leading, spacing: AppSpacing.xs) {
                    Text(flightTitleLine)
                        .font(.sectionHeader)
                        .foregroundStyle(AppColors.textPrimary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.85)

                    Text(carrierCodeLine)
                        .font(.appFootnote.weight(.medium))
                        .foregroundStyle(AppColors.textSecondary)
                        .monospacedDigit()

                    if details.lookupVerified {
                        Label(String(localized: "Schedule verified"), systemImage: "checkmark.seal.fill")
                            .font(.appSmall.weight(.semibold))
                            .foregroundStyle(AppColors.appSuccess)
                            .padding(.top, 2)
                    }
                }

                Spacer(minLength: 0)
            }

            if let conf = trimmedConfirmation {
                HStack(alignment: .firstTextBaseline) {
                    Text(String(localized: "Confirmation"))
                        .font(.appCaption.weight(.medium))
                        .foregroundStyle(AppColors.textSecondary)
                    Spacer(minLength: AppSpacing.sm)
                    Text(conf)
                        .font(.appCaption.weight(.semibold))
                        .foregroundStyle(accent)
                        .monospacedDigit()
                        .multilineTextAlignment(.trailing)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(AppSpacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColors.appSurface)
        .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous)
                .strokeBorder(accent.opacity(0.2), lineWidth: 1)
        )
        .padding(.horizontal, AppSpacing.lg)
    }

    // MARK: - Route & schedule

    private var routeScheduleCard: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            Text(String(localized: "Route & times"))
                .font(.footnote.weight(.medium))
                .foregroundStyle(AppColors.textSecondary)
                .textCase(.uppercase)
                .kerning(0.5)

            HStack(alignment: .top, spacing: AppSpacing.sm) {
                airportBlock(
                    code: details.departureAirport,
                    instant: details.departureTime,
                    alignment: .leading
                )
                .frame(maxWidth: .infinity, alignment: .leading)

                routeConnector

                airportBlock(
                    code: details.arrivalAirport,
                    instant: details.arrivalTime,
                    alignment: .trailing
                )
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(AppSpacing.lg)
        .background(AppColors.appSurface)
        .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous))
        .padding(.horizontal, AppSpacing.lg)
    }

    private var routeConnector: some View {
        VStack(spacing: AppSpacing.xs) {
            if let duration = flightDurationLabel {
                Text(duration)
                    .font(.appSmall.weight(.semibold))
                    .foregroundStyle(AppColors.textSecondary)
                    .padding(.horizontal, AppSpacing.sm)
                    .padding(.vertical, 4)
                    .background(accent.opacity(0.1), in: Capsule())
                    .accessibilityLabel(String(localized: "Flight duration"))
                    .accessibilityValue(duration)
            }
            Image(systemName: "airplane")
                .font(.title3.weight(.semibold))
                .foregroundStyle(accent)
                .rotationEffect(.degrees(90))
                .accessibilityHidden(true)
            Capsule()
                .fill(AppColors.appDivider)
                .frame(width: 32, height: 3)
        }
        .padding(.top, AppSpacing.sm)
        .frame(minWidth: 72)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(String(localized: "In flight"))
    }

    private func airportBlock(code: String, instant: Date?, alignment: HorizontalAlignment) -> some View {
        let iata = trimmedUpper(code)
        return VStack(alignment: alignment, spacing: AppSpacing.xs) {
            Text(iata.isEmpty ? "—" : iata)
                .font(.tripDetailHeroTitle)
                .foregroundStyle(AppColors.textPrimary)
                .minimumScaleFactor(0.6)
                .lineLimit(1)

            if let instant {
                Text(instant.timeFormatted(timeZone: timeZone))
                    .font(.appBody.weight(.semibold))
                    .foregroundStyle(AppColors.textPrimary)
                    .monospacedDigit()
                Text(instant.shortFormatted(timeZone: timeZone))
                    .font(.appCaption)
                    .foregroundStyle(AppColors.textSecondary)
            } else {
                Text(String(localized: "Time TBD"))
                    .font(.appBody.weight(.medium))
                    .foregroundStyle(AppColors.textSecondary)
            }
        }
    }

    // MARK: - Operational sections

    private func operationalCard(sectionTitle: String, systemImage: String, rows: [(icon: String, title: String, value: String)]) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            HStack(spacing: AppSpacing.sm) {
                Image(systemName: systemImage)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(accent)
                Text(sectionTitle)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(AppColors.textSecondary)
                    .textCase(.uppercase)
                    .kerning(0.5)
            }

            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    if index > 0 { flightDivider }
                    flightDetailRow(icon: row.icon, title: row.title, value: row.value)
                }
            }
        }
        .padding(AppSpacing.lg)
        .background(AppColors.appSurface)
        .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous))
        .padding(.horizontal, AppSpacing.lg)
    }

    private var departureRows: [(icon: String, title: String, value: String)] {
        var r: [(icon: String, title: String, value: String)] = []
        let term = details.terminal.trimmingCharacters(in: .whitespacesAndNewlines)
        if !term.isEmpty {
            r.append(("building.2.fill", String(localized: "Terminal"), term))
        }
        let gate = details.gate.trimmingCharacters(in: .whitespacesAndNewlines)
        if !gate.isEmpty {
            r.append(("door.left.hand.open", String(localized: "Gate"), gate))
        }
        let seat = details.seat.trimmingCharacters(in: .whitespacesAndNewlines)
        if !seat.isEmpty {
            r.append(("rectangle.inset.filled.and.person.filled", String(localized: "Seat"), seat))
        }
        return r
    }

    private var arrivalRows: [(icon: String, title: String, value: String)] {
        var r: [(icon: String, title: String, value: String)] = []
        if let term = details.terminalDestination?.trimmingCharacters(in: .whitespacesAndNewlines), !term.isEmpty {
            r.append(("building.2.fill", String(localized: "Terminal"), term))
        }
        if let gate = details.gateDestination?.trimmingCharacters(in: .whitespacesAndNewlines), !gate.isEmpty {
            r.append(("door.left.hand.open", String(localized: "Gate"), gate))
        }
        if let bag = details.baggageClaim?.trimmingCharacters(in: .whitespacesAndNewlines), !bag.isEmpty {
            r.append(("suitcase.cart.fill", String(localized: "Baggage"), bag))
        }
        return r
    }

    private var hasDepartureOperationalDetails: Bool { !departureRows.isEmpty }
    private var hasArrivalOperationalDetails: Bool { !arrivalRows.isEmpty }

    private var flightDivider: some View {
        Divider()
            .background(AppColors.appDivider.opacity(0.6))
            .padding(.vertical, AppSpacing.sm)
    }

    private func flightDetailRow(icon: String, title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: AppSpacing.md) {
            Image(systemName: icon)
                .font(.appBody.weight(.medium))
                .foregroundStyle(accent)
                .frame(width: 22, alignment: .center)
            Text(title)
                .font(.appCaption.weight(.medium))
                .foregroundStyle(AppColors.textSecondary)
                .frame(width: 88, alignment: .leading)
            Text(value)
                .font(.appBody.weight(.medium))
                .foregroundStyle(AppColors.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Copy helpers

    private var flightTitleLine: String {
        let airline = details.airline.trimmingCharacters(in: .whitespacesAndNewlines)
        let number = details.flightNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        if airline.isEmpty { return number.isEmpty ? String(localized: "Flight") : number }
        if number.isEmpty { return airline }
        return "\(airline) \(number)"
    }

    private var carrierCodeLine: String {
        let iata = details.carrierIATA?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() ?? ""
        let num = details.flightNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        if iata.isEmpty, num.isEmpty { return String(localized: "Flight number not set") }
        if iata.isEmpty { return num }
        if num.isEmpty { return iata }
        return "\(iata) \(num)"
    }

    private var lookupStatusLine: String? {
        guard !details.lookupVerified else { return nil }
        let s = details.lookupStatus?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return s.isEmpty ? nil : s
    }

    private var flightDurationLabel: String? {
        guard let dep = details.departureTime,
              let arr = details.arrivalTime,
              arr > dep else { return nil }
        let minutes = max(0, Int(arr.timeIntervalSince(dep) / 60))
        guard minutes > 0 else { return nil }
        let h = minutes / 60
        let m = minutes % 60
        if h == 0 {
            return String(format: String(localized: "%d min"), m)
        }
        if m == 0 {
            return String(format: String(localized: "%d hr"), h)
        }
        return String(format: String(localized: "%1$d hr %2$d min"), h, m)
    }

    private func trimmedUpper(_ code: String) -> String {
        code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }
}
