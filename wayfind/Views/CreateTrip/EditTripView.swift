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
            ScrollView {
                VStack(alignment: .leading, spacing: AppSpacing.xl) {
                    coverPhotoSection

                    EditTripMapSectionCard(title: "Trip") {
                        EditTripMapTextRow(
                            icon: "textformat",
                            title: "Title",
                            placeholder: "Trip title",
                            text: $title
                        )

                        EditTripMapDivider()

                        EditTripMapTextRow(
                            icon: "mappin.circle.fill",
                            title: "Destination",
                            placeholder: "Destination",
                            capitalization: .words,
                            text: $destination
                        )
                    }

                    EditTripMapSectionCard(title: "Dates") {
                        EditTripMapDateRow(
                            icon: "calendar.badge.plus",
                            title: "Starts",
                            selection: $startDate
                        )

                        EditTripMapDivider()

                        EditTripMapDateRow(
                            icon: "calendar.badge.minus",
                            title: "Ends",
                            selection: $endDate
                        )
                    }

                    notesSection

                    if let saveError {
                        Text(saveError)
                            .font(.appCaption)
                            .foregroundStyle(AppColors.appError)
                    }
                }
                .padding(AppSpacing.lg)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(AppColors.appBackground)
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
    }

    @ViewBuilder
    private var coverPhotoSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            FormSectionTitle("Cover Photo")

            Group {
                if let pickedCoverJPEG, let uiImage = UIImage(data: pickedCoverJPEG) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: .infinity)
                        .frame(height: EditTripCoverPhoto.previewHeight)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous))
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
                    .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous))
                } else {
                    RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous)
                        .fill(AppColors.appSurface)
                        .frame(height: EditTripCoverPhoto.previewHeight)
                        .overlay {
                            VStack(spacing: AppSpacing.sm) {
                                MapStyleIcon(
                                    systemName: "photo",
                                    size: .large,
                                    accent: AppColors.appPrimary,
                                    backgroundStyle: .soft,
                                    accessibilityLabel: "Cover photo"
                                )
                                Text("Add a cover photo")
                                    .font(.appBody)
                                    .foregroundStyle(AppColors.textSecondary)
                            }
                        }
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous)
                    .strokeBorder(AppColors.appDivider, lineWidth: 1)
            }

            if AppConfig.useRealBackend {
                EditTripMapSectionCard(title: nil) {
                    PhotosPicker(selection: $photoPickerItem, matching: .images) {
                        HStack(spacing: AppSpacing.md) {
                            MapStyleIcon(
                                systemName: "photo.on.rectangle.angled",
                                size: .small,
                                accent: AppColors.appPrimary,
                                accessibilityLabel: "Choose photo"
                            )

                            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                                Text("Choose Photo")
                                    .font(.appBody)
                                    .foregroundStyle(AppColors.textPrimary)
                                Text("Use a picture that helps everyone recognize the trip")
                                    .font(.appSmall)
                                    .foregroundStyle(AppColors.textSecondary)
                                    .lineLimit(1)
                            }

                            Spacer(minLength: AppSpacing.md)

                            Image(systemName: "chevron.right")
                                .font(.appSmall.weight(.semibold))
                                .foregroundStyle(AppColors.textTertiary)
                        }
                        .padding(.horizontal, AppSpacing.md)
                        .frame(minHeight: EditTripMapFormMetrics.rowMinHeight)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if pickedCoverJPEG != nil {
                        EditTripMapDivider()

                        Button(role: .destructive) {
                            photoPickerItem = nil
                            pickedCoverJPEG = nil
                        } label: {
                            HStack(spacing: AppSpacing.md) {
                                MapStyleIcon(
                                    systemName: "xmark.circle.fill",
                                    size: .small,
                                    accent: AppColors.appError,
                                    accessibilityLabel: "Clear selected photo"
                                )

                                Text("Clear Selected Photo")
                                    .font(.appBody)
                                    .foregroundStyle(AppColors.appError)

                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, AppSpacing.md)
                            .frame(minHeight: EditTripMapFormMetrics.rowMinHeight)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            } else {
                EditTripMapSectionCard(title: nil) {
                    HStack(spacing: AppSpacing.md) {
                        MapStyleIcon(
                            systemName: "icloud.slash.fill",
                            size: .small,
                            accent: AppColors.textTertiary,
                            accessibilityLabel: "Cover upload unavailable"
                        )
                        Text("Cover upload is available when using the live backend.")
                            .font(.appBody)
                            .foregroundStyle(AppColors.textSecondary)
                    }
                    .padding(.horizontal, AppSpacing.md)
                    .frame(minHeight: EditTripMapFormMetrics.rowMinHeight)
                }
            }
        }
    }

    private var notesSection: some View {
        EditTripMapSectionCard(title: "Notes") {
            HStack(alignment: .top, spacing: AppSpacing.md) {
                MapStyleIcon(
                    systemName: "note.text",
                    size: .small,
                    accent: AppColors.appPrimary,
                    accessibilityLabel: "Notes"
                )
                .padding(.top, AppSpacing.sm)

                ZStack(alignment: .topLeading) {
                    if notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("Add planning notes, reminders, or group context")
                            .font(.appBody)
                            .foregroundStyle(AppColors.textTertiary)
                            .padding(.top, AppSpacing.sm)
                            .allowsHitTesting(false)
                    }

                    TextField("", text: $notes, axis: .vertical)
                        .font(.appBody)
                        .foregroundStyle(AppColors.textPrimary)
                        .lineLimit(3...8)
                }
            }
            .padding(.horizontal, AppSpacing.md)
            .padding(.vertical, AppSpacing.sm)
            .frame(minHeight: EditTripMapFormMetrics.notesMinHeight, alignment: .top)
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

private struct EditTripMapSectionCard<Content: View>: View {
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

private struct EditTripMapTextRow: View {
    let icon: String
    let title: String
    let placeholder: String
    var capitalization: TextInputAutocapitalization = .sentences
    @Binding var text: String

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
                .textInputAutocapitalization(capitalization)
                .autocorrectionDisabled()
                .frame(minWidth: EditTripMapFormMetrics.trailingFieldMinWidth)
        }
        .padding(.horizontal, AppSpacing.md)
        .frame(minHeight: EditTripMapFormMetrics.rowMinHeight)
        .contentShape(Rectangle())
    }
}

private struct EditTripMapDateRow: View {
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
        .frame(minHeight: EditTripMapFormMetrics.rowMinHeight)
        .contentShape(Rectangle())
    }
}

private struct EditTripMapDivider: View {
    var body: some View {
        Divider()
            .background(AppColors.appDivider)
            .padding(.leading, AppSpacing.xxxl + AppSpacing.md)
    }
}

private enum EditTripMapFormMetrics {
    static let rowMinHeight: CGFloat = 56
    static let notesMinHeight: CGFloat = 104
    static let trailingFieldMinWidth: CGFloat = 140
}


// =============================================================================

