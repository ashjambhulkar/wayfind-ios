//
//  CarRentalBookingDetailContent.swift
//  wayfind
//
//  Car rental booking detail for `PlaceDetailSheet` — pick-up and return
//  columns, optional span summary, vehicle row, optional address.
//

import SwiftUI

struct CarRentalBookingDetailContent: View {
    let details: CarRentalDetails
    let timeZone: TimeZone
    var address: String? = nil

    private var accent: Color { BookingCategory.carRental.color }

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.lg) {
            pickupReturnCard
            vehicleCard
            if let trimmed = address?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty {
                locationCard(trimmed)
            }
        }
    }

    // MARK: - Pick-up & return

    private var pickupReturnCard: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            Text("Pick-up & return")
                .font(.footnote.weight(.medium))
                .foregroundStyle(AppColors.textSecondary)
                .textCase(.uppercase)
                .kerning(0.5)

            HStack(alignment: .top, spacing: AppSpacing.md) {
                endpointColumn(
                    title: String(localized: "Pick-up"),
                    locationRaw: details.pickupLocation,
                    instant: details.pickupTime,
                    alignment: .leading
                )
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(spacing: AppSpacing.xs) {
                    Image(systemName: "car.fill")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(accent)
                        .accessibilityHidden(true)
                    Capsule()
                        .fill(AppColors.appDivider)
                        .frame(width: 28, height: 3)
                }
                .padding(.top, AppSpacing.md)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(String(localized: "Car rental"))

                endpointColumn(
                    title: String(localized: "Drop-off"),
                    locationRaw: details.dropoffLocation,
                    instant: details.dropoffTime,
                    alignment: .trailing
                )
                .frame(maxWidth: .infinity, alignment: .trailing)
            }

            if let spanLine = rentalSpanSummaryLine {
                Label(spanLine, systemImage: "calendar")
                    .font(.appCaption.weight(.semibold))
                    .foregroundStyle(accent)
                    .padding(.horizontal, AppSpacing.md)
                    .padding(.vertical, AppSpacing.sm)
                    .background(accent.opacity(0.12))
                    .clipShape(Capsule())
                    .accessibilityLabel(spanLine)
            }
        }
        .padding(AppSpacing.lg)
        .background(AppColors.appSurface)
        .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous))
        .padding(.horizontal, AppSpacing.lg)
        .padding(.top, AppSpacing.md)
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
        return String(localized: "\(days) days")
    }

    // MARK: - Vehicle

    private var vehicleCard: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            Text("Vehicle")
                .font(.footnote.weight(.medium))
                .foregroundStyle(AppColors.textSecondary)
                .textCase(.uppercase)
                .kerning(0.5)

            carDetailRow(
                icon: "key.horizontal.fill",
                title: String(localized: "Type"),
                value: vehicleTypeDisplay
            )
        }
        .padding(AppSpacing.lg)
        .background(AppColors.appSurface)
        .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous))
        .padding(.horizontal, AppSpacing.lg)
    }

    private var vehicleTypeDisplay: String {
        let trimmed = details.carType.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return String(localized: "Not specified")
        }
        return trimmed
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

    private func carDetailRow(icon: String, title: String, value: String) -> some View {
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
