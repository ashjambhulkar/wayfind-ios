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
//  Detents are owned by the presenter: minimized, medium, and large native
//  SwiftUI sheet stops so the user can keep map context while browsing.
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

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: AppSpacing.lg) {
                    placeSummary
                        .padding(.horizontal, AppSpacing.lg)

                    primaryAction
                        .padding(.horizontal, AppSpacing.lg)

                    quickActionsRow
                        .padding(.horizontal, AppSpacing.lg)

                    visualPreviewCard
                        .padding(.horizontal, AppSpacing.lg)

                    if hasInfoRows {
                        infoCard
                            .padding(.horizontal, AppSpacing.lg)
                    }

                    Spacer(minLength: 24)
                }
                .padding(.top, AppSpacing.xl)
            }
            .scrollIndicators(.hidden)
            .background(AppColors.appBackground)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .navigationBar)
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

    private var placeSummary: some View {
        HStack(alignment: .top, spacing: AppSpacing.md) {
            placeIcon

            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                Text(preview.name)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.86)

                if !preview.subtitle.isEmpty {
                    Text(preview.subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                HStack(spacing: AppSpacing.sm) {
                    categoryBadge

                    if preview.isOwnedRow {
                        Label("Wayfind suggestion", systemImage: "checkmark.seal.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AppColors.appPrimary)
                            .padding(.horizontal, AppSpacing.sm)
                            .padding(.vertical, 6)
                            .background(AppColors.appPrimaryLight, in: Capsule())
                    }
                }
                .padding(.top, AppSpacing.xs)
            }

            Spacer(minLength: 0)

            Button(role: .cancel) {
                onDismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close preview")
        }
        .padding(.top, AppSpacing.xs)
    }

    private var visualPreviewCard: some View {
        ZStack(alignment: .bottomLeading) {
            heroBackground

            LinearGradient(
                colors: [
                    Color.black.opacity(0.0),
                    Color.black.opacity(0.44),
                    Color.black.opacity(0.62),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .allowsHitTesting(false)

            Label(
                lookAroundScene == nil ? "Map preview" : "Look Around",
                systemImage: lookAroundScene == nil ? "map.fill" : "binoculars.fill"
            )
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, AppSpacing.sm)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(AppSpacing.md)
            .allowsHitTesting(false)
        }
        .frame(height: 220)
        .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        }
        .contentShape(RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous))
        .onTapGesture {
            if lookAroundScene != nil {
                showLookAround = true
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(lookAroundScene == nil ? "Map preview" : "Look Around preview")
        .accessibilityAddTraits(lookAroundScene == nil ? [] : .isButton)
    }

    @ViewBuilder
    private var heroBackground: some View {
        if let scene = lookAroundScene {
            LookAroundPreviewWrapper(scene: scene) {
                showLookAround = true
            }
        } else if let thumbnailURL = preview.thumbnailURL {
            AsyncImage(url: thumbnailURL) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFill()
                case .failure, .empty:
                    fallbackHeroBackground
                @unknown default:
                    fallbackHeroBackground
                }
            }
        } else {
            fallbackHeroBackground
        }
    }

    private var fallbackHeroBackground: some View {
        ZStack {
            LinearGradient(
                colors: [
                    placeTint.opacity(0.95),
                    AppColors.appSecondary.opacity(0.82),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Image(systemName: preview.category?.mapBadgeSymbol ?? "mappin.circle.fill")
                .font(.system(size: 64, weight: .semibold))
                .foregroundStyle(.white.opacity(0.22))
                .offset(x: 86, y: -36)
        }
    }

    // MARK: - Actions

    private var primaryAction: some View {
        Button {
            PlatformUsageTelemetry.mapSearch(.addToDayTapped, origin: preview.origin)
            onAddToDay()
        } label: {
            Label("Add to itinerary", systemImage: "calendar.badge.plus")
                .font(.headline.weight(.semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background(AppColors.appPrimary, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityHint("Choose a day and add this place to your trip")
    }

    private var quickActionsRow: some View {
        HStack(spacing: AppSpacing.md) {
            quickAction(
                title: "Directions",
                systemImage: "arrow.triangle.turn.up.right.diamond.fill"
            ) {
                openDirections()
            }

            quickAction(
                title: "Nearby",
                systemImage: "location.magnifyingglass"
            ) {
                PlatformUsageTelemetry.mapSearch(.searchThisAreaTapped)
                onSearchNearby()
            }

            quickAction(
                title: "Maps",
                systemImage: "map.fill"
            ) {
                openInAppleMaps()
            }

        }
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
    }

    private func quickAction(
        title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: AppSpacing.xs) {
                Image(systemName: systemImage)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(AppColors.appPrimary)
                    .frame(width: 48, height: 48)
                    .background(Color(uiColor: .secondarySystemBackground), in: Circle())

                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    private var categoryBadge: some View {
        Label(categoryTitle, systemImage: preview.category?.mapBadgeSymbol ?? "mappin.circle.fill")
            .font(.caption.weight(.semibold))
            .foregroundStyle(placeTint)
            .padding(.horizontal, AppSpacing.sm)
            .padding(.vertical, 6)
            .background(placeTint.opacity(0.14), in: Capsule())
    }

    private var placeIcon: some View {
        ZStack {
            Circle()
                .fill(placeTint.opacity(0.14))
                .frame(width: 52, height: 52)
            Image(systemName: preview.category?.mapBadgeSymbol ?? "mappin.circle.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(placeTint)
        }
        .accessibilityHidden(true)
    }

    // MARK: - Info card

    private var infoCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            let hasAddress = !preview.subtitle.isEmpty
            let hasPhone = preview.phone?.isEmpty == false
            if !preview.subtitle.isEmpty {
                infoRow(
                    icon: "mappin.and.ellipse",
                    title: "Address",
                    text: preview.subtitle,
                    action: nil
                )
            }

            if let phone = preview.phone, !phone.isEmpty {
                if hasAddress {
                    Divider().padding(.leading, 50)
                }
                infoRow(
                    icon: "phone.fill",
                    title: "Phone",
                    text: phone,
                    action: phone.callURL.map { url in { openURL(url) } }
                )
            }

            if let website = preview.website {
                if hasAddress || hasPhone {
                    Divider().padding(.leading, 50)
                }
                infoRow(
                    icon: "safari.fill",
                    title: "Website",
                    text: website.host ?? website.absoluteString,
                    action: { openURL(website) }
                )
            }
        }
        .padding(.vertical, AppSpacing.xs)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    @ViewBuilder
    private func infoRow(icon: String, title: String, text: String, action: (() -> Void)?) -> some View {
        Button {
            action?()
        } label: {
            HStack(spacing: AppSpacing.md) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(AppColors.appPrimary)
                    .frame(width: 26, height: 26)
                    .background(AppColors.appPrimaryLight, in: Circle())

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(text)
                        .font(.subheadline)
                        .foregroundStyle(action != nil ? AppColors.appPrimary : .primary)
                        .lineLimit(title == "Address" ? 2 : 1)
                }

                Spacer(minLength: 0)

                if action != nil {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, AppSpacing.md)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(action == nil)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Derived display values

    private var placeTint: Color {
        preview.category?.color ?? AppColors.appPrimary
    }

    private var categoryTitle: String {
        preview.category?.label ?? "Place"
    }

    private var hasInfoRows: Bool {
        !preview.subtitle.isEmpty || preview.phone?.isEmpty == false || preview.website != nil
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
