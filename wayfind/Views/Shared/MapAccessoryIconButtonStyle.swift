import SwiftUI

extension View {
    /// Native icon-button treatment for map sheet chrome (system press feedback).
    /// Uses `.borderless` instead of `.glass` so taps reliably reach the control inside stacked sheets and materials.
    func mapAccessoryIconButtonStyle() -> some View {
        buttonStyle(.borderless)
    }
}
