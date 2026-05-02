import CoreLocation
import SwiftUI

// MARK: - Root View

/// Sheet-based wizard that hosts the AI Day Planner flow.
///
/// Phase A introduced the sheet IA + Cancel contract. Phase B replaces the
/// scroll-list preview with a map-led layout (header → mini-map → vertical
/// card list) and adds a transforming bottom action bar so the primary
/// action is always pinned within thumb reach. Phase C wires an
/// `onApplied` callback so the parent can dismiss the sheet, route the
/// user to the Map tab, and surface a success toast.
struct AIPlanWizardSheet: View {
    let trip: Trip

    /// Fired exactly once after a successful `apply`. Receives the number
    /// of operations the server committed so the parent can render a
    /// "Added 6 stops" toast. The parent is responsible for dismissing
    /// the sheet — we never call `dismiss()` ourselves on the success
    /// path so the handoff stays single-sourced.
    var onApplied: ((Int) -> Void)? = nil

    @Environment(DataService.self) private var dataService
    @Environment(\.dismiss) private var dismiss

    @State private var vm: AIDayPlannerViewModel
    @State private var showStayAreaPicker = false
    @State private var showDiscardConfirm = false

    /// Two-way bound between the preview map and the card strip. Tapping
    /// a pin highlights its card; tapping a card pans the map.
    @State private var selectedPreviewCardId: UUID?

