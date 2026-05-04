//
//  ActivityBookingDetailContent.swift
//  wayfind
//
//  Activity booking detail for `PlaceDetailSheet` — start time, duration,
//  provider and ticket, optional venue address.
//

import SwiftUI

struct ActivityBookingDetailContent: View {
    let details: ActivityDetails
    let timeZone: TimeZone
    /// Wall-clock start from the itinerary row (`Place.startTime`).
    var startTime: Date? = nil
    var address: String? = nil

    private var accent: Color { BookingCategory.activity.color }

    private var providerTrimmed: String {
        details.provider.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var ticketTrimmed: String {
        details.ticketNumber.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var durationTrimmed: String? {
        let t = details.duration?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return t.isEmpty ? nil : t
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.lg) {
            scheduleCard
            bookingDetailsCard
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

            if let instant = startTime {
                HStack(alignment: .center, spacing: AppSpacing.md) {
                    ZStack {
                        Circle()
                            .fill(accent.opacity(0.14))
                            .frame(width: 52, height: 52)

                        Image(systemName: BookingCategory.activity.sfSymbol)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(accent)
                    }
                    .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: AppSpacing.xs) {
                        Text(instant.timeFormatted(timeZone: timeZone))
                            .font(.sectionHeader)
                            .foregroundStyle(AppColors.textPrimary)
                            .minimumScaleFactor(0.8)

                        Text(dateSubtitle(for: instant))
                            .font(.appBody)
                            .foregroundStyle(AppColors.textSecondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(String(localized: "Start time"))
                .accessibilityValue(
                    "\(instant.timeFormatted(timeZone: timeZone)), \(dateSubtitle(for: instant))"
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

                        Text("Set a start time in edit when you know it.")
                            .font(.appCaption)
                            .foregroundStyle(AppColors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityElement(children: .combine)
            }

            if let durationLine = durationTrimmed {
                Label(durationLine, systemImage: "clock.fill")
                    .font(.appCaption.weight(.semibold))
                    .foregroundStyle(accent)
                    .padding(.horizontal, AppSpacing.md)
                    .padding(.vertical, AppSpacing.sm)
                    .background(accent.opacity(0.12))
                    .clipShape(Capsule())
                    .accessibilityLabel(durationLine)
            }
        }
        .padding(AppSpacing.lg)
        .background(AppColors.appSurface)
        .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous))
        .padding(.horizontal, AppSpacing.lg)
        .padding(.top, AppSpacing.md)
    }

    private func dateSubtitle(for instant: Date) -> String {
        let day = instant.dayOfWeekShort(timeZone: timeZone)
        let date = instant.shortFormatted(timeZone: timeZone)
        return "\(day) · \(date)"
    }

    // MARK: - Booking

    private var bookingDetailsCard: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            Text("Booking")
                .font(.footnote.weight(.medium))
                .foregroundStyle(AppColors.textSecondary)
                .textCase(.uppercase)
                .kerning(0.5)

            VStack(spacing: 0) {
                activityDetailRow(
                    icon: "person.crop.circle.fill",
                    title: String(localized: "Provider"),
                    value: providerTrimmed.isEmpty ? String(localized: "Not specified") : providerTrimmed
                )
                activityDivider
                activityDetailRow(
                    icon: "number",
                    title: String(localized: "Ticket"),
                    value: ticketTrimmed.isEmpty ? String(localized: "Not specified") : ticketTrimmed
                )
            }
        }
        .padding(AppSpacing.lg)
        .background(AppColors.appSurface)
        .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous))
        .padding(.horizontal, AppSpacing.lg)
    }

    private var activityDivider: some View {
        Divider()
            .background(AppColors.appDivider.opacity(0.6))
            .padding(.vertical, AppSpacing.sm)
    }

    private func activityDetailRow(icon: String, title: String, value: String) -> some View {
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

    // MARK: - Venue

    private func locationCard(_ line: String) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            Text("Venue")
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
