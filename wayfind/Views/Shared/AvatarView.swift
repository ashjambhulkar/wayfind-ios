//
//  AvatarView.swift
//  wayfind
//
//  Image-or-initials avatar used by the trip members surfaces, the activity
//  feed, and any other place we display a person. When `imageURL` is present,
//  we load through `CachedAvatarImage` / `AvatarRemoteImageCache`; otherwise we
//  fall back to a solid disc tinted with one of the brand-warm palette colors
//  derived deterministically from the identifier so the same person always gets
//  the same color.
//

import SwiftUI

struct AvatarView: View {
    let displayName: String?
    let imageURL: URL?
    /// Stable identifier used to deterministically pick a fallback color so
    /// the same collaborator gets the same disc across sheets.
    let stableID: String
    var size: CGFloat = 32
    /// Adds a thin contrasting ring (used in the overlapping nav-bar stack
    /// so adjacent discs visually separate from each other).
    var showRing: Bool = false
    /// When `showRing` is true, overrides the default `AppColors.appSurface` stroke (e.g. white on hero photos).
    var ringStrokeColor: Color? = nil

    init(
        displayName: String?,
        imageURL: URL?,
        stableID: String,
        size: CGFloat = 32,
        showRing: Bool = false,
        ringStrokeColor: Color? = nil
    ) {
        self.displayName = displayName
        self.imageURL = imageURL
        self.stableID = stableID
        self.size = size
        self.showRing = showRing
        self.ringStrokeColor = ringStrokeColor
    }

    var body: some View {
        ZStack {
            if let imageURL {
                CachedAvatarImage(url: imageURL, showsProgressWhileLoading: false) {
                    initialsDisc
                }
            } else {
                initialsDisc
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(
            Circle()
                .strokeBorder(
                    showRing ? (ringStrokeColor ?? AppColors.appSurface) : Color.clear,
                    lineWidth: showRing ? 2 : 0
                )
        )
    }

    private var initialsDisc: some View {
        ZStack {
            Self.color(for: stableID)
            Text(initials)
                .font(.system(size: size * 0.42, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
        }
    }

    private var initials: String {
        let trimmed = (displayName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            // Fall back to first character of the stable ID so we never render
            // a blank disc — the ID is the same every render so the letter
            // stays stable for the same person.
            return String(stableID.prefix(1)).uppercased()
        }
        let parts = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
        if parts.count >= 2 {
            let a = String(parts[0].prefix(1))
            let b = String(parts[1].prefix(1))
            return (a + b).uppercased()
        }
        return String(trimmed.prefix(2)).uppercased()
    }

    /// Brand-warm palette: terracotta / clay / muted ochre tones so avatars
    /// blend with the rest of the Wayfind warm-paper aesthetic and never clash
    /// with the green success / red destructive colors used for status chips.
    private static let palette: [Color] = [
        Color(red: 0.76, green: 0.43, blue: 0.29), // terracotta
        Color(red: 0.91, green: 0.66, blue: 0.49), // peach clay
        Color(red: 0.55, green: 0.47, blue: 0.36), // warm taupe
        Color(red: 0.85, green: 0.55, blue: 0.37), // burnt sienna
        Color(red: 0.40, green: 0.50, blue: 0.50), // muted teal-grey
        Color(red: 0.62, green: 0.43, blue: 0.55), // dusty plum
        Color(red: 0.34, green: 0.42, blue: 0.55), // dusty blue
    ]

    private static func color(for id: String) -> Color {
        guard !id.isEmpty else { return palette[0] }
        var hash: UInt64 = 5381
        for byte in id.utf8 {
            hash = ((hash << 5) &+ hash) &+ UInt64(byte)
        }
        return palette[Int(hash % UInt64(palette.count))]
    }
}


// =============================================================================

#if DEBUG
#Preview("Avatars") {
    HStack(spacing: 16) {
        AvatarView(displayName: "Alex Johnson", imageURL: nil, stableID: "1", size: 40)
        AvatarView(displayName: "Sam Rivera", imageURL: nil, stableID: "2", size: 40, showRing: true)
        AvatarView(displayName: nil, imageURL: nil, stableID: "3", size: 40)
        AvatarView(displayName: "Z", imageURL: nil, stableID: "4", size: 56)
    }
    .padding()
    .background(AppColors.appBackground)
}
#endif
