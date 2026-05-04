//
//  FlightBookingDetailContent.swift
//  wayfind
//
//  Flight-specific booking detail layout for `PlaceDetailSheet` — schedule
//  first, then operational details, using trip-destination clock for times.
//

import SwiftUI

struct FlightBookingDetailContent: View {
    let details: FlightDetails
    let timeZone: TimeZone

    private var accent: Color { BookingCategory.flight.color }

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.lg) {
            scheduleCard
            detailsCard
        }
    }

    private var scheduleCard: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            Text("Schedule")
                .font(.footnote.weight(.medium))
                .foregroundStyle(AppColors.textSecondary)
                .textCase(.uppercase)
                .kerning(0.5)

            HStack(alignment: .top, spacing: AppSpacing.md) {
                airportColumn(
                    code: details.departureAirport,
                    instant: details.departureTime,
                    alignment: .leading
                )
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(spacing: AppSpacing.xs) {
                    Image(systemName: "airplane")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(accent)
                        .rotationEffect(.degrees(90))
                        .accessibilityHidden(true)
                    Capsule()
                        .fill(AppColors.appDivider)
                        .frame(width: 28, height: 3)
                }
                .padding(.top, AppSpacing.md)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Flight")

                airportColumn(
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
        .padding(.top, AppSpacing.md)
    }

    private func airportColumn(code: String, instant: Date?, alignment: HorizontalAlignment) -> some View {
        let vStack = VStack(alignment: alignment, spacing: AppSpacing.xs) {
            Text(code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased())
                .font(.system(size: 32, weight: .semibold, design: .rounded))
                .foregroundStyle(AppColors.textPrimary)
                .minimumScaleFactor(0.65)
                .lineLimit(1)
            if let instant {
                Text(instant.timeFormatted(timeZone: timeZone))
                    .font(.appBody.weight(.semibold))
                    .foregroundStyle(AppColors.textPrimary)
                Text(instant.shortFormatted(timeZone: timeZone))
                    .font(.appCaption)
                    .foregroundStyle(AppColors.textSecondary)
            } else {
                Text("Time TBD")
                    .font(.appBody.weight(.medium))
                    .foregroundStyle(AppColors.textSecondary)
            }
        }
        return vStack
    }

    private var detailsCard: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            Text("Flight details")
                .font(.footnote.weight(.medium))
                .foregroundStyle(AppColors.textSecondary)
                .textCase(.uppercase)
                .kerning(0.5)

            VStack(spacing: 0) {
                flightDetailRow(
                    icon: "airplane.circle.fill",
                    title: "Flight",
                    value: flightTitleLine
                )
                if !details.terminal.isEmpty {
                    flightDivider
                    flightDetailRow(icon: "building.2.fill", title: "Terminal", value: details.terminal)
                }
                if !details.gate.isEmpty {
                    flightDivider
                    flightDetailRow(icon: "door.left.hand.open", title: "Gate", value: details.gate)
                }
                if !details.seat.isEmpty {
                    flightDivider
                    flightDetailRow(icon: "rectangle.inset.filled.and.person.filled", title: "Seat", value: details.seat)
                }
            }
        }
        .padding(AppSpacing.lg)
        .background(AppColors.appSurface)
        .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous))
        .padding(.horizontal, AppSpacing.lg)
    }

    private var flightTitleLine: String {
        let airline = details.airline.trimmingCharacters(in: .whitespacesAndNewlines)
        let number = details.flightNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        if airline.isEmpty { return number.isEmpty ? "Flight" : number }
        if number.isEmpty { return airline }
        return "\(airline) \(number)"
    }

    private var flightDivider: some View {
        Divider()
            .background(AppColors.appDivider.opacity(0.6))
            .padding(.vertical, AppSpacing.sm)
    }

    private func flightDetailRow(icon: String, title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: AppSpacing.md) {
            Image(systemName: icon)
                .font(.body.weight(.medium))
                .foregroundStyle(accent)
                .frame(width: 22, alignment: .center)
            Text(title)
                .font(.appCaption.weight(.medium))
                .foregroundStyle(AppColors.textSecondary)
                .frame(width: 76, alignment: .leading)
            Text(value)
                .font(.appBody.weight(.medium))
                .foregroundStyle(AppColors.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}
