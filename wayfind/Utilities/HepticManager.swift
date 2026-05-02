//
//  HepticManager.swift
//  wayfind
//
//  Created by Ashish Jambhulkar on 4/2/26.
//

import UIKit

enum HapticManager {
    private static let lightGenerator = UIImpactFeedbackGenerator(style: .light)
    private static let mediumGenerator = UIImpactFeedbackGenerator(style: .medium)
    private static let heavyGenerator = UIImpactFeedbackGenerator(style: .heavy)
    private static let notificationGenerator = UINotificationFeedbackGenerator()
    private static let selectionGenerator = UISelectionFeedbackGenerator()

    /// Decorative impacts and selection ticks are silenced when the user has
    /// asked the system to dampen non-essential motion/animations. Notification
    /// feedback (success / warning / error) carries critical safety information
    /// for destructive actions and stays on regardless.
    private static var shouldSuppressDecorativeHaptics: Bool {
        UIAccessibility.isReduceMotionEnabled
    }

    static func light() {
        guard !shouldSuppressDecorativeHaptics else { return }
        lightGenerator.prepare()
        lightGenerator.impactOccurred()
    }

    static func medium() {
        guard !shouldSuppressDecorativeHaptics else { return }
        mediumGenerator.prepare()
        mediumGenerator.impactOccurred()
    }

    static func heavy() {
        guard !shouldSuppressDecorativeHaptics else { return }
        heavyGenerator.prepare()
        heavyGenerator.impactOccurred()
    }

    static func success() {
        notificationGenerator.prepare()
        notificationGenerator.notificationOccurred(.success)
    }

    static func warning() {
        notificationGenerator.prepare()
        notificationGenerator.notificationOccurred(.warning)
    }

    static func error() {
        notificationGenerator.prepare()
        notificationGenerator.notificationOccurred(.error)
    }

    static func selection() {
        guard !shouldSuppressDecorativeHaptics else { return }
        selectionGenerator.prepare()
        selectionGenerator.selectionChanged()
    }
}


// =============================================================================

