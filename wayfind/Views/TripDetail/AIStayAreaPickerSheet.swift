import SwiftUI

/// Bottom sheet for picking a "stay area" (neighborhood / lodging anchor) used
/// by the AI Day Planner. Wraps `PlaceSearchService` with `types: "geocode"` to
/// surface neighborhoods and addresses (not just whole cities).
///
/// Submission contract: calls `onSelect(label, placeId)` with the Google
/// `place_id`, then dismisses. Cancellation just dismisses.
struct AIStayAreaPickerSheet: View {

    /// Pre-fill so the search field shows the trip's current stay-area label.
    let initialQuery: String

    /// Optional copy shown below the search bar before any typing.
    var helperText: String = "Pick a neighborhood, hotel, or lodging area near where you're staying. The AI uses this as the anchor for nearby suggestions."

    let onSelect: (_ label: String, _ placeId: String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var placeSearch = PlaceSearchService()
    @State private var query: String = ""
    @State private var isResolvingDetails: Bool = false

    var body: some View {
        NavigationStack {
            content
                .background(AppColors.appBackground.ignoresSafeArea())
                .navigationTitle("Stay Area")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                }
                .searchable(
                    text: $query,
                    placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "Neighborhood, hotel, or address"
                )
                .autocorrectionDisabled()
                .textInputAutocapitalization(.words)
                .onAppear {
                    if query.isEmpty, !initialQuery.isEmpty {
                        query = initialQuery
                        placeSearch.search(query: initialQuery, types: "geocode")
                    }
                }
                .onChange(of: query) { _, newVal in
                    let trimmed = newVal.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.isEmpty {
                        placeSearch.clearResults()
                    } else {
                        placeSearch.search(query: trimmed, types: "geocode")
                    }
                }
                .scrollDismissesKeyboard(.interactively)
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    @ViewBuilder
    private var content: some View {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)

        if isResolvingDetails {
            VStack(spacing: AppSpacing.md) {
                ProgressView()
                Text("Pinning the area…")
                    .font(.appCaption)
                    .foregroundStyle(AppColors.textSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if trimmed.isEmpty {
            emptyState
        } else if placeSearch.isSearching && placeSearch.results.isEmpty {
            loadingSkeleton
        } else if placeSearch.results.isEmpty {
            ContentUnavailableView.search(text: trimmed)
        } else {
            resultsList
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            Image(systemName: "mappin.and.ellipse")
                .font(.system(size: 36))
                .foregroundStyle(AppColors.appPrimary)
                .padding(.top, AppSpacing.xl)

            Text("Where will you be based?")
                .font(.cardTitle)
                .foregroundStyle(AppColors.textPrimary)

            Text(helperText)
                .font(.appBody)
                .foregroundStyle(AppColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()
        }
        .padding(AppSpacing.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var loadingSkeleton: some View {
        List {
            Section {
                ForEach(0..<5, id: \.self) { _ in
                    HStack(spacing: AppSpacing.md) {
                        Circle()
                            .fill(AppColors.appDivider)
                            .frame(width: 36, height: 36)
                        VStack(alignment: .leading, spacing: 6) {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(AppColors.appDivider)
                                .frame(height: 12)
                                .frame(maxWidth: 200, alignment: .leading)
                            RoundedRectangle(cornerRadius: 4)
                                .fill(AppColors.appDivider)
                                .frame(height: 10)
                                .frame(maxWidth: 140, alignment: .leading)
                        }
                    }
                    .redacted(reason: .placeholder)
                    .padding(.vertical, 4)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(.clear)
    }

    private var resultsList: some View {
        List {
            Section {
                ForEach(placeSearch.results) { result in
                    Button {
                        select(result)
                    } label: {
                        resultRow(result)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(.clear)
    }

    private func resultRow(_ result: PlaceAutocompleteResult) -> some View {
        HStack(spacing: AppSpacing.md) {
            ZStack {
                Circle()
                    .fill(AppColors.appPrimary.opacity(0.12))
                    .frame(width: 36, height: 36)
                Image(systemName: "mappin.circle.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(AppColors.appPrimary)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(result.mainText)
                    .font(.appBody)
                    .foregroundStyle(AppColors.textPrimary)
                    .lineLimit(1)
                if !result.secondaryText.isEmpty {
                    Text(result.secondaryText)
                        .font(.appCaption)
                        .foregroundStyle(AppColors.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AppColors.textTertiary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private func select(_ result: PlaceAutocompleteResult) {
        // We resolve full place details to confirm the place_id and capture the
        // formatted name. The autocomplete row's `id` IS the Google place_id, so
        // worst case (network fails) we still have a valid id to send.
        HapticManager.light()
        let fallbackLabel = result.mainText.isEmpty ? result.fullDescription : result.mainText
        let fallbackId = result.id

        isResolvingDetails = true
        Task { @MainActor in
            defer { isResolvingDetails = false }
            if let detail = await placeSearch.getPlaceDetails(placeId: result.id) {
                let label = detail.name.isEmpty ? fallbackLabel : detail.name
                onSelect(label, detail.placeId)
            } else {
                onSelect(fallbackLabel, fallbackId)
            }
            dismiss()
        }
    }
}
