//
//  AddActivitySheet.swift
//  wayfind
//
//  Trip Detail-native add flow: search, select, schedule, save.
//

import CoreLocation
import MapKit
import SwiftUI
import UIKit

struct AddActivitySheet: View {
    @Environment(DataService.self) private var dataService
    @Environment(\.openURL) private var openURL

    let trip: Trip
    let selectedDayNumber: Int
    let days: [ItineraryDay]
    let scheduledPlaces: [Place]
    let wishlistPlaces: [Place]
    let onSaved: (Place) async -> Void
    let onCancel: () -> Void

    @State private var query = ""
    @State private var searchContext: AddActivitySearchContext?
    @State private var isLoadingContext = false
    @State private var isLoadingSuggested = false
    @State private var isResolvingSelection = false
    @State private var isSaving = false
    @State private var suggestedPlaces: [MapSearchPreview] = []
    @State private var ownedRows: [MapSearchPreview] = []
    @State private var nearbyRows: [MapSearchPreview] = []
    @State private var searchTask: Task<Void, Never>?
    @State private var selectedDraft: AddActivityDraft?
    @State private var selectedDayId: UUID?
    @State private var includeTime = false
    @State private var startTime = Date()
    @State private var notes = ""
    @State private var manualName = ""
    @State private var manualAddress = ""
    @State private var manualCategory: PlaceCategory = .custom
    @State private var errorMessage: String?

    /// Full suggested-places browser — same surface as Map search (`SuggestedPlacesAllSheet`).
    @State private var showSuggestedPlacesBrowser = false
    @FocusState private var searchFieldFocused: Bool
    @State private var scheduleLookAroundScene: MKLookAroundScene?
    @State private var fetchedLookAroundDraftId: String?
    @State private var showScheduleLookAround = false

    @State private var apple = AppleMapSearchService()
    @State private var google = PlaceSearchService()

