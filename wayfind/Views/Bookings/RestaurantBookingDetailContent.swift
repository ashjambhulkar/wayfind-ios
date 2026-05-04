//
//  RestaurantBookingDetailContent.swift
//  wayfind
//
//  Restaurant booking detail layout for `PlaceDetailSheet` — reservation
//  time first, then party size and optional address, using trip clock.
//

import SwiftUI

struct RestaurantBookingDetailContent: View {
    let details: RestaurantDetails
    let timeZone: TimeZone
    var address: String? = nil

    private var accent: Color { BookingCategory.restaurant.color }

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.lg) {
            reservationCard
            partyCard
            if let trimmed = address?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty {
                locationCard(trimmed)
            }
        }
    }

    // MARK: - Reservation

    private var reservationCard: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            Text("Your reservation")
                .font(.footnote.weight(.medium))
                .foregroundStyle(AppColors.textSecondary)
                .textCase(.uppercase)
                .kerning(0.5)

            if let instant = details.reservationTime {
                HStack(alignment: .center, spacing: AppSpacing.md) {
                    ZStack {
                        Circle()
                            .fill(accent.opacity(0.14))
                            .frame(width: 52, height: 52)

                        Image(systemName: "clock.fill")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(accent)
                    }
                    .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: AppSpacing.xs) {
                        Text(instant.timeFormatted(timeZone: timeZone))
                            .font(.sectionHeader)
                            .foregroundStyle(AppColors.textPrimary)
                            .minimumScaleFactor(0.8)

                        Text(reservationDateLine(for: instant))
                            .font(.appBody)
                            .foregroundStyle(AppColors.textSecondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(String(localized: "Reservation time"))
                .accessibilityValue(
                    "\(instant.timeFormatted(timeZone: timeZone)), \(reservationDateLine(for: instant))"
                )
            } else {
                HStack(alignment: .center, spacing: AppSpacing.md) {
                    ZStack {
                        Circle()
                            .fill(AppColors.textSecondary.opacity(0.12))
                            .frame(width: 52, height: 52)

                        Image(systemName: "clock.badge.questionmark")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(AppColors.textSecondary)
                    }
                    .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: AppSpacing.xs) {
                        Text("Time TBD")
                            .font(.appBody.weight(.semibold))
                            .foregroundStyle(AppColors.textPrimary)

                        Text("Set the reservation time in edit when you know it.")
                            .font(.appCaption)
                            .foregroundStyle(AppColors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(AppSpacing.lg)
        .background(AppColors.appSurface)
        .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous))
        .padding(.horizontal, AppSpacing.lg)
        .padding(.top, AppSpacing.md)
    }

    private func reservationDateLine(for instant: Date) -> String {
        let day = instant.dayOfWeekShort(timeZone: timeZone)
        let date = instant.shortFormatted(timeZone: timeZone)
        return "\(day) · \(date)"
    }

    // MARK: - Party

    private var partyCard: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            Text("Party")
                .font(.footnote.weight(.medium))
                .foregroundStyle(AppColors.textSecondary)
                .textCase(.uppercase)
                .kerning(0.5)

            restaurantDetailRow(
                icon: "person.2.fill",
                title: String(localized: "Size"),
                value: partySizeDisplay
            )
        }
        .padding(AppSpacing.lg)
        .background(AppColors.appSurface)
        .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous))
        .padding(.horizontal, AppSpacing.lg)
    }

    private var partySizeDisplay: String {
        guard let p = details.partySize, p > 0 else {
            return String(localized: "Not specified")
        }
        if p == 1 {
            return String(localized: "Party of 1")
        }
        return String(localized: "Party of \(p)")
    }

    // MARK: - Location

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

    private func restaurantDetailRow(icon: String, title: String, value: String) -> some View {
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
