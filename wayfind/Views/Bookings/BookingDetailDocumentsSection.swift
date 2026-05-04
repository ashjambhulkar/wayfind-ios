//
//  BookingDetailDocumentsSection.swift
//  wayfind
//
//  Inline documents for any booking detail (boarding passes, PDFs, photos).
//  "Manage" opens the full `BookingAttachmentsSheet` upload experience.
//

import QuickLook
import SwiftUI

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
                MapStyleIcon(
                    systemName: "doc.text.fill",
                    accent: BookingCategory.flight.color,
                    backgroundStyle: .soft
                )
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