    private var provider: FeatureFlagsService.MapSearchProvider {
        FeatureFlagsService.shared.mapSearchProvider(forCountry: searchContext?.country)
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Tighter than default inset-grouped row insets so place rows match `safeAreaInset` capsules + scroll `contentMargins` (see `searchList`).
    private var addActivityGroupedPlaceRowInsets: EdgeInsets {
        EdgeInsets(top: AppSpacing.sm, leading: AppSpacing.md, bottom: AppSpacing.sm, trailing: AppSpacing.lg)
    }

    init(
        trip: Trip,
        selectedDayNumber: Int,
        days: [ItineraryDay],
        scheduledPlaces: [Place],
        wishlistPlaces: [Place],
        onSaved: @escaping (Place) async -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.trip = trip
        self.selectedDayNumber = selectedDayNumber
        self.days = days
        self.scheduledPlaces = scheduledPlaces
        self.wishlistPlaces = wishlistPlaces
        self.onSaved = onSaved
        self.onCancel = onCancel
        let preselected = days.first(where: { $0.dayNumber == selectedDayNumber })?.id ?? days.first?.id
        _selectedDayId = State(initialValue: preselected)
    }

    var body: some View {
        searchList
            .onAppear {
                presentSearchField()
            }
            .onChange(of: query) { _, newValue in
                refreshSearch(for: newValue)
            }
        .task {
            await loadSearchContextIfNeeded()
        }
        .onDisappear {
            searchTask?.cancel()
            apple.clear()
            google.clearResults()
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationBackground(AppColors.appBackground)
        .tint(AppColors.appPrimary)
        .sheet(isPresented: $showSuggestedPlacesBrowser) {
            SuggestedPlacesAllSheet(
                cityProfileId: searchContext?.cityProfileId,
                excludedPlaceIds: searchContext?.excludedPlaceIds ?? []
            ) { preview in
                showSuggestedPlacesBrowser = false
                select(preview)
            } onCancel: {
                showSuggestedPlacesBrowser = false
            }
            .presentationDetents([.large])
            .presentationContentInteraction(.scrolls)
            .presentationDragIndicator(.visible)
            .presentationBackgroundInteraction(.disabled)
            .presentationBackground(AppColors.appBackground)
        }
        .sheet(item: $selectedDraft, onDismiss: {
            presentSearchField()
        }) { draft in
            scheduleActivitySheet(for: draft)
        }
    }

    private func scheduleActivitySheet(for draft: AddActivityDraft) -> some View {
        NavigationStack {
            scheduleForm(for: draft)
                .navigationTitle(String(localized: "Add Activity"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button() {
                            selectedDraft = nil
                        } label: {
                            Image(systemName: "chevron.left")
                                .font(.appBody.weight(.medium))
                                .foregroundStyle(AppColors.textSecondary)
                        }
                    }

                    ToolbarItem(placement: .confirmationAction) {
                        Button {
                            Task { await saveSelectedDraft() }
                        } label: {
                            if isSaving {
                                ProgressView()
                            } else {
                                Text("Add").bold()
                            }
                        }
                        .disabled(!canSave || isSaving)
                    }
                }
                .background(AppColors.appBackground)
        }
        .task(id: draft.id) {
            await fetchScheduleLookAroundIfNeeded(for: draft)
        }
        .sheet(isPresented: $showScheduleLookAround) {
            if let scene = scheduleLookAroundScene {
                AddActivityLookAroundFullScreenWrapper(scene: scene)
                    .ignoresSafeArea()
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationBackground(AppColors.appBackground)
        .tint(AppColors.appPrimary)
    }

    private var searchList: some View {
        List {
            if isLoadingContext {
                Section {
                    HStack(spacing: AppSpacing.sm) {
                        ProgressView().controlSize(.small)
                        Text("Preparing trip search...")
                            .font(.appBody)
                            .foregroundStyle(AppColors.textSecondary)
                    }
                    .listRowBackground(AppColors.appSurface)
                }
            }

            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .font(.appBody)
                        .foregroundStyle(AppColors.appWarning)
                        .listRowBackground(AppColors.appPrimaryLight)
                }
            }

            if trimmedQuery.isEmpty {
                emptySearchSections
            } else {
                typedSearchSections
            }
        }
        .listStyle(.insetGrouped)
        .contentMargins(.top, 0, for: .scrollContent)
        .listSectionSpacing(trimmedQuery.isEmpty ? AppSpacing.lg : AppSpacing.xs)
        .scrollContentBackground(.hidden)
        .background(AppColors.appBackground)
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .top, spacing: AppSpacing.sm) {
            addActivitySearchChromeInset
        }
    }

    private var addActivitySearchChromeInset: some View {
        VStack(spacing: 5) {
            addActivitySearchChromeRow

            if trimmedQuery.isEmpty {
                addActivityCategoryCapsulesRow
            }
        }
        .padding(.top, AppSpacing.md)
    }

    /// Native `.searchable` requires a navigation host, which briefly flashes a nav header here.
    /// This custom TextField is scoped to this no-navigation bottom sheet search surface.
    private var addActivitySearchChromeRow: some View {
        HStack(alignment: .center, spacing: AppSpacing.sm) {
            HStack(spacing: AppSpacing.sm) {
                Image(systemName: "magnifyingglass")
                    .font(.appBody.weight(.medium))
                    .foregroundStyle(AppColors.textSecondary)

                TextField(String(localized: "Search..."), text: $query)
                    .font(.appBody)
                    .foregroundStyle(AppColors.textPrimary)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .focused($searchFieldFocused)
                    .onSubmit {
                        Task { await runNearbySearch() }
                    }
            }
            .padding(.horizontal, AppSpacing.md)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(AppColors.appSurface, in: Capsule(style: .continuous))
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(AppColors.appDivider, lineWidth: 0.5)
            }

            Button {
                HapticManager.light()
                onCancel()
            } label: {
                Image(systemName: "xmark")
                    .font(.title2.weight(.medium))
                    .foregroundStyle(AppColors.textPrimary)
                    .frame(width: 44, height: 44)
                    .background(AppColors.appSurface, in: Circle())
                    .overlay {
                        Circle()
                            .strokeBorder(AppColors.appDivider, lineWidth: 0.5)
                    }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "Close"))
        }
        .padding(.horizontal, AppSpacing.lg)
        .padding(.top, AppSpacing.xs)
        .padding(.bottom, AppSpacing.sm)
    }

    /// Same horizontal rhythm as `MapSearchOverlay` / `CategoryPillsRow`: pills sit in `safeAreaInset`
    /// under `.searchable` so leading padding matches the search field instead of inset-grouped `List` margins.
    private var addActivityCategoryCapsulesRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: AppSpacing.sm) {
                ForEach(AddActivityCategoryShortcut.all) { shortcut in
                    Button {
                        Task { await runCategorySearch(shortcut) }
                    } label: {
                        let iconTint = shortcut.category?.color ?? AppColors.appPrimary
                        HStack(spacing: AppSpacing.xs) {
                            Image(systemName: shortcut.symbol)
                                .font(.appCaption.weight(.semibold))
                                .foregroundStyle(iconTint)
                                .symbolRenderingMode(.hierarchical)
                            Text(shortcut.label)
                                .font(.appBody.weight(.semibold))
                                .foregroundStyle(AppColors.textPrimary)
                                .lineLimit(1)
                                .fixedSize()
                        }
                        .padding(.vertical, AppSpacing.sm)
                        .padding(.horizontal, AppSpacing.md)
                        .background(AppColors.appSurface, in: Capsule(style: .continuous))
                        .overlay {
                            Capsule(style: .continuous)
                                .strokeBorder(AppColors.appDivider, lineWidth: 0.5)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Searches nearby places in this trip destination.")
                }
            }
            .padding(.horizontal, AppSpacing.lg)
        }
        .padding(.bottom, AppSpacing.xs)
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
    }

    /// Expandable Apple Maps-style header: title + adjacent chevron opens `SuggestedPlacesAllSheet`.
    private var addActivitySuggestedPlacesHeaderRow: some View {
        Button {
            HapticManager.selection()
            showSuggestedPlacesBrowser = true
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: AppSpacing.xs) {
                Text("Suggested Places")
                    .font(.sectionHeader.weight(.bold))
                    .foregroundStyle(AppColors.textPrimary)
                    .textCase(nil)
                Image(systemName: "chevron.right")
                    .font(.appBody.weight(.semibold))
                    .foregroundStyle(AppColors.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(String(localized: "Suggested Places"))
        .accessibilityHint(String(localized: "Opens the full suggested places list"))
    }

    /// Thumbnail rows mirroring `MapSearchOverlay.suggestedPlaceRow`.
    private func inlineSuggestedPlaceRow(_ preview: MapSearchPreview) -> some View {
        Button {
            select(preview)
        } label: {
            HStack(spacing: AppSpacing.md) {
                SuggestedThumbnail(preview: preview, size: AddActivitySuggestedInline.thumbnailSize)
                VStack(alignment: .leading, spacing: AppSpacing.xs) {
                    Text(preview.name)
                        .font(.appBody.weight(.semibold))
                        .foregroundStyle(AppColors.textPrimary)
                        .lineLimit(1)
                    if let cat = preview.category {
                        Text(cat.label)
                            .font(.appCaption)
                            .foregroundStyle(AppColors.textSecondary)
                            .lineLimit(1)
                    } else if !preview.subtitle.isEmpty {
                        Text(preview.subtitle)
                            .font(.appCaption)
                            .foregroundStyle(AppColors.textSecondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, AppSpacing.sm)
        .padding(.horizontal, AppSpacing.lg)
    }

    private var addActivitySuggestedPlacesGroup: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            addActivitySuggestedPlacesHeaderRow
            addActivitySuggestedPlacesCard
        }
    }

    @ViewBuilder
    private var addActivitySuggestedPlacesCard: some View {
        VStack(spacing: 0) {
            if isLoadingSuggested && suggestedPlaces.isEmpty {
                addActivitySuggestedStatusRow("Loading suggestions…")
            } else if searchContext?.cityProfileId == nil {
                addActivitySuggestedStatusRow("Suggestions appear here once your destination loads.")
            } else if suggestedPlaces.isEmpty {
                addActivitySuggestedStatusRow("No curated places yet for this city.")
            } else {
                let rows = Array(suggestedPlaces.prefix(AddActivitySuggestedInline.rowLimit))
                ForEach(rows) { preview in
                    inlineSuggestedPlaceRow(preview)
                    if preview.id != rows.last?.id {
                        Divider()
                            .padding(.leading, AddActivitySuggestedInline.dividerLeadingInset)
                    }
                }
            }
        }
        .background(AppColors.appSurface, in: RoundedRectangle(cornerRadius: AppCornerRadius.xLarge, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.xLarge, style: .continuous))
    }

    private func addActivitySuggestedStatusRow(_ message: LocalizedStringKey) -> some View {
        Text(message)
            .font(.appBody)
            .foregroundStyle(AppColors.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, AppSpacing.lg)
            .padding(.horizontal, AppSpacing.lg)
    }

    @ViewBuilder
    private var emptySearchSections: some View {
        Section {
            addActivitySuggestedPlacesGroup
                .listRowInsets(EdgeInsets(top: AppSpacing.lg, leading: 0, bottom: AppSpacing.xs, trailing: 0))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        }

        if !wishlistPlaces.isEmpty {
            Section("Ideas") {
                ForEach(wishlistPlaces) { place in
                    ideaRow(place)
                }
            }
        }

        Section {
            manualRow(title: String(localized: "Add a manual activity"), subtitle: String(localized: "Use this for plans without a map location.")) {
                selectManual(name: "", address: nil, category: .custom)
            }
        }
    }

    @ViewBuilder
    private var typedSearchSections: some View {
        Section {
            if searchContext?.region != nil {
                searchNearbyRow
            }

            ForEach(nearbyRows) { preview in
                previewRow(preview) { select(preview) }
            }

            ForEach(ownedRows) { preview in
                previewRow(preview) { select(preview) }
            }

            switch provider {
            case .apple, .chinaFallback:
                ForEach(apple.suggestions) { suggestion in
                    appleSuggestionRow(suggestion)
                }
            case .google:
                ForEach(google.results) { prediction in
                    googlePredictionRow(prediction)
                }
            }

            if isResolvingSelection {
                HStack(spacing: AppSpacing.sm) {
                    ProgressView().controlSize(.small)
                    Text("Finding place details...")
                        .font(.appBody)
                        .foregroundStyle(AppColors.textSecondary)
                }
                .listRowInsets(addActivityGroupedPlaceRowInsets)
                .listRowBackground(AppColors.appSurface)
            }
        } 

        Section {
            manualRow(title: "Add \"\(trimmedQuery)\" manually", subtitle: String(localized: "Create an activity without a map location.")) {
                selectManual(name: trimmedQuery, address: nil, category: .custom)
            }
        }
    }

    private var searchNearbyRow: some View {
        Button {
            Task { await runNearbySearch() }
        } label: {
            AddActivityPlaceRow(
                symbol: "magnifyingglass",
                family: .generic,
                title: trimmedQuery,
                subtitle: String(localized: "Search nearby in this trip area")
            )
        }
        .buttonStyle(.plain)
        .listRowInsets(addActivityGroupedPlaceRowInsets)
        .listRowBackground(AppColors.appSurface)
        .accessibilityHint("Finds matching places near the trip destination.")
    }

    private func previewRow(_ preview: MapSearchPreview, action: @escaping () -> Void) -> some View {
        let icon: (symbol: String, family: PlaceCategoryFamily) = {
            if let category = preview.category {
                return (category.mapBadgeSymbol, category.family)
            }
            return SearchRowIconHeuristic.icon(forTitle: preview.name)
        }()
        return Button(action: action) {
            AddActivityPlaceRow(
                symbol: icon.symbol,
                family: icon.family,
                title: preview.name,
                subtitle: preview.subtitle.isEmpty ? (preview.category?.label ?? String(localized: "Place")) : preview.subtitle
            )
        }
        .buttonStyle(.plain)
        .listRowInsets(addActivityGroupedPlaceRowInsets)
        .listRowBackground(AppColors.appSurface)
    }

    private func appleSuggestionRow(_ suggestion: AppleMapSuggestion) -> some View {
        let icon = SearchRowIconHeuristic.icon(forTitle: suggestion.title)
        return Button {
            Task { await resolveAppleSuggestion(suggestion) }
        } label: {
            AddActivityPlaceRow(
                symbol: icon.symbol,
                family: icon.family,
                title: suggestion.title,
                subtitle: suggestion.subtitle
            )
        }
        .buttonStyle(.plain)
        .listRowInsets(addActivityGroupedPlaceRowInsets)
        .listRowBackground(AppColors.appSurface)
    }

    private func googlePredictionRow(_ prediction: PlaceAutocompleteResult) -> some View {
        let icon = SearchRowIconHeuristic.icon(forTitle: prediction.mainText)
        return Button {
            Task { await resolveGooglePrediction(prediction) }
        } label: {
            AddActivityPlaceRow(
                symbol: icon.symbol,
                family: icon.family,
                title: prediction.mainText,
                subtitle: prediction.secondaryText
            )
        }
        .buttonStyle(.plain)
        .listRowInsets(addActivityGroupedPlaceRowInsets)
        .listRowBackground(AppColors.appSurface)
    }

    private func ideaRow(_ place: Place) -> some View {
        Button {
            selectIdea(place)
        } label: {
            AddActivityPlaceRow(
                symbol: place.categoryEnum.mapBadgeSymbol,
                family: place.categoryEnum.family,
                title: place.name,
                subtitle: place.address ?? String(localized: "Idea")
            )
        }
        .buttonStyle(.plain)
        .listRowInsets(addActivityGroupedPlaceRowInsets)
        .listRowBackground(AppColors.appSurface)
    }

    private func manualRow(title: String, subtitle: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            AddActivityPlaceRow(
                symbol: "text.badge.plus",
                family: .generic,
                title: title,
                subtitle: subtitle
            )
        }
        .buttonStyle(.plain)
        .listRowInsets(addActivityGroupedPlaceRowInsets)
        .listRowBackground(AppColors.appSurface)
    }

    private func scheduleForm(for draft: AddActivityDraft) -> some View {
        List {
            Section("Activity") {
                AddActivityPlaceSummary(
                    title: displayTitle(for: draft),
                    subtitle: displaySubtitle(for: draft),
                    symbol: displayIcon(for: draft).symbol,
                    family: displayIcon(for: draft).family
                )
                .listRowInsets(addActivityGroupedPlaceRowInsets)
                .listRowBackground(AppColors.appSurface)

                if case .manual = draft {
                    TextField("Activity name", text: $manualName)
                        .textInputAutocapitalization(.words)
                        .listRowBackground(AppColors.appSurface)
                    TextField("Address or note (optional)", text: $manualAddress)
                        .textInputAutocapitalization(.words)
                        .listRowBackground(AppColors.appSurface)
                    Picker("Category", selection: $manualCategory) {
                        ForEach(PlaceCategory.allCases, id: \.self) { category in
                            Label(category.label, systemImage: category.sfSymbol)
                                .tag(category)
                        }
                    }
                    .listRowBackground(AppColors.appSurface)
                }
            }

            if shouldShowScheduleDetails(for: draft) {
                Section("Details") {
                    scheduleDetailsRows(for: draft)
                }
            }

            Section("Schedule") {
                Picker("Day", selection: Binding(
                    get: { selectedDayId ?? days.first?.id ?? UUID() },
                    set: { selectedDayId = $0 }
                )) {
                    ForEach(days, id: \.id) { day in
                        Text(dayLabel(day)).tag(day.id)
                    }
                }
                .pickerStyle(.menu)
                .listRowBackground(AppColors.appSurface)

                Toggle(isOn: $includeTime.animation(AppSpring.smooth)) {
                    Label("Set start time", systemImage: "clock")
                }
                .listRowBackground(AppColors.appSurface)

                if includeTime {
                    DatePicker("Start time", selection: $startTime, displayedComponents: .hourAndMinute)
                        .listRowBackground(AppColors.appSurface)
                }
            }

            Section("Notes") {
                TextField("Notes (optional)", text: $notes, axis: .vertical)
                    .lineLimit(2...5)
                    .listRowBackground(AppColors.appSurface)
            }

            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(AppColors.appWarning)
                        .listRowBackground(AppColors.appPrimaryLight)
                }
            }
        }
        .listStyle(.insetGrouped)
        .contentMargins(.top, AppSpacing.xs, for: .scrollContent)
        .listSectionSpacing(AppSpacing.lg)
        .scrollContentBackground(.hidden)
        .background(AppColors.appBackground)
        .scrollDismissesKeyboard(.interactively)
    }

    private func shouldShowScheduleDetails(for draft: AddActivityDraft) -> Bool {
        switch draft {
        case .preview(let preview):
            return !preview.subtitle.isEmpty
                || preview.phone?.isEmpty == false
                || preview.website != nil
                || scheduleLookAroundScene != nil
        case .manual:
            return false
        }
    }

    @ViewBuilder
    private func scheduleDetailsRows(for draft: AddActivityDraft) -> some View {
        if case .preview(let preview) = draft {
            if !preview.subtitle.isEmpty {
                AddActivityDetailRow(
                    icon: "mappin.and.ellipse",
                    title: "Address",
                    value: preview.subtitle
                )
                .listRowBackground(AppColors.appSurface)
            }

            if let phone = preview.phone, !phone.isEmpty {
                AddActivityDetailRow(
                    icon: "phone.fill",
                    title: "Phone",
                    value: phone,
                    isActionable: phone.callURL != nil
                ) {
                    if let url = phone.callURL {
                        openURL(url)
                    }
                }
                .listRowBackground(AppColors.appSurface)
            }

            if let website = preview.website {
                AddActivityDetailRow(
                    icon: "safari.fill",
                    title: "Website",
                    value: website.host ?? website.absoluteString,
                    isActionable: true
                ) {
                    openURL(website)
                }
                .listRowBackground(AppColors.appSurface)
            }

            if scheduleLookAroundScene != nil {
                AddActivityDetailRow(
                    icon: "binoculars.fill",
                    title: "Look Around",
                    value: "Preview this area",
                    isActionable: true
                ) {
                    showScheduleLookAround = true
                }
                .listRowBackground(AppColors.appSurface)
            }
        }
    }

    private var canSave: Bool {
        guard selectedDayId != nil || days.first?.id != nil else { return false }
        guard let draft = selectedDraft else { return false }
        if case .manual = draft {
            return !manualName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return true
    }

    private func presentSearchField() {
        Task { @MainActor in
            await Task.yield()
            guard selectedDraft == nil else { return }
            searchFieldFocused = true
        }
    }

    private func fetchScheduleLookAroundIfNeeded(for draft: AddActivityDraft) async {
        guard fetchedLookAroundDraftId != draft.id else { return }
        fetchedLookAroundDraftId = draft.id
        scheduleLookAroundScene = nil
        guard case .preview(let preview) = draft else { return }
        if #available(iOS 16.0, *) {
            let scene = await AppleMapSearchService().lookAroundScene(for: preview.coordinate)
            await MainActor.run {
                guard selectedDraft?.id == draft.id else { return }
                scheduleLookAroundScene = scene
            }
        }
    }

    private func loadSearchContextIfNeeded() async {
        guard searchContext == nil, !isLoadingContext else { return }
        isLoadingContext = true
        defer { isLoadingContext = false }
        searchContext = await AddActivitySearchContext.resolve(
            trip: trip,
            scheduledPlaces: scheduledPlaces,
            dataService: dataService
        )
        await loadSuggestedPlaces()
    }

    private func loadSuggestedPlaces() async {
        guard let searchContext else { return }
        isLoadingSuggested = true
        defer { isLoadingSuggested = false }
        suggestedPlaces = await CityPlacesSearchService.shared.topPicks(
            cityProfileId: searchContext.cityProfileId,
            excluding: searchContext.excludedPlaceIds,
            limit: AddActivitySuggestedInline.topPicksFetchLimit
        )
    }

    private func refreshSearch(for rawQuery: String) {
        searchTask?.cancel()
        let trimmed = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        nearbyRows = []
        ownedRows = []
        guard trimmed.count >= 2 else {
            apple.clear()
            google.clearResults()
            return
        }

        switch provider {
        case .apple, .chinaFallback:
            apple.update(query: trimmed, region: searchContext?.region)
            google.clearResults()
        case .google:
            google.search(query: trimmed, types: "establishment")
            apple.clear()
        }

        searchTask = Task {
            guard let searchContext, let region = searchContext.region else { return }
            let rows = await CityPlacesSearchService.shared.search(
                cityProfileId: searchContext.cityProfileId,
                query: trimmed,
                category: nil,
                region: region,
                excluding: searchContext.excludedPlaceIds,
                limit: 8
            )
            await MainActor.run {
                guard !Task.isCancelled else { return }
                ownedRows = rows
            }
        }
    }

    private func runNearbySearch() async {
        guard let searchContext, let region = searchContext.region, trimmedQuery.count >= 2 else { return }
        isResolvingSelection = true
        defer { isResolvingSelection = false }
        async let appleResults = apple.searchNearbyPreviews(query: trimmedQuery, in: region, resultLimit: 18)
        async let dbResults = CityPlacesSearchService.shared.search(
            cityProfileId: searchContext.cityProfileId,
            query: trimmedQuery,
            category: nil,
            region: region,
            excluding: searchContext.excludedPlaceIds,
            limit: 18
        )
        let (appleRows, dbRows) = await (appleResults, dbResults)
        nearbyRows = MapSearchResultMerger.merge(apple: appleRows, db: dbRows, limit: 24)
        HapticManager.selection()
    }

    private func runCategorySearch(_ shortcut: AddActivityCategoryShortcut) async {
        guard let searchContext, let region = searchContext.region else {
            query = shortcut.label
            return
        }
        query = shortcut.label
        isResolvingSelection = true
        defer { isResolvingSelection = false }
        async let appleResults = apple.searchNearbyPreviews(query: shortcut.query, in: region, resultLimit: 18)
        async let dbResults = CityPlacesSearchService.shared.search(
            cityProfileId: searchContext.cityProfileId,
            query: nil,
            category: shortcut.category,
            region: region,
            excluding: searchContext.excludedPlaceIds,
            limit: 18
        )
        let (appleRows, dbRows) = await (appleResults, dbResults)
        nearbyRows = MapSearchResultMerger.merge(apple: appleRows, db: dbRows, limit: 24)
        HapticManager.selection()
    }

    private func resolveAppleSuggestion(_ suggestion: AppleMapSuggestion) async {
        isResolvingSelection = true
        defer { isResolvingSelection = false }
        guard let preview = await apple.resolveDetail(suggestion: suggestion, in: searchContext?.region) else {
            errorMessage = "That place is not near this trip area. Try a broader search."
            return
        }
        select(preview)
    }

    private func resolveGooglePrediction(_ prediction: PlaceAutocompleteResult) async {
        isResolvingSelection = true
        defer { isResolvingSelection = false }
        guard let detail = await google._getPlaceDetailsForChinaFallback(placeId: prediction.id) else {
            errorMessage = "Could not load that place. Try another result."
            return
        }
        let preview = MapSearchPreview(
            id: "google|\(detail.placeId)",
            origin: .googleFallback,
            name: detail.name,
            subtitle: detail.address,
            coordinate: CLLocationCoordinate2D(latitude: detail.lat, longitude: detail.lng),
            googlePlaceId: detail.placeId,
            phone: nil,
            website: nil,
            thumbnailURL: nil,
            category: PlaceCategory.fromGoogleTypes(detail.types)
        )
        select(preview)
    }

    private func select(_ preview: MapSearchPreview) {
        errorMessage = nil
        selectedDraft = .preview(preview)
        HapticManager.light()
    }

    private func selectIdea(_ place: Place) {
        if let lat = place.lat, let lng = place.lng {
            select(MapSearchPreview(
                id: "idea|\(place.id.uuidString)",
                origin: place.googlePlaceId == nil ? .apple : .cityPlaces,
                name: place.name,
                subtitle: place.address ?? "",
                coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lng),
                googlePlaceId: place.googlePlaceId,
                phone: place.phoneNumber,
                website: place.website.flatMap { URL(string: $0) },
                thumbnailURL: place.heroImageUrl.flatMap { URL(string: $0) },
                category: place.categoryEnum
            ))
        } else {
            selectManual(name: place.name, address: place.address, category: place.categoryEnum)
        }
    }

    private func selectManual(name: String, address: String?, category: PlaceCategory) {
        manualName = name
        manualAddress = address ?? ""
        manualCategory = category
        selectedDraft = .manual(UUID())
        HapticManager.light()
    }

    private func saveSelectedDraft() async {
        guard !isSaving, let selectedDraft else { return }
        guard let dayId = selectedDayId ?? days.first?.id else { return }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let existingPlacesForDay = scheduledPlaces.filter { $0.itineraryDayId == dayId }
        let saver = ActivityPlaceSaver(dataService: dataService)
        let saved: Place
        switch selectedDraft {
        case .preview(let preview):
            saved = await saver.save(
                preview: preview,
                dayId: dayId,
                existingPlacesForDay: existingPlacesForDay,
                startTime: includeTime ? startTime : nil,
                notes: trimmedNotes.isEmpty ? nil : trimmedNotes,
                cityProfileId: searchContext?.cityProfileId
            )
        case .manual:
            saved = await saver.saveManual(
                name: manualName,
                address: manualAddress,
                category: manualCategory,
                dayId: dayId,
                existingPlacesForDay: existingPlacesForDay,
                startTime: includeTime ? startTime : nil,
                notes: trimmedNotes.isEmpty ? nil : trimmedNotes
            )
        }
        await onSaved(saved)
    }

    private func dayLabel(_ day: ItineraryDay) -> String {
        guard let date = day.date else { return "Day \(day.dayNumber)" }
        return "Day \(day.dayNumber) · \(date.shortFormatted)"
    }

    private func displayTitle(for draft: AddActivityDraft) -> String {
        switch draft {
        case .preview(let preview): return preview.name
        case .manual: return manualName.isEmpty ? String(localized: "Manual activity") : manualName
        }
    }

    private func displaySubtitle(for draft: AddActivityDraft) -> String {
        switch draft {
        case .preview(let preview):
            return preview.subtitle.isEmpty ? (preview.category?.label ?? String(localized: "Place")) : preview.subtitle
        case .manual:
            return manualAddress.isEmpty ? String(localized: "No map location") : manualAddress
        }
    }

    private func displayIcon(for draft: AddActivityDraft) -> (symbol: String, family: PlaceCategoryFamily) {
        switch draft {
        case .preview(let preview):
            if let category = preview.category {
                return (category.mapBadgeSymbol, category.family)
            }
            return SearchRowIconHeuristic.icon(forTitle: preview.name)
        case .manual:
            return (manualCategory.mapBadgeSymbol, manualCategory.family)
        }
    }
}