    init(trip: Trip, onApplied: ((Int) -> Void)? = nil) {
        self.trip = trip
        self.onApplied = onApplied
        self._vm = State(initialValue: AIDayPlannerViewModel(trip: trip))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 0) {
                    if vm.isDaysLoading {
                        ProgressView()
                            .padding(.vertical, AppSpacing.xxl)
                    } else if vm.hasPreview {
                        previewBody
                    } else if vm.isEmpty {
                        emptyPreviewState
                    } else {
                        // .idle, .loading, .applying, .error, .applied all
                        // show the configurator. Loading / applying just
                        // disable the bottom bar; applied is handled by
                        // the handoff before this branch ever renders.
                        configuratorSection
                    }
                }
                .padding(.bottom, AppSpacing.xl)
            }
            .background(AppColors.appBackground)
            .navigationTitle(navTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel", role: .cancel) {
                        attemptDismiss()
                    }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                AIPlanWizardBottomBar(
                    vm: vm,
                    onGenerate: { Task { await vm.generate() } },
                    onApply: { Task { await vm.applyPreview() } },
                    onReset: { vm.reset() },
                    onUpgradeTap: { presentAIUpsell(surface: "quota_exhausted_cta") }
                )
            }
            .interactiveDismissDisabled(needsDiscardConfirmation)
            // Drag indicator is part of "this sheet looks dismissible"
            // semantics. We hide it the moment a generated preview lives
            // here so the OS isn't visually inviting a swipe that will
            // get blocked. The configurator/idle states keep the
            // affordance — those are cheap to dismiss.
            .presentationDragIndicator(needsDiscardConfirmation ? .hidden : .visible)
        }
        .task {
            vm.trip = trip
            await vm.loadDays(from: dataService)
            // Wave 4.2 — keep the "X of 3 free remaining" badge honest
            // even when a sibling device burned a credit while this
            // sheet was off-screen. Cheap COUNT(*) PostgREST call.
            await EntitlementService.shared.refreshAIUsage()
        }
        .onDisappear {
            vm.cancelGenerate()
        }
        .sheet(isPresented: $showStayAreaPicker) {
            AIStayAreaPickerSheet(initialQuery: vm.stayAreaLabel) { label, placeId in
                vm.setStayArea(label: label, placeId: placeId)
            }
        }
        // Wave 4.3 — paywall presentation lives at the scene root via
        // `.paywallSurface()` so we don't stack a paywall sheet inside
        // this wizard sheet. The wizard remains visible underneath the
        // paywall so the user keeps the context they were trying to
        // unlock.
        // Mail-style "unsent draft" pattern. When the user taps Cancel
        // (or attempts to dismiss in any future swipe-capture path) on a
        // live preview, we present three weighted choices instead of a
        // single binary discard prompt. The default action is to SAVE
        // — converting accidental dismissal attempts into one-tap apply
        // ~most of the time. Discard stays available but is destructive
        // and second.
        .confirmationDialog(
            "What would you like to do?",
            isPresented: $showDiscardConfirm,
            titleVisibility: .visible
        ) {
            Button("Add to Itinerary") {
                Task { await vm.applyPreview() }
            }
            Button("Discard plan", role: .destructive) {
                vm.cancelGenerate()
                dismiss()
            }
            Button("Keep previewing", role: .cancel) {}
        } message: {
            Text(discardConfirmationMessage)
        }
        .onChange(of: vm.plannerState) { _, newState in
            // Phase C handoff: bubble up to the parent the moment the
            // server confirms the apply. We do NOT dismiss locally —
            // the parent owns the sheet binding and will tear us down,
            // which fires .onDisappear and cleans up the in-flight task.
            if case .applied = newState {
                onApplied?(vm.appliedOpsCount)
                // Phase J.6 — warm `city_travel_times` for the day's
                // legs we just committed. Fire-and-forget; the service
                // throttles per-trip and dedupes against its in-memory
                // cache, so spamming this is safe.
                Task {
                    await warmAppleTravelTimesAfterApply()
                }
            }
        }
        .onChange(of: vm.previewCards.map(\.id)) { _, ids in
            selectedPreviewCardId = ids.first
        }
    }

    // MARK: - Dismissal contract

    /// True only when there's an LLM-generated artifact in the sheet that
    /// would cost a credit to recreate. `.empty` and `.error` get silent
    /// dismissal — the credit was already spent and there's nothing
    /// recoverable to protect. Keeping the gate this narrow avoids
    /// training users to dismiss confirmation dialogs reflexively.
    private var needsDiscardConfirmation: Bool {
        if case .preview = vm.plannerState { return true }
        return false
    }

    private var discardConfirmationMessage: String {
        vm.isProUser
            ? "You can keep previewing this plan or add it to your itinerary."
            : "Generating a new plan uses one of your monthly AI credits."
    }

    private func attemptDismiss() {
        if needsDiscardConfirmation {
            showDiscardConfirm = true
        } else {
            vm.cancelGenerate()
            dismiss()
        }
    }

    /// Wave 4.3 — routes the upsell tap through the central
    /// `PaywallPresenter` so the analytics call site, the placement id
    /// (used by RevenueCat for A/B'd offerings), and the eventual
    /// purchase flow all share one shape across the app. The `surface`
    /// distinguishes "configurator badge" from "quota exhausted CTA"
    /// for funnel breakdown purposes.
    private func presentAIUpsell(surface: String) {
        let placement: PaywallPlacement = surface == "quota_exhausted_cta"
            ? .aiQuotaExhausted
            : .aiBadgeSoftGate
        PaywallPresenter.shared.present(
            placement,
            dataService: dataService,
            metadata: [
                "remaining": String(EntitlementService.shared.aiRemainingForFree),
                "limit": String(EntitlementService.shared.aiFreeMonthlyLimit),
                "trigger": surface,
            ]
        )
    }

    // MARK: - Phase J.6: Apple travel-times warm-up
    //
    // After AI apply succeeds, we have a fresh sequence of stops in
    // `vm.previewOps`. Each consecutive (prev → cur) pair becomes a
    // leg request the user is *very* likely to query soon (the map
    // tab will draw a polyline; the next AI generation will read
    // travel minutes). MapKit walks/drives/transits each leg in the
    // background and the result is uploaded to `city_travel_times`
    // via `upload-travel-leg`, so the next planner call gets a free
    // cache hit instead of a Google Routes charge.
    //
    // Guards:
    //   • Need a Google `place_id` for both endpoints — otherwise
    //     `city_travel_times` has nothing to key on.
    //   • Need lat/lng — `MKDirections` requires real coordinates.
    //   • Need a resolved `city_profiles.id` — the upload function
    //     scopes rows by it.
    //   • The service itself throttles per-tripId and dedupes by
    //     (cityProfileId, from, to), so calling this on every apply
    //     is safe.
    private func warmAppleTravelTimesAfterApply() async {
        let trip = vm.trip
        // Trip must have a destination Google place_id at all — without
        // it `upload-travel-leg` has no contextual anchor to attribute
        // legs to. We don't actually use the value here because the new
        // resolver pulls the city profile from slug + coords first, but
        // the presence check stays as a sanity gate.
        guard let pid = trip.destinationPlaceId, !pid.isEmpty else { return }

        let inserts = vm.previewOps
            .compactMap { $0.row }
            .filter { ($0.place_id?.isEmpty == false)
                      && $0.latitude != nil
                      && $0.longitude != nil }
            .sorted { (lhs, rhs) in
                (lhs.sort_order ?? Int.max) < (rhs.sort_order ?? Int.max)
            }
        guard inserts.count >= 2 else { return }

        var legs: [AppleTravelTimesService.LegRequest] = []
        legs.reserveCapacity(inserts.count - 1)
        for i in 1..<inserts.count {
            let prev = inserts[i - 1]
            let cur = inserts[i]
            guard let pid = prev.place_id, let cid = cur.place_id,
                  let plat = prev.latitude, let plng = prev.longitude,
                  let clat = cur.latitude, let clng = cur.longitude else { continue }
            legs.append(.init(
                fromPlaceId: pid,
                fromCoordinate: CLLocationCoordinate2D(latitude: plat, longitude: plng),
                toPlaceId: cid,
                toCoordinate: CLLocationCoordinate2D(latitude: clat, longitude: clng)
            ))
        }
        guard !legs.isEmpty else { return }

        // Use the robust resolver (slug → geo → place_id) so trips
        // whose destinationPlaceId is a locality (not a seeded POI in
        // city_places) still find their city_profile and warm
        // travel-time caches against the right city row.
        _ = pid // anchor — kept around so future call sites can read it
        guard let cityProfileId = await dataService.resolveCityProfileId(
            forTrip: trip
        ) else { return }

        await MainActor.run {
            AppleTravelTimesService.shared.enqueue(
                tripId: trip.id,
                cityProfileId: cityProfileId,
                legs: legs
            )
        }
    }

    private var navTitle: String {
        switch vm.plannerState {
        case .preview: return "Preview your day"
        case .empty: return "No suggestions"
        default: return "Plan with AI"
        }
    }

    // MARK: - Configurator (idle / loading)

    private var configuratorSection: some View {
        VStack(spacing: AppSpacing.lg) {
            // Hero — emotional anchor that says "this is a creative
            // tool" not a settings form.
            configuratorHero

            // Primary inputs — day + stay area. These are required
            // before Generate becomes available, so they live in the
            // most prominent card.
            SettingsCard {
                DayPickerRow(vm: vm)
                CardDivider()
                StayAreaRow(
                    label: vm.stayAreaLabel,
                    needsPlaceId: vm.needsStayAreaPlaceId,
                    onTap: { showStayAreaPicker = true }
                )
            }

            // Preferences — optional tweaks. Grouped in a second card
            // to visually subordinate them to the day/area selection.
            SettingsCard {
                PacePickerRow(selection: $vm.pace)
                CardDivider()
                TimeWindowRow(timeStart: $vm.timeStart, timeEnd: $vm.timeEnd)
                CardDivider()
                ExplorationScopeRow(selection: $vm.explorationScope)
                CardDivider()
                MealsToggleRow(isOn: $vm.includeMeals)
            }

            if let errorMessage = vm.errorMessage {
                inlineError(errorMessage)
            }
        }
        .padding(.horizontal, AppSpacing.lg)
        .padding(.top, AppSpacing.md)
    }

    private var configuratorHero: some View {
        VStack(spacing: AppSpacing.sm) {
            MapStyleIcon(
                systemName: "sparkles",
                size: .large,
                accent: AppColors.appPrimary,
                accessibilityLabel: "AI planner"
            )
            Text("Build your perfect day")
                .font(.sectionHeader)
                .foregroundStyle(AppColors.textPrimary)
            Text("Pick a day and area, tweak preferences, and we'll craft a personalised itinerary.")
                .font(.appBody)
                .foregroundStyle(AppColors.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            // Wave 4.2 — quota badge. Free users see "X of 3 free
            // remaining" and the badge doubles as a soft upsell tap
            // target that fires `pro_gate_attempted`. Pro users see
            // "Unlimited" with no tap affordance.
            quotaBadge
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, AppSpacing.md)
    }

    /// Wave 4.2 — the remaining-credits chip rendered under the hero.
    /// Free users get a tappable variant that surfaces the upsell sheet
    /// and logs intent; Pro users see a static "Unlimited" pill so the
    /// value of the entitlement stays visible.
    @ViewBuilder
    private var quotaBadge: some View {
        let isPro = vm.isProUser
        let label = vm.quotaBadgeText

        Group {
            if isPro {
                HStack(spacing: 4) {
                    Image(systemName: "infinity")
                        .font(.appSmall.weight(.semibold))
                    Text(label)
                        .font(.appCaption.weight(.semibold))
                }
                .foregroundStyle(AppColors.appPrimary)
                .padding(.horizontal, AppSpacing.sm)
                .padding(.vertical, AppSpacing.xs)
                .background(AppColors.appPrimaryLight, in: Capsule())
            } else {
                Button {
                    presentAIUpsell(surface: "configurator_badge")
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "sparkles")
                            .font(.appSmall.weight(.semibold))
                        Text(label)
                            .font(.appCaption.weight(.semibold))
                        Image(systemName: "chevron.right")
                            .font(.appSmall)
                    }
                    .foregroundStyle(AppColors.appPrimary)
                    .padding(.horizontal, AppSpacing.sm)
                    .padding(.vertical, AppSpacing.xs)
                    .background(AppColors.appPrimaryLight, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Upgrade to Pro for unlimited AI day plans")
            }
        }
        .padding(.top, AppSpacing.xs)
    }

    private func inlineError(_ message: String) -> some View {
        HStack(alignment: .top, spacing: AppSpacing.sm) {
            MapStyleIcon(
                systemName: "exclamationmark.circle.fill",
                size: .small,
                accent: AppColors.appError,
                backgroundStyle: .soft,
                accessibilityLabel: "Error"
            )
            Text(message)
                .font(.appCaption)
                .foregroundStyle(AppColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(AppSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColors.appError.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.small))
    }

    // MARK: - Preview body (map-led)

    private var previewBody: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            previewHeader
                .padding(.horizontal, AppSpacing.lg)
                .padding(.top, AppSpacing.md)

            AIPreviewMapView(
                cards: vm.previewCards,
                dayColor: previewDayColor,
                selectedCardId: $selectedPreviewCardId
            )

            VStack(spacing: 0) {
                ForEach(Array(vm.previewCards.enumerated()), id: \.element.id) { index, card in
                    PreviewActivityCard(
                        card: card,
                        index: index,
                        isSelected: selectedPreviewCardId == card.id,
                        formatTime: vm.formattedTime
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        HapticManager.selection()
                        selectedPreviewCardId = card.id
                    }
                    if index < vm.previewCards.count - 1 {
                        TravelConnectorView(minutes: card.travelFromPreviousMinutes)
                    }
                }
            }
            .padding(.top, AppSpacing.sm)
        }
    }

    private var previewHeader: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            HStack(alignment: .top, spacing: AppSpacing.md) {
                MapStyleIcon(
                    systemName: "sparkles",
                    accent: AppColors.appPrimary,
                    accessibilityLabel: "AI plan preview"
                )
                VStack(alignment: .leading, spacing: 2) {
                    if let title = vm.previewStoryTitle, !title.isEmpty {
                        Text(title)
                            .font(.sectionHeader)
                            .foregroundStyle(AppColors.textPrimary)
                    } else {
                        Text("Your day plan")
                            .font(.sectionHeader)
                            .foregroundStyle(AppColors.textPrimary)
                    }
                    HStack(spacing: AppSpacing.xs) {
                        Image(systemName: "sparkles")
                            .font(.appSmall)
                            .foregroundStyle(AppColors.appPrimary)
                        // Frames the result as a committed artifact + a
                        // priced one. Loss-aversion does the heavy work:
                        // users intuitively don't want to throw away
                        // something labeled as having cost a credit.
                        Text("AI-generated · \(vm.previewCards.count) \(vm.previewCards.count == 1 ? "stop" : "stops") · 1 credit used")
                            .font(.appCaption.weight(.medium))
                            .foregroundStyle(AppColors.textSecondary)
                    }
                    if let day = vm.selectedDay {
                        Text(vm.dayLabel(for: day))
                            .font(.appCaption)
                            .foregroundStyle(AppColors.textTertiary)
                    }
                }
                Spacer(minLength: AppSpacing.md)
                Button {
                    vm.reset()
                } label: {
                    Label("Edit", systemImage: "slider.horizontal.3")
                        .font(.appCaption.weight(.semibold))
                        .foregroundStyle(AppColors.appPrimary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Edit settings")
            }

            if !vm.previewStoryArc.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: AppSpacing.xs) {
                        ForEach(vm.previewStoryArc.prefix(5), id: \.self) { arc in
                            Text(arc)
                                .font(.appSmall.weight(.medium))
                                .foregroundStyle(AppColors.appPrimary)
                                .padding(.horizontal, AppSpacing.sm)
                                .padding(.vertical, AppSpacing.xs)
                                .background(AppColors.appPrimaryLight)
                                .clipShape(Capsule())
                        }
                    }
                }
            }

            if let subtitle = vm.previewStorySubtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.appBody)
                    .foregroundStyle(AppColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !vm.previewSummary.isEmpty {
                Text(vm.previewSummary)
                    .font(.appBody)
                    .foregroundStyle(AppColors.textSecondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var previewDayColor: Color {
        if let day = vm.selectedDay {
            return AppColors.dayColor(for: day.dayNumber)
        }
        return AppColors.appPrimary
    }

    // MARK: - Empty state

    /// Server returned a 200 with no insertable ops — usually means the
    /// time window or scope was too narrow. Surface this explicitly so
    /// users don't think Generate silently failed. The bottom bar will
    /// switch to "Adjust Settings" to send them back to the configurator.
    private var emptyPreviewState: some View {
        VStack(spacing: AppSpacing.md) {
            MapStyleIcon(
                systemName: "sparkles.slash",
                size: .large,
                accent: AppColors.textTertiary,
                backgroundStyle: .surface,
                accessibilityLabel: "No AI suggestions"
            )
            Text("No suggestions for this day")
                .font(.cardTitle.weight(.semibold))
                .foregroundStyle(AppColors.textPrimary)
            Text("Try widening the day window, picking a broader range, or removing some interests.")
                .font(.appBody)
                .foregroundStyle(AppColors.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, AppSpacing.xl)
        .padding(.vertical, AppSpacing.xxl)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Bottom Action Bar (transforms by state)

private struct AIPlanWizardBottomBar: View {
    @Bindable var vm: AIDayPlannerViewModel
    let onGenerate: () -> Void
    let onApply: () -> Void
    let onReset: () -> Void
    /// Wave 4.2 — fired when the user taps the upgrade CTA after
    /// `free_limit_reached`. The parent surfaces the paywall sheet so
    /// this view stays presentation-free.
    var onUpgradeTap: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            Divider().background(AppColors.appDivider)
            content
                .padding(.horizontal, AppSpacing.lg)
                .padding(.vertical, AppSpacing.md)
        }
        .background(.regularMaterial)
        .animation(.snappy(duration: 0.2), value: vm.plannerState)
    }

    @ViewBuilder
    private var content: some View {
        switch vm.plannerState {
        case .idle:
            primaryButton(
                title: "Generate My Day",
                icon: "sparkles",
                enabled: vm.canGenerate,
                action: onGenerate
            )

        case .loading:
            progressButton(title: "Planning your day…")

        case .preview:
            // Asymmetric layout by design: Add to Itinerary owns the
            // bar (54pt full-width primary) so it's unmissable; Redo
            // shrinks to a text affordance with an explicit cost label
            // so the user feels the credit before tapping it.
            VStack(spacing: AppSpacing.sm) {
                Button(action: onGenerate) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.appCaption.weight(.semibold))
                        Text("Redo")
                            .font(.appCaption.weight(.semibold))
                        Text("· uses 1 credit")
                            .font(.appCaption)
                            .foregroundStyle(AppColors.textTertiary)
                    }
                    .foregroundStyle(AppColors.appPrimary)
                    .padding(.vertical, AppSpacing.xs)
                    .padding(.horizontal, AppSpacing.sm)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Regenerate plan, uses one credit")

                primaryButton(
                    title: "Add to Itinerary",
                    icon: "checkmark.circle.fill",
                    enabled: !vm.isApplying,
                    action: onApply,
                    tall: true
                )
            }

        case .applying:
            progressButton(title: "Adding to itinerary…")

        case .empty:
            primaryButton(
                title: "Adjust Settings",
                icon: "slider.horizontal.3",
                enabled: true,
                action: onReset
            )

        case .error:
            primaryButton(
                title: "Try Again",
                icon: "arrow.clockwise",
                enabled: vm.canGenerate,
                action: onGenerate
            )

        case .quotaExhausted:
            // Wave 4.2 — server returned `free_limit_reached`. Skip the
            // generic "Try Again" and route the user straight to the
            // paywall. The CTA copy intentionally references the value
            // they're unlocking ("Unlimited AI day plans"), not the
            // price — the paywall itself handles billing optics.
            primaryButton(
                title: "Upgrade for unlimited plans",
                icon: "sparkles",
                enabled: true,
                action: onUpgradeTap,
                tall: true
            )

        case .applied:
            // Parent dismisses on `.applied`. We render an empty footer
            // for the brief frame between state flip and tear-down.
            Color.clear.frame(height: 1)
        }
    }

    private func primaryButton(
        title: String,
        icon: String,
        enabled: Bool,
        action: @escaping () -> Void,
        tall: Bool = false
    ) -> some View {
        Button(action: action) {
            HStack(spacing: AppSpacing.sm) {
                Image(systemName: icon)
                    .font(.appBody.weight(.semibold))
                Text(title)
                    .font(.appBody.weight(.semibold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(minHeight: tall ? 54 : 0)
            .padding(.vertical, tall ? 0 : AppSpacing.md)
            .background(enabled ? AppColors.appPrimary : AppColors.textTertiary)
            .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.medium))
        }
        .disabled(!enabled)
    }

    private func secondaryButton(title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: AppSpacing.sm) {
                Image(systemName: icon)
                Text(title)
                    .font(.appBody.weight(.semibold))
            }
            .foregroundStyle(AppColors.appPrimary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, AppSpacing.md)
            .background(AppColors.appPrimaryLight)
            .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.medium))
        }
    }

    private func progressButton(title: String) -> some View {
        HStack(spacing: AppSpacing.sm) {
            ProgressView().tint(.white).scaleEffect(0.85)
            Text(title)
                .font(.appBody.weight(.semibold))
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity)
        .padding(.vertical, AppSpacing.md)
        .background(AppColors.appPrimary.opacity(0.7))
        .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.medium))
    }
}

