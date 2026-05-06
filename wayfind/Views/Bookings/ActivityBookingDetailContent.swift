//
//  ActivityBookingDetailContent.swift
//  wayfind
//
//  Activity booking detail for `PlaceDetailSheet` — identity header, start
//  time, optional duration, ticket & provider, and venue address (with empty
//  state), using trip timezone.
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

    private var trimmedAddress: String? {
        let a = address?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return a.isEmpty ? nil : a
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.lg) {
            activitySummaryCard
            locationCard
        }
        .padding(.top, AppSpacing.md)
    }

    // MARK: - Summary

    private var activitySummaryCard: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            HStack(alignment: .center, spacing: AppSpacing.md) {
                ZStack {
                    Circle()
                        .fill(accent.opacity(0.14))
                        .frame(width: 56, height: 56)
                    Image(systemName: BookingCategory.activity.sfSymbol)
                        .font(.sectionHeader)
                        .foregroundStyle(accent)
                        .accessibilityHidden(true)
                }

                VStack(alignment: .leading, spacing: AppSpacing.xs) {
                    Text(String(localized: "Your activity"))
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

            scheduleBlock

            if let durationLine = durationTrimmed {
                HStack {
                    Spacer(minLength: 0)
                    Label(durationLine, systemImage: "clock.fill")
                        .font(.appCaption.weight(.semibold))
                        .foregroundStyle(accent)
                        .padding(.horizontal, AppSpacing.md)
                        .padding(.vertical, AppSpacing.sm)
                        .background(accent.opacity(0.12))
                        .clipShape(Capsule())
                        .accessibilityLabel(durationLine)
                    Spacer(minLength: 0)
                }
                .padding(.top, AppSpacing.xs)
            }

            detailDivider

            detailRow(
                icon: "number",
                title: String(localized: "Ticket"),
                value: ticketTrimmed.isEmpty ? String(localized: "Not specified") : ticketTrimmed
            )

            detailDivider

            detailRow(
                icon: "person.crop.circle.fill",
                title: String(localized: "Provider"),
                value: providerTrimmed.isEmpty ? String(localized: "Not specified") : providerTrimmed
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
        if !ticketTrimmed.isEmpty {
            return ticketTrimmed
        }
        if !providerTrimmed.isEmpty {
            return providerTrimmed
        }
        return String(localized: "Ticket or provider not set")
    }

    @ViewBuilder
    private var scheduleBlock: some View {
        if let instant = startTime {
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

                    Text(String(localized: "Add a start time when you edit this booking."))
                        .font(.appCaption)
                        .foregroundStyle(AppColors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private func dateSubtitle(for instant: Date) -> String {
        let day = instant.dayOfWeekShort(timeZone: timeZone)
        let date = instant.shortFormatted(timeZone: timeZone)
        return "\(day) · \(date)"
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
            Text(String(localized: "Venue"))
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
