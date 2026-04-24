import SwiftUI

struct CreateTripView: View {
    @Environment(DataService.self) private var dataService

    var onCreate: ((Trip) -> Void)?

    @State private var destination: String
    @State private var startDate: Date
    @State private var endDate: Date

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
        !trimmedDestination.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.lg) {
            Text("Plan a New Trip")
                .font(.sectionHeader)
                .foregroundStyle(AppColors.textPrimary)

            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                Text("Where are you going?")
                    .font(.appCaption)
                    .foregroundStyle(AppColors.textSecondary)

                HStack(spacing: AppSpacing.sm) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(AppColors.textTertiary)
                    TextField("Search destination", text: $destination)
                        .font(.appBody)
                        .textInputAutocapitalization(.words)
                }
                .padding(.horizontal, AppSpacing.md)
                .frame(height: 48)
                .background(AppColors.appSurface)
                .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous)
                        .strokeBorder(AppColors.appDivider, lineWidth: 1)
                )
            }

            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                Text("When?")
                    .font(.appCaption)
                    .foregroundStyle(AppColors.textSecondary)

                HStack(spacing: AppSpacing.lg) {
                    VStack(alignment: .leading, spacing: AppSpacing.xs) {
                        Text("Start")
                            .font(.appSmall)
                            .foregroundStyle(AppColors.textSecondary)
                        DatePicker("", selection: $startDate, displayedComponents: .date)
                            .labelsHidden()
                            .tint(AppColors.appPrimary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    VStack(alignment: .leading, spacing: AppSpacing.xs) {
                        Text("End")
                            .font(.appSmall)
                            .foregroundStyle(AppColors.textSecondary)
                        DatePicker("", selection: $endDate, displayedComponents: .date)
                            .labelsHidden()
                            .tint(AppColors.appPrimary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            AppButton(
                title: "Start Planning →",
                style: .primary,
                isDisabled: !canSubmit,
                isLoading: false
            ) {
                Task { await createTrip() }
            }
        }
        .padding(AppSpacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(AppColors.appBackground)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .onChange(of: startDate) { _, newValue in
            if newValue > endDate {
                endDate = newValue
            }
        }
        .onChange(of: endDate) { _, newValue in
            if newValue < startDate {
                startDate = newValue
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
            lat: nil,
            lng: nil,
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
}

#Preview {
    CreateTripView()
        .environment(DataService())
        .environment(UserPreferencesStore())
}

// =============================================================================

