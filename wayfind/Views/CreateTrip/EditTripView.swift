import SwiftUI

struct EditTripView: View {
    let trip: Trip
    var onSave: ((Trip) -> Void)?

    @Environment(\.dismiss) private var dismiss

    @State private var title: String
    @State private var destination: String
    @State private var startDate: Date
    @State private var endDate: Date
    @State private var notes: String

    init(trip: Trip, onSave: ((Trip) -> Void)? = nil) {
        self.trip = trip
        self.onSave = onSave
        _title = State(initialValue: trip.title)
        _destination = State(initialValue: trip.destination)
        _startDate = State(initialValue: trip.startDate)
        _endDate = State(initialValue: trip.endDate)
        _notes = State(initialValue: trip.notes ?? "")
    }

    private var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedDestination: String {
        destination.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSave: Bool {
        !trimmedTitle.isEmpty && !trimmedDestination.isEmpty
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.lg) {
                Text("Edit Trip")
                    .font(.sectionHeader)
                    .foregroundStyle(AppColors.textPrimary)

                VStack(alignment: .leading, spacing: AppSpacing.xs) {
                    Text("Title")
                        .font(.appCaption)
                        .foregroundStyle(AppColors.textSecondary)
                    TextField("Trip title", text: $title)
                        .font(.appBody)
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
                    Text("Destination")
                        .font(.appCaption)
                        .foregroundStyle(AppColors.textSecondary)
                    TextField("Destination", text: $destination)
                        .font(.appBody)
                        .textInputAutocapitalization(.words)
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
                    Text("When")
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

                VStack(alignment: .leading, spacing: AppSpacing.xs) {
                    Text("Notes")
                        .font(.appCaption)
                        .foregroundStyle(AppColors.textSecondary)
                    TextField("Add notes...", text: $notes, axis: .vertical)
                        .font(.appBody)
                        .foregroundStyle(AppColors.textPrimary)
                        .lineLimit(3...8)
                        .padding(AppSpacing.md)
                        .background(AppColors.appSurface)
                        .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous)
                                .strokeBorder(AppColors.appDivider, lineWidth: 1)
                        )
                }

                AppButton(title: "Save Changes", style: .primary, isDisabled: !canSave, isLoading: false) {
                    save()
                }
            }
            .padding(AppSpacing.xl)
        }
        .scrollDismissesKeyboard(.interactively)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(AppColors.appBackground)
        .presentationDetents([.large])
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

    private func save() {
        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let updated = Trip(
            id: trip.id,
            userId: trip.userId,
            title: trimmedTitle,
            destination: trimmedDestination,
            lat: trip.lat,
            lng: trip.lng,
            startDate: startDate,
            endDate: endDate,
            coverImageUrl: trip.coverImageUrl,
            notes: trimmedNotes.isEmpty ? nil : trimmedNotes,
            createdAt: trip.createdAt
        )
        onSave?(updated)
        dismiss()
    }
}