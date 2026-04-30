import SwiftUI

enum MapStyleIconSize {
    case small
    case regular
    case large

    var length: CGFloat {
        switch self {
        case .small:
            32
        case .regular:
            40
        case .large:
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
        }
    }
}

enum MapStyleIconBackground {
    case tinted
    case soft
    case surface
}

enum MapStyleIconShape {
    case circle
    case roundedRectangle
}

/// Shared Apple Maps-style SF Symbol badge for rows, cards, sheets, and metadata clusters.
struct MapStyleIcon: View {
    let systemName: String
    var size: MapStyleIconSize = .regular
    var accent: Color = AppColors.appPrimary
    var backgroundStyle: MapStyleIconBackground = .tinted
    var shape: MapStyleIconShape = .circle
    var accessibilityLabel: String?

    var body: some View {
        Image(systemName: systemName)
            .font(size.glyphFont)
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(foregroundStyle)
            .frame(width: size.length, height: size.length)
            .background {
                iconBackground
            }
            .overlay {
                border
            }
            .modifier(OptionalIconAccessibilityLabel(label: accessibilityLabel))
    }

    private var foregroundStyle: Color {
        switch backgroundStyle {
        case .tinted:
            AppColors.iconOnColoredSurface
        case .soft, .surface:
            accent
        }
    }

    @ViewBuilder
    private var iconBackground: some View {
        switch backgroundStyle {
        case .tinted:
            iconShape.fill(AppColors.iconBadgeGradient(accent: accent))
        case .soft:
            iconShape.fill(accent.opacity(0.14))
        case .surface:
            iconShape.fill(AppColors.appSurface)
        }
    }

    private var border: some View {
        iconShape
            .strokeBorder(AppColors.appDivider.opacity(0.85), lineWidth: 0.5)
    }

    private var iconShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    private var cornerRadius: CGFloat {
        switch shape {
        case .circle:
            size.length / 2
        case .roundedRectangle:
            AppCornerRadius.medium
        }
    }
}

private struct OptionalIconAccessibilityLabel: ViewModifier {
    let label: String?

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
        }
    }
    .padding(AppSpacing.xl)
    .background(AppColors.appBackground)
}
