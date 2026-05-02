//
//  AppColors.swift
//  wayfind
//
//  Created by Ashish Jambhulkar on 4/2/26.
//

import SwiftUI
import UIKit

extension Color {
    init(light: Color, dark: Color) {
        self.init(uiColor: UIColor { traitCollection in
            switch traitCollection.userInterfaceStyle {
            case .dark:
                UIColor(dark)
            default:
                UIColor(light)
            }
        })
    }
}

private extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

enum AppColors {
    static let appBackground = Color(light: Color(hex: 0xFDF8F0), dark: Color(hex: 0x1C1C1E))
    static let appSurface = Color(light: Color(hex: 0xFFFFFF), dark: Color(hex: 0x2C2C2E))
    static let appPrimary = Color(light: Color(hex: 0xC26F4B), dark: Color(hex: 0xD4845F))
    static let appPrimaryLight = Color(light: Color(hex: 0xF4E8E0), dark: Color(hex: 0x2A1F1A))
    static let appSecondary = Color(light: Color(hex: 0x2C3E50), dark: Color(hex: 0xE2E8F0))
    static let appAccent = Color(light: Color(hex: 0xE8A87C), dark: Color(hex: 0xE8A87C))
    static let iconOnColoredSurface = Color.white
    static let textPrimary = Color(light: Color(hex: 0x1A1A1A), dark: Color(hex: 0xF5F5F5))
    static let textSecondary = Color(light: Color(hex: 0x57534E), dark: Color(hex: 0xD6D3D1))
    static let textTertiary = Color(light: Color(hex: 0x78716C), dark: Color(hex: 0xA8A29E))
    static let appSuccess = Color(light: Color(hex: 0x059669), dark: Color(hex: 0x059669))
    static let appWarning = Color(light: Color(hex: 0xD97706), dark: Color(hex: 0xD97706))
    static let appError = Color(light: Color(hex: 0xDC2626), dark: Color(hex: 0xDC2626))
    /// List swipe-delete backgrounds; UIKit semantic red tracks light/dark (distinct from flat `appError` fills).
    static let swipeDestructiveTint = Color(uiColor: .systemRed)
    static let appDivider = Color(light: Color(hex: 0xF3EDE4), dark: Color(hex: 0x3A3A3C))
    static let bookingPassHeaderTop = Color(light: Color(hex: 0x2C3E50), dark: Color(hex: 0x0D1224))
    static let bookingPassHeaderBottom = Color(light: Color(hex: 0x243447), dark: Color(hex: 0x151A33))

    static let day1 = Color(light: Color(hex: 0x4A90D9), dark: Color(hex: 0x4A90D9))
    static let day2 = Color(light: Color(hex: 0xD4845F), dark: Color(hex: 0xD4845F))
    static let day3 = Color(light: Color(hex: 0x059669), dark: Color(hex: 0x059669))
    static let day4 = Color(light: Color(hex: 0xD97706), dark: Color(hex: 0xD97706))
    static let day5 = Color(light: Color(hex: 0x8B5CF6), dark: Color(hex: 0x8B5CF6))
    static let day6 = Color(light: Color(hex: 0xEC4899), dark: Color(hex: 0xEC4899))
    static let day7 = Color(light: Color(hex: 0x06B6D4), dark: Color(hex: 0x06B6D4))

    static func dayColor(for dayNumber: Int) -> Color {
        let palette = [day1, day2, day3, day4, day5, day6, day7]
        let index = ((dayNumber - 1) % 7 + 7) % 7
        return palette[index]
    }

    /// Opaque badge fill: same hue as `accent`, slightly muted so category icons stay readable.
    static func iconBadgeGradient(accent: Color) -> LinearGradient {
        let ui = UIColor(accent)
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0

        guard ui.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha), alpha > 0 else {
            return LinearGradient(colors: [accent, accent], startPoint: .top, endPoint: .bottom)
        }

        let mutedSaturationTop = min(max(saturation * 0.88, 0), 1)
        let mutedSaturationBottom = min(max(saturation * 0.92, 0), 1)
        let topBrightness = min(max(brightness * 1.05 * 0.94, 0.12), 1)
        let bottomBrightness = min(max(brightness * 0.82 * 0.94, 0.1), 1)

        let top = Color(UIColor(hue: hue, saturation: mutedSaturationTop, brightness: topBrightness, alpha: alpha))
        let bottom = Color(UIColor(hue: hue, saturation: mutedSaturationBottom, brightness: bottomBrightness, alpha: alpha))
        return LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom)
    }
}


// =============================================================================