// MARK: - Settings Card (grouped material surface)

/// Material-backed card container — the Airbnb "white card on warm
/// background" pattern that groups related controls and gives the
/// configurator visual hierarchy. Each card insets its children so
/// the individual rows don't need their own horizontal padding.
private struct SettingsCard<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            content()
        }
        .padding(.horizontal, AppSpacing.lg)
        .padding(.vertical, AppSpacing.md)
        .background(AppColors.appSurface)
        .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.large))
        .overlay(
            RoundedRectangle(cornerRadius: AppCornerRadius.large)
                .strokeBorder(AppColors.appDivider.opacity(0.85), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.04), radius: 10, x: 0, y: 3)
    }
}

/// Thin inset divider used between rows inside a `SettingsCard`.
private struct CardDivider: View {
    var body: some View {
        Divider()
            .background(AppColors.appDivider)
            .padding(.vertical, AppSpacing.xs)
    }
}

// MARK: - Day Picker Row

private struct DayPickerRow: View {
    @Bindable var vm: AIDayPlannerViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            HStack(spacing: AppSpacing.sm) {
                MapStyleIcon(
                    systemName: "calendar",
                    size: .small,
                    accent: AppColors.appPrimary,
                    accessibilityLabel: "Trip day"
                )
                Text("Which day?")
                    .font(.appBody.weight(.semibold))
                    .foregroundStyle(AppColors.textPrimary)
            }
            if vm.scheduledDays.isEmpty {
                Text("No days found for this trip.")
                    .font(.appCaption)
                    .foregroundStyle(AppColors.textTertiary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: AppSpacing.sm) {
                        ForEach(vm.scheduledDays) { day in
                            DayChip(
                                day: day,
                                label: vm.dayLabel(for: day),
                                isSelected: vm.selectedDay?.id == day.id,
                                color: AppColors.dayColor(for: day.dayNumber)
                            ) {
                                vm.selectedDay = day
                                if vm.plannerState != .idle {
                                    vm.reset()
                                }
                            }
                        }
                    }
                    .padding(.horizontal, AppSpacing.xs)
                }
            }
        }
        .padding(.vertical, AppSpacing.xs)
    }
}

