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
        /// Centered polaroid-style stack (white mat, slight rotations) on the trailing edge of a timeline activity card.
        case timelineCardTrailing
    }

    var arrangement: Arrangement = .sheetRow
    let onTap: () -> Void

    private var zStackAlignment: Alignment {
        switch arrangement {
        case .sheetRow: .bottomTrailing
        case .timelineLeading: .center
        /// Shared center so rotations read like a scattered print stack (see timeline polaroid layout).
        case .timelineCardTrailing: .center
        }
    }

    var body: some View {
        let visible = Array(items.prefix(maxVisible))
        let overflow = max(0, items.count - maxVisible)
        Button(action: onTap) {
            ZStack(alignment: zStackAlignment) {
                // Draw back-to-front so the first model item (cover from the
                // service) is the last subview and paints on top.
                ForEach(Array(visible.enumerated().reversed()), id: \.element.id) { index, item in
                    stackedTile(for: item)
                        .rotationEffect(
                            .degrees(stackTilt(depth: index, visibleCount: visible.count)),
                            anchor: .center
                        )
                        .offset(stackOffset(for: index, count: visible.count))
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
                alignment: frameAlignment
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

    private var frameAlignment: Alignment {
        switch arrangement {
        case .sheetRow: .bottomTrailing
        case .timelineLeading: .center
        case .timelineCardTrailing: .center
        }
    }

    private var stackStepX: CGFloat {
        switch arrangement {
        case .sheetRow: return 7
        case .timelineLeading: return 2
        case .timelineCardTrailing: return 0
        }
    }

    private var stackStepY: CGFloat {
        switch arrangement {
        case .sheetRow: return 2.5
        case .timelineLeading: return 1.25
        case .timelineCardTrailing: return 0
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
        case .timelineCardTrailing:
            return .zero
        }
    }

    private func frameWidth(for visibleCount: Int) -> CGFloat {
        let spread = CGFloat(max(visibleCount - 1, 0)) * stackStepX
        switch arrangement {
        case .sheetRow:
            return tileSize + spread + 6
        case .timelineLeading:
            return tileSize + spread + AppSpacing.xs
        case .timelineCardTrailing:
            return timelineTrailingStackFrameExtent(visibleCount: visibleCount)
        }
    }

    private func frameHeight(for visibleCount: Int) -> CGFloat {
        let verticalSpread = CGFloat(max(visibleCount - 1, 0)) * stackStepY
        switch arrangement {
        case .sheetRow:
            return tileSize + verticalSpread + 6 + 4
        case .timelineLeading:
            return tileSize + verticalSpread + AppSpacing.xs
        case .timelineCardTrailing:
            return timelineTrailingStackFrameExtent(visibleCount: visibleCount)
        }
    }

    /// Square envelope so rotated polaroid tiles don’t clip; single photo stays compact.
    private func timelineTrailingStackFrameExtent(visibleCount: Int) -> CGFloat {
        guard visibleCount > 1 else { return tileSize }
        let maxTiltDegrees: Double = 15.0
        let maxTiltRadians = maxTiltDegrees * .pi / 180
        let rotatedSquareSpan = tileSize * CGFloat(abs(cos(maxTiltRadians)) + abs(sin(maxTiltRadians)))
        return rotatedSquareSpan + AppSpacing.sm
    }

    private func stackTilt(depth: Int, visibleCount: Int) -> Double {
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
        case .timelineCardTrailing:
            return stackTiltTimelineTrailing(index: depth, count: visibleCount)
        }
    }

    /// Front (index 0): level; each card behind tilts more so the whole stack fans out.
    private func stackTiltTimelineTrailing(index: Int, count: Int) -> Double {
        guard count > 1 else { return 0 }
        if index == 0 { return 0 }
        if index == count - 1 { return -15.0 }
        return index % 2 == 1 ? 13.0 : -10.0
    }

    @ViewBuilder
    private func stackedTile(for item: ActivityFeedPhotoStackItem) -> some View {
        switch arrangement {
        case .timelineCardTrailing:
            timelineTrailingPolaroidTile(for: item)
        case .sheetRow, .timelineLeading:
            tile(for: item)
        }
    }

    /// White mat + subtle outer stroke so the stack reads like layered prints (timeline trailing only).
    private func timelineTrailingPolaroidTile(for item: ActivityFeedPhotoStackItem) -> some View {
        let matInset = Self.timelineTrailingPolaroidMatInset
        let inner = max(tileSize - matInset * 2, 1)
        return ZStack {
            RoundedRectangle(cornerRadius: tileCornerRadius + 1, style: .continuous)
                .fill(Color.white)
            CachedAttachmentImage(attachmentId: item.id, url: item.url) {
                tilePlaceholder
            }
            .frame(width: inner, height: inner)
            .clipShape(RoundedRectangle(cornerRadius: max(tileCornerRadius - 1, 2), style: .continuous))
        }
        .frame(width: tileSize, height: tileSize)
        .clipShape(RoundedRectangle(cornerRadius: tileCornerRadius + 1, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: tileCornerRadius + 1, style: .continuous)
                .strokeBorder(AppColors.appDivider.opacity(0.55), lineWidth: 0.75)
        )
    }

    private static let timelineTrailingPolaroidMatInset: CGFloat = 3

    @ViewBuilder
    private func tile(for item: ActivityFeedPhotoStackItem) -> some View {
        CachedAttachmentImage(attachmentId: item.id, url: item.url) {
            tilePlaceholder
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
        case .timelineLeading, .timelineCardTrailing:
            content
        }
    }
}

