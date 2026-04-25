//
//  MapSearchPreviewSheet.swift
//  wayfind
//
//  Phase 5 of the Map Screen Search Redesign.
//
//  Bottom sheet shown when the user taps a search result on the map.
//  Strict free-data only: name, formatted address, phone, website,
//  category icon, and (iOS 16+) an optional Look Around scene.
//
//  Actions: Add to Day, Search nearby, Open in Apple Maps, Directions
//  in Apple Maps.
//
//  Detents: `.height(180)` (compact card) and `.medium`. Background
//  interaction is enabled at `.height(180)` so the user can pan/zoom
//  the map to context the place.
//

import MapKit
import SwiftUI

struct MapSearchPreviewSheet: View {
    let preview: MapSearchPreview

    /// Tap "Add to Day" — caller swaps in `MapAddToDaySheet`.
    var onAddToDay: () -> Void

    /// Tap "Search nearby" — caller refires the active category in a
    /// region centered on the preview.
    var onSearchNearby: () -> Void

    /// Caller dismisses (X / drag-down).
    var onDismiss: () -> Void

    @State private var lookAroundScene: MKLookAroundScene?
    @State private var fetchedLookAround = false
    @State private var showLookAround = false

    @Environment(\.openURL) private var openURL
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header

                    if let scene = lookAroundScene {
                        LookAroundPreviewWrapper(scene: scene) {
                            showLookAround = true
                        }
                        .frame(height: 140)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .padding(.horizontal, 16)
                    }

                    actionsGrid
                        .padding(.horizontal, 16)

                    if preview.phone != nil || preview.website != nil || !preview.subtitle.isEmpty {
                        infoCard
                            .padding(.horizontal, 16)
                    }

                    Spacer(minLength: 24)
                }
                .padding(.top, 6)
            }
            .scrollIndicators(.hidden)
            .background(AppColors.appBackground)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        onDismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title3)
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("Close preview")
                }
            }
            .toolbarBackground(.regularMaterial, for: .navigationBar)
        }
        .task {
            PlatformUsageTelemetry.mapSearch(.previewShown, origin: preview.origin)
            await fetchLookAroundIfNeeded()
        }
        .sheet(isPresented: $showLookAround) {
            if let scene = lookAroundScene {
                LookAroundFullScreenWrapper(scene: scene)
                    .ignoresSafeArea()
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(AppColors.appPrimaryLight)
                    .frame(width: 46, height: 46)
                Image(systemName: preview.category?.mapBadgeSymbol ?? "mappin.circle.fill")
                    .font(.title3)
                    .foregroundStyle(AppColors.appPrimary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(preview.name)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)

                if !preview.subtitle.isEmpty {
                    Text(preview.subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                if preview.isOwnedRow {
                    Label("From this city's places", systemImage: "checkmark.seal.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(AppColors.appPrimary)
                        .labelStyle(.titleAndIcon)
                        .padding(.top, 2)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
    }

    // MARK: - Actions

    private var actionsGrid: some View {
        // Two-column grid of capsule-style tiles. Capped at
        // `.accessibility1` so glyph + label still fit the column at
        // larger sizes; users beyond that read the same actions in the
        // info card / sheet body, which scales freely.
        let cols = [
            GridItem(.flexible(), spacing: 8),
            GridItem(.flexible(), spacing: 8),
        ]
        return LazyVGrid(columns: cols, spacing: 8) {
            actionTile(
                title: "Add to Day",
                systemImage: "calendar.badge.plus",
                tint: AppColors.appPrimary,
                isPrimary: true
            ) {
                PlatformUsageTelemetry.mapSearch(.addToDayTapped, origin: preview.origin)
                onAddToDay()
            }
            actionTile(
                title: "Search nearby",
                systemImage: "location.magnifyingglass",
                tint: .secondary,
                isPrimary: false
            ) {
                PlatformUsageTelemetry.mapSearch(.searchThisAreaTapped)
                onSearchNearby()
            }
            actionTile(
                title: "Apple Maps",
                systemImage: "map.fill",
                tint: .secondary,
                isPrimary: false
            ) {
                openInAppleMaps()
            }
            actionTile(
                title: "Directions",
                systemImage: "arrow.triangle.turn.up.right.diamond.fill",
                tint: .secondary,
                isPrimary: false
            ) {
                openDirections()
            }
        }
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
    }

    @ViewBuilder
    private func actionTile(
        title: String,
        systemImage: String,
        tint: Color,
        isPrimary: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 16, weight: .semibold))
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.9)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isPrimary ? AppColors.appPrimary : Color(uiColor: .secondarySystemBackground))
            )
            .foregroundStyle(isPrimary ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    // MARK: - Info card

    private var infoCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let phone = preview.phone, !phone.isEmpty {
                infoRow(
                    icon: "phone.fill",
                    text: phone,
                    action: phone.callURL.map { url in { openURL(url) } }
                )
            }

            if let website = preview.website {
                infoRow(
                    icon: "safari.fill",
                    text: website.host ?? website.absoluteString,
                    action: { openURL(website) }
                )
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(uiColor: .secondarySystemBackground))
        )
    }

    @ViewBuilder
    private func infoRow(icon: String, text: String, action: (() -> Void)?) -> some View {
        Button {
            action?()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22)
                Text(text)
                    .font(.subheadline)
                    .foregroundStyle(action != nil ? AppColors.appPrimary : .primary)
                    .lineLimit(1)
                Spacer()
                if action != nil {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(action == nil)
    }

    // MARK: - Apple Maps deep links

    private func openInAppleMaps() {
        let placemark = MKPlacemark(coordinate: preview.coordinate)
        let item = MKMapItem(placemark: placemark)
        item.name = preview.name
        item.openInMaps()
    }

    private func openDirections() {
        let placemark = MKPlacemark(coordinate: preview.coordinate)
        let dest = MKMapItem(placemark: placemark)
        dest.name = preview.name
        MKMapItem.openMaps(
            with: [MKMapItem.forCurrentLocation(), dest],
            launchOptions: [
                MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving,
            ]
        )
    }

    // MARK: - Look Around fetch

    private func fetchLookAroundIfNeeded() async {
        guard !fetchedLookAround else { return }
        fetchedLookAround = true
        if #available(iOS 16.0, *) {
            let svc = AppleMapSearchService()
            let scene = await svc.lookAroundScene(for: preview.coordinate)
            await MainActor.run {
                self.lookAroundScene = scene
                if scene != nil {
                    PlatformUsageTelemetry.mapSearch(.lookAroundFetched)
                }
            }
        }
    }
}