private struct DayChip: View {
    let day: ItineraryDay
    let label: String
    let isSelected: Bool
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.appCaption.weight(isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? .white : AppColors.textSecondary)
                .padding(.horizontal, AppSpacing.md)
                .padding(.vertical, AppSpacing.sm)
                .background(isSelected ? color : Color.clear)
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .strokeBorder(isSelected ? Color.clear : AppColors.appDivider, lineWidth: 1)
                )
        }
        .contentShape(Capsule())
    }
}

// MARK: - Stay Area Row

private struct StayAreaRow: View {
    let label: String
    let needsPlaceId: Bool
    let onTap: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            Button(action: onTap) {
                HStack(spacing: AppSpacing.md) {
                    HStack(spacing: AppSpacing.sm) {
                        MapStyleIcon(
                            systemName: "mappin.and.ellipse",
                            size: .small,
                            accent: AppColors.appPrimary,
                            accessibilityLabel: "Stay area"
                        )
                        Text("Stay area")
                            .font(.appBody.weight(.semibold))
                            .foregroundStyle(AppColors.textPrimary)
                    }
                    .layoutPriority(1)
                    Spacer(minLength: AppSpacing.sm)
                    Text(displayLabel)
                        .font(.appBody)
                        .foregroundStyle(displayLabel == "Choose area" ? AppColors.textTertiary : AppColors.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Image(systemName: "chevron.right")
                        .font(.appSmall.weight(.semibold))
                        .foregroundStyle(AppColors.textTertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if needsPlaceId {
                HStack(alignment: .center, spacing: AppSpacing.xs) {
                    Image(systemName: "info.circle.fill")
                        .font(.appSmall)
                        .foregroundStyle(AppColors.appWarning)
                    Text("Pick a neighborhood or lodging area to start.")
                        .font(.appCaption)
                        .foregroundStyle(AppColors.textSecondary)
                }
                .padding(.horizontal, AppSpacing.sm)
                .padding(.vertical, AppSpacing.xs)
                .background(AppColors.appWarning.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.small))
            }
        }
        .padding(.vertical, AppSpacing.xs)
    }

    private var displayLabel: String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Choose area" : trimmed
    }
}

