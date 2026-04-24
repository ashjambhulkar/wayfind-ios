import SwiftUI

struct MoveToDaySheet: View {
    let place: Place
    let days: [ItineraryDay]
    let currentDayId: UUID
    let placesPerDay: [UUID: Int]
    var onMove: (UUID) -> Void

    @Environment(\.dismiss) private var dismiss

    private var scheduledDays: [ItineraryDay] {
        days.filter { !$0.isWishlist }.sorted { $0.dayNumber < $1.dayNumber }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                Text("Move")
                    .font(.sectionHeader)
                    .foregroundStyle(AppColors.textPrimary)
                Text(place.name)
                    .font(.sectionHeader)
                    .foregroundStyle(AppColors.textPrimary)
            }

            Text("Choose a day")
                .font(.appCaption)
                .foregroundStyle(AppColors.textSecondary)
                .padding(.top, AppSpacing.xs)

            ScrollView {
                VStack(spacing: AppSpacing.sm) {
                    ForEach(scheduledDays) { day in
                        dayRow(day)
                    }
                }
                .padding(.top, AppSpacing.lg)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, AppSpacing.xl)
        .padding(.horizontal, AppSpacing.lg)
        .background(AppColors.appBackground)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func dayRow(_ day: ItineraryDay) -> some View {
        let count = placesPerDay[day.id] ?? 0
        let isCurrent = day.id == currentDayId

        return Button {
            guard !isCurrent else { return }
            onMove(day.id)
            dismiss()
        } label: {
            HStack(alignment: .center, spacing: AppSpacing.md) {
                VStack(alignment: .leading, spacing: AppSpacing.xs) {
                    Text(dayTitle(for: day))
                        .font(.cardTitle)
                        .foregroundStyle(AppColors.textPrimary)
                        .multilineTextAlignment(.leading)

                    Group {
                        if count == 0 {
                            Text("empty")
                                .font(.appCaption)
                                .foregroundStyle(AppColors.appPrimary)
                        } else {
                            Text("\(count) items")
                                .font(.appCaption)
                                .foregroundStyle(AppColors.textTertiary)
                        }
                    }
                }

                Spacer(minLength: 0)

                if isCurrent {
                    Text("Current")
                        .font(.appSmall)
                        .foregroundStyle(AppColors.textTertiary)
                }
            }
            .padding(.vertical, AppSpacing.md)
            .padding(.horizontal, AppSpacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppColors.appSurface)
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(AppColors.dayColor(for: day.dayNumber))
                    .frame(width: 4)
                    .frame(maxHeight: .infinity)
            }
            .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous))
            .opacity(isCurrent ? 0.5 : 1)
        }
        .buttonStyle(.plain)
        .disabled(isCurrent)
    }

    private func dayTitle(for day: ItineraryDay) -> String {
        if let date = day.date {
            return "Day \(day.dayNumber) — \(date.dayOfWeekShort), \(date.shortFormatted)"
        }
        return "Day \(day.dayNumber)"
    }
}


// =============================================================================

