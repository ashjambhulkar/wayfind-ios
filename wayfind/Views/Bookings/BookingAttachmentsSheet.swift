//
//  BookingAttachmentsSheet.swift
//  wayfind
//
//  Wave 1.2 — full-screen attachments manager for one trip booking.
//  Handles photos AND PDFs; preview goes through QuickLook so users get
//  the native iOS viewer (zoom, share, mark-up).
//
//  Surfaces:
//    • Skeleton list while loading.
//    • PhotosPicker entry (multi-select) for image attachments.
//    • DocumentPicker entry for PDFs (and re-imported images).
//    • Per-row trailing menu: "Preview", "Share", "Delete".
//    • Live BackgroundUploader status row at the top.
//
//  Plan tags: §1.2, §0.5 E4 MIME allowlist, §0.5 C6 off-main PDF render.
//

import PhotosUI
import QuickLook
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct BookingAttachmentsSheet: View {
    let bookingId: UUID
    let tripId: UUID
    let bookingTitle: String

    @Environment(\.dismiss) private var dismiss
    @Environment(DataService.self) private var dataService

    @State private var service: BookingAttachmentService?
    @State private var photoPickerItems: [PhotosPickerItem] = []
    @State private var showingDocumentPicker: Bool = false
    @State private var pendingUploads: [PendingAttachmentUpload] = []
    @State private var uploadError: String?
    @State private var previewURL: URL?

    var body: some View {
        NavigationStack {
            List {
                if !pendingUploads.isEmpty {
                    Section {
                        ForEach(pendingUploads) { up in
                            BookingUploadRow(upload: up, onClear: { clearUpload(id: up.id) })
                        }
                    }
                }
                if let service, service.isLoading && service.attachments.isEmpty {
                    Section {
                        ForEach(0..<3, id: \.self) { _ in
                            SkeletonView(cornerRadius: AppCornerRadius.medium, height: 64)
                        }
                    }
                } else if let service, service.attachments.isEmpty {
                    Section {
                        emptyState
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                    }
                } else if let service {
                    Section {
                        ForEach(service.attachments) { att in
                            BookingAttachmentRow(
                                attachment: att,
                                onPreview: { Task { await preview(attachment: att) } },
                                onDelete: { Task { await service.delete(attachmentId: att.id) } }
                            )
                            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                        }
                    } header: {
                        Text("\(service.attachments.count) of \(BookingAttachmentService.softCap)")
                            .accessibilityLabel("\(service.attachments.count) attachments out of \(BookingAttachmentService.softCap) maximum")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .background(AppColors.appBackground.ignoresSafeArea())
            .navigationTitle("Files & Photos")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        PhotosPicker(
                            selection: $photoPickerItems,
                            maxSelectionCount: remainingSlots,
                            matching: .images,
                            photoLibrary: .shared()
                        ) {
                            Label("Choose Photos", systemImage: "photo.on.rectangle.angled")
                        }
                        Button {
                            showingDocumentPicker = true
                        } label: {
                            Label("Choose Files", systemImage: "doc.badge.plus")
                        }
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .accessibilityLabel("Add attachment")
                    }
                    .disabled(remainingSlots == 0)
                }
            }
            .sheet(isPresented: $showingDocumentPicker) {
                DocumentPicker(
                    allowedTypes: [.pdf, .jpeg, .png, .heic, .webP, .image],
                    onPicked: { url in
                        Task { await handleDocumentPicked(url: url) }
                    }
                )
            }
            .sheet(item: previewURLBinding) { wrapped in
                QuickLookPreview(url: wrapped.url)
            }
            .alert(
                "Couldn't add file",
                isPresented: Binding(
                    get: { uploadError != nil },
                    set: { if !$0 { uploadError = nil } }
                )
            ) {
                Button("OK") { uploadError = nil }
            } message: {
                Text(uploadError ?? "")
            }
            .onChange(of: photoPickerItems) { _, items in
                guard !items.isEmpty else { return }
                Task { await handlePhotosPicked(items: items) }
            }
            .task {
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
        }
    }

    // MARK: – Empty state

    private var emptyState: some View {
        VStack(spacing: AppSpacing.md) {
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 44))
                .foregroundStyle(AppColors.textSecondary)
                .accessibilityHidden(true)
            Text("Keep your booking docs handy")
                .font(.appBody.weight(.semibold))
                .foregroundStyle(AppColors.textPrimary)
            Text("Attach boarding passes, hotel confirmations, or receipts for \(bookingTitle).")
                .font(.appCaption)
                .foregroundStyle(AppColors.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(.vertical, AppSpacing.xxxl)
        .frame(maxWidth: .infinity)
    }

    // MARK: – Picker handlers

    private var remainingSlots: Int {
        let count = service?.attachments.count ?? 0
        return max(0, BookingAttachmentService.softCap - count)
    }

    private var previewURLBinding: Binding<PreviewURLWrapper?> {
        Binding(
            get: { previewURL.map { PreviewURLWrapper(url: $0) } },
            set: { previewURL = $0?.url }
        )
    }

    private func handlePhotosPicked(items: [PhotosPickerItem]) async {
        defer { photoPickerItems = [] }
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
                // Run through ImageProcessor so HEIC / PNG also normalize.
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
        // `??` evaluates the right-hand side as an autoclosure which
        // can't carry `async`. Resolve the lazy fallback explicitly.
        let signed: URL?
        if let cached = attachment.signedURL {
            signed = cached
        } else {
            signed = await refreshURL(for: attachment)
        }
        guard let signed else { return }
        do {
            let local = try await downloadToTemp(url: signed, suggestedName: attachment.displayName)
            await MainActor.run { previewURL = local }
        } catch {
            uploadError = "Couldn't open the file."
        }
    }

    private func refreshURL(for attachment: BookingAttachment) async -> URL? {
        await service?.resolveSignedURLs()
        return service?.attachments.first(where: { $0.id == attachment.id })?.signedURL
    }

    private func downloadToTemp(url: URL, suggestedName: String) async throws -> URL {
        let (data, _) = try await URLSession.shared.data(from: url)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("booking-previews", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let target = dir.appendingPathComponent(suggestedName)
        try? FileManager.default.removeItem(at: target)
        try data.write(to: target, options: .atomic)
        return target
    }

    private func clearUpload(id: UUID) {
        pendingUploads.removeAll { $0.id == id }
    }
}

// MARK: – Helpers

private struct PreviewURLWrapper: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

private struct BookingAttachmentRow: View {
    let attachment: BookingAttachment
    let onPreview: () -> Void
    let onDelete: () -> Void

    @State private var thumbnail: UIImage?

    var body: some View {
        HStack(spacing: AppSpacing.md) {
            thumbnailView
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.small, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(attachment.displayName)
                    .font(.appBody.weight(.medium))
                    .foregroundStyle(AppColors.textPrimary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(attachment.isPDF ? "PDF" : (attachment.isImage ? "Photo" : "File"))
                    if !attachment.sizeLabel.isEmpty {
                        Text("·")
                        Text(attachment.sizeLabel)
                    }
                    Text("·")
                    Text(attachment.createdAt.formatted(.relative(presentation: .numeric)))
                }
                .font(.caption2)
                .foregroundStyle(AppColors.textSecondary)
            }
            Spacer(minLength: AppSpacing.sm)
            Menu {
                Button { onPreview() } label: { Label("Preview", systemImage: "eye") }
                Button(role: .destructive) { onDelete() } label: {
                    Label("Delete", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .foregroundStyle(AppColors.textSecondary)
                    .accessibilityLabel("More actions for \(attachment.displayName)")
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onPreview() }
        .task(id: attachment.signedURL?.absoluteString) {
            await loadThumbnail()
        }
    }

    @ViewBuilder
    private var thumbnailView: some View {
        if let thumbnail {
            Image(uiImage: thumbnail)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                AppColors.appSurface
                Image(systemName: attachment.isPDF
                      ? "doc.richtext"
                      : attachment.isImage
                        ? "photo"
                        : "doc")
                    .font(.system(size: 22))
                    .foregroundStyle(AppColors.textSecondary)
            }
        }
    }

    private func loadThumbnail() async {
        guard thumbnail == nil, let url = attachment.signedURL else { return }
        if attachment.isImage {
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                if let img = UIImage(data: data) {
                    await MainActor.run { thumbnail = img }
                }
            } catch {}
        } else if attachment.isPDF {
            let img = await PDFThumbnailService.shared.thumbnail(
                for: attachment.storagePath,
                remoteURL: url,
                targetSize: CGSize(width: 112, height: 112)
            )
            await MainActor.run { thumbnail = img }
        }
    }
}

private struct BookingUploadRow: View {
    let upload: PendingAttachmentUpload
    let onClear: () -> Void

    var body: some View {
        HStack(spacing: AppSpacing.md) {
            statusIcon
            VStack(alignment: .leading, spacing: 2) {
                Text(upload.displayName)
                    .font(.appCaption.weight(.medium))
                    .lineLimit(1)
                statusText
                    .font(.caption2)
                    .foregroundStyle(AppColors.textSecondary)
            }
            Spacer()
            if isTerminal {
                Button(action: onClear) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(AppColors.textSecondary)
                }
                .accessibilityLabel("Dismiss upload")
            }
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch upload.status {
        case .waiting, .committing, .finalizing: ProgressView()
        case .uploading(let p): ProgressView(value: p).progressViewStyle(.linear).frame(width: 60)
        case .completed: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private var statusText: some View {
        switch upload.status {
        case .waiting: Text("Queued")
        case .committing: Text("Preparing")
        case .uploading(let p): Text("Uploading \(Int(p * 100))%")
        case .finalizing: Text("Finishing")
        case .completed: Text("Added")
        case .failed(let m, _): Text(m)
        }
    }

    private var isTerminal: Bool {
        switch upload.status {
        case .completed, .failed: return true
        default: return false
        }
    }
}

// MARK: – DocumentPicker bridge

struct DocumentPicker: UIViewControllerRepresentable {
    let allowedTypes: [UTType]
    let onPicked: (URL) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: allowedTypes)
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPicked: onPicked) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPicked: (URL) -> Void
        init(onPicked: @escaping (URL) -> Void) { self.onPicked = onPicked }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if let url = urls.first { onPicked(url) }
        }
    }
}

// MARK: – QuickLookPreview bridge

struct QuickLookPreview: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: QLPreviewController, context: Context) {
        uiViewController.reloadData()
    }

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            url as QLPreviewItem
        }
    }
}
