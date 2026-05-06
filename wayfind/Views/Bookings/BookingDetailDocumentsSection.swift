//
//  BookingDetailDocumentsSection.swift
//  wayfind
//
//  Inline documents for any booking detail (boarding passes, PDFs, photos).
//  "Manage" opens the full `BookingAttachmentsSheet` upload experience.
//
//  Also exports `BookingDocumentsInlineSection` — an edit-form variant that
//  embeds the full upload/list experience as a plain `Section` inside the
//  Add/Edit booking Form, eliminating the intermediate Files & Photos sheet.
//

import PhotosUI
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

struct BookingDetailDocumentsSection: View {
    let bookingId: UUID
    let tripId: UUID
    let bookingTitle: String

    @Environment(DataService.self) private var dataService

    @State private var service: BookingAttachmentService?
    @State private var showingManageSheet = false
    @State private var previewURL: URL?
    @State private var previewError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            HStack(alignment: .firstTextBaseline) {
                Text("Documents")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(AppColors.textSecondary)
                    .textCase(.uppercase)
                    .kerning(0.5)

                Spacer()

                Button {
                    showingManageSheet = true
                } label: {
                    Text("Manage")
                        .font(.appCaption.weight(.semibold))
                }
                .buttonStyle(.borderless)
                .tint(AppColors.appPrimary)
                .accessibilityLabel("Add or manage booking documents")
            }

            if service == nil || (service?.isLoading == true && service?.attachments.isEmpty == true) {
                VStack(spacing: AppSpacing.sm) {
                    ForEach(0..<2, id: \.self) { _ in
                        SkeletonView(cornerRadius: AppCornerRadius.medium, height: 64)
                    }
                }
            } else if let service, service.attachments.isEmpty {
                emptyInlineState
            } else if let service {
                VStack(spacing: AppSpacing.sm) {
                    ForEach(service.attachments) { att in
                        BookingAttachmentListRowView(
                            attachment: att,
                            onPreview: { Task { await preview(attachment: att) } },
                            onDelete: { Task { await service.delete(attachmentId: att.id) } }
                        )
                        .padding(AppSpacing.md)
                        .background(AppColors.appSurface)
                        .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous))
                    }
                }
            }
        }
        .padding(.horizontal, AppSpacing.lg)
        .padding(.top, AppSpacing.lg)
        .sheet(isPresented: $showingManageSheet) {
            BookingAttachmentsSheet(
                bookingId: bookingId,
                tripId: tripId,
                bookingTitle: bookingTitle
            )
            .environment(dataService)
        }
        .sheet(item: previewURLBinding) { wrapped in
            QuickLookPreview(url: wrapped.url)
        }
        .alert(
            "Couldn't open file",
            isPresented: Binding(
                get: { previewError != nil },
                set: { if !$0 { previewError = nil } }
            )
        ) {
            Button("OK") { previewError = nil }
        } message: {
            Text(previewError ?? "")
        }
        .task(id: bookingId) {
            if service == nil {
                let new = BookingAttachmentService(
                    bookingId: bookingId,
                    tripId: tripId,
                    dataService: dataService
                )
                service = new
                await new.reload()
            }
        }
        .onChange(of: showingManageSheet) { _, isPresented in
            if !isPresented {
                Task { await service?.reload() }
            }
        }
    }

    private var emptyInlineState: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            Text("No boarding pass or confirmation yet")
                .font(.appBody.weight(.medium))
                .foregroundStyle(AppColors.textPrimary)
            Text("Add a PDF or photo so everything is one tap away when you travel.")
                .font(.appCaption)
                .foregroundStyle(AppColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AppSpacing.lg)
        .background(AppColors.appSurface)
        .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous))
    }

    private var previewURLBinding: Binding<BookingPreviewURLWrapper?> {
        Binding(
            get: { previewURL.map { BookingPreviewURLWrapper(url: $0) } },
            set: { previewURL = $0?.url }
        )
    }

    private func preview(attachment: BookingAttachment) async {
        let signed: URL?
        if let cached = attachment.signedURL {
            signed = cached
        } else {
            await service?.resolveSignedURLs()
            signed = service?.attachments.first(where: { $0.id == attachment.id })?.signedURL
        }
        guard let signed else {
            await MainActor.run { previewError = "Could not load a preview link." }
            return
        }
        do {
            let local = try await Self.downloadToTemp(url: signed, suggestedName: attachment.displayName)
            await MainActor.run { previewURL = local }
        } catch {
            await MainActor.run { previewError = "Couldn't open the file." }
        }
    }

    private static func downloadToTemp(url: URL, suggestedName: String) async throws -> URL {
        let (data, _) = try await URLSession.shared.data(from: url)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("booking-previews", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let target = dir.appendingPathComponent(suggestedName)
        try? FileManager.default.removeItem(at: target)
        try data.write(to: target, options: .atomic)
        return target
    }
}

private struct BookingPreviewURLWrapper: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

// MARK: - Edit flow entry (Add / Edit booking)

