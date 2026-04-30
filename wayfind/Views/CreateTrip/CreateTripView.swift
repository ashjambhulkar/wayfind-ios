import SwiftUI

struct CreateTripView: View {
    @Environment(DataService.self) private var dataService
    @FocusState private var isDestinationFocused: Bool

    var onCreate: ((Trip) -> Void)?

    @State private var destination: String
    @State private var startDate: Date
    @State private var endDate: Date
    @State private var destinationPlaceId: String?
    @State private var destinationLat: Double?
    @State private var destinationLng: Double?
    @State private var selectedDestinationText = ""
    @State private var autocompleteSessionToken: String?
    @State private var isResolvingDestination = false
    @State private var placeSearch = PlaceSearchService()

    init(onCreate: ((Trip) -> Void)? = nil) {
        self.onCreate = onCreate
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        _destination = State(initialValue: "")
        _startDate = State(initialValue: today)
        _endDate = State(initialValue: calendar.date(byAdding: .day, value: 7, to: today) ?? today)
    }

    private var trimmedDestination: String {
        destination.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSubmit: Bool {
        !trimmedDestination.isEmpty && !isResolvingDestination
    }

    private var shouldShowDestinationPredictions: Bool {
        isDestinationFocused && !placeSearch.results.isEmpty
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: AppSpacing.xl) {
                    CreateTripMapSectionCard(title: "Destination") {
                        CreateTripMapTextRow(
                            icon: "mappin.circle.fill",
                            title: "Where",
                            placeholder: "Where are you going?",
                            text: $destination,
                            isFocused: $isDestinationFocused
                        )

                        if shouldShowDestinationPredictions {
                            CreateTripMapDivider()

                            VStack(spacing: 0) {
                                ForEach(placeSearch.results) { prediction in
                                    DestinationPredictionRow(prediction: prediction) {
                                        Task { await selectDestinationPrediction(prediction) }
                                    }

                                    if prediction != placeSearch.results.last {
                                        CreateTripMapDivider()
                                    }
                                }
                            }
                        } else if isResolvingDestination {
                            CreateTripMapDivider()

                            DestinationStatusRow(message: "Finding destination…")
                        }
                    }

                    dateRangeSection
                }
                .padding(AppSpacing.lg)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(AppColors.appBackground)
            .navigationTitle("Plan a New Trip")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start") {
                        Task { await createTrip() }
                    }
                    .disabled(!canSubmit)
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .onChange(of: startDate) { _, newValue in
            if newValue > endDate { endDate = newValue }
        }
        .onChange(of: endDate) { _, newValue in
            if newValue < startDate { startDate = newValue }
        }
        .onChange(of: destination) { _, newValue in
            destinationTextChanged(newValue)
        }
    }

    private var dateRangeSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            FormSectionTitle("Dates")

            VStack(spacing: 0) {
                CreateTripMapDateRow(
                    icon: "calendar.badge.plus",
                    title: "Start",
                    selection: $startDate
                )

                CreateTripMapDivider()

                CreateTripMapDateRow(
                    icon: "calendar.badge.minus",
                    title: "End",
                    selection: $endDate
                )
            }
            .background(AppColors.appSurface)
            .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous)
                    .strokeBorder(AppColors.appDivider, lineWidth: 1)
            }
        }
    }

    private func createTrip() async {
        let title = "Trip to \(trimmedDestination)"
        let now = Date()
        let calendar = Calendar.current
        let dbStatus = SupabaseModelMapping.inferTripStatus(startDate: startDate, endDate: endDate, calendar: calendar)
        let isActive = SupabaseModelMapping.isTripActive(startDate: startDate, endDate: endDate, calendar: calendar)
        let trip = Trip(
            id: UUID(),
            userId: UUID(),
            title: title,
            destination: trimmedDestination,
            destinationPlaceId: destinationPlaceId,
            lat: destinationLat,
            lng: destinationLng,
            startDate: startDate,
            endDate: endDate,
            coverImageUrl: nil,
            notes: nil,
            createdAt: now,
            updatedAt: now,
            databaseStatus: dbStatus,
            isMarkedActiveOnServer: isActive
        )
        let persisted = await dataService.addTrip(trip)
        onCreate?(persisted)
    }

    private func destinationTextChanged(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != selectedDestinationText else { return }

        destinationPlaceId = nil
        destinationLat = nil
        destinationLng = nil
        selectedDestinationText = ""

        guard !trimmed.isEmpty else {
            placeSearch.clearResults()
            autocompleteSessionToken = nil
            return
        }

        let token = autocompleteSessionToken ?? placeSearch.makeAutocompleteSessionToken()
        autocompleteSessionToken = token
        placeSearch.search(query: trimmed, types: "(regions)", sessionToken: token)
    }

    @MainActor
    private func selectDestinationPrediction(_ prediction: PlaceAutocompleteResult) async {
        HapticManager.selection()
        isResolvingDestination = true
        defer { isResolvingDestination = false }

        let token = autocompleteSessionToken ?? placeSearch.makeAutocompleteSessionToken()
        let detail = await placeSearch.getDestinationDetails(placeId: prediction.id, sessionToken: token)
        let selectedText = detail?.address.trimmedNonEmpty
            ?? detail?.name.trimmedNonEmpty
            ?? prediction.fullDescription

        destination = selectedText
        selectedDestinationText = selectedText
        destinationPlaceId = detail?.placeId ?? prediction.id
        destinationLat = detail?.lat
        destinationLng = detail?.lng
        autocompleteSessionToken = nil
        placeSearch.clearResults()
        isDestinationFocused = false
    }
}

