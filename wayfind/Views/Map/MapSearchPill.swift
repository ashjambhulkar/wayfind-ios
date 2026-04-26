//
//  MapSearchPill.swift
//  wayfind
//
//  Phase 3 of the Map Screen Search Redesign.
//
//  Floating capsule pinned to the top safe area. Tapping it opens
//  `MapSearchOverlay`. While search annotations exist on the map a
//  trailing X clears them all (Apple + city_places) and restores the
//  day sheet.
//
//  HIG fit:
//   • Material background with HIG-standard regularMaterial; respects
//     dark mode and Increase Contrast.
//   • Pinned to the top safe area; never crosses 50% of screen height.
//   • Doesn't collide with the right-edge map control stack — the
//     pill claims a leading-aligned region and stops short of the
//     trailing edge by 56 pt (the control stack width plus padding).
//

import SwiftUI

struct MapSearchPill: View {
    /// True when there are committed search results on the map. Drives
    /// the trailing Clear (X) affordance.
    var hasResults: Bool

    /// Tap on the pill body — opens the search overlay.
    var onTapPill: () -> Void

    /// Tap the trailing X — clears all search annotations + closes
    /// the preview sheet.
    var onTapClear: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 10) {
            Button {
                HapticManager.light()
                onTapPill()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.88))
                    Text("Search places")
                        .font(.body)
                        .foregroundStyle(.white.opacity(0.92))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 11)
                .padding(.leading, 14)
                .padding(.trailing, hasResults ? 4 : 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Search places")
            .accessibilityHint("Opens place search")

            if hasResults {
                Divider()
                    .frame(height: 22)
                    .overlay(.white.opacity(0.20))

                Button {
                    HapticManager.light()
                    onTapClear()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.white.opacity(0.88))
                        .padding(.trailing, 10)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear results")
            }
        }
        .background {
            Capsule()
                .fill(.ultraThinMaterial)
            Capsule()
                .fill(Color.black.opacity(colorScheme == .dark ? 0.42 : 0.34))
        }
        .clipShape(Capsule())
        .shadow(color: .black.opacity(0.28), radius: 12, x: 0, y: 5)
        .overlay(
            Capsule()
                .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5)
        )
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .accessibilityElement(children: .contain)
    }
}

// =============================================================================

#if DEBUG
#Preview("Map search pill") {
    VStack(spacing: 16) {
        MapSearchPill(hasResults: false, onTapPill: {}, onTapClear: {})
        MapSearchPill(hasResults: true, onTapPill: {}, onTapClear: {})
    }
    .padding()
    .background(Color.gray.opacity(0.2))
}
#endif
