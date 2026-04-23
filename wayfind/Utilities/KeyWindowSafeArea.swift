import UIKit

/// Reads the key window’s safe area when `EnvironmentValues.safeAreaInsets` is unavailable for the deployment/SDK mix.
enum KeyWindowSafeArea {
    static var bottomInset: CGFloat {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive || $0.activationState == .foregroundInactive })
        else {
            return 0
        }
        let bottoms = scene.windows.map(\.safeAreaInsets.bottom)
        let maxBottom = bottoms.max() ?? 0
        if maxBottom > 0 {
            return maxBottom
        }
        if let window = scene.windows.first(where: \.isKeyWindow) ?? scene.windows.first {
            return window.safeAreaInsets.bottom
        }
        return 0
    }
}
