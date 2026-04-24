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
    static let appBackground = Color(light: Color(hex: 0xFDF8F0), dark: Color(hex: 0x0F0F0F))
    static let appSurface = Color(light: Color(hex: 0xFFFFFF), dark: Color(hex: 0x1A1A1A))
    static let appPrimary = Color(light: Color(hex: 0xC26F4B), dark: Color(hex: 0xD4845F))
    static let appPrimaryLight = Color(light: Color(hex: 0xF4E8E0), dark: Color(hex: 0x2A1F1A))
    static let appSecondary = Color(light: Color(hex: 0x2C3E50), dark: Color(hex: 0xE2E8F0))
    static let appAccent = Color(light: Color(hex: 0xE8A87C), dark: Color(hex: 0xE8A87C))
    static let textPrimary = Color(light: Color(hex: 0x1A1A1A), dark: Color(hex: 0xF5F5F5))
    static let textSecondary = Color(light: Color(hex: 0x57534E), dark: Color(hex: 0xD6D3D1))
    static let textTertiary = Color(light: Color(hex: 0x78716C), dark: Color(hex: 0xA8A29E))
    static let appSuccess = Color(light: Color(hex: 0x059669), dark: Color(hex: 0x059669))
    static let appWarning = Color(light: Color(hex: 0xD97706), dark: Color(hex: 0xD97706))
    static let appError = Color(light: Color(hex: 0xDC2626), dark: Color(hex: 0xDC2626))
    static let appDivider = Color(light: Color(hex: 0xF3EDE4), dark: Color(hex: 0x2A2A2A))

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
}


// =============================================================================