// MARK: - Look Around UIKit bridges
//
// SwiftUI's `LookAroundPreview` is iOS 16.4+ only and doesn't expose
// a tap callback in earlier 16 builds. UIKit `MKLookAroundViewController`
// has been available since iOS 16.0, so we wrap it.

private struct LookAroundPreviewWrapper: UIViewControllerRepresentable {
    let scene: MKLookAroundScene
    var onTap: () -> Void

    func makeUIViewController(context: Context) -> MKLookAroundViewController {
        let vc = MKLookAroundViewController(scene: scene)
        vc.isNavigationEnabled = false
        vc.showsRoadLabels = true
        let tap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleTap)
        )
        vc.view.addGestureRecognizer(tap)
        context.coordinator.onTap = onTap
        return vc
    }

    func updateUIViewController(_ uiViewController: MKLookAroundViewController, context: Context) {
        uiViewController.scene = scene
        context.coordinator.onTap = onTap
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject {
        var onTap: (() -> Void)?
        @objc func handleTap() { onTap?() }
    }
}

private struct LookAroundFullScreenWrapper: UIViewControllerRepresentable {
    let scene: MKLookAroundScene

    func makeUIViewController(context: Context) -> MKLookAroundViewController {
        let vc = MKLookAroundViewController(scene: scene)
        vc.isNavigationEnabled = true
        vc.showsRoadLabels = true
        return vc
    }

    func updateUIViewController(_ uiViewController: MKLookAroundViewController, context: Context) {
        uiViewController.scene = scene
    }
}

// MARK: - Helpers

private extension String {
    var callURL: URL? {
        let cleaned = filter { $0.isNumber || $0 == "+" }
        guard !cleaned.isEmpty else { return nil }
        return URL(string: "tel://\(cleaned)")
    }
}

// =============================================================================