/// Compact row on the flight edit form that opens the same attachments manager
/// used on the detail sheet.
struct BookingDocumentsEditEntryRow: View {
    let bookingId: UUID
    let tripId: UUID
    let bookingTitle: String

    @Environment(DataService.self) private var dataService

    @State private var service: BookingAttachmentService?
    @State private var showingManageSheet = false

    var body: some View {
        Button {
            showingManageSheet = true
        } label: {
            HStack(spacing: AppSpacing.md) {
                Image(systemName: "doc.text")
                    .font(.appBody)
                    .foregroundStyle(AppColors.textSecondary)
                    .frame(width: 24)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: AppSpacing.xs) {
                    Text("Boarding pass & documents")
                        .font(.appBody.weight(.semibold))
                        .foregroundStyle(AppColors.textPrimary)
                    Text(subtitle)
                        .font(.appCaption)
                        .foregroundStyle(AppColors.textSecondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: AppSpacing.sm)
                Image(systemName: "chevron.right")
                    .font(.appCaption.weight(.semibold))
                    .foregroundStyle(AppColors.textSecondary)
            }
            .padding(AppSpacing.lg)
            .background(AppColors.appSurface)
            .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous)
                    .strokeBorder(AppColors.appDivider, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens file and photo attachments for this booking.")
        .sheet(isPresented: $showingManageSheet) {
            BookingAttachmentsSheet(
                bookingId: bookingId,
                tripId: tripId,
                bookingTitle: bookingTitle
            )
            .environment(dataService)
        }
        .task(id: bookingId) {
            if service == nil {
                let new = BookingAttachmentService(
                    bookingId: bookingId,
                    tripId: tripId,
                    dataService: dataService
                )
                service = new
                await new.reload()
            }
        }
        .onChange(of: showingManageSheet) { _, isPresented in
            if !isPresented {
                Task { await service?.reload() }
            }
        }
    }

    private var subtitle: String {
        guard let service else { return "Tap to add PDFs or photos" }
        let n = service.attachments.count
        if n == 0 { return "Tap to add PDFs or photos" }
        if n == 1 { return "1 file attached" }
        return "\(n) files attached"
    }
}

// MARK: - Inline edit section (embedded in Add/Edit booking Form)

/// Renders as a `Section` inside the booking edit `Form`.
/// Handles photo and document uploads entirely inline — no separate
/// Files & Photos sheet is needed. Attachments and in-progress uploads
/// appear as standard list rows directly below the section header.
///
/// The add row is a `Menu` that lets the user choose "Choose Photo" or
/// "Choose File".  Menu items set `triggerPhotosPicker` / `triggerDocumentPicker`
/// bindings (owned by `AddBookingView`) so the actual presentations happen at
/// the NavigationStack level.  This avoids the "already presenting" conflict
/// that occurs when PhotosPicker or a sheet is attached inside a Form Section
/// that is itself inside a `.sheet` presentation.
/// The parent owns: `triggerPhotosPicker`, `triggerDocumentPicker`,
/// `incomingPhotoItems`, `incomingDocumentURL`; this component owns all
/// upload/display logic.
struct BookingDocumentsInlineSection: View {
    let bookingId: UUID
    let tripId: UUID
    let bookingTitle: String

    /// Owned by the parent so the actual pickers present at the NavigationStack
    /// level, not inside the Form Section (avoids "already presenting" conflicts).
    /// The row uses a `Menu` to make the choice; menu items set these bindings
    /// with a short delay so the menu animation finishes first.
    @Binding var triggerPhotosPicker: Bool
    @Binding var triggerDocumentPicker: Bool
    @Binding var incomingPhotoItems: [PhotosPickerItem]
    @Binding var incomingDocumentURL: URL?

    @Environment(DataService.self) private var dataService

    @State private var service: BookingAttachmentService?
    @State private var pendingUploads: [PendingAttachmentUpload] = []
    @State private var uploadError: String?
    @State private var previewURL: URL?

    var body: some View {
        Section("Documents") {
            addRow
            pendingRows
            attachmentRows
        }
        .onChange(of: incomingPhotoItems) { _, items in
            guard !items.isEmpty else { return }
            Task { await handlePhotosPicked(items: items) }
        }
        .onChange(of: incomingDocumentURL) { _, url in
            guard let url else { return }
            Task {
                await handleDocumentPicked(url: url)
                incomingDocumentURL = nil
            }
        }
        .sheet(item: previewURLBinding) { wrapped in
            QuickLookPreview(url: wrapped.url)
        }
        .alert(
            "Couldn't add file",
            isPresented: Binding(get: { uploadError != nil }, set: { if !$0 { uploadError = nil } })
        ) {
            Button("OK") { uploadError = nil }
        } message: {
            Text(uploadError ?? "")
        }
        .task(id: bookingId) {
            let new = BookingAttachmentService(
                bookingId: bookingId,
                tripId: tripId,
                dataService: dataService
            )
            service = new
            await new.reload()
        }
    }

    // MARK: – Row builders