private enum AddActivityDraft: Identifiable {
    case preview(MapSearchPreview)
    case manual(UUID)

    var id: String {
        switch self {
        case .preview(let preview): return preview.id
        case .manual(let id): return id.uuidString
        }
    }
}

private struct AddActivitySearchContext {
    let country: String?
    let cityProfileId: UUID?
    let region: MKCoordinateRegion?
    let excludedPlaceIds: Set<String>

    static func resolve(
        trip: Trip,
        scheduledPlaces: [Place],
        dataService: DataService
    ) async -> AddActivitySearchContext {
        var cityProfileId = trip.cityProfileId
        var center = coordinate(lat: trip.lat, lng: trip.lng)

        if cityProfileId == nil {
            cityProfileId = await dataService.resolveCityProfileId(forTrip: trip)
        }

        if center == nil, let cityProfileId {
            if let coords = await dataService.fetchCityProfileCenterCoords(id: cityProfileId) {
                center = CLLocationCoordinate2D(latitude: coords.lat, longitude: coords.lng)
                await dataService.patchTripCityProfile(
                    tripId: trip.id,
                    cityProfileId: cityProfileId,
                    lat: coords.lat,
                    lng: coords.lng
                )
            }
        }

        let region = center.map {
            MKCoordinateRegion(
                center: $0,
                span: MKCoordinateSpan(latitudeDelta: 0.18, longitudeDelta: 0.18)
            )
        }

        return AddActivitySearchContext(
            country: Locale.current.region?.identifier,
            cityProfileId: cityProfileId,
            region: region,
            excludedPlaceIds: Set(scheduledPlaces.compactMap(\.googlePlaceId))
        )
    }

