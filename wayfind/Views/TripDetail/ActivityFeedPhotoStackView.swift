import SwiftUI

/// Identifies which activity to show in `ActivityPhotosSheet` when using `.sheet(item:)`.
struct ActivityPhotosSheetTarget: Identifiable, Hashable {
    let activityId: UUID
    let title: String
    var id: UUID { activityId }
}

/// Overlapping thumbnails for activity attachments (timeline + recent activity).
struct ActivityFeedPhotoStackView: View {
    let items: [ActivityFeedPhotoStackItem]
    var maxVisible: Int = 3
    let onTap: () -> Void

    private let tileSize: CGFloat = 38
    /// Horizontal step between stack layers (peek of cards underneath).
    private var stackStepX: CGFloat { 7 }
    /// Vertical step so back cards sit slightly lower — reads as a pile.
    private var stackStepY: CGFloat { 2.5 }

    var body: some View {
        let visible = Array(items.prefix(maxVisible))
        let overflow = max(0, items.count - maxVisible)
        let spreadX = CGFloat(max(visible.count - 1, 0)) * stackStepX
        Button(action: onTap) {
            ZStack(alignment: .bottomTrailing) {
                // Draw back-to-front so the first model item (cover from the
                // service) is the last subview and paints on top.
                ForEach(Array(visible.enumerated().reversed()), id: \.element.id) { index, item in
                    tile(for: item.url)
                        .rotationEffect(.degrees(stackTilt(depth: index)))
                        .offset(
                            x: -CGFloat(index) * stackStepX,
                            y: CGFloat(index) * stackStepY
                        )
                        .shadow(
                            color: index == 0 ? Color.black.opacity(0.2) : Color.black.opacity(0.06),
                            radius: index == 0 ? 4 : 2,
                            x: 0,
                            y: index == 0 ? 2 : 1
                        )
                        .overlay(alignment: .bottomTrailing) {
                            if index == 0, overflow > 0 {
                                Text("+\(overflow)")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(.white)
                                    .padding(4)
                                    .background(Circle().fill(Color.black.opacity(0.58)))
                                    .offset(x: 4, y: 4)
                            }
                        }
                }
            }
            .padding(.top, 4)
            .padding(.leading, 3)
            .frame(
                width: tileSize + spreadX + 6,
                height: tileSize + CGFloat(max(visible.count - 1, 0)) * stackStepY + 6,
                alignment: .bottomTrailing
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            items.count == 1
                ? String(localized: "1 photo")
                : "\(items.count) photos"
        )
        .accessibilityHint(String(localized: "Opens gallery"))
    }

    /// Alternating tilt by depth so layers read as a messy real-world stack.
    private func stackTilt(depth: Int) -> Double {
        switch depth {
        case 0: return 0
        case 1: return -6
        case 2: return 5
        default: return 0
        }
    }

    @ViewBuilder
    private func tile(for url: URL) -> some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let image):
                image
                    .resizable()
                    .scaledToFill()
            case .failure:
                tilePlaceholder
            case .empty:
                tilePlaceholder
            @unknown default:
                tilePlaceholder
            }
        }
        .frame(width: tileSize, height: tileSize)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(AppColors.appDivider.opacity(0.9), lineWidth: 1)
        )
    }

    private var tilePlaceholder: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(AppColors.appDivider.opacity(0.35))
    }
}
