//
//  CarRentalBookingDetailContent.swift
//  wayfind
//
//  Car rental booking detail for `PlaceDetailSheet` — company header,
//  pick-up / drop-off strip with times, rental span, vehicle type, and
//  optional billing address (with empty state), using trip timezone.
//

import SwiftUI

struct CarRentalBookingDetailContent: View {
    let details: CarRentalDetails
    let timeZone: TimeZone
    var address: String? = nil

    private var accent: Color { BookingCategory.carRental.color }

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.lg) {
            rentalSummaryCard
            locationCard
        }
        .padding(.top, AppSpacing.md)
    }

    private var companyDisplay: String {
        let c = details.company.trimmingCharacters(in: .whitespacesAndNewlines)
        return c.isEmpty ? String(localized: "Rental company TBD") : c
    }

    private var trimmedAddress: String? {
        let a = address?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return a.isEmpty ? nil : a
    }

    // MARK: - Main card

    private var rentalSummaryCard: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            HStack(alignment: .center, spacing: AppSpacing.md) {
                ZStack {
                    Circle()
                        .fill(accent.opacity(0.14))
                        .frame(width: 56, height: 56)
                    Image(systemName: "car.fill")
                        .font(.sectionHeader)
                        .foregroundStyle(accent)
                        .accessibilityHidden(true)
                }

                VStack(alignment: .leading, spacing: AppSpacing.xs) {
                    Text(companyDisplay)
                        .font(.sectionHeader)
                        .foregroundStyle(AppColors.textPrimary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.85)

                    Text(String(localized: "Pick-up & drop-off"))
                        .font(.appCaption)
                        .foregroundStyle(AppColors.textTertiary)
                }

                Spacer(minLength: 0)
            }

            detailDivider

            HStack(alignment: .top, spacing: AppSpacing.sm) {
                endpointColumn(
                    title: String(localized: "Pick-up"),
                    locationRaw: details.pickupLocation,
                    instant: details.pickupTime,
                    alignment: .leading
                )
                .frame(maxWidth: .infinity, alignment: .leading)

                routeConnector

                endpointColumn(
                    title: String(localized: "Drop-off"),
                    locationRaw: details.dropoffLocation,
                    instant: details.dropoffTime,
                    alignment: .trailing
                )
                .frame(maxWidth: .infinity, alignment: .trailing)
            }

            if let spanLine = rentalSpanSummaryLine {
                HStack {
                    Spacer(minLength: 0)
                    Label(spanLine, systemImage: "calendar")
                        .font(.appCaption.weight(.semibold))
                        .foregroundStyle(accent)
                        .padding(.horizontal, AppSpacing.md)
                        .padding(.vertical, AppSpacing.sm)
                        .background(accent.opacity(0.12))
                        .clipShape(Capsule())
                        .accessibilityLabel(spanLine)
                    Spacer(minLength: 0)
                }
                .padding(.top, AppSpacing.xs)
            }

            detailDivider

            detailRow(
                icon: "key.horizontal.fill",
                title: String(localized: "Vehicle"),
                value: vehicleTypeDisplay
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

    private var routeConnector: some View {
        VStack(spacing: AppSpacing.xs) {
            Image(systemName: "car.side.fill")
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
        .accessibilityLabel(String(localized: "Car rental"))
    }

    private func endpointColumn(
        title: String,
        locationRaw: String,
        instant: Date?,
        alignment: HorizontalAlignment
    ) -> some View {
        let locationLine = displayLocation(locationRaw)
        return VStack(alignment: alignment, spacing: AppSpacing.xs) {
            Text(title)
                .font(.appSmall.weight(.semibold))
                .foregroundStyle(AppColors.textSecondary)
                .textCase(.uppercase)

            Text(locationLine)
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

    private func displayLocation(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return String(localized: "Not specified")
        }
        return trimmed
    }

    private var rentalSpanSummaryLine: String? {
        guard let pick = details.pickupTime, let ret = details.dropoffTime else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let start = calendar.startOfDay(for: pick)
        let end = calendar.startOfDay(for: ret)
        let days = calendar.dateComponents([.day], from: start, to: end).day ?? 0
        if days <= 0 {
            return String(localized: "Same-day rental")
        }
        if days == 1 {
            return String(localized: "1 day")
        }
        return String(format: String(localized: "%d days"), days)
    }

    private var vehicleTypeDisplay: String {
        let trimmed = details.carType.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return String(localized: "Not specified")
        }
        return trimmed
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