    private static func coordinate(lat: Double?, lng: Double?) -> CLLocationCoordinate2D? {
        guard let lat, let lng else { return nil }
        guard abs(lat) > 0.000_001 || abs(lng) > 0.000_001 else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lng)
    }
}

private enum AddActivitySuggestedInline {
    /// Inline cap before "See all" — matches `MapSearchOverlay.recentsAndDefaults`.
    static let rowLimit = 4
    /// Matches `MapSearchOverlay.loadSuggestedIfNeeded` so `>` `rowLimit` reflects the full curated pool where available.
    static let topPicksFetchLimit = 30
    /// Slightly larger than the map-search inline thumbnail so Add Activity's suggested card has stronger visual weight.
    static let thumbnailSize: CGFloat = 60
    /// Align dividers with suggested row text after thumbnail + row spacing.
    static let dividerLeadingInset = AppSpacing.lg + thumbnailSize + AppSpacing.md
}

private struct AddActivityCategoryShortcut: Identifiable {
    let id: String
    let label: String
    let query: String
    let symbol: String
    let category: PlaceCategory?

    static let all: [AddActivityCategoryShortcut] = [
        AddActivityCategoryShortcut(id: "attractions", label: "Attractions", query: "attractions", symbol: "building.columns.fill", category: .attraction),
        AddActivityCategoryShortcut(id: "restaurants", label: "Restaurants", query: "restaurants", symbol: "fork.knife", category: .restaurant),
        AddActivityCategoryShortcut(id: "cafes", label: "Cafes", query: "coffee", symbol: "cup.and.saucer.fill", category: .restaurant),
        AddActivityCategoryShortcut(id: "museums", label: "Museums", query: "museums", symbol: "building.columns.fill", category: .attraction),
        AddActivityCategoryShortcut(id: "parks", label: "Parks", query: "parks", symbol: "leaf.fill", category: .nature),
        AddActivityCategoryShortcut(id: "nightlife", label: "Nightlife", query: "nightlife", symbol: "wineglass.fill", category: .nightlife),
        AddActivityCategoryShortcut(id: "shopping", label: "Shopping", query: "shopping", symbol: "bag.fill", category: .shopping),
    ]
}

