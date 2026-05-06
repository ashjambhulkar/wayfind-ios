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
            Form {
                Section(String(localized: "Destination")) {
                    TextField(String(localized: "Where are you going?"), text: $destination)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                        .focused($isDestinationFocused)

                    if isResolvingDestination {
                        HStack(spacing: AppSpacing.sm) {
                            ProgressView()
                                .tint(AppColors.appPrimary)
                                .controlSize(.small)
                            Text(String(localized: "Finding destination…"))
                                .font(.appBody)
                                .foregroundStyle(AppColors.textSecondary)
                        }
                    } else if shouldShowDestinationPredictions {
                        ForEach(placeSearch.results) { prediction in
                            Button {
                                Task { await selectDestinationPrediction(prediction) }
                            } label: {
                                VStack(alignment: .leading, spacing: AppSpacing.xs) {
                                    Text(prediction.mainText)
                                        .font(.appBody)
                                        .foregroundStyle(AppColors.textPrimary)
                                    if !prediction.secondaryText.isEmpty {
                                        Text(prediction.secondaryText)
                                            .font(.appSmall)
                                            .foregroundStyle(AppColors.textSecondary)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Section(String(localized: "Dates")) {
                    DatePicker(
                        String(localized: "Start"),
                        selection: $startDate,
                        displayedComponents: .date
                    )
                    .tint(AppColors.appPrimary)

                    DatePicker(
                        String(localized: "End"),
                        selection: $endDate,
                        displayedComponents: .date
                    )
                    .tint(AppColors.appPrimary)
                }
            }
            .scrollContentBackground(.hidden)
            .background(AppColors.appBackground)
            .scrollDismissesKeyboard(.interactively)
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
