//
//  InAppLegalSafariView.swift
//  wayfind
//
//  Full-screen in-app legal pages. There is no SwiftUI equivalent; Apple
//  documents `SFSafariViewController` for this use case.
//

import SafariServices
import SwiftUI

struct InAppLegalSafariView: UIViewControllerRepresentable {
    let url: URL
    var onDismiss: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onDismiss: onDismiss)
    }

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let configuration = SFSafariViewController.Configuration()
        configuration.barCollapsingEnabled = true
        let controller = SFSafariViewController(url: url, configuration: configuration)
        controller.delegate = context.coordinator
        controller.preferredControlTintColor = LegalSafariChrome.controlTint
        controller.dismissButtonStyle = .close
        return controller
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}

    final class Coordinator: NSObject, SFSafariViewControllerDelegate {
        let onDismiss: () -> Void

        init(onDismiss: @escaping () -> Void) {
            self.onDismiss = onDismiss
        }

        func safariViewControllerDidFinish(_ controller: SFSafariViewController) {
            onDismiss()
        }
    }
}

private enum LegalSafariChrome {
    /// Aligned with `AppColors.appPrimary` light (0xC26F4B) / dark (0xD4845F).
    static let controlTint = UIColor { traitCollection in
        switch traitCollection.userInterfaceStyle {
        case .dark:
            UIColor(red: 212 / 255, green: 132 / 255, blue: 95 / 255, alpha: 1)
        default:
            UIColor(red: 194 / 255, green: 111 / 255, blue: 75 / 255, alpha: 1)
        }
    }
}

// =============================================================================
