//
//  BookingAttachmentListRowView.swift
//  wayfind
//
//  Shared row for booking attachments — used by `BookingAttachmentsSheet`
//  and inline booking detail surfaces so preview / thumbnail behavior stays
//  consistent.
//

import SwiftUI
import UIKit

struct BookingAttachmentListRowView: View {
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
                .font(.appSmall)
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
