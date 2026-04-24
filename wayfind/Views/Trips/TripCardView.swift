import SwiftUI

struct TripCardView: View {
    let trip: Trip
    var action: () -> Void

    private var isUpcoming: Bool {
        trip.status == .upcoming
    }

    private var isPast: Bool {
        trip.status == .past
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 0) {
                imageSection
                    .frame(height: 120)
                    .clipped()

                VStack(alignment: .leading, spacing: AppSpacing.xs) {
                    Text(trip.title)
                        .font(.cardTitle)
                        .foregroundStyle(AppColors.textPrimary)
                        .lineLimit(1)

                    Text("\(trip.startDate.shortFormatted) 􀆊 \(trip.endDate.shortFormatted)")
                        .font(.appCaption)
                        .foregroundStyle(AppColors.textSecondary)

                    if isUpcoming {
                        Text("In \(trip.daysUntilStart ?? 0) days")
                            .font(.appCaption)
                            .foregroundStyle(AppColors.appPrimary)
                    } else if isPast {
                        Text("Completed")
                            .font(.appCaption)
                            .foregroundStyle(AppColors.textTertiary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(AppSpacing.md)
                .background(AppColors.appSurface)
            }
            .frame(width: 160, height: 200)
            .background(AppColors.appSurface)
            .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous))
            .shadow(color: Color.black.opacity(0.08), radius: 6, x: 0, y: 3)
        }
        .accessibilityLabel("\(trip.title), \(trip.status == .upcoming ? "starts in \(trip.daysUntilStart ?? 0) days" : "completed")")
        .buttonStyle(WayfindCardButtonStyle())
    }

    @ViewBuilder
    private var imageSection: some View {
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

private struct WayfindCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(AppSpring.snappy, value: configuration.isPressed)
    }
}

// =============================================================================

