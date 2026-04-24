import PhotosUI
import SwiftUI
import UIKit

private enum EditTripCoverPhoto {
    static let userAttribution = "Your photo"
    static let jpegCompressionQuality: CGFloat = 0.88
    static let previewHeight: CGFloat = 160
}

struct EditTripView: View {
    let trip: Trip
    var onSave: ((Trip) -> Void)?

    @Environment(DataService.self) private var dataService
    @Environment(\.dismiss) private var dismiss

    @State private var title: String
    @State private var destination: String
    @State private var startDate: Date
    @State private var endDate: Date
    @State private var notes: String

    @State private var photoPickerItem: PhotosPickerItem?
    @State private var pickedCoverJPEG: Data?
    @State private var isSaving = false
    @State private var saveError: String?

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

                coverPhotoSection

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

                if let saveError {
                    Text(saveError)
                        .font(.appCaption)
                        .foregroundStyle(AppColors.appError)
                }

                AppButton(title: "Save Changes", style: .primary, isDisabled: !canSave, isLoading: isSaving) {
                    Task { await saveAsync() }
                }
            }
            .padding(AppSpacing.xl)
        }
        .scrollDismissesKeyboard(.interactively)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(AppColors.appBackground)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .task(id: photoPickerItem) {
            await loadPickedPhoto()
        }
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

    @ViewBuilder
    private var coverPhotoSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            Text("Cover photo")
                .font(.appCaption)
                .foregroundStyle(AppColors.textSecondary)

            Group {
                if let pickedCoverJPEG, let uiImage = UIImage(data: pickedCoverJPEG) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: .infinity)
                        .frame(height: EditTripCoverPhoto.previewHeight)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous))
                } else if let urlString = trip.coverImageUrl, let url = URL(string: urlString) {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .empty:
                            ProgressView()
                                .frame(maxWidth: .infinity, minHeight: EditTripCoverPhoto.previewHeight)
                        case .success(let image):
                            image
                                .resizable()
                                .scaledToFill()
                                .frame(maxWidth: .infinity)
                                .frame(height: EditTripCoverPhoto.previewHeight)
                                .clipped()
                        case .failure:
                            Color.clear
                                .frame(height: EditTripCoverPhoto.previewHeight)
                        @unknown default:
                            EmptyView()
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous))
                } else {
                    RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous)
                        .fill(AppColors.appSurface)
                        .frame(height: EditTripCoverPhoto.previewHeight)
                        .overlay {
                            Image(systemName: "photo")
                                .font(.title2)
                                .foregroundStyle(AppColors.textTertiary)
                        }
                }
            }

            if AppConfig.useRealBackend {
                HStack(spacing: AppSpacing.md) {
                    PhotosPicker(selection: $photoPickerItem, matching: .images) {
                        Label("Choose photo", systemImage: "photo.on.rectangle.angled")
                            .font(.appBody)
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                            .background(AppColors.appSurface)
                            .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous)
                                    .strokeBorder(AppColors.appDivider, lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)

                    if pickedCoverJPEG != nil {
                        Button("Clear") {
                            photoPickerItem = nil
                            pickedCoverJPEG = nil
                        }
                        .font(.appBody)
                        .foregroundStyle(AppColors.appPrimary)
                    }
                }
            } else {
                Text("Cover upload is available when using the live backend.")
                    .font(.appCaption)
                    .foregroundStyle(AppColors.textSecondary)
            }
        }
    }

    @MainActor
    private func loadPickedPhoto() async {
        guard let photoPickerItem else { return }
        saveError = nil
        do {
            guard let raw = try await photoPickerItem.loadTransferable(type: Data.self) else { return }
            guard
                let jpeg = UIImage(data: raw)?.jpegData(
                    compressionQuality: EditTripCoverPhoto.jpegCompressionQuality
                )
            else {
                saveError = TripCoverUploadError.couldNotReadImage.localizedDescription
                return
            }
            pickedCoverJPEG = jpeg
        } catch {
            saveError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    @MainActor
    private func saveAsync() async {
        guard canSave else { return }
        isSaving = true
        saveError = nil
        defer { isSaving = false }

        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)

        var coverUrl = trip.coverImageUrl
        var coverAttribution = trip.coverImageAttribution

        if let jpeg = pickedCoverJPEG, AppConfig.useRealBackend {
            do {
                coverUrl = try await dataService.uploadTripCoverPhoto(tripId: trip.id, imageData: jpeg)
                coverAttribution = EditTripCoverPhoto.userAttribution
            } catch {
                saveError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                return
            }
        }

        let touch = Date()
        let calendar = Calendar.current
        let dbStatus = SupabaseModelMapping.inferTripStatus(startDate: startDate, endDate: endDate, calendar: calendar)
        let isActive = SupabaseModelMapping.isTripActive(startDate: startDate, endDate: endDate, calendar: calendar)
        let updated = Trip(
            id: trip.id,
            userId: trip.userId,
            title: trimmedTitle,
            destination: trimmedDestination,
            lat: trip.lat,
            lng: trip.lng,
            startDate: startDate,
            endDate: endDate,
            coverImageUrl: coverUrl,
            coverImageAttribution: coverAttribution,
            notes: trimmedNotes.isEmpty ? nil : trimmedNotes,
            createdAt: trip.createdAt,
            updatedAt: touch,
            databaseStatus: dbStatus,
            isMarkedActiveOnServer: isActive
        )
        onSave?(updated)
        dismiss()
    }
}


// =============================================================================

