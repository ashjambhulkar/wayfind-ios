import SwiftUI

struct ActiveTripHeroView: View {
    let trip: Trip
    var action: () -> Void = {}

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .bottomLeading) {
                heroImage
                    .frame(maxWidth: .infinity)
                    .frame(height: 180)
                    .clipped()

                LinearGradient(
                    colors: [.clear, Color.black.opacity(0.6)],
                    startPoint: .top,
                    endPoint: .bottom
                )

                VStack(alignment: .leading, spacing: AppSpacing.xs) {
                    Text("Day \(trip.currentDayNumber ?? 1) of \(trip.dayCount)")
                        .font(.appSmall)
                        .foregroundStyle(.white)
                        .padding(.horizontal, AppSpacing.sm)
                        .padding(.vertical, AppSpacing.xs)
                        .background(Color.white.opacity(0.2))
                        .clipShape(Capsule())

                    Text(trip.title)
                        .font(.sectionHeader)
                        .foregroundStyle(.white)
                        .bold()

                    Text("\(trip.startDate.shortFormatted) – \(trip.endDate.shortFormatted)")
                        .font(.appCaption)
                        .foregroundStyle(.white.opacity(0.8))
                }
                .padding(AppSpacing.lg)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 180)
            .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.xLarge, style: .continuous))
            .shadow(color: Color.black.opacity(0.12), radius: 10, x: 0, y: 4)
            .contentShape(RoundedRectangle(cornerRadius: AppCornerRadius.xLarge, style: .continuous))
        }
        .accessibilityLabel("Current trip: \(trip.title), Day \(trip.currentDayNumber ?? 1) of \(trip.dayCount)")
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var heroImage: some View {
        if let urlString = trip.coverImageUrl, let url = URL(string: urlString) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .empty, .failure:
                    PlaceholderGradientView(destinationName: trip.destination)
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFill()
                @unknown default:
                    PlaceholderGradientView(destinationName: trip.destination)
                }
            }
        } else {
            PlaceholderGradientView(destinationName: trip.destination)
        }
    }
}

// =============================================================================


#if DEBUG
#Preview("Active trip hero") {
    ActiveTripHeroView(trip: .previewActive, action: {})
        .padding()
        .background(AppColors.appBackground)
}
#endif
