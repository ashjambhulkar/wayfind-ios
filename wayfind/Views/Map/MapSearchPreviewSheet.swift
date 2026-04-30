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
//  Actions: Add to trip and view Look Around when available.
//
//  Detents are owned by the presenter: minimized, medium, and large native
//  SwiftUI sheet stops so the user can keep map context while browsing.
//

import MapKit
import SwiftUI

struct MapSearchPreviewSheet: View {
    let preview: MapSearchPreview
    let scheduledDays: [ItineraryDay]
    let preselectedDayId: UUID?

    /// Tap "Add" — caller saves the place directly to the current trip day.
    var onAdd: (UUID, Date?, String?) -> Void

    /// Caller dismisses (X / drag-down).
    var onDismiss: () -> Void

    @State private var lookAroundScene: MKLookAroundScene?
    @State private var fetchedLookAround = false
    @State private var showLookAround = false
    @State private var selectedDayId: UUID?
    @State private var includeTime = false
    @State private var startTime = Date()
    @State private var notes = ""

    @Environment(\.openURL) private var openURL

    init(
        preview: MapSearchPreview,
        scheduledDays: [ItineraryDay],
        preselectedDayId: UUID?,
        onAdd: @escaping (UUID, Date?, String?) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.preview = preview
        self.scheduledDays = scheduledDays
        self.preselectedDayId = preselectedDayId
        self.onAdd = onAdd
        self.onDismiss = onDismiss
        _selectedDayId = State(initialValue: preselectedDayId ?? scheduledDays.first?.id)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: AppSpacing.lg) {
                    placeSummary
                        .padding(.horizontal, AppSpacing.lg)

                    scheduleAndNotesCard
                        .padding(.horizontal, AppSpacing.lg)

                    visualPreviewCard
                        .padding(.horizontal, AppSpacing.lg)

                    if hasInfoRows {
                        infoCard
                            .padding(.horizontal, AppSpacing.lg)
                    }

                    Spacer(minLength: AppSpacing.xl)
                }
                .padding(.top, AppSpacing.xl)
            }
            .scrollIndicators(.hidden)
            .background {
                AppColors.appBackground.ignoresSafeArea()
            }
            .navigationTitle("Place Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(AppColors.appBackground, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        onDismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        PlatformUsageTelemetry.mapSearch(.addToDayTapped, origin: preview.origin)
                        savePreview()
                    }
                    .font(.appBody.weight(.semibold))
                    .disabled(selectedDayId == nil && scheduledDays.first?.id == nil)
                }
            }
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
                    .font(.sectionHeader.weight(.bold))
                    .foregroundStyle(AppColors.textPrimary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.86)

                if !preview.subtitle.isEmpty {
                    Text(preview.subtitle)
                        .font(.appBody)
                        .foregroundStyle(AppColors.textSecondary)
                        .lineLimit(2)
                }

            }

        }
        .padding(.top, AppSpacing.xs)
    }

    private var scheduleAndNotesCard: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: AppSpacing.sm) {
                Text("Schedule")
                    .font(.appCaption.weight(.semibold))
                    .foregroundStyle(AppColors.textSecondary)
                    .textCase(.uppercase)

                Picker("Day", selection: Binding(
                    get: { selectedDayId ?? scheduledDays.first?.id ?? UUID() },
                    set: { selectedDayId = $0 }
                )) {
                    ForEach(scheduledDays, id: \.id) { day in
                        Text(dayLabel(day)).tag(day.id)
                    }
                }
                .pickerStyle(.menu)

                Toggle(isOn: $includeTime.animation(AppSpring.smooth)) {
                    Label("Set start time", systemImage: "clock")
                }

                if includeTime {
                    DatePicker("Start time", selection: $startTime, displayedComponents: .hourAndMinute)
                }
            }
            .padding(AppSpacing.md)

            Divider()
                .overlay(AppColors.appDivider)

            VStack(alignment: .leading, spacing: AppSpacing.sm) {
                Text("Notes")
                    .font(.appCaption.weight(.semibold))
                    .foregroundStyle(AppColors.textSecondary)
                    .textCase(.uppercase)

                TextField("Notes (optional)", text: $notes, axis: .vertical)
                    .lineLimit(2...5)
            }
            .padding(AppSpacing.md)
        }
        .font(.appBody)
        .foregroundStyle(AppColors.textPrimary)
        .background(AppColors.appSurface, in: RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous)
                .strokeBorder(AppColors.appDivider, lineWidth: 0.5)
        }
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

            if lookAroundScene == nil {
                HStack(spacing: AppSpacing.xs) {
                    Image(systemName: "map.fill")
                        .font(.appCaption.weight(.semibold))
                        .symbolRenderingMode(.monochrome)
                        .foregroundStyle(AppColors.iconOnColoredSurface)
                    Text("Map preview")
                        .font(.appCaption.weight(.semibold))
                        .foregroundStyle(AppColors.iconOnColoredSurface)
                }
                    .padding(.horizontal, AppSpacing.sm)
                    .padding(.vertical, AppSpacing.xs)
                    .background(AppColors.iconBadgeGradient(accent: AppColors.appPrimary), in: Capsule())
                    .padding(AppSpacing.md)
                    .allowsHitTesting(false)
            }
        }
        .frame(height: 220)
        .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous)
                .strokeBorder(AppColors.appDivider, lineWidth: 0.5)
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
            Image(systemName: previewIconSymbol)
                .font(.screenTitle.weight(.semibold))
                .foregroundStyle(AppColors.iconOnColoredSurface.opacity(0.22))
                .offset(x: 86, y: -36)
        }
    }

    private var placeIcon: some View {
        ZStack {
            Circle()
                .fill(AppColors.iconBadgeGradient(accent: placeBadgeAccent))
                .frame(width: 52, height: 52)
            Image(systemName: previewIconSymbol)
                .font(.sectionHeader.weight(.semibold))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(AppColors.iconOnColoredSurface)
        }
        .accessibilityHidden(true)
    }

    // MARK: - Info card

    private var infoCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            let hasAddress = !preview.subtitle.isEmpty
            let hasPhone = preview.phone?.isEmpty == false
            let hasWebsite = preview.website != nil
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

            if hasAddress || hasPhone || hasWebsite {
                Divider().padding(.leading, 50)
            }
            infoRow(
                icon: "map.fill",
                title: "Open in Maps",
                text: "Apple Maps",
                action: openInAppleMaps
            )
        }
        .padding(.vertical, AppSpacing.xs)
        .background(AppColors.appSurface, in: RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous)
                .strokeBorder(AppColors.appDivider, lineWidth: 1)
        }
    }

    @ViewBuilder
    private func infoRow(icon: String, title: String, text: String, action: (() -> Void)?) -> some View {
        Button {
            guard let action else { return }
            action()
        } label: {
            HStack(spacing: AppSpacing.md) {
                Image(systemName: icon)
                    .font(.appBody.weight(.semibold))
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(AppColors.iconOnColoredSurface)
                    .frame(width: 26, height: 26)
                    .background(AppColors.iconBadgeGradient(accent: infoRowBadgeAccent(for: icon)), in: Circle())

                VStack(alignment: .leading, spacing: AppSpacing.xs) {
                    Text(title)
                        .font(.appCaption)
                        .foregroundStyle(AppColors.textSecondary)
                    Text(text)
                        .font(.appBody)
                        .foregroundStyle(action != nil ? AppColors.appPrimary : AppColors.textPrimary)
                        .lineLimit(title == "Address" ? 2 : 1)
                }

                Spacer(minLength: 0)

                if action != nil {
                    Image(systemName: "chevron.right")
                        .font(.appCaption.weight(.semibold))
                        .foregroundStyle(AppColors.iconOnColoredSurface)
                }
            }
            .padding(.horizontal, AppSpacing.md)
            .padding(.vertical, AppSpacing.md)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Derived display values

    private var placeTint: Color {
        preview.category?.color ?? AppColors.appError
    }

    private var placeBadgeAccent: Color {
        preview.category == nil ? AppColors.appError : placeTint
    }

    private var previewIconSymbol: String {
        preview.category?.mapBadgeSymbol ?? "mappin"
    }

    private func infoRowBadgeAccent(for icon: String) -> Color {
        icon.hasPrefix("mappin") ? AppColors.appError : AppColors.appPrimary
    }

    private var hasInfoRows: Bool {
        !preview.subtitle.isEmpty || preview.phone?.isEmpty == false || preview.website != nil
    }

    private func savePreview() {
        guard let dayId = selectedDayId ?? scheduledDays.first?.id else { return }
        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        onAdd(dayId, includeTime ? startTime : nil, trimmedNotes.isEmpty ? nil : trimmedNotes)
    }

    private func dayLabel(_ day: ItineraryDay) -> String {
        guard let date = day.date else { return "Day \(day.dayNumber)" }
        return "Day \(day.dayNumber) · \(date.shortFormatted)"
    }

    private func openInAppleMaps() {
        let placemark = MKPlacemark(coordinate: preview.coordinate)
        let item = MKMapItem(placemark: placemark)
        item.name = preview.name
        item.openInMaps()
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

#if DEBUG
#Preview("Preview sheet — Wayfind suggestion") {
    let tripId = UUID()
    let day1Id = UUID()
    let days = [
        ItineraryDay(id: day1Id, tripId: tripId, dayNumber: 1, date: Date()),
        ItineraryDay(id: UUID(), tripId: tripId, dayNumber: 2, date: Date().addingTimeInterval(86_400)),
    ]
    let preview = MapSearchPreview(
        id: "louvre-city-places",
        origin: .cityPlaces,
        name: "Louvre Museum",
        subtitle: "Rue de Rivoli, 75001 Paris",
        coordinate: .init(latitude: 48.8606, longitude: 2.3376),
        googlePlaceId: "ChIJD7fiBh9u5kcRYJSMaMOCCwQ",
        phone: "+33 1 40 20 53 17",
        website: URL(string: "https://www.louvre.fr"),
        thumbnailURL: nil,
        category: .attraction
    )
    MapSearchPreviewSheet(
        preview: preview,
        scheduledDays: days,
        preselectedDayId: day1Id,
        onAdd: { _, _, _ in },
        onDismiss: {}
    )
}

#Preview("Preview sheet — Apple result") {
    let tripId = UUID()
    let day1Id = UUID()
    let days = [
        ItineraryDay(id: day1Id, tripId: tripId, dayNumber: 1, date: Date()),
        ItineraryDay(id: UUID(), tripId: tripId, dayNumber: 2, date: Date().addingTimeInterval(86_400)),
    ]
    let preview = MapSearchPreview(
        id: "eiffel-apple",
        origin: .apple,
        name: "Eiffel Tower",
        subtitle: "Champ de Mars, 75007 Paris",
        coordinate: .init(latitude: 48.8584, longitude: 2.2945),
        googlePlaceId: nil,
        phone: nil,
        website: nil,
        thumbnailURL: nil,
        category: .attraction
    )
    MapSearchPreviewSheet(
        preview: preview,
        scheduledDays: days,
        preselectedDayId: day1Id,
        onAdd: { _, _, _ in },
        onDismiss: {}
    )
}
#endif
