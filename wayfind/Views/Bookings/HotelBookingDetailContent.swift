//
//  HotelBookingDetailContent.swift
//  wayfind
//
//  Hotel booking detail for `PlaceDetailSheet` — separate check-in and
//  check-out cards (date, day, time), room, optional address.
//

import SwiftUI

struct HotelBookingDetailContent: View {
    let details: HotelDetails
    let timeZone: TimeZone
    /// Property or free-text address when the booking row has it.
    var address: String? = nil

    private var accent: Color { BookingCategory.hotel.color }

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.lg) {
            checkInCard
            checkOutCard
            roomCard
            if let trimmed = address?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty {
                locationCard(trimmed)
            }
        }
    }

    // MARK: - Check-in

    private var checkInCard: some View {
        hotelMomentCard(
            title: String(localized: "Check-in"),
            systemImage: "arrow.down.to.line.circle.fill",
            date: details.checkInDate,
            wallClockLabel: details.checkInTime,
            footerChipText: nightsSummaryLine,
            footerChipIcon: "moon.stars.fill"
        )
        .padding(.top, AppSpacing.md)
    }

    // MARK: - Check-out

    private var checkOutCard: some View {
        hotelMomentCard(
            title: String(localized: "Check-out"),
            systemImage: "arrow.up.from.line.circle.fill",
            date: details.checkOutDate,
            wallClockLabel: details.checkOutTime,
            footerChipText: nil,
            footerChipIcon: nil
        )
    }

    private func hotelMomentCard(
        title: String,
        systemImage: String,
        date: Date?,
        wallClockLabel: String?,
        footerChipText: String?,
        footerChipIcon: String?
    ) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            Text(title)
                .font(.footnote.weight(.medium))
                .foregroundStyle(AppColors.textSecondary)
                .textCase(.uppercase)
                .kerning(0.5)

            if let date {
                HStack(alignment: .center, spacing: AppSpacing.md) {
                    ZStack {
                        Circle()
                            .fill(accent.opacity(0.14))
                            .frame(width: 52, height: 52)

                        Image(systemName: systemImage)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(accent)
                    }
                    .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: AppSpacing.xs) {
                        Text("\(date.dayOfWeekShort(timeZone: timeZone)) · \(date.shortFormatted(timeZone: timeZone))")
                            .font(.appBody)
                            .foregroundStyle(AppColors.textSecondary)

                        Text(displayTime(for: date, wallClockLabel: wallClockLabel))
                            .font(.sectionHeader)
                            .foregroundStyle(AppColors.textPrimary)
                            .minimumScaleFactor(0.85)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityElement(children: .combine)
            } else {
                HStack(alignment: .center, spacing: AppSpacing.md) {
                    ZStack {
                        Circle()
                            .fill(AppColors.textSecondary.opacity(0.12))
                            .frame(width: 52, height: 52)

                        Image(systemName: "calendar.badge.questionmark")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(AppColors.textSecondary)
                    }
                    .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: AppSpacing.xs) {
                        Text("Date TBD")
                            .font(.appBody.weight(.semibold))
                            .foregroundStyle(AppColors.textPrimary)

                        Text("Set this in edit when you know it.")
                            .font(.appCaption)
                            .foregroundStyle(AppColors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityElement(children: .combine)
            }

            if let chipText = footerChipText,
               let chipIcon = footerChipIcon,
               !chipText.isEmpty {
                Label(chipText, systemImage: chipIcon)
                    .font(.appCaption.weight(.semibold))
                    .foregroundStyle(accent)
                    .padding(.horizontal, AppSpacing.md)
                    .padding(.vertical, AppSpacing.sm)
                    .background(accent.opacity(0.12))
                    .clipShape(Capsule())
                    .accessibilityLabel(chipText)
            }
        }
        .padding(AppSpacing.lg)
        .background(AppColors.appSurface)
        .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous))
        .padding(.horizontal, AppSpacing.lg)
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
        return String(localized: "\(n) nights")
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

    // MARK: - Room

    private var roomCard: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            Text("Room")
                .font(.footnote.weight(.medium))
                .foregroundStyle(AppColors.textSecondary)
                .textCase(.uppercase)
                .kerning(0.5)

            let room = details.roomType.trimmingCharacters(in: .whitespacesAndNewlines)
            hotelDetailRow(
                icon: "key.horizontal.fill",
                title: String(localized: "Type"),
                value: room.isEmpty ? String(localized: "Not specified") : room
            )
        }
        .padding(AppSpacing.lg)
        .background(AppColors.appSurface)
        .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous))
        .padding(.horizontal, AppSpacing.lg)
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

    private func hotelDetailRow(icon: String, title: String, value: String) -> some View {
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
    }
}
