//
//  ActivityPhotosSheet.swift
//  wayfind
//
//  Wave 1.1 — full-screen photos manager for one timeline activity.
//  Surfaces:
//    • A grid of existing photos (3-col on iPhone, 4-col on iPad).
//    • Skeleton tiles during the initial load so the layout never
//      collapses (per HIG, no bare spinners on chrome views).
//    • PhotosPicker entry to add up to (5 - existingCount) more.
//    • Per-tile context menu: "Set as cover" + "Delete".
//    • Live BackgroundUploader progress at the top.
//
//  Accessibility:
//    • Each tile carries a VoiceOver label describing position + cover state.
//    • The picker button is a .button trait with a clear hint.
//    • Reduce-Motion: shimmer is suppressed by SkeletonView.
//
//  Plan tags: §1.1 (activity photos), §0.5 U2 (no bare spinners),
//  §0.5 U7 (iPad density), §0.5 C2 (accessibility audit).
//

import PhotosUI
import SwiftUI
import UIKit

struct ActivityPhotosSheet: View {
    let activityId: UUID
    let tripId: UUID
    let activityTitle: String
    /// When false, hides add affordances and per-tile edit actions (view-only gallery).
    var canEditAttachments: Bool = true

    @Environment(\.dismiss) private var dismiss
    @Environment(DataService.self) private var dataService
    @Environment(\.horizontalSizeClass) private var sizeClass

    @State private var service: ActivityAttachmentService?
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var isUploading: Bool = false
    @State private var uploadError: String?
    @State private var pendingUploads: [PendingAttachmentUpload] = []

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: AppSpacing.lg) {
                    if !pendingUploads.isEmpty {
                        uploadProgressSection
                    }
                    if let service, service.isLoading && service.attachments.isEmpty {
                        skeletonGrid
                    } else if let service, service.attachments.isEmpty {
                        emptyState
                    } else if let service {
                        gridSection(attachments: service.attachments, canEdit: canEditAttachments)
                    }
                }
                .padding(AppSpacing.lg)
            }
            .background(AppColors.appBackground.ignoresSafeArea())
            .navigationTitle(String(localized: "Photos"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Close")) {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    if canEditAttachments {
                        PhotosPicker(
                            selection: $pickerItems,
                            maxSelectionCount: remainingSlots,
                            matching: .images,
                            photoLibrary: .shared()
                        ) {
                            Label(String(localized: "Add"), systemImage: "plus.circle.fill")
                                .labelStyle(.iconOnly)
                        }
                        .disabled(remainingSlots == 0)
                        .accessibilityLabel(String(localized: "Add"))
                        .accessibilityHint(remainingSlots == 0
                            ? "Maximum 5 photos reached"
                            : "Add up to \(remainingSlots) more photos to \(activityTitle)")
                    }
                }
            }
            .tint(AppColors.appPrimary)
            .alert(
                "Couldn't add photo",
                isPresented: Binding(
                    get: { uploadError != nil },
                    set: { if !$0 { uploadError = nil } }
                )
            ) {
                Button("OK") { uploadError = nil }
            } message: {
                Text(uploadError ?? "")
            }
            .task {
                if service == nil {
                    let new = ActivityAttachmentService(
                        activityId: activityId,
                        tripId: tripId,
                        dataService: dataService
                    )
                    service = new
                    await new.reload()
                }
            }
            .onChange(of: pickerItems) { _, newItems in
                guard !newItems.isEmpty else { return }
                Task { await handlePicked(items: newItems) }
            }
        }
    }

    // MARK: - Sections

    private var uploadProgressSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            ForEach(pendingUploads) { upload in
                UploadProgressRow(upload: upload, onClear: { clearUpload(id: upload.id) })
            }
        }
    }

    private var skeletonGrid: some View {
        LazyVGrid(columns: gridColumns, spacing: AppSpacing.md) {
            ForEach(0..<6, id: \.self) { _ in
                SkeletonView(cornerRadius: AppCornerRadius.medium, height: tileSize)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: AppSpacing.lg) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 48, weight: .regular))
                .foregroundStyle(AppColors.textSecondary)
                .accessibilityHidden(true)
            if canEditAttachments {
                Text("Capture this moment")
                    .font(.appBody.weight(.semibold))
                    .foregroundStyle(AppColors.textPrimary)
                Text("Add up to 5 photos to remember \(activityTitle).")
                    .font(.appCaption)
                    .foregroundStyle(AppColors.textSecondary)
                    .multilineTextAlignment(.center)
                PhotosPicker(
                    selection: $pickerItems,
                    maxSelectionCount: 5,
                    matching: .images,
                    photoLibrary: .shared()
                ) {
                    Label("Add photo", systemImage: "plus")
                        .font(.appBody.weight(.semibold))
                        .labelStyle(.titleAndIcon)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .foregroundStyle(Color.white)
                        .background(AppColors.appPrimary)
                        .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous))
                        .shadow(color: Color.black.opacity(0.12), radius: 4, x: 0, y: 2)
                }
                .buttonStyle(.plain)
                .padding(.top, AppSpacing.sm)
            } else {
                Text("No photos yet")
                    .font(.appBody.weight(.semibold))
                    .foregroundStyle(AppColors.textPrimary)
                Text("Editors can add photos for \(activityTitle).")
                    .font(.appCaption)
                    .foregroundStyle(AppColors.textSecondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.vertical, AppSpacing.xxxl)
        .frame(maxWidth: .infinity)
    }

    private func gridSection(attachments: [ActivityAttachment], canEdit: Bool) -> some View {
        LazyVGrid(columns: gridColumns, spacing: AppSpacing.md) {
            ForEach(Array(attachments.enumerated()), id: \.element.id) { idx, att in
                AttachmentTile(
                    attachment: att,
                    index: idx,
                    total: attachments.count,
                    canEdit: canEdit,
                    onSetCover: {
                        Task { await service?.setCover(attachmentId: att.id) }
                    },
                    onDelete: {
                        Task { await service?.delete(attachmentId: att.id) }
                    }
                )
                .frame(height: tileSize)
            }
        }
    }

    // MARK: - Layout

    private var gridColumns: [GridItem] {
        let count = sizeClass == .regular ? 4 : 3
        return Array(repeating: GridItem(.flexible(), spacing: AppSpacing.md), count: count)
    }

    private var tileSize: CGFloat {
        sizeClass == .regular ? 140 : 110
    }

    private var remainingSlots: Int {
        let imageCount = service?.attachments.filter { $0.isImage }.count ?? 0
        return max(0, 5 - imageCount)
    }

    // MARK: - Picker

    private func handlePicked(items: [PhotosPickerItem]) async {
        defer {
            pickerItems = []
        }
        guard let service else { return }
        for item in items {
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else { continue }
                let processed = try await ImageProcessor.process(
                    data: data,
                    sourceFileName: nil
                )
                let isFirst = service.attachments.isEmpty
                let pending = try await service.uploadImage(
                    processed: processed,
                    isCover: isFirst
                )
                pendingUploads.append(pending)
            } catch let err as ActivityAttachmentError {
                uploadError = err.errorDescription
                break
            } catch let err as ImageProcessorError {
                uploadError = err.errorDescription
            } catch {
                uploadError = error.localizedDescription
            }
        }
    }

    private func clearUpload(id: UUID) {
        pendingUploads.removeAll { $0.id == id }
    }
}