private struct AddActivityDetailRow: View {
    let icon: String
    let title: String
    let value: String
    var isActionable = false
    var action: (() -> Void)?

    var body: some View {
        Button {
            action?()
        } label: {
            HStack(spacing: AppSpacing.md) {
                Image(systemName: icon)
                    .font(.appCaption.weight(.semibold))
                    .foregroundStyle(AppColors.appPrimary)
                    .frame(width: 30, height: 30)
                    .background(AppColors.appPrimaryLight, in: Circle())
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: AppSpacing.xs) {
                    Text(title)
                        .font(.appCaption.weight(.medium))
                        .foregroundStyle(AppColors.textSecondary)
                    Text(value)
                        .font(.appBody)
                        .foregroundStyle(isActionable ? AppColors.appPrimary : AppColors.textPrimary)
                        .lineLimit(title == "Address" ? 2 : 1)
                }

                Spacer(minLength: 0)

                if isActionable {
                    Image(systemName: "chevron.right")
                        .font(.appCaption.weight(.semibold))
                        .foregroundStyle(AppColors.textTertiary)
                }
            }
            .padding(.vertical, AppSpacing.xs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isActionable)
        .accessibilityElement(children: .combine)
    }
}

/// Opaque badge fill: same hue as `accent`, slightly muted (less neon than flat full saturation).
private func addActivityRowBadgeGradient(accent: Color) -> LinearGradient {
    let ui = UIColor(accent)
    var hue: CGFloat = 0
    var saturation: CGFloat = 0
    var brightness: CGFloat = 0
    var alpha: CGFloat = 0

    guard ui.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha), alpha > 0 else {
        return LinearGradient(colors: [accent, accent], startPoint: .top, endPoint: .bottom)
    }

    let mutedSaturationTop = min(max(saturation * 0.88, 0), 1)
    let mutedSaturationBottom = min(max(saturation * 0.92, 0), 1)
    let topBrightness = min(max(brightness * 1.05 * 0.94, 0.12), 1)
    let bottomBrightness = min(max(brightness * 0.82 * 0.94, 0.1), 1)

    let top = Color(UIColor(hue: hue, saturation: mutedSaturationTop, brightness: topBrightness, alpha: alpha))
    let bottom = Color(UIColor(hue: hue, saturation: mutedSaturationBottom, brightness: bottomBrightness, alpha: alpha))
    return LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom)
}