// MARK: - Pace Picker Row

private struct PacePickerRow: View {
    @Binding var selection: PlanPace

    var body: some View {
        HStack {
            HStack(spacing: AppSpacing.sm) {
                MapStyleIcon(
                    systemName: "gauge.with.dots.needle.33percent",
                    size: .small,
                    accent: AppColors.appPrimary,
                    accessibilityLabel: "Pace"
                )
                Text("Pace")
                    .font(.appBody.weight(.semibold))
                    .foregroundStyle(AppColors.textPrimary)
            }
            Spacer()
            Picker("Pace", selection: $selection) {
                ForEach(PlanPace.allCases) { pace in
                    Text(pace.displayName).tag(pace)
                }
            }
            .pickerStyle(.menu)
            .tint(AppColors.appPrimary)
        }
        .padding(.vertical, AppSpacing.xs)
    }
}

// MARK: - Time Window Row

private struct TimeWindowRow: View {
    @Binding var timeStart: String
    @Binding var timeEnd: String

    @State private var startDate: Date = defaultDate(from: "09:00")
    @State private var endDate: Date = defaultDate(from: "21:00")

    var body: some View {
        VStack(spacing: AppSpacing.sm) {
            HStack {
                HStack(spacing: AppSpacing.sm) {
                    MapStyleIcon(
                        systemName: "clock",
                        size: .small,
                        accent: AppColors.appPrimary,
                        accessibilityLabel: "Day window"
                    )
                    Text("Day window")
                        .font(.appBody.weight(.semibold))
                        .foregroundStyle(AppColors.textPrimary)
                }
                Spacer()
            }
            HStack(spacing: AppSpacing.xl) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Start")
                        .font(.appCaption)
                        .foregroundStyle(AppColors.textTertiary)
                    DatePicker("Start", selection: $startDate, displayedComponents: .hourAndMinute)
                        .labelsHidden()
                        .tint(AppColors.appPrimary)
                        .onChange(of: startDate) { _, v in
                            timeStart = formatHHmm(v)
                        }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("End")
                        .font(.appCaption)
                        .foregroundStyle(AppColors.textTertiary)
                    DatePicker("End", selection: $endDate, displayedComponents: .hourAndMinute)
                        .labelsHidden()
                        .tint(AppColors.appPrimary)
                        .onChange(of: endDate) { _, v in
                            timeEnd = formatHHmm(v)
                        }
                }
                Spacer()
            }
        }
        .padding(.vertical, AppSpacing.xs)
        .onAppear {
            startDate = Self.defaultDate(from: timeStart)
            endDate = Self.defaultDate(from: timeEnd)
        }
    }

    private static func defaultDate(from hhmm: String) -> Date {
        let parts = hhmm.split(separator: ":").compactMap { Int($0) }
        var comps = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        comps.hour = parts.first ?? 9
        comps.minute = parts.dropFirst().first ?? 0
        return Calendar.current.date(from: comps) ?? Date()
    }

    private func formatHHmm(_ date: Date) -> String {
        let comps = Calendar.current.dateComponents([.hour, .minute], from: date)
        let h = comps.hour ?? 9
        let m = comps.minute ?? 0
        return String(format: "%02d:%02d", h, m)
    }
}

