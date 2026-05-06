//
//  TransportBookingDetailContent.swift
//  wayfind
//
//  Transport booking detail for `PlaceDetailSheet` — identity header,
//  departure / arrival strip with times, operator / service / seat, and
//  optional stop address (with empty state), using trip timezone.
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

    private var trimmedAddress: String? {
        let a = address?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return a.isEmpty ? nil : a
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.lg) {
            transportSummaryCard
            locationCard
        }
        .padding(.top, AppSpacing.md)
    }

    // MARK: - Summary

    private var transportSummaryCard: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            HStack(alignment: .center, spacing: AppSpacing.md) {
                ZStack {
                    Circle()
                        .fill(accent.opacity(0.14))
                        .frame(width: 56, height: 56)
                    Image(systemName: BookingCategory.transport.sfSymbol)
                        .font(.sectionHeader)
                        .foregroundStyle(accent)
                        .accessibilityHidden(true)
                }

                VStack(alignment: .leading, spacing: AppSpacing.xs) {
                    Text(String(localized: "Your trip"))
                        .font(.sectionHeader)
                        .foregroundStyle(AppColors.textPrimary)

                    Text(identitySubtitle)
                        .font(.appCaption)
                        .foregroundStyle(AppColors.textTertiary)
                        .lineLimit(2)
                }

                Spacer(minLength: 0)
            }

            detailDivider

            HStack(alignment: .top, spacing: AppSpacing.sm) {
                stationColumn(
                    title: String(localized: "From"),
                    stationRaw: details.departureStation,
                    instant: details.departureTime,
                    alignment: .leading
                )
                .frame(maxWidth: .infinity, alignment: .leading)

                routeConnector

                stationColumn(
                    title: String(localized: "To"),
                    stationRaw: details.arrivalStation,
                    instant: details.arrivalTime,
                    alignment: .trailing
                )
                .frame(maxWidth: .infinity, alignment: .trailing)
            }

            if let duration = journeyDurationLabel {
                HStack {
                    Spacer(minLength: 0)
                    Text(duration)
                        .font(.appCaption.weight(.semibold))
                        .foregroundStyle(AppColors.textSecondary)
                        .padding(.horizontal, AppSpacing.md)
                        .padding(.vertical, AppSpacing.sm)
                        .background(accent.opacity(0.1), in: Capsule())
                        .accessibilityLabel(String(localized: "Journey time"))
                        .accessibilityValue(duration)
                    Spacer(minLength: 0)
                }
                .padding(.top, AppSpacing.xs)
            }

            detailDivider

            detailRow(
                icon: "building.2.fill",
                title: String(localized: "Operator"),
                value: operatorTrimmed.isEmpty ? String(localized: "Not specified") : operatorTrimmed
            )

            detailDivider

            detailRow(
                icon: "number",
                title: String(localized: "Service"),
                value: serviceTrimmed.isEmpty ? String(localized: "Not specified") : serviceTrimmed
            )

            detailDivider

            detailRow(
                icon: "rectangle.inset.filled.and.person.filled",
                title: String(localized: "Seat"),
                value: seatTrimmed.isEmpty ? String(localized: "Not specified") : seatTrimmed
            )
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

    private var identitySubtitle: String {
        switch (operatorTrimmed.isEmpty, serviceTrimmed.isEmpty) {
        case (false, false):
            return "\(operatorTrimmed) · \(serviceTrimmed)"
        case (false, true):
            return operatorTrimmed
        case (true, false):
            return serviceTrimmed
        case (true, true):
            return String(localized: "Operator & service not set")
        }
    }

    private var routeConnector: some View {
        VStack(spacing: AppSpacing.xs) {
            Image(systemName: BookingCategory.transport.sfSymbol)
                .font(.sectionHeader)
                .foregroundStyle(accent)
                .accessibilityHidden(true)
            Capsule()
                .fill(AppColors.appDivider)
                .frame(width: 32, height: 3)
        }
        .padding(.top, AppSpacing.sm)
        .frame(minWidth: 72)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(String(localized: "Transport"))
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
                    .font(.tripDetailHeroTitle)
                    .foregroundStyle(AppColors.textPrimary)
                    .monospacedDigit()
                    .minimumScaleFactor(0.75)
                    .lineLimit(1)

                Text(dateSubtitle(for: instant))
                    .font(.appCaption)
                    .foregroundStyle(AppColors.textSecondary)
            } else {
                Text(String(localized: "Time TBD"))
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

    /// Wall-clock span between departure and arrival when both are set (same idea as timeline transport card).
    private var journeyDurationLabel: String? {
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

    private var detailDivider: some View {
        Rectangle()
            .fill(AppColors.appDivider.opacity(0.85))
            .frame(height: 1)
    }

    private func detailRow(icon: String, title: String, value: String) -> some View {
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

    // MARK: - Location

    private var locationCard: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            Text(String(localized: "Location"))
                .font(.footnote.weight(.medium))
                .foregroundStyle(AppColors.textSecondary)
                .textCase(.uppercase)
                .kerning(0.5)

            if let line = trimmedAddress {
                HStack(alignment: .top, spacing: AppSpacing.md) {
                    Image(systemName: "mappin.and.ellipse")
                        .font(.appBody.weight(.semibold))
                        .foregroundStyle(accent)
                        .frame(width: 22, alignment: .center)

                    Text(line)
                        .font(.appBody)
                        .foregroundStyle(AppColors.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(String(localized: "Address"))
                .accessibilityValue(line)
            } else {
                HStack(alignment: .top, spacing: AppSpacing.md) {
                    Image(systemName: "mappin.slash")
                        .font(.appBody.weight(.semibold))
                        .foregroundStyle(AppColors.textTertiary)
                        .frame(width: 22, alignment: .center)

                    Text(String(localized: "No address on this booking yet"))
                        .font(.appBody)
                        .foregroundStyle(AppColors.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(AppSpacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColors.appSurface)
        .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous))
        .padding(.horizontal, AppSpacing.lg)
    }
}
