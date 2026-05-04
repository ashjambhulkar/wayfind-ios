//
//  TransportBookingDetailContent.swift
//  wayfind
//
//  Transport booking detail for `PlaceDetailSheet` — from/to schedule,
//  optional service rows, optional address.
//

import SwiftUI

struct TransportBookingDetailContent: View {
    let details: TransportDetails
    let timeZone: TimeZone
    var address: String? = nil

    private var accent: Color { BookingCategory.transport.color }

    private var operatorTrimmed: String {
        details.operatorName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var serviceTrimmed: String {
        details.serviceNumber.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var seatTrimmed: String {
        details.seat.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasServiceDetails: Bool {
        !operatorTrimmed.isEmpty || !serviceTrimmed.isEmpty || !seatTrimmed.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.lg) {
            scheduleCard
            if hasServiceDetails {
                serviceDetailsCard
            }
            if let trimmed = address?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty {
                locationCard(trimmed)
            }
        }
    }

    // MARK: - Schedule

    private var scheduleCard: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            Text("Schedule")
                .font(.footnote.weight(.medium))
                .foregroundStyle(AppColors.textSecondary)
                .textCase(.uppercase)
                .kerning(0.5)

            HStack(alignment: .top, spacing: AppSpacing.md) {
                stationColumn(
                    title: String(localized: "From"),
                    stationRaw: details.departureStation,
                    instant: details.departureTime,
                    alignment: .leading
                )
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(spacing: AppSpacing.xs) {
                    Image(systemName: BookingCategory.transport.sfSymbol)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(accent)
                        .accessibilityHidden(true)
                    Capsule()
                        .fill(AppColors.appDivider)
                        .frame(width: 28, height: 3)
                }
                .padding(.top, AppSpacing.md)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(String(localized: "Transport"))

                stationColumn(
                    title: String(localized: "To"),
                    stationRaw: details.arrivalStation,
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

    private func stationColumn(
        title: String,
        stationRaw: String,
        instant: Date?,
        alignment: HorizontalAlignment
    ) -> some View {
        let stationLine = displayStation(stationRaw)
        return VStack(alignment: alignment, spacing: AppSpacing.xs) {
            Text(title)
                .font(.appSmall.weight(.semibold))
                .foregroundStyle(AppColors.textSecondary)
                .textCase(.uppercase)

            Text(stationLine)
                .font(.appBody.weight(.medium))
                .foregroundStyle(AppColors.textPrimary)
                .multilineTextAlignment(alignment == .leading ? .leading : .trailing)
                .fixedSize(horizontal: false, vertical: true)

            if let instant {
                Text(instant.timeFormatted(timeZone: timeZone))
                    .font(.sectionHeader)
                    .foregroundStyle(AppColors.textPrimary)
                    .minimumScaleFactor(0.8)

                Text(dateSubtitle(for: instant))
                    .font(.appCaption)
                    .foregroundStyle(AppColors.textSecondary)
            } else {
                Text("Time TBD")
                    .font(.appBody.weight(.medium))
                    .foregroundStyle(AppColors.textSecondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func dateSubtitle(for instant: Date) -> String {
        let day = instant.dayOfWeekShort(timeZone: timeZone)
        let date = instant.shortFormatted(timeZone: timeZone)
        return "\(day) · \(date)"
    }

    private func displayStation(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return String(localized: "Not specified")
        }
        return trimmed
    }

    // MARK: - Service details

    private var serviceDetailsCard: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            Text("Service details")
                .font(.footnote.weight(.medium))
                .foregroundStyle(AppColors.textSecondary)
                .textCase(.uppercase)
                .kerning(0.5)

            VStack(spacing: 0) {
                if !operatorTrimmed.isEmpty {
                    transportDetailRow(
                        icon: "building.2.fill",
                        title: String(localized: "Operator"),
                        value: operatorTrimmed
                    )
                    if !serviceTrimmed.isEmpty || !seatTrimmed.isEmpty {
                        transportDivider
                    }
                }
                if !serviceTrimmed.isEmpty {
                    transportDetailRow(
                        icon: "number",
                        title: String(localized: "Service"),
                        value: serviceTrimmed
                    )
                    if !seatTrimmed.isEmpty {
                        transportDivider
                    }
                }
                if !seatTrimmed.isEmpty {
                    transportDetailRow(
                        icon: "rectangle.inset.filled.and.person.filled",
                        title: String(localized: "Seat"),
                        value: seatTrimmed
                    )
                }
            }
        }
        .padding(AppSpacing.lg)
        .background(AppColors.appSurface)
        .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous))
        .padding(.horizontal, AppSpacing.lg)
    }

    private var transportDivider: some View {
        Divider()
            .background(AppColors.appDivider.opacity(0.6))
            .padding(.vertical, AppSpacing.sm)
    }

    private func transportDetailRow(icon: String, title: String, value: String) -> some View {
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

    // MARK: - Address

    private func locationCard(_ line: String) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            Text("Address")
                .font(.footnote.weight(.medium))
                .foregroundStyle(AppColors.textSecondary)
                .textCase(.uppercase)
                .kerning(0.5)

            HStack(alignment: .top, spacing: AppSpacing.md) {
                Image(systemName: "mappin.and.ellipse")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(accent)
                    .frame(width: 22, alignment: .center)

                Text(line)
                    .font(.appBody)
                    .foregroundStyle(AppColors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
        }
        .padding(AppSpacing.lg)
        .background(AppColors.appSurface)
        .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous))
        .padding(.horizontal, AppSpacing.lg)
    }
}