// MARK: - Exploration Scope Row

private struct ExplorationScopeRow: View {
    @Binding var selection: ExplorationScope

    var body: some View {
        HStack {
            HStack(spacing: AppSpacing.sm) {
                MapStyleIcon(
                    systemName: "map",
                    size: .small,
                    accent: AppColors.appPrimary,
                    accessibilityLabel: "Range"
                )
                Text("Range")
                    .font(.appBody.weight(.semibold))
                    .foregroundStyle(AppColors.textPrimary)
            }
            Spacer()
            Picker("Range", selection: $selection) {
                ForEach(ExplorationScope.allCases) { scope in
                    Text(scope.displayName).tag(scope)
                }
            }
            .pickerStyle(.menu)
            .tint(AppColors.appPrimary)
        }
        .padding(.vertical, AppSpacing.xs)
    }
}

// MARK: - Meals Toggle Row

private struct MealsToggleRow: View {
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(spacing: AppSpacing.sm) {
                MapStyleIcon(
                    systemName: "fork.knife",
                    size: .small,
                    accent: AppColors.appPrimary,
                    accessibilityLabel: "Meals"
                )
                Text("Include meals")
                    .font(.appBody.weight(.semibold))
                    .foregroundStyle(AppColors.textPrimary)
            }
        }
        .tint(AppColors.appPrimary)
        .padding(.vertical, AppSpacing.xs)
    }
}

