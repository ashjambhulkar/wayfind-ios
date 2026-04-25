//
//  ExpenseReceiptsSection.swift
//  wayfind
//
//  Wave 1.3 — receipts UI for `AddExpenseSheet`. Two flavors:
//
//    * **Compose mode** (no existing expense): user picks photos / PDFs
//      that are *staged* in memory (`StagedReceipt`). They're flushed to
//      `trip_expense_attachments` after the parent expense is saved.
//
//    * **Edit mode** (existing expense): we instantiate
//      `ExpenseAttachmentService` for the row and let the user
//      add / remove receipts directly. Uploads run through
//      `BackgroundUploader` exactly like activity / booking attachments.
//
//  Both modes share the same chip-row layout so the UI doesn't shift when
//  the user transitions from compose to edit (e.g. saves then re-opens).
//

import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ExpenseReceiptsSection: View {
    /// When non-nil, we hit the network. When nil, we stage in memory and
    /// the parent flushes after `addExpense`.
    let expenseId: UUID?
    let tripId: UUID

    /// Two-way binding for compose-mode staged receipts. Ignored when
    /// `expenseId != nil`.
    @Binding var stagedReceipts: [StagedReceipt]

    @Environment(DataService.self) private var dataService
    @State private var service: ExpenseAttachmentService?
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showingDocumentPicker: Bool = false
    @State private var pendingUploads: [PendingAttachmentUpload] = []
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            HStack {
                Text("Receipts")
                    .font(.appCaption)
                    .foregroundStyle(AppColors.textSecondary)
                Spacer()
                if isAtCap {
                    Text("Max 5")
                        .font(.caption2)
                        .foregroundStyle(AppColors.textTertiary)
                }
            }

            chipRow

            if let error {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .accessibilityLabel("Receipt error: \(error)")
            }
        }
        .task {
            if let expenseId, service == nil {
                let new = ExpenseAttachmentService(
                    expenseId: expenseId,
                    tripId: tripId,
                    dataService: dataService
                )
                service = new
                await new.reload()
            }
        }
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            Task { await handlePhotos(items: items) }
        }
        .sheet(isPresented: $showingDocumentPicker) {
            DocumentPicker(
                allowedTypes: [.pdf, .jpeg, .png, .heic, .webP, .image],
                onPicked: { url in
                    Task { await handleDocument(url: url) }
                }
            )
        }
    }

    // MARK: - Chip row

    private var chipRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: AppSpacing.sm) {
                ForEach(displayItems) { item in
                    ReceiptChip(item: item, onDelete: { remove(item: item) })
                }
                if !isAtCap {
                    addMenu
                }
            }
            .padding(.vertical, 2)
        }
    }

    private var addMenu: some View {
        Menu {
            PhotosPicker(
                selection: $photoItems,
                maxSelectionCount: max(0, ExpenseAttachmentService.softCap - currentCount),
                matching: .images,
                photoLibrary: .shared()
            ) {
                Label("Photo", systemImage: "photo.on.rectangle.angled")
            }
            Button {
                showingDocumentPicker = true
            } label: {
                Label("File", systemImage: "doc.badge.plus")
            }
        } label: {
            VStack(spacing: 4) {
                Image(systemName: "plus")
                    .font(.system(size: 18, weight: .medium))
                Text("Receipt")
                    .font(.caption2)
            }
            .frame(width: 64, height: 64)
            .foregroundStyle(AppColors.appPrimary)
            .background(
                AppColors.appSurface,
                in: RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous)
                    .strokeBorder(AppColors.appPrimary.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [4]))
            )
            .accessibilityLabel("Add receipt")
        }
    }

    // MARK: - Display unification

    private var displayItems: [ReceiptDisplayItem] {
        if let service {
            return service.attachments.map { att in
                ReceiptDisplayItem(
                    id: att.id,
                    label: att.displayName,
                    isPDF: att.isPDF,
                    isImage: att.isImage,
                    signedURL: att.signedURL,
                    storagePath: att.storagePath,
                    bytes: nil,
                    isStaged: false
                )
            }
        }
        return stagedReceipts.map { staged in
            ReceiptDisplayItem(
                id: staged.id,
                label: staged.fileName,
                isPDF: staged.mimeType == "application/pdf",
                isImage: staged.mimeType.hasPrefix("image/"),
                signedURL: nil,
                storagePath: nil,
                bytes: staged.bytes,
                isStaged: true
            )
        }
    }

    private var currentCount: Int {
        displayItems.count + pendingUploads.count
    }

    private var isAtCap: Bool {
        currentCount >= ExpenseAttachmentService.softCap
    }

    private func remove(item: ReceiptDisplayItem) {
        if item.isStaged {
            stagedReceipts.removeAll { $0.id == item.id }
        } else if let service {
            Task { await service.delete(attachmentId: item.id) }
        }
    }

    // MARK: - Picker handlers

    private func handlePhotos(items: [PhotosPickerItem]) async {
        defer { photoItems = [] }
        for item in items {
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else { continue }
                let processed = try await ImageProcessor.process(data: data)
                try await commit(
                    bytes: processed.data,
                    mimeType: processed.mimeType,
                    fileName: processed.fileName
                )
            } catch let err as ExpenseAttachmentError {
                error = err.errorDescription
                break
            } catch let err as ImageProcessorError {
                error = err.errorDescription
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func handleDocument(url: URL) async {
        let ok = url.startAccessingSecurityScopedResource()
        defer { if ok { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            let utType = UTType(filenameExtension: url.pathExtension) ?? .data
            let mime = AttachmentValidator.mimeType(for: utType) ?? "application/octet-stream"
            let bytesToSend: Data
            let mimeToSend: String
            let fileName: String
            if mime.hasPrefix("image/") && mime != "image/jpeg" {
                let processed = try await ImageProcessor.process(
                    data: data,
                    sourceFileName: url.lastPathComponent
                )
                bytesToSend = processed.data
                mimeToSend = processed.mimeType
                fileName = processed.fileName
            } else {
                bytesToSend = data
                mimeToSend = mime
                fileName = url.lastPathComponent
            }
            try await commit(bytes: bytesToSend, mimeType: mimeToSend, fileName: fileName)
        } catch let err as AttachmentValidator.ValidationError {
            error = err.errorDescription
        } catch let err as ExpenseAttachmentError {
            error = err.errorDescription
        } catch let err as ImageProcessorError {
            error = err.errorDescription
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func commit(bytes: Data, mimeType: String, fileName: String) async throws {
        if let service {
            let pending = try await service.upload(
                bytes: bytes,
                mimeType: mimeType,
                fileName: fileName
            )
            pendingUploads.append(pending)
        } else {
            try AttachmentValidator.validate(data: bytes, mimeType: mimeType)
            if currentCount >= ExpenseAttachmentService.softCap {
                throw ExpenseAttachmentError.quotaReached
            }
            stagedReceipts.append(StagedReceipt(bytes: bytes, mimeType: mimeType, fileName: fileName))
        }
        error = nil
    }
}

// MARK: - Helpers

private struct ReceiptDisplayItem: Identifiable, Hashable {
    let id: UUID
    let label: String
    let isPDF: Bool
    let isImage: Bool
    let signedURL: URL?
    let storagePath: String?
    let bytes: Data?
    let isStaged: Bool
}

private struct ReceiptChip: View {
    let item: ReceiptDisplayItem
    let onDelete: () -> Void

    @State private var thumbnail: UIImage?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            chip
            Button(action: onDelete) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.white)
                    .background(.black.opacity(0.55), in: Circle())
            }
            .offset(x: 6, y: -6)
            .accessibilityLabel("Remove \(item.label)")
        }
        .task(id: thumbnailKey) { await loadThumbnail() }
    }

    private var thumbnailKey: String {
        item.signedURL?.absoluteString ?? "\(item.bytes?.count ?? 0)-\(item.id.uuidString)"
    }

    @ViewBuilder
    private var chip: some View {
        ZStack {
            if let thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                AppColors.appSurface
                Image(systemName: item.isPDF ? "doc.richtext" : "photo")
                    .foregroundStyle(AppColors.textSecondary)
            }
        }
        .frame(width: 64, height: 64)
        .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous)
                .strokeBorder(AppColors.appDivider, lineWidth: 1)
        )
        .accessibilityLabel(item.label)
    }

    private func loadThumbnail() async {
        if item.isImage {
            if let bytes = item.bytes, let img = UIImage(data: bytes) {
                await MainActor.run { thumbnail = img }
                return
            }
            if let url = item.signedURL {
                do {
                    let (data, _) = try await URLSession.shared.data(from: url)
                    if let img = UIImage(data: data) {
                        await MainActor.run { thumbnail = img }
                    }
                } catch {}
            }
        } else if item.isPDF {
            if let bytes = item.bytes {
                let img = await PDFThumbnailService.shared.thumbnail(
                    for: "staged-\(item.id.uuidString)",
                    bytes: bytes,
                    targetSize: CGSize(width: 128, height: 128)
                )
                await MainActor.run { thumbnail = img }
                return
            }
            if let url = item.signedURL, let path = item.storagePath {
                let img = await PDFThumbnailService.shared.thumbnail(
                    for: path,
                    remoteURL: url,
                    targetSize: CGSize(width: 128, height: 128)
                )
                await MainActor.run { thumbnail = img }
            }
        }
    }
}
