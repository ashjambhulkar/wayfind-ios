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
        NavigationStack {
            Form {
                Section {
                    coverPhotoContent
                } header: {
                    Text(String(localized: "Cover Photo"))
                }

                Section(String(localized: "Trip")) {
                    LabeledContent(String(localized: "Title")) {
                        TextField(String(localized: "Trip title"), text: $title)
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.sentences)
                    }
                    LabeledContent(String(localized: "Destination")) {
                        TextField(String(localized: "Destination"), text: $destination)
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.words)
                            .autocorrectionDisabled()
                    }
                }

                Section(String(localized: "Dates")) {
                    DatePicker(
                        String(localized: "Starts"),
                        selection: $startDate,
                        displayedComponents: .date
                    )
                    .tint(AppColors.appPrimary)

                    DatePicker(
                        String(localized: "Ends"),
                        selection: $endDate,
                        displayedComponents: .date
                    )
                    .tint(AppColors.appPrimary)
                }

                Section(String(localized: "Notes")) {
                    TextField(
                        String(localized: "Planning notes, reminders, or group context"),
                        text: $notes,
                        axis: .vertical
                    )
                    .lineLimit(3...8)
                }

                if let saveError {
                    Section {
                        Text(saveError)
                            .font(.appFootnote)
                            .foregroundStyle(AppColors.appError)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(AppColors.appBackground)
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Edit Trip")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task { await saveAsync() }
                    }
                    .disabled(!canSave || isSaving)
                }
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            .task(id: photoPickerItem) {
                await loadPickedPhoto()
            }
            .onChange(of: startDate) { _, newValue in
                if newValue > endDate { endDate = newValue }
            }
            .onChange(of: endDate) { _, newValue in
                if newValue < startDate { startDate = newValue }
            }
        }
    }

    @ViewBuilder
    private var coverPhotoContent: some View {
        coverPhotoPreview
            .listRowInsets(EdgeInsets())

        if AppConfig.useRealBackend {
            PhotosPicker(selection: $photoPickerItem, matching: .images) {
                Label("Choose Photo", systemImage: "photo.on.rectangle.angled")
            }

            if pickedCoverJPEG != nil {
                Button(role: .destructive) {
                    photoPickerItem = nil
                    pickedCoverJPEG = nil
                } label: {
                    Label("Clear Selected Photo", systemImage: "xmark.circle.fill")
                }
            }
        } else {
            Label("Cover upload requires the live backend.", systemImage: "icloud.slash.fill")
                .foregroundStyle(AppColors.textSecondary)
                .font(.appBody)
        }
    }

    @ViewBuilder
    private var coverPhotoPreview: some View {
        Group {
            if let pickedCoverJPEG, let uiImage = UIImage(data: pickedCoverJPEG) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
            } else if let urlString = trip.coverImageUrl, let url = URL(string: urlString) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    case .empty:
                        ProgressView()
                            .frame(maxWidth: .infinity, minHeight: EditTripCoverPhoto.previewHeight)
                    case .failure:
                        Color.clear
                    @unknown default:
                        EmptyView()
                    }
                }
            } else {
                ZStack {
                    AppColors.appSurface
                    VStack(spacing: AppSpacing.sm) {
                        Image(systemName: "photo")
                            .font(.title2)
                            .foregroundStyle(AppColors.appPrimary)
                        Text("Add a cover photo")
                            .font(.appBody)
                            .foregroundStyle(AppColors.textSecondary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: EditTripCoverPhoto.previewHeight)
        .clipped()
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