// MARK: - Interests Row

private struct InterestsRow: View {
    @Binding var selectedInterests: Set<String>
    let available: [String]
    let displayName: (String) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            HStack(spacing: AppSpacing.sm) {
                MapStyleIcon(
                    systemName: "heart",
                    size: .small,
                    accent: AppColors.appPrimary,
                    accessibilityLabel: "Interests"
                )
                Text("Interests (optional)")
                    .font(.appBody.weight(.semibold))
                    .foregroundStyle(AppColors.textPrimary)
            }
            FlowLayout(spacing: AppSpacing.sm) {
                ForEach(available, id: \.self) { interest in
                    let isOn = selectedInterests.contains(interest)
                    Button {
                        if isOn {
                            selectedInterests.remove(interest)
                        } else if selectedInterests.count < 3 {
                            selectedInterests.insert(interest)
                        }
                    } label: {
                        Text(displayName(interest))
                            .font(.appCaption.weight(isOn ? .semibold : .regular))
                            .foregroundStyle(isOn ? AppColors.appPrimary : AppColors.textSecondary)
                            .padding(.horizontal, AppSpacing.md)
                            .padding(.vertical, AppSpacing.xs)
                            .background(isOn ? AppColors.appPrimaryLight : AppColors.appSurface)
                            .clipShape(Capsule())
                            .overlay(
                                Capsule().strokeBorder(
                                    isOn ? AppColors.appPrimary.opacity(0.4) : AppColors.appDivider,
                                    lineWidth: 1
                                )
                            )
                    }
                    .contentShape(Capsule())
                    .opacity(!isOn && selectedInterests.count >= 3 ? 0.4 : 1)
                    .disabled(!isOn && selectedInterests.count >= 3)
                }
            }
        }
        .padding(.horizontal, AppSpacing.lg)
        .padding(.vertical, AppSpacing.md)
    }
}

// MARK: - Flow Layout

private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? 320
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowH: CGFloat = 0

        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                y += rowH + spacing
                x = 0
                rowH = 0
            }
            rowH = max(rowH, size.height)
            x += size.width + spacing
        }
        y += rowH
        return CGSize(width: maxWidth, height: y)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var rowH: CGFloat = 0

        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                y += rowH + spacing
                x = bounds.minX
                rowH = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            rowH = max(rowH, size.height)
            x += size.width + spacing
        }
    }
}

