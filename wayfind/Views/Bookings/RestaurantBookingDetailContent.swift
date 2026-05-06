//
//  RestaurantBookingDetailContent.swift
//  wayfind
//
//  Restaurant booking detail for `PlaceDetailSheet` — reservation identity
//  header, hero time + date, party size, and address (with empty state),
//  using the trip-destination timezone.
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
            locationCard
        }
        .padding(.top, AppSpacing.md)
    }

    /// Prefer address saved on the booking payload; fall back to the place’s `address`.
    private var resolvedAddressLine: String? {
        let fromDetails = details.address?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !fromDetails.isEmpty { return fromDetails }
        let fromPlace = address?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return fromPlace.isEmpty ? nil : fromPlace
    }

    // MARK: - Reservation

    private var reservationCard: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            HStack(alignment: .center, spacing: AppSpacing.md) {
                ZStack {
                    Circle()
                        .fill(accent.opacity(0.14))
                        .frame(width: 56, height: 56)
                    Image(systemName: "fork.knife")
                        .font(.sectionHeader)
                        .foregroundStyle(accent)
                        .accessibilityHidden(true)
                }

                VStack(alignment: .leading, spacing: AppSpacing.xs) {
                    Text(String(localized: "Your reservation"))
                        .font(.sectionHeader)
                        .foregroundStyle(AppColors.textPrimary)
                    Text(String(localized: "Time uses your trip timezone"))
                        .font(.appCaption)
                        .foregroundStyle(AppColors.textTertiary)
                }

                Spacer(minLength: 0)
            }

            detailDivider

            reservationTimeBlock

            detailDivider

            detailRow(
                icon: "person.2.fill",
                title: String(localized: "Party"),
                value: partySizeDisplay
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

    @ViewBuilder
    private var reservationTimeBlock: some View {
        if let instant = details.reservationTime {
            HStack(alignment: .center, spacing: AppSpacing.md) {
                ZStack {
                    Circle()
                        .fill(accent.opacity(0.14))
                        .frame(width: 52, height: 52)
                    Image(systemName: "clock.fill")
                        .font(.sectionHeader)
                        .foregroundStyle(accent)
                }
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: AppSpacing.xs) {
                    Text(instant.timeFormatted(timeZone: timeZone))
                        .font(.tripDetailHeroTitle)
                        .foregroundStyle(AppColors.textPrimary)
                        .monospacedDigit()
                        .minimumScaleFactor(0.75)
                        .lineLimit(1)

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
                        .fill(AppColors.textTertiary.opacity(0.12))
                        .frame(width: 52, height: 52)
                    Image(systemName: "clock.badge.questionmark")
                        .font(.sectionHeader)
                        .foregroundStyle(AppColors.textTertiary)
                }
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: AppSpacing.xs) {
                    Text(String(localized: "Time TBD"))
                        .font(.appBody.weight(.semibold))
                        .foregroundStyle(AppColors.textPrimary)

                    Text(String(localized: "Add a reservation time when you edit this booking."))
                        .font(.appCaption)
                        .foregroundStyle(AppColors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private func reservationDateLine(for instant: Date) -> String {
        let day = instant.dayOfWeekShort(timeZone: timeZone)
        let date = instant.shortFormatted(timeZone: timeZone)
        return "\(day) · \(date)"
    }

    private var partySizeDisplay: String {
        guard let p = details.partySize, p > 0 else {
            return String(localized: "Not specified")
        }
        if p == 1 {
            return String(localized: "Party of 1")
        }
        return String(format: String(localized: "Party of %d"), p)
    }

    // MARK: - Location

    private var locationCard: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            Text(String(localized: "Location"))
                .font(.footnote.weight(.medium))
                .foregroundStyle(AppColors.textSecondary)
                .textCase(.uppercase)
                .kerning(0.5)

            if let line = resolvedAddressLine {
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
}