private struct AddActivityPlaceRow: View {
    let symbol: String
    let family: PlaceCategoryFamily
    /// When `nil`, badge gradient uses `family.color` from `PlaceTypeRegistry`.
    var iconColor: Color? = nil
    let title: String
    let subtitle: String

    /// Hue for the badge: explicit tint (e.g. generic pin) or the family’s map color.
    private var iconAccentBase: Color {
        iconColor ?? family.color
    }

    private var iconCircleGradient: LinearGradient {
        addActivityRowBadgeGradient(accent: iconAccentBase)
    }

    var body: some View {
        HStack(spacing: AppSpacing.md) {
            ZStack {
                Circle()
                    .fill(iconCircleGradient)
                Image(systemName: symbol)
                    .font(.appBody.weight(.semibold))
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(Color.white)
            }
            .frame(width: 36, height: 36)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                Text(title)
                    .font(.appBody.weight(.semibold))
                    .foregroundStyle(AppColors.textPrimary)
                    .lineLimit(1)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.appCaption)
                        .foregroundStyle(AppColors.textSecondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, AppSpacing.xs)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

private struct AddActivityPlaceSummary: View {
    let title: String
    let subtitle: String
    let symbol: String
    let family: PlaceCategoryFamily

    var body: some View {
        HStack(spacing: AppSpacing.md) {
            ZStack {
                RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous)
                    .fill(family.tint)
                Image(systemName: symbol)
                    .font(.appBody.weight(.semibold))
                    .foregroundStyle(family.color)
            }
            .frame(width: 44, height: 44)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                Text(title)
                    .font(.appBody.weight(.semibold))
                    .foregroundStyle(AppColors.textPrimary)
                    .lineLimit(2)
                Text(subtitle)
                    .font(.appCaption)
                    .foregroundStyle(AppColors.textSecondary)
                    .lineLimit(2)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// UIKit wrapper is required here because `MKLookAroundViewController` is the stable MapKit Look Around API available across our supported iOS range.
private struct AddActivityLookAroundFullScreenWrapper: UIViewControllerRepresentable {
    let scene: MKLookAroundScene

    func makeUIViewController(context: Context) -> MKLookAroundViewController {
        let viewController = MKLookAroundViewController(scene: scene)
        viewController.isNavigationEnabled = true
        viewController.showsRoadLabels = true
        return viewController
    }

    func updateUIViewController(_ uiViewController: MKLookAroundViewController, context: Context) {
        uiViewController.scene = scene
    }
}

private extension String {
    var callURL: URL? {
        let cleaned = filter { $0.isNumber || $0 == "+" }
        guard !cleaned.isEmpty else { return nil }
        return URL(string: "tel://\(cleaned)")
    }
}

#if DEBUG
#Preview("Add Activity Sheet") {
    AddActivitySheet(
        trip: .preview,
        selectedDayNumber: 1,
        days: [.preview1, .preview2],
        scheduledPlaces: [.previewAttraction, .previewRestaurant],
        wishlistPlaces: [],
        onSaved: { _ in },
        onCancel: {}
    )
    .environment(DataService(previewMockData: true))
}
#endif
