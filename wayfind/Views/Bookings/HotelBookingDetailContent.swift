//
//  HotelBookingDetailContent.swift
//  wayfind
//
//  Hotel booking detail for `PlaceDetailSheet` — property identity header,
//  check-in / check-out columns (car-rental style), nights chip, room type,
//  and location card, using trip timezone.
//

import SwiftUI

struct HotelBookingDetailContent: View {
    let details: HotelDetails
    let timeZone: TimeZone
    /// Hotel name from the itinerary row (`Place.name`).
    var propertyName: String
    var confirmationNumber: String? = nil
    var address: String? = nil

    private var accent: Color { BookingCategory.hotel.color }

    private var trimmedAddress: String? {
        let a = address?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return a.isEmpty ? nil : a
    }

    private var propertyTitle: String {
        let n = propertyName.trimmingCharacters(in: .whitespacesAndNewlines)
        return n.isEmpty ? String(localized: "Your stay") : n
    }

    private var confirmationTrimmed: String? {
        let c = confirmationNumber?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return c.isEmpty ? nil : c
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.lg) {
            hotelSummaryCard
            locationCard
        }
        .padding(.top, AppSpacing.md)
    }

    // MARK: - Main card

    private var hotelSummaryCard: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            HStack(alignment: .center, spacing: AppSpacing.md) {
                ZStack {
                    Circle()
                        .fill(accent.opacity(0.14))
                        .frame(width: 56, height: 56)
                    Image(systemName: BookingCategory.hotel.sfSymbol)
                        .font(.sectionHeader)
                        .foregroundStyle(accent)
                        .accessibilityHidden(true)
                }

                VStack(alignment: .leading, spacing: AppSpacing.xs) {
                    Text(propertyTitle)
                        .font(.sectionHeader)
                        .foregroundStyle(AppColors.textPrimary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.85)

                    Text(String(localized: "Check-in & check-out"))
                        .font(.appCaption)
                        .foregroundStyle(AppColors.textTertiary)
                }

                Spacer(minLength: AppSpacing.sm)

                if let conf = confirmationTrimmed {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(String(localized: "Confirmation"))
                            .font(.appSmall.weight(.medium))
                            .foregroundStyle(AppColors.textSecondary)

                        Text(conf)
                            .font(.appCaption.weight(.semibold))
                            .monospaced()
                            .foregroundStyle(accent)
                            .lineLimit(2)
                            .multilineTextAlignment(.trailing)
                            .minimumScaleFactor(0.8)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(String(localized: "Confirmation number"))
                    .accessibilityValue(conf)
                }
            }

            detailDivider

            HStack(alignment: .top, spacing: AppSpacing.sm) {
                stayColumn(
                    title: String(localized: "Check-in"),
                    date: details.checkInDate,
                    wallClockLabel: details.checkInTime,
                    alignment: .leading
                )
                .frame(maxWidth: .infinity, alignment: .leading)

                stayConnector

                stayColumn(
                    title: String(localized: "Check-out"),
                    date: details.checkOutDate,
                    wallClockLabel: details.checkOutTime,
                    alignment: .trailing
                )
                .frame(maxWidth: .infinity, alignment: .trailing)
            }

            if let nightsLine = nightsSummaryLine {
                HStack {
                    Spacer(minLength: 0)
                    Label(nightsLine, systemImage: "moon.stars.fill")
                        .font(.appCaption.weight(.semibold))
                        .foregroundStyle(accent)
                        .padding(.horizontal, AppSpacing.md)
                        .padding(.vertical, AppSpacing.sm)
                        .background(accent.opacity(0.12))
                        .clipShape(Capsule())
                        .accessibilityLabel(nightsLine)
                    Spacer(minLength: 0)
                }
                .padding(.top, AppSpacing.xs)
            }

            detailDivider

            detailRow(
                icon: "key.horizontal.fill",
                title: String(localized: "Room"),
                value: roomTypeDisplay
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

    private var stayConnector: some View {
        VStack(spacing: AppSpacing.xs) {
            Image(systemName: "bed.double.fill")
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
        .accessibilityLabel(String(localized: "Hotel stay"))
    }

    private func stayColumn(
        title: String,
        date: Date?,
        wallClockLabel: String?,
        alignment: HorizontalAlignment
    ) -> some View {
        VStack(alignment: alignment, spacing: AppSpacing.xs) {
            Text(title)
                .font(.appSmall.weight(.semibold))
                .foregroundStyle(AppColors.textSecondary)
                .textCase(.uppercase)

            if let date {
                Text("\(date.dayOfWeekShort(timeZone: timeZone)) · \(date.shortFormatted(timeZone: timeZone))")
                    .font(.appBody)
                    .foregroundStyle(AppColors.textSecondary)
                    .multilineTextAlignment(alignment == .leading ? .leading : .trailing)

                Text(displayTime(for: date, wallClockLabel: wallClockLabel))
                    .font(.tripDetailHeroTitle)
                    .foregroundStyle(AppColors.textPrimary)
                    .monospacedDigit()
                    .minimumScaleFactor(0.75)
                    .lineLimit(2)
                    .multilineTextAlignment(alignment == .leading ? .leading : .trailing)
            } else {
                Text(String(localized: "Date TBD"))
                    .font(.appBody.weight(.semibold))
                    .foregroundStyle(AppColors.textPrimary)

                Text(String(localized: "Add when you edit this booking."))
                    .font(.appCaption)
                    .foregroundStyle(AppColors.textSecondary)
                    .multilineTextAlignment(alignment == .leading ? .leading : .trailing)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func displayTime(for date: Date, wallClockLabel: String?) -> String {
        let wall = wallClockLabel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !wall.isEmpty { return wall }
        return date.timeFormatted(timeZone: timeZone)
    }

    private var nightsSummaryLine: String? {
        let n = resolvedNightCount
        guard let n, n > 0 else { return nil }
        if n == 1 { return String(localized: "1 night") }
        return String(format: String(localized: "%d nights"), n)
    }

    private var resolvedNightCount: Int? {
        if let n = details.nights, n > 0 { return n }
        guard let checkIn = details.checkInDate, let checkOut = details.checkOutDate else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let start = calendar.startOfDay(for: checkIn)
        let end = calendar.startOfDay(for: checkOut)
        let days = calendar.dateComponents([.day], from: start, to: end).day ?? 0
        return max(0, days)
    }

    private var roomTypeDisplay: String {
        let room = details.roomType.trimmingCharacters(in: .whitespacesAndNewlines)
        return room.isEmpty ? String(localized: "Not specified") : room
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
