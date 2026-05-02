import SwiftUI

private enum MapStyleIconMetrics {
    /// Add Expense / category grid glyph (matches prior `ExpenseCategoryGrid` sizing).
    static let expenseCategoryGlyphPoints: CGFloat = 18
}

enum MapStyleIconSize {
    case small
    case regular
    case large
    /// Circular gradient badge (map search rows): 36pt, white monochrome glyph.
    case mapSearchBadge
    /// Same visual language as `mapSearchBadge`, smaller for timeline chain markers.
    case mapSearchBadgeSmall
    /// Suggested Places row thumbnail (map search empty state, default list).
    case suggestedPlace
    /// “See all” suggested sheet rows (slightly larger tile).
    case suggestedPlaceLarge
    /// Rare larger thumbnail (e.g. DEBUG preview) — matches ~72pt tile.
    case suggestedPlaceXL
    /// Add Expense category grid: solid circle, white glyph.
    case expenseCategory

    /// Typography bucket for suggested-place tiles when the frame side is not exactly `52` / `56` / `72`.
    static func suggestedThumbnailGlyphBucket(side: CGFloat) -> MapStyleIconSize {
        if side >= 68 { return .suggestedPlaceXL }
        if side >= 54 { return .suggestedPlaceLarge }
        return .suggestedPlace
    }

    var length: CGFloat {
        switch self {
        case .small:
            32
        case .regular:
            40
        case .large:
            48
        case .mapSearchBadge:
            36
        case .mapSearchBadgeSmall:
            32
        case .suggestedPlace:
            52
        case .suggestedPlaceLarge:
            56
        case .suggestedPlaceXL:
            72
        case .expenseCategory:
            48
        }
    }

    var glyphFont: Font {
        switch self {
        case .small:
            .appCaption.weight(.semibold)
        case .regular:
            .appBody.weight(.semibold)
        case .large:
            .cardTitle.weight(.semibold)
        case .mapSearchBadge, .mapSearchBadgeSmall:
            .sectionHeader.weight(.semibold)
        case .suggestedPlace, .suggestedPlaceLarge:
            .sectionHeader.weight(.semibold)
        case .suggestedPlaceXL:
            .cardTitle.weight(.semibold)
        case .expenseCategory:
            .system(size: MapStyleIconMetrics.expenseCategoryGlyphPoints, weight: .semibold, design: .default)
        }
    }
}

enum MapStyleIconBackground {
    /// Gradient (or flat override via `solidFillOverride`) + hierarchical or search-badge monochrome.
    case tinted
    case soft
    case surface
    /// Flat `accent` fill + white monochrome glyph — Suggested Places fallback tile & expense category circles.
    case solidAccent
}

enum MapStyleIconShape {
    case circle
    case roundedRectangle
}

/// Shared icon surfaces for Wayfind (three families):
/// 1. **Map row** — `backgroundStyle` `.tinted` / `.soft` / `.surface` (gradient or soft wash, hierarchical glyph).
/// 2. **Map search / timeline spine** — `.tinted` + `monochromeSearchBadge` (optional `solidFillOverride`, `symbolScale`).
/// 3. **Category solid** — `.solidAccent` + rounded rect or circle (Suggested Places thumbnail, expense category grid).
///
/// Implementation note: the rendering logic lives in `MapStyleIconBody` so the outer type stays a thin
/// wrapper. That avoids oversized view-struct copies that have triggered preview JIT retain crashes on some
/// simulator + Xcode combinations when nested deep in timeline rows.
struct MapStyleIcon: View {
    let systemName: String
    var size: MapStyleIconSize = .regular
    var accent: Color = AppColors.appPrimary
    var backgroundStyle: MapStyleIconBackground = .tinted
    var shape: MapStyleIconShape = .circle
    /// When set, the badge is laid out at this square side; `size` still drives glyph typography unless you match them.
    var frameSide: CGFloat? = nil
    /// When `backgroundStyle == .tinted` and set, uses a flat fill instead of the accent gradient (e.g. Google row pin).
    var solidFillOverride: Color? = nil
    /// Gradient / solid tinted circle with white **monochrome** glyph (map search + timeline spine).
    var monochromeSearchBadge: Bool = false
    /// Scales the SF Symbol inside the frame (used for timeline spine “breathing room”).
    var symbolScale: CGFloat = 1
    var accessibilityLabel: String?

    var body: some View {
        MapStyleIconBody(
            systemName: systemName,
            size: size,
            accent: accent,
            backgroundStyle: backgroundStyle,
            shape: shape,
            frameSide: frameSide,
            solidFillOverride: solidFillOverride,
            monochromeSearchBadge: monochromeSearchBadge,
            symbolScale: symbolScale,
            accessibilityLabel: accessibilityLabel
        )
    }
}