    @ViewBuilder
    private var addRow: some View {
        if remainingSlots > 0 {
            Menu {
                Button {
                    Task {
                        try? await Task.sleep(for: .milliseconds(300))
                        triggerPhotosPicker = true
                    }
                } label: {
                    Label(String(localized: "Choose Photo"), systemImage: "photo.on.rectangle.angled")
                }
                Button {
                    Task {
                        try? await Task.sleep(for: .milliseconds(300))
                        triggerDocumentPicker = true
                    }
                } label: {
                    Label(String(localized: "Choose File"), systemImage: "doc.badge.plus")
                }
            } label: {
                Label(String(localized: "Add Photo or File"), systemImage: "plus.circle.fill")
                    .foregroundStyle(AppColors.appPrimary)
            }
            .accessibilityLabel(String(localized: "Add Photo or File"))
        }
    }

    @ViewBuilder
    private var pendingRows: some View {
        ForEach(pendingUploads) { up in
            BookingUploadRow(upload: up, onClear: { clearUpload(id: up.id) })
        }
    }

    @ViewBuilder
    private var attachmentRows: some View {
        if let service, service.isLoading && service.attachments.isEmpty {
            ForEach(0..<2, id: \.self) { _ in
                SkeletonView(cornerRadius: AppCornerRadius.medium, height: 44)
                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
            }
        } else if let service {
            ForEach(service.attachments) { att in
                BookingAttachmentListRowView(
                    attachment: att,
                    onPreview: { Task { await preview(attachment: att) } },
                    onDelete: { Task { await service.delete(attachmentId: att.id) } }
                )
                .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
            }
        }
    }

    // MARK: – Helpers

    private var remainingSlots: Int {
        let count = service?.attachments.count ?? 0
        return max(0, BookingAttachmentService.softCap - count)
    }

    private var previewURLBinding: Binding<InlinePreviewURLWrapper?> {
        Binding(
            get: { previewURL.map { InlinePreviewURLWrapper(url: $0) } },
            set: { previewURL = $0?.url }
        )
    }

    private func clearUpload(id: UUID) {
        pendingUploads.removeAll { $0.id == id }
    }

    private func handlePhotosPicked(items: [PhotosPickerItem]) async {
        defer { incomingPhotoItems = [] }
        guard let service else { return }
        for item in items {
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else { continue }
                let processed = try await ImageProcessor.process(data: data)
                let pending = try await service.upload(
                    bytes: processed.data,
                    mimeType: processed.mimeType,
                    fileName: processed.fileName
                )
                pendingUploads.append(pending)
            } catch let err as ImageProcessorError {
                uploadError = err.errorDescription
            } catch let err as BookingAttachmentError {
                uploadError = err.errorDescription
                break
            } catch let err as AttachmentValidator.ValidationError {
                uploadError = err.errorDescription
            } catch {
                uploadError = error.localizedDescription
            }
        }
    }

    private func handleDocumentPicked(url: URL) async {
        guard let service else { return }
        let ok = url.startAccessingSecurityScopedResource()
        defer { if ok { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            let utType = UTType(filenameExtension: url.pathExtension)
            let mime = AttachmentValidator.mimeType(for: utType ?? .data) ?? "application/octet-stream"
            let bytesToUpload: Data
            let mimeToUpload: String
            let fileName: String
            if mime.hasPrefix("image/") && mime != "image/jpeg" {
                let processed = try await ImageProcessor.process(
                    data: data,
                    sourceFileName: url.lastPathComponent
                )
                bytesToUpload = processed.data
                mimeToUpload = processed.mimeType
                fileName = processed.fileName
            } else {
                bytesToUpload = data
                mimeToUpload = mime
                fileName = url.lastPathComponent
            }
            let pending = try await service.upload(
                bytes: bytesToUpload,
                mimeType: mimeToUpload,
                fileName: fileName
            )
            pendingUploads.append(pending)
        } catch let err as BookingAttachmentError {
            uploadError = err.errorDescription
        } catch let err as AttachmentValidator.ValidationError {
            uploadError = err.errorDescription
        } catch let err as ImageProcessorError {
            uploadError = err.errorDescription
        } catch {
            uploadError = error.localizedDescription
        }
    }

    private func preview(attachment: BookingAttachment) async {
        let signed: URL?
        if let cached = attachment.signedURL {
            signed = cached
        } else {
            await service?.resolveSignedURLs()
            signed = service?.attachments.first(where: { $0.id == attachment.id })?.signedURL
        }
        guard let signed else { return }
        do {
            let local = try await Self.downloadToTemp(url: signed, suggestedName: attachment.displayName)
            await MainActor.run { previewURL = local }
        } catch {
            uploadError = "Couldn't open the file."
        }
    }

    private static func downloadToTemp(url: URL, suggestedName: String) async throws -> URL {
        let (data, _) = try await URLSession.shared.data(from: url)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("booking-previews", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let target = dir.appendingPathComponent(suggestedName)
        try? FileManager.default.removeItem(at: target)
        try data.write(to: target, options: .atomic)
        return target
    }
}

private struct InlinePreviewURLWrapper: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}