private struct CreateTripMapSectionCard<Content: View>: View {
    let title: String?
    let content: Content

    init(title: String?, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            if let title {
                FormSectionTitle(title)
            }

            VStack(spacing: 0) {
                content
            }
            .background(AppColors.appSurface)
            .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous)
                    .strokeBorder(AppColors.appDivider, lineWidth: 1)
            }
        }
    }
}

private struct CreateTripMapTextRow: View {
    let icon: String
    let title: String
    let placeholder: String
    @Binding var text: String
    var isFocused: FocusState<Bool>.Binding

    var body: some View {
        HStack(spacing: AppSpacing.md) {
            MapStyleIcon(
                systemName: icon,
                size: .small,
                accent: AppColors.appPrimary,
                accessibilityLabel: title
            )

            Text(title)
                .font(.appBody)
                .foregroundStyle(AppColors.textPrimary)

            Spacer(minLength: AppSpacing.md)

            TextField(placeholder, text: $text)
                .font(.appBody)
                .foregroundStyle(AppColors.textPrimary)
                .multilineTextAlignment(.trailing)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .focused(isFocused)
                .frame(minWidth: CreateTripMapFormMetrics.trailingFieldMinWidth)
        }
        .padding(.horizontal, AppSpacing.md)
        .frame(minHeight: CreateTripMapFormMetrics.tallRowMinHeight)
        .contentShape(Rectangle())
    }
}

private struct DestinationPredictionRow: View {
    let prediction: PlaceAutocompleteResult
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: AppSpacing.md) {
                MapStyleIcon(
                    systemName: "mappin.and.ellipse",
                    size: .small,
                    accent: AppColors.appPrimary,
                    accessibilityLabel: "Destination suggestion"
                )

                VStack(alignment: .leading, spacing: AppSpacing.xs) {
                    Text(prediction.mainText)
                        .font(.appBody)
                        .foregroundStyle(AppColors.textPrimary)
                        .lineLimit(1)

                    if !prediction.secondaryText.isEmpty {
                        Text(prediction.secondaryText)
                            .font(.appSmall)
                            .foregroundStyle(AppColors.textSecondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AppColors.textTertiary.opacity(0.55))
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, AppSpacing.md)
            .frame(minHeight: CreateTripMapFormMetrics.tallRowMinHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct DestinationStatusRow: View {
    let message: String

    var body: some View {
        HStack(spacing: AppSpacing.md) {
            ProgressView()
                .tint(AppColors.appPrimary)

            Text(message)
                .font(.appBody)
                .foregroundStyle(AppColors.textSecondary)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, AppSpacing.md)
        .frame(minHeight: CreateTripMapFormMetrics.tallRowMinHeight)
    }
}

private struct CreateTripMapDateRow: View {
    let icon: String
    let title: String
    @Binding var selection: Date

    var body: some View {
        HStack(spacing: AppSpacing.md) {
            MapStyleIcon(
                systemName: icon,
                size: .small,
                accent: AppColors.appPrimary,
                accessibilityLabel: title
            )

            DatePicker(title, selection: $selection, displayedComponents: .date)
                .font(.appBody)
                .datePickerStyle(.compact)
                .tint(AppColors.appPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, AppSpacing.md)
        .frame(minHeight: CreateTripMapFormMetrics.tallRowMinHeight)
        .contentShape(Rectangle())
    }
}

private struct CreateTripMapDivider: View {
    var body: some View {
        Divider()
            .background(AppColors.appDivider)
            .padding(.leading, AppSpacing.xxxl + AppSpacing.md)
    }
}

private enum CreateTripMapFormMetrics {
    static let tallRowMinHeight: CGFloat = 64
    static let trailingFieldMinWidth: CGFloat = 160
}

private extension String {
    var trimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

#Preview {
    CreateTripView()
        .environment(DataService())
        .environment(UserPreferencesStore())
}
