//
//  CardPulseModifier.swift
//  wayfind
//
//  Phase 3 — One-shot color-multiply pulse used to acknowledge a realtime
//  change without shifting layout (replaces the Slack-style green border
//  that pushed neighbours around). Triggers when the `flashID` value
//  changes — the parent flash store rotates the id every time it records
//  a new flash for a place, so a follow-up edit on the same row pulses
//  again rather than being swallowed.
//
//  Reduce Motion: when enabled the pulse is suppressed entirely. The
//  attribution chip rendered next to the title is layout-stable on its
//  own, so the user still gets the "Alex · just now" affordance — they
//  just don't get the visual heartbeat.
//

import SwiftUI

struct CardPulseModifier: ViewModifier {
    /// Flash identity. When this changes the modifier runs one cycle of
    /// the pulse. Pass `nil` when there's no flash so the modifier does
    /// nothing.
    let flashID: UUID?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var multiplier: Double = 1.0

    func body(content: Content) -> some View {
        content
            // colorMultiply at 1.0 is identity — no visible effect when
            // we're idle. Drives down to 0.95 mid-pulse to nudge the card
            // surface slightly cooler/darker, then back to 1.0.
            .colorMultiply(Color(white: multiplier))
            .onChange(of: flashID) { _, newValue in
                guard newValue != nil, !reduceMotion else { return }
                runPulse()
            }
    }

    private func runPulse() {
        // Two-phase animation: dip then recover. Total 0.6s — long enough
        // to register but short enough to feel like an acknowledgement
        // rather than a status change.
        withAnimation(.easeOut(duration: 0.3)) {
            multiplier = 0.95
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            withAnimation(.easeIn(duration: 0.3)) {
                multiplier = 1.0
            }
        }
    }
}

extension View {
    /// One-shot color-multiply pulse, fired whenever `flashID` changes.
    /// Pair with the attribution chip rendered above the card title.
    func cardPulse(flashID: UUID?) -> some View {
        modifier(CardPulseModifier(flashID: flashID))
    }
}


// =============================================================================
