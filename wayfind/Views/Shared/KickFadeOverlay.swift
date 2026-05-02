//
//  KickFadeOverlay.swift
//  wayfind
//
//  Phase 3 — Soft dim+blur fade rendered above the trip content when the
//  realtime kick handler fires the "you were removed" path. Sits beneath
//  the toast (the toast renders at the top-level WayfindApp scene) so the
//  toast stays crisp while the trip view dims out behind it.
//
//  Reduce Motion fallback: opacity-only, no blur. Both modes use the same
//  4-tenths-of-a-second easeInOut so the toast and the fade resolve at
//  roughly the same time.
//

import SwiftUI

struct KickFadeOverlay: View {
    let isActive: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if isActive {
                if reduceMotion {
                    Color.black.opacity(0.35)
                        .ignoresSafeArea()
                        .transition(.opacity)
                } else {
                    // Translucent material gives both the dim AND the
                    // blur in a single pass — cheaper than stacking
                    // .blur and .background.
                    Color.black.opacity(0.18)
                        .background(.ultraThinMaterial)
                        .ignoresSafeArea()
                        .transition(.opacity)
                }
            }
        }
        .allowsHitTesting(isActive)
        .accessibilityHidden(true)
    }
}


// =============================================================================
