import SwiftUI

// MARK: - Metrics

enum MapChromeIconMetrics {
    static let touchLength: CGFloat = 40
    static let dismissGlyphPointSize: CGFloat = 36
    static let accessoryGlyphPointSize: CGFloat = 18
}

// MARK: - Button

/// Shared square chrome control for map / sheet toolbars: SF Symbol + action, consistent 40×40 hit target.
///
/// Use presets (`mapSearchDismiss`, `suggestedPlaces`, `placeDismiss`) or the initializer for new icons.
struct MapChromeIconButton: View {
    let systemName: String
    let iconFont: Font
    var symbolRenderingMode: SymbolRenderingMode = .monochrome
    var minTouchSize: CGFloat = MapChromeIconMetrics.touchLength

    /// When non-nil, applies `.tint` (e.g. `.secondary` for neutral dismiss). Otherwise the symbol uses `monochromeForeground`.
    var tint: Color?

    var monochromeForeground: Color = .primary

    /// `tertiarySystemFill` disk behind the glyph on iOS < 26 (e.g. suggested places).
    var legacyDiskFill: Bool = false

    var accessibilityLabel: String
    var accessibilityHint: String?

    let action: () -> Void

    var body: some View {
        Button(action: action) {
            label
                .frame(width: minTouchSize, height: minTouchSize)
                .contentShape(Rectangle())
        }
        .mapAccessoryIconButtonStyle()
        .modifier(OptionalTintModifier(tint: tint))
        .accessibilityLabel(accessibilityLabel)
        .modifier(OptionalAccessibilityHintModifier(hint: accessibilityHint))
    }

    @ViewBuilder
    private var label: some View {
        if legacyDiskFill {
            if #available(iOS 26.0, *) {
                Image(systemName: systemName)
                    .font(iconFont)
                    .symbolRenderingMode(symbolRenderingMode)
                    .foregroundStyle(monochromeForeground)
            } else {
                Image(systemName: systemName)
                    .font(iconFont)
                    .symbolRenderingMode(symbolRenderingMode)
                    .foregroundStyle(monochromeForeground)
                    .background(Color(UIColor.tertiarySystemFill), in: Circle())
            }
        } else {
            Image(systemName: systemName)
                .font(iconFont)
                .symbolRenderingMode(symbolRenderingMode)
        }
    }
}

// MARK: - Presets

extension MapChromeIconButton {
    /// Filled `xmark.circle.fill`, hierarchical, `.secondary` tint (overrides ancestor brand tint).
    static func mapSearchDismiss(
        accessibilityHint: String? = nil,
        action: @escaping () -> Void
    ) -> MapChromeIconButton {
        MapChromeIconButton(
            systemName: "xmark.circle.fill",
            iconFont: .system(size: MapChromeIconMetrics.dismissGlyphPointSize, weight: .regular),
            symbolRenderingMode: .hierarchical,
            tint: .secondary,
            monochromeForeground: .primary,
            legacyDiskFill: false,
            accessibilityLabel: String(localized: "Close"),
            accessibilityHint: accessibilityHint,
            action: action
        )
    }

    /// Sparkles control for suggested places.
    static func suggestedPlaces(action: @escaping () -> Void) -> MapChromeIconButton {
        MapChromeIconButton(
            systemName: "sparkles",
            iconFont: .system(size: MapChromeIconMetrics.accessoryGlyphPointSize, weight: .semibold),
            symbolRenderingMode: .monochrome,
            tint: nil,
            monochromeForeground: .primary,
            legacyDiskFill: true,
            accessibilityLabel: String(localized: "Suggested Places"),
            accessibilityHint: String(localized: "Opens the list of suggested places for this trip"),
            action: action
        )
    }

    /// Same dismiss appearance as map search clear (e.g. place detail toolbar).
    static func placeDismiss(action: @escaping () -> Void) -> MapChromeIconButton {
        mapSearchDismiss(accessibilityHint: nil, action: action)
    }
}

// MARK: - Private

private struct OptionalTintModifier: ViewModifier {
    let tint: Color?

    func body(content: Content) -> some View {
        if let tint {
            content.tint(tint)
        } else {
            content
        }
    }
}

private struct OptionalAccessibilityHintModifier: ViewModifier {
    let hint: String?

    func body(content: Content) -> some View {
        if let hint {
            content.accessibilityHint(hint)
        } else {
            content
        }
    }
}