// MARK: - Preview Activity Card

private struct PreviewActivityCard: View {
    let card: ActivityPreviewCard
    let index: Int
    let isSelected: Bool
    let formatTime: (String?) -> String?

    var category: PlaceCategory {
        guard let raw = card.category else { return .custom }
        return PlaceCategory(rawValue: raw) ?? .custom
    }

    var body: some View {
        HStack(alignment: .top, spacing: AppSpacing.md) {
            MapStyleIcon(
                systemName: category.sfSymbol,
                accent: category.color,
                accessibilityLabel: category.label
            )

            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                HStack(spacing: AppSpacing.sm) {
                    if let phase = card.phaseLabel {
                        Text(phase.uppercased())
                            .font(.appSmall.weight(.semibold))
                            .foregroundStyle(AppColors.textTertiary)
                            .kerning(0.5)
                    }
                    Spacer()
                    if let time = formatTime(card.startsAt) {
                        Text(time)
                            .font(.appCaption.weight(.medium))
                            .foregroundStyle(AppColors.textSecondary)
                    }
                    if let dur = card.durationMinutes {
                        Text("· \(dur)min")
                            .font(.appCaption)
                            .foregroundStyle(AppColors.textTertiary)
                    }
                }

                Text(card.name)
                    .font(.appBody.weight(.semibold))
                    .foregroundStyle(AppColors.textPrimary)

                if let desc = card.momentLine ?? card.description, !desc.isEmpty {
                    Text(desc)
                        .font(.appCaption)
                        .foregroundStyle(AppColors.textSecondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let url = card.heroImageUrl.flatMap(URL.init) {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let img):
                            img
                                .resizable()
                                .scaledToFill()
                                .frame(height: 100)
                                .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.small))
                        default:
                            Color.clear.frame(height: 0)
                        }
                    }
                }

                if !card.tips.isEmpty {
                    VStack(alignment: .leading, spacing: AppSpacing.xs) {
                        ForEach(card.tips.prefix(2), id: \.self) { tip in
                            HStack(spacing: AppSpacing.xs) {
                                Image(systemName: "lightbulb.min")
                                    .font(.appSmall)
                                    .foregroundStyle(AppColors.appWarning)
                                Text(tip)
                                    .font(.appCaption)
                                    .foregroundStyle(AppColors.textSecondary)
                            }
                        }
                    }
                    .padding(.top, AppSpacing.xs)
                }

                if card.rating != nil || card.priceLevel != nil {
                    HStack(spacing: AppSpacing.sm) {
                        if let rating = card.rating {
                            HStack(spacing: 3) {
                                Image(systemName: "star.fill")
                                    .font(.appSmall)
                                    .foregroundStyle(AppColors.appWarning)
                                Text(String(format: "%.1f", rating))
                                    .font(.appCaption)
                                    .foregroundStyle(AppColors.textSecondary)
                            }
                        }
                        if let price = card.priceLevel {
                            Text(String(repeating: "$", count: price))
                                .font(.appCaption)
                                .foregroundStyle(AppColors.textTertiary)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, AppSpacing.lg)
        .padding(.vertical, AppSpacing.md)
        .background(
            // Subtle highlight when this card is the one focused on the
            // map. Keeps the visual link bidirectional.
            isSelected ? AppColors.appPrimaryLight.opacity(0.55) : AppColors.appSurface
        )
        .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.large))
        .overlay(
            RoundedRectangle(cornerRadius: AppCornerRadius.large)
                .strokeBorder(
                    isSelected ? AppColors.appPrimary.opacity(0.35) : AppColors.appDivider.opacity(0.85),
                    lineWidth: 0.5
                )
        )
        .padding(.horizontal, AppSpacing.lg)
        .animation(.easeInOut(duration: 0.2), value: isSelected)
    }
}

// MARK: - Travel Connector

private struct TravelConnectorView: View {
    let minutes: Int?

    var body: some View {
        HStack {
            Spacer(minLength: 0)
            HStack(spacing: AppSpacing.xs) {
                Image(systemName: "figure.walk")
                    .font(.appSmall.weight(.semibold))
                Text(travelLabel)
                    .font(.appSmall)
            }
            .foregroundStyle(AppColors.textTertiary)
            .padding(.horizontal, AppSpacing.sm)
            .padding(.vertical, AppSpacing.xs)
            .background(AppColors.appSurface)
            .clipShape(Capsule())
            .overlay {
                Capsule()
                    .strokeBorder(AppColors.appDivider.opacity(0.85), lineWidth: 0.5)
            }
            Spacer()
        }
        .padding(.vertical, AppSpacing.xs)
    }

    private var travelLabel: String {
        if let minutes, minutes > 0 {
            return "\(minutes) min"
        }
        return "Travel"
    }
}
