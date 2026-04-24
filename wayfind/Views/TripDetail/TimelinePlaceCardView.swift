import SwiftUI

struct TimelinePlaceCardView: View {
    let place: Place
    let dayNumber: Int

    var onEdit: () -> Void = {}
    var onMoveToDay: () -> Void = {}
    var onMoveToIdeas: () -> Void = {}
    var onDelete: () -> Void = {}

    private var dayColor: Color {
        AppColors.dayColor(for: dayNumber)
    }

    private var categorySymbol: String {
        place.categoryEnum.sfSymbol
    }

    private var timeRangeText: String? {
        switch (place.startTime, place.endTime) {
        case let (start?, end?):
            return "\(start.timeFormatted) - \(end.timeFormatted)"
        case let (start?, nil):
            return start.timeFormatted
        default:
            return nil
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: AppSpacing.sm) {
            ZStack(alignment: .top) {
                TimelineRailView.railLine()
                    .frame(maxHeight: .infinity)
                TimelineRailView.railDot(isBooking: false, color: dayColor)
                    .padding(.top, 2)
            }
            .frame(width: 40)

            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                HStack(alignment: .firstTextBaseline, spacing: AppSpacing.xs) {
                    Image(systemName: categorySymbol)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(AppColors.textSecondary)
                    Text(place.name)
                        .font(.cardTitle)
                        .foregroundStyle(AppColors.textPrimary)
                }

                if let address = place.address, !address.isEmpty {
                    Text(address)
                        .font(.appCaption)
                        .foregroundStyle(AppColors.textSecondary)
                        .lineLimit(1)
                }

                if let timeRangeText {
                    Text(timeRangeText)
                        .font(.appCaption)
                        .foregroundStyle(AppColors.textTertiary)
                }
            }
            .padding(AppSpacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppColors.appSurface)
            .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous))
            .shadow(color: Color.black.opacity(0.08), radius: 6, x: 0, y: 3)
        }
        .contextMenu {
            Button("Edit", action: onEdit)
            Button("Move to Day", action: onMoveToDay)
            if dayNumber != 0 {
                Button("Move to Ideas", action: onMoveToIdeas)
            }
            Button("Delete", role: .destructive, action: onDelete)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(place.categoryEnum.label): \(place.name)\(timeRangeText.map { ", \($0)" } ?? "")")
    }
}


// =============================================================================

