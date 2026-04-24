import SwiftUI

struct WishlistSectionView: View {
    let places: [Place]
    var onAssign: (Place) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(places.enumerated()), id: \.element.id) { index, place in
                WishlistPlaceRowView(place: place) {
                    HapticManager.medium()
                    onAssign(place)
                }

                if index < places.count - 1 {
                    Divider()
                        .background(AppColors.appDivider)
                }
            }
        }
    }
}

private struct WishlistPlaceRowView: View {
    let place: Place
    let onAdd: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: AppSpacing.sm) {
            Image(systemName: place.categoryEnum.sfSymbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(AppColors.textSecondary)
                .frame(width: 24, alignment: .center)

            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                Text(place.name)
                    .font(.cardTitle)
                    .foregroundStyle(AppColors.textPrimary)

                if let address = place.address, !address.isEmpty {
                    Text(address)
                        .font(.appCaption)
                        .foregroundStyle(AppColors.textSecondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            Button {
                onAdd()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(AppColors.appPrimary)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(AppSpacing.md)
        .background(AppColors.appSurface)
        .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous))
    }
}

// =============================================================================

