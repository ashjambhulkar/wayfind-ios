import SwiftUI

/// How `ActivityPhotosSheet` should present when opened (e.g. timeline swipe vs menu).
enum ActivityPhotosManageEntry: Hashable {
    /// Land on grid or empty state.
    case browse
    /// Present the system photo picker after attachments finish loading.
    case openSystemPickerOnAppear
}

/// Identifies which activity to show when using `.sheet(item:)` — full manager vs view-only gallery.
struct ActivityPhotosSheetTarget: Identifiable, Hashable {
    enum Presentation: Hashable {
        case manage(ActivityPhotosManageEntry)
        case galleryOnly
    }

    let activityId: UUID
    let title: String
    var presentation: Presentation = .manage(.browse)

    var id: String {
        switch presentation {
        case .manage(let entry):
            let suffix = entry == .browse ? "browse" : "picker"
            return "\(activityId.uuidString)-manage-\(suffix)"
        case .galleryOnly:
            return "\(activityId.uuidString)-galleryOnly"
        }
    }
}

/// Overlapping thumbnails for activity attachments (timeline + recent activity).
struct ActivityFeedPhotoStackView: View {
    let items: [ActivityFeedPhotoStackItem]
    var maxVisible: Int = 3
    /// Default matches recent-activity rows; callers can pass a larger size for timeline-style previews.
    var tileSize: CGFloat = 38
    var tileCornerRadius: CGFloat = AppCornerRadius.small
    enum Arrangement {
        /// Loose fan — peek and tilt for sheet rows.
        case sheetRow
        /// Minimal offset, centered vertically with the headline row beside it.
        case timelineLeading
    }

    var arrangement: Arrangement = .sheetRow
    let onTap: () -> Void

    var body: some View {
        let visible = Array(items.prefix(maxVisible))
        let overflow = max(0, items.count - maxVisible)
        Button(action: onTap) {
            ZStack(alignment: arrangement == .timelineLeading ? .center : .bottomTrailing) {
                // Draw back-to-front so the first model item (cover from the
                // service) is the last subview and paints on top.
                ForEach(Array(visible.enumerated().reversed()), id: \.element.id) { index, item in
                    tile(for: item.url)
                        .rotationEffect(.degrees(stackTilt(depth: index)))
                        .offset(stackOffset(for: index, count: visible.count))
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
            .modifier(PhotoStackOuterInsets(arrangement: arrangement))
            .frame(
                width: frameWidth(for: visible.count),
                height: frameHeight(for: visible.count),
                alignment: arrangement == .timelineLeading ? .center : .bottomTrailing
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

    private var stackStepX: CGFloat {
        switch arrangement {
        case .sheetRow: return 7
        case .timelineLeading: return 2
        }
    }

    private var stackStepY: CGFloat {
        switch arrangement {
        case .sheetRow: return 2.5
        case .timelineLeading: return 1.25
        }
    }

    private func stackOffset(for index: Int, count: Int) -> CGSize {
        switch arrangement {
        case .sheetRow:
            return CGSize(
                width: -CGFloat(index) * stackStepX,
                height: CGFloat(index) * stackStepY
            )
        case .timelineLeading:
            guard count > 1 else { return .zero }
            let midY = CGFloat(count - 1) * stackStepY / 2
            let midX = CGFloat(count - 1) * stackStepX / 2
            let x = -CGFloat(index) * stackStepX + midX
            let y = CGFloat(index) * stackStepY - midY
            return CGSize(width: x, height: y)
        }
    }

    private func frameWidth(for visibleCount: Int) -> CGFloat {
        let spread = CGFloat(max(visibleCount - 1, 0)) * stackStepX
        switch arrangement {
        case .sheetRow:
            return tileSize + spread + 6
        case .timelineLeading:
            return tileSize + spread + AppSpacing.xs
        }
    }

    private func frameHeight(for visibleCount: Int) -> CGFloat {
        let verticalSpread = CGFloat(max(visibleCount - 1, 0)) * stackStepY
        switch arrangement {
        case .sheetRow:
            return tileSize + verticalSpread + 6 + 4
        case .timelineLeading:
            return tileSize + verticalSpread + AppSpacing.xs
        }
    }

    private func stackTilt(depth: Int) -> Double {
        switch arrangement {
        case .sheetRow:
            switch depth {
            case 0: return 0
            case 1: return -6
            case 2: return 5
            default: return 0
            }
        case .timelineLeading:
            switch depth {
            case 0: return 0
            case 1: return -3
            case 2: return 3
            default: return 0
            }
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
        .clipShape(RoundedRectangle(cornerRadius: tileCornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: tileCornerRadius, style: .continuous)
                .strokeBorder(AppColors.appDivider.opacity(0.9), lineWidth: 1)
        )
    }

    private var tilePlaceholder: some View {
        RoundedRectangle(cornerRadius: tileCornerRadius, style: .continuous)
            .fill(AppColors.appDivider.opacity(0.35))
    }
}

private struct PhotoStackOuterInsets: ViewModifier {
    let arrangement: ActivityFeedPhotoStackView.Arrangement

    func body(content: Content) -> some View {
        switch arrangement {
        case .sheetRow:
            content
                .padding(.top, 4)
                .padding(.leading, 3)
        case .timelineLeading:
            content
        }
    }
}

