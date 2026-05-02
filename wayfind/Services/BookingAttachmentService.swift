//
//  BookingAttachmentService.swift
//  wayfind
//
//  Wave 1.2 — owner of all `trip_booking_attachments` reads + writes for
//  one booking. Mirrors `ActivityAttachmentService` so the UI patterns
//  (skeleton tiles, BackgroundUploader status row, context menu) stay
//  symmetrical across surfaces.
//
//  Behavior different from activity photos:
//    • PDFs are first-class citizens (boarding passes, hotel
//      confirmations, rental contracts). Thumbnail rendering goes
//      through `PDFThumbnailService`.
//    • No 5-photo trigger on the server — bookings can have many
//      attachments. We still cap at a soft 25 / booking in the UI to
//      protect the picker from runaway uploads.
//    • No "cover" concept; bookings already have a known kind icon.
//

import Foundation
import Observation
import Supabase

struct BookingAttachment: Identifiable, Hashable, Sendable {
    let id: UUID
    let bookingId: UUID
    let storagePath: String
    let mimeType: String
    let originalFilename: String?
    let fileSizeBytes: Int?
    let createdAt: Date
    var signedURL: URL?

    var isImage: Bool { mimeType.lowercased().hasPrefix("image/") }
    var isPDF: Bool { mimeType.lowercased() == "application/pdf" }

    var displayName: String {
        if let originalFilename, !originalFilename.isEmpty { return originalFilename }
        let ext = (mimeType.split(separator: "/").last.map(String.init)) ?? "bin"
        return "Attachment.\(ext)"
    }

    var sizeLabel: String {
        guard let bytes = fileSizeBytes, bytes > 0 else { return "" }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }
}

enum BookingAttachmentError: LocalizedError, Sendable {
    case quotaReached
    case underlying(String)

    var errorDescription: String? {
        switch self {
        case .quotaReached: return "You can attach up to 25 files per booking."
        case .underlying(let m): return m
        }
    }
}

@MainActor
@Observable
final class BookingAttachmentService {
    static let softCap: Int = 25

    let bookingId: UUID
    let tripId: UUID

    private let dataService: DataService
    private var signedURLCache: [UUID: (url: URL, expiry: Date)] = [:]

    private(set) var attachments: [BookingAttachment] = []
    private(set) var isLoading: Bool = false
    private(set) var lastError: String?

    init(bookingId: UUID, tripId: UUID, dataService: DataService) {
        self.bookingId = bookingId
        self.tripId = tripId
        self.dataService = dataService
    }

    func reload() async {
        guard let client = AuthSessionService.shared.client else {
            attachments = []
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            struct Row: Decodable {
                let id: String
                let booking_id: String
                let storage_path: String
                let mime_type: String?
                let original_filename: String?
                let file_size_bytes: Int?
                let created_at: String
            }
            let rows: [Row] = try await client
                .from("trip_booking_attachments")
                .select("id, booking_id, storage_path, mime_type, original_filename, file_size_bytes, created_at")
                .eq("booking_id", value: bookingId.uuidString.lowercased())
                .order("created_at", ascending: false)
                .execute()
                .value
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let isoFallback = ISO8601DateFormatter()
            isoFallback.formatOptions = [.withInternetDateTime]
            self.attachments = rows.compactMap { row in
                guard let id = UUID(uuidString: row.id),
                      let bookingId = UUID(uuidString: row.booking_id) else { return nil }
                let date = iso.date(from: row.created_at) ?? isoFallback.date(from: row.created_at) ?? Date()
                return BookingAttachment(
                    id: id,
                    bookingId: bookingId,
                    storagePath: row.storage_path,
                    mimeType: row.mime_type ?? "application/octet-stream",
                    originalFilename: row.original_filename,
                    fileSizeBytes: row.file_size_bytes,
                    createdAt: date,
                    signedURL: nil
                )
            }
            await resolveSignedURLs()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func resolveSignedURLs() async {
        guard let client = AuthSessionService.shared.client else { return }
        let now = Date()
        // Apply cached URLs first.
        attachments = attachments.map { att in
            var copy = att
            if let cached = signedURLCache[att.id], cached.expiry > now {
                copy.signedURL = cached.url
            }
            return copy
        }
        let pending = attachments.enumerated().filter { _, att in att.signedURL == nil }
        guard !pending.isEmpty else { return }
        await withTaskGroup(of: (Int, URL?).self) { group in
            for (idx, att) in pending {
                group.addTask {
                    do {
                        let url = try await client.storage
                            .from("booking-attachments")
                            .createSignedURL(path: att.storagePath, expiresIn: 60 * 60)
                        return (idx, url)
                    } catch {
                        return (idx, nil)
                    }
                }
            }
            for await (idx, url) in group {
                guard idx < attachments.count else { continue }
                if let url {
                    let expiry = now.addingTimeInterval(50 * 60)
                    signedURLCache[attachments[idx].id] = (url, expiry)
                    attachments[idx].signedURL = url
                }
            }
        }
    }

    /// Upload a freshly-validated PDF or processed image. Caller is
    /// responsible for running images through `ImageProcessor` first;
    /// PDFs flow through unmodified after `AttachmentValidator.validate`.
    @discardableResult
    func upload(
        bytes: Data,
        mimeType: String,
        fileName: String
    ) async throws -> PendingAttachmentUpload {
        if attachments.count >= Self.softCap {
            throw BookingAttachmentError.quotaReached
        }
        try AttachmentValidator.validate(data: bytes, mimeType: mimeType)

        let descriptor = AttachmentUploadDescriptor(
            surface: .tripBookingAttachment,
            parentId: bookingId,
            tripId: tripId,
            fileName: fileName,
            mimeType: mimeType,
            bytes: bytes,
            attachmentType: nil,
            isCover: false,
            title: nil,
            category: nil
        )
        let pending = BackgroundUploader.shared.enqueue(
            descriptor: descriptor,
            dataService: dataService,
            displayName: fileName
        )
        Task { [weak self] in await self?.observe(pending: pending) }
        return pending
    }

    func delete(attachmentId: UUID) async {
        guard let client = AuthSessionService.shared.client else { return }
        do {
            try await client
                .from("trip_booking_attachments")
                .delete()
                .eq("id", value: attachmentId.uuidString.lowercased())
                .execute()
            attachments.removeAll { $0.id == attachmentId }
            signedURLCache.removeValue(forKey: attachmentId)
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func observe(pending: PendingAttachmentUpload) async {
        for _ in 0..<600 {
            try? await Task.sleep(nanoseconds: 200_000_000)
            switch pending.status {
            case .completed: await reload(); return
            case .failed: return
            default: continue
            }
        }
    }
}
