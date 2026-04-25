//
//  PhotoCarouselView.swift
//  wayfind
//
//  Phase F.5 — Airbnb-style horizontal photo carousel for PlaceDetailSheet.
//
//  Design notes
//  ------------
//  * Snap-to-page horizontal scroll (`.scrollTargetBehavior(.viewAligned)`)
//    so each photo settles in the centre — feels like the App Store / Airbnb
//    listing scroller, not a generic ScrollView.
//  * Lazy `AsyncImage` load. Skeleton placeholder while in flight; ProgressView
//    suppressed because the skeleton conveys progress with less chrome.
//  * Page indicator below the rail: dots + "i of N" caption next to it. Falls
//    back to a single subtle attribution row when there's only one photo.
//  * Accessibility: each card has a label describing its kind ("photo by a
//    traveler", "google maps photo") so VoiceOver doesn't say
//    "image, image, image". (Phase G.4 will localize these strings.)
//

import SwiftUI

struct PhotoCarouselView: View {
    let photos: [PlacePhoto]
    var onTap: (PlacePhoto) -> Void = { _ in }
    /// Phase F.8 — long-press / context-menu hook. The carousel exposes
    /// the chosen photo here so the parent screen can present the
    /// `ReportUserPhotoSheet`. Provider photos (Google fallbacks) skip
    /// this affordance because we already have a Place-level "Report"
    /// flow for those (Phase E).
    var onReport: (PlacePhoto) -> Void = { _ in }

    @State private var visibleId: String?

    /// Phase G.2 — `flag_user_photos` master kill-switch. When the
    /// flag is OFF we still render provider photos (Google fallbacks
    /// are governed by their own Phase E pipeline) but drop every
    /// user-uploaded photo, even ones already in the moderation
    /// pipeline. This keeps the carousel non-empty during outages
    /// rather than yanking the entire section away.
    private var visiblePhotos: [PlacePhoto] {
        if FeatureFlagsService.shared.userPhotosEnabled { return photos }
        return photos.filter { $0.kind != .approvedUser && $0.kind != .pendingUser }
    }

    private var resolvedVisible: PlacePhoto? {
        guard let id = visibleId, let p = visiblePhotos.first(where: { $0.id == id }) else {
            return visiblePhotos.first
        }
        return p
    }

    private var currentIndex: Int {
        guard let id = visibleId else { return 0 }
        return visiblePhotos.firstIndex(where: { $0.id == id }) ?? 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(visiblePhotos) { photo in
                        photoCard(photo)
                            .containerRelativeFrame(.horizontal)
                            .id(photo.id)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
            .scrollPosition(id: $visibleId)
            .frame(height: 240)

            attributionRow
                .padding(.horizontal, 16)
        }
        .onAppear {
            if visibleId == nil { visibleId = visiblePhotos.first?.id }
        }
    }

    // MARK: – Photo card

    @ViewBuilder
    private func photoCard(_ photo: PlacePhoto) -> some View {
        Button {
            onTap(photo)
        } label: {
            ZStack(alignment: .topTrailing) {
                AsyncImage(url: photo.url, transaction: .init(animation: .easeInOut(duration: 0.2))) { phase in
                    switch phase {
                    case .empty:
                        SkeletonView(cornerRadius: 14, height: 240)
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    case .failure:
                        SkeletonView(cornerRadius: 14, height: 240)
                            .overlay(
                                Image(systemName: "photo")
                                    .font(.system(size: 24))
                                    .foregroundStyle(AppColors.textTertiary)
                            )
                    @unknown default:
                        SkeletonView(cornerRadius: 14, height: 240)
                    }
                }
                .frame(height: 240)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .clipped()

                if photo.kind == .pendingUser {
                    pendingBadge
                        .padding(10)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel(for: photo))
        .accessibilityHint(photo.kind == .approvedUser || photo.kind == .pendingUser
                           ? "Double tap to open. Long press to report."
                           : "Double tap to open fullscreen.")
        .accessibilityAddTraits(.isImage)
        .contextMenu {
            // Only user photos go through the per-photo report flow.
            // Provider fallbacks reuse the place-level report sheet.
            if photo.kind == .approvedUser || photo.kind == .pendingUser {
                Button(role: .destructive) {
                    HapticManager.warning()
                    onReport(photo)
                } label: {
                    Label("Report photo", systemImage: "flag")
                }
            }
        }
    }

    private var pendingBadge: some View {
        Label("Awaiting review", systemImage: "clock")
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().stroke(.white.opacity(0.25), lineWidth: 0.5))
            .foregroundStyle(.white)
    }

    // MARK: – Attribution row

    private var attributionRow: some View {
        HStack(spacing: 8) {
            if let p = resolvedVisible {
                Image(systemName: badgeIcon(for: p.kind))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(AppColors.textTertiary)
                    .accessibilityHidden(true)
                Text(attributionText(for: p))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(AppColors.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if visiblePhotos.count > 1 {
                Text("\(currentIndex + 1) of \(visiblePhotos.count)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(AppColors.textTertiary)
                    .monospacedDigit()
            }
        }
        // Phase G.4 — Cap Dynamic Type for chrome rows so the
        // bottom attribution doesn't push the whole carousel
        // around at accessibilityXXL sizes. The fullscreen viewer
        // remains uncapped for actual content.
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .accessibilityElement(children: .combine)
    }

    private func badgeIcon(for kind: PlacePhoto.Kind) -> String {
        switch kind {
        case .approvedUser:    return "person.crop.circle.fill.badge.checkmark"
        case .pendingUser:     return "clock"
        case .providerFallback: return "globe"
        }
    }

    private func attributionText(for photo: PlacePhoto) -> String {
        switch photo.kind {
        case .approvedUser:
            if let credit = photo.credit, !credit.isEmpty {
                return "Photo by \(credit)"
            }
            return "Photo by a traveler"
        case .pendingUser:
            return "Your photo (in review)"
        case .providerFallback:
            return photo.attribution ?? "Photo via Google"
        }
    }

    private func accessibilityLabel(for photo: PlacePhoto) -> String {
        switch photo.kind {
        case .approvedUser:
            if let credit = photo.credit, !credit.isEmpty {
                return "Photo by \(credit)"
            }
            return "Photo by a traveler"
        case .pendingUser:
            return "Your photo, awaiting review"
        case .providerFallback:
            return "Photo from Google Maps"
        }
    }
}

#Preview {
    PhotoCarouselView(photos: [
        PlacePhoto(
            id: "1",
            url: URL(string: "https://picsum.photos/seed/1/800/500")!,
            kind: .approvedUser,
            attribution: nil,
            credit: "Marcus L."
        ),
        PlacePhoto(
            id: "2",
            url: URL(string: "https://picsum.photos/seed/2/800/500")!,
            kind: .providerFallback,
            attribution: "Photo via Google",
            credit: nil
        ),
        PlacePhoto(
            id: "3",
            url: URL(string: "https://picsum.photos/seed/3/800/500")!,
            kind: .pendingUser,
            attribution: nil,
            credit: nil
        )
    ])
    .padding(.vertical)
}