// MARK: - Tile

private struct AttachmentTile: View {
    let attachment: ActivityAttachment
    let index: Int
    let total: Int
    var canEdit: Bool = true
    let onSetCover: () -> Void
    let onDelete: () -> Void

    @State private var image: UIImage?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous)
                .fill(AppColors.appSurface)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous))
            } else {
                SkeletonView(cornerRadius: AppCornerRadius.medium, height: 200)
            }
            if attachment.isCover {
                coverBadge
                    .padding(AppSpacing.xs)
            }
        }
        .clipped()
        .contextMenu {
            if canEdit {
                if !attachment.isCover && attachment.isImage {
                    Button {
                        onSetCover()
                    } label: {
                        Label("Set as cover", systemImage: "star")
                    }
                }
                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
        .task(id: "\(attachment.id.uuidString)-\(attachment.signedURL?.absoluteString ?? "")") {
            await loadImage()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(.isImage)
    }

    private var coverBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: "star.fill")
            Text("Cover")
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, AppSpacing.sm)
        .padding(.vertical, AppSpacing.xs)
        .background(.black.opacity(0.55), in: Capsule())
    }

    private var accessibilityLabel: String {
        var parts: [String] = ["Photo \(index + 1) of \(total)"]
        if attachment.isCover { parts.append("Cover") }
        if let name = attachment.originalFilename, !name.isEmpty {
            parts.append(name)
        }
        return parts.joined(separator: ", ")
    }

    private func loadImage() async {
        if let cached = await ActivityAttachmentImageCache.shared.image(for: attachment.id) {
            await MainActor.run { self.image = cached }
            return
        }
        guard let url = attachment.signedURL else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard !data.isEmpty, let img = UIImage(data: data) else { return }
            await ActivityAttachmentImageCache.shared.store(data: data, for: attachment.id)
            await MainActor.run { self.image = img }
        } catch {
            // Tile keeps skeleton; per-tile errors would be noisy.
        }
    }
}

// MARK: - Upload progress row

private struct UploadProgressRow: View {
    let upload: PendingAttachmentUpload
    let onClear: () -> Void

    var body: some View {
        HStack(spacing: AppSpacing.md) {
            statusIcon
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(upload.displayName)
                    .font(.appCaption.weight(.semibold))
                    .foregroundStyle(AppColors.textPrimary)
                    .lineLimit(1)
                statusLine
                    .font(.caption2)
                    .foregroundStyle(AppColors.textSecondary)
            }
            Spacer(minLength: AppSpacing.sm)
            if isTerminal {
                Button(action: onClear) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(AppColors.textSecondary)
                }
                .accessibilityLabel("Dismiss upload row")
            }
        }
        .padding(.horizontal, AppSpacing.md)
        .padding(.vertical, AppSpacing.sm)
        .background(AppColors.appSurface, in: RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous))
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch upload.status {
        case .waiting, .committing, .finalizing:
            ProgressView()
        case .uploading(let p):
            ProgressView(value: p)
                .progressViewStyle(.circular)
        case .completed:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        switch upload.status {
        case .waiting: Text("Waiting…")
        case .committing: Text("Preparing…")
        case .uploading(let p): Text("Uploading \(Int(p * 100))%")
        case .finalizing: Text("Finishing…")
        case .completed: Text("Added")
        case .failed(let msg, _): Text(msg)
        }
    }

    private var isTerminal: Bool {
        switch upload.status {
        case .completed, .failed: return true
        default: return false
        }
    }
}