private struct MapStyleIconBody: View {
    let systemName: String
    let size: MapStyleIconSize
    let accent: Color
    let backgroundStyle: MapStyleIconBackground
    let shape: MapStyleIconShape
    let frameSide: CGFloat?
    let solidFillOverride: Color?
    let monochromeSearchBadge: Bool
    let symbolScale: CGFloat
    let accessibilityLabel: String?

    private var layoutSide: CGFloat {
        frameSide ?? size.length
    }

    var body: some View {
        Image(systemName: systemName)
            .font(size.glyphFont)
            .symbolRenderingMode(symbolRenderingMode)
            .foregroundStyle(foregroundStyle)
            .scaleEffect(symbolScale)
            .frame(width: layoutSide, height: layoutSide)
            .background {
                iconBackground
            }
            .overlay {
                border
            }
            .modifier(OptionalIconAccessibilityLabel(label: accessibilityLabel))
    }

    private var symbolRenderingMode: SymbolRenderingMode {
        if backgroundStyle == .solidAccent || monochromeSearchBadge {
            return .monochrome
        }
        return .hierarchical
    }

    private var foregroundStyle: Color {
        if monochromeSearchBadge {
            return AppColors.iconOnColoredSurface
        }
        switch backgroundStyle {
        case .solidAccent, .tinted:
            return AppColors.iconOnColoredSurface
        case .soft, .surface:
            return accent
        }
    }

    @ViewBuilder
    private var iconBackground: some View {
        switch backgroundStyle {
        case .tinted:
            if let solidFillOverride {
                iconShape.fill(solidFillOverride)
            } else {
                iconShape.fill(AppColors.iconBadgeGradient(accent: accent))
            }
        case .soft:
            iconShape.fill(accent.opacity(0.14))
        case .surface:
            iconShape.fill(AppColors.appSurface)
        case .solidAccent:
            iconShape.fill(accent)
        }
    }

    @ViewBuilder
    private var border: some View {
        if backgroundStyle == .solidAccent {
            EmptyView()
        } else {
            iconShape
                .strokeBorder(
                    monochromeSearchBadge ? AppColors.appDivider : AppColors.appDivider.opacity(0.85),
                    lineWidth: 0.5
                )
        }
    }

    private var iconShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    private var cornerRadius: CGFloat {
        switch shape {
        case .circle:
            layoutSide / 2
        case .roundedRectangle:
            AppCornerRadius.medium
        }
    }
}

private struct OptionalIconAccessibilityLabel: ViewModifier {
    let label: String?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let label {
            content.accessibilityLabel(label)
        } else {
            content.accessibilityHidden(true)
        }
    }
}

#Preview("Map Style Icons") {
    VStack(alignment: .leading, spacing: AppSpacing.lg) {
        HStack(spacing: AppSpacing.md) {
            MapStyleIcon(systemName: "mappin.circle.fill", accessibilityLabel: "Place")
            MapStyleIcon(systemName: "car.fill", accent: AppColors.day1, accessibilityLabel: "Drive")
            MapStyleIcon(systemName: "calendar", accent: AppColors.day2, accessibilityLabel: "Booking")
            MapStyleIcon(systemName: "clock", accent: AppColors.day3, backgroundStyle: .soft, accessibilityLabel: "Time")
        }

        HStack(spacing: AppSpacing.md) {
            MapStyleIcon(systemName: "location.fill", size: .small, accent: AppColors.day4, accessibilityLabel: "Location")
            MapStyleIcon(systemName: "person.crop.circle", accent: AppColors.day5, backgroundStyle: .surface, accessibilityLabel: "Person")
            MapStyleIcon(
                systemName: "fork.knife",
                size: .large,
                accent: AppColors.day6,
                shape: .roundedRectangle,
                accessibilityLabel: "Restaurant"
            )
            MapStyleIcon(
                systemName: "mappin.circle.fill",
                size: .mapSearchBadge,
                accent: AppColors.appError,
                monochromeSearchBadge: true,
                accessibilityLabel: "Search badge"
            )
        }

        HStack(spacing: AppSpacing.md) {
            MapStyleIcon(
                systemName: "fork.knife",
                size: .suggestedPlace,
                accent: AppColors.day6,
                backgroundStyle: .solidAccent,
                shape: .roundedRectangle,
                accessibilityLabel: "Suggested place"
            )
            MapStyleIcon(
                systemName: "airplane",
                size: .expenseCategory,
                accent: AppColors.day1,
                backgroundStyle: .solidAccent,
                shape: .circle,
                accessibilityLabel: "Expense category"
            )
        }
    }
    .padding(AppSpacing.xl)
    .background(AppColors.appBackground)
}
