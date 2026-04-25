//
//  ActivityAttachmentService.swift
//  wayfind
//
//  Wave 1.1 — owner of all `trip_activity_attachments` reads + writes
//  for one activity. Bridges the SwiftUI `ActivityPhotosSheet` to:
//    • `commit-attachment` Edge Function (atomic row + signed URL)
//    • `BackgroundUploader` (race-safe PUT with retry)
//    • Supabase Storage `activity-attachments` bucket (signed reads)
//
//  Why a service instead of inlining the calls in the view model:
//    • Multiple surfaces (timeline preview, full sheet) need the same
//      list, and we want a single source of truth so a long-press
//      "Set as cover" flips both immediately.
//    • Server enforces a hard 5-photo cap via trigger
//      (`enforce_trip_activity_max_photos`). Surfacing that as a typed
//      error here means callers don't have to parse Postgres error codes.
//    • Garbage collection is enqueued by the DELETE trigger added in
//      `pending_storage_deletions`. The service just deletes the row;
//      orphaned bytes are swept by `gc-storage-objects` nightly.
//

import Foundation
import Observation
import Supabase

// MARK: - DTOs

struct ActivityAttachment: Identifiable, Hashable, Sendable {
    let id: UUID
    let activityId: UUID
    let storagePath: String
    let mimeType: String
    let attachmentType: String
    let originalFilename: String?
    let fileSizeBytes: Int?
    let isCover: Bool
    let createdAt: Date

    /// Lazily-resolved signed URL (60-min TTL). The view layer caches
    /// these per `id` and refetches when nil.
    var signedURL: URL?

    var isImage: Bool {
        mimeType.lowercased().hasPrefix("image/")
    }

    var displayName: String {
        if let originalFilename, !originalFilename.isEmpty { return originalFilename }
        let ext = (mimeType.split(separator: "/").last.map(String.init)) ?? "bin"
        return "Attachment.\(ext)"
    }
}

enum ActivityAttachmentError: LocalizedError, Sendable {
    case quotaReached
    case notSignedIn
    case forbidden
    case underlying(String)

    var errorDescription: String? {
        switch self {
        case .quotaReached: return "You can attach up to 5 photos per activity."
        case .notSignedIn: return "Sign in to attach photos."
        case .forbidden: return "You don't have permission to edit this activity."
        case .underlying(let m): return m
        }
    }
}

// MARK: - Service

@MainActor
@Observable
final class ActivityAttachmentService {
    let activityId: UUID
    let tripId: UUID

    private let dataService: DataService
    /// Refreshed signed URLs cache, keyed by attachment id.
    private var signedURLCache: [UUID: (url: URL, expiry: Date)] = [:]

    private(set) var attachments: [ActivityAttachment] = []
    private(set) var isLoading: Bool = false
    private(set) var lastError: String?

    init(activityId: UUID, tripId: UUID, dataService: DataService) {
        self.activityId = activityId
        self.tripId = tripId
        self.dataService = dataService
    }

    // MARK: – Reads

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
                let activity_id: String
                let storage_path: String?
                let mime_type: String?
                let attachment_type: String
                let original_filename: String?
                let file_size_bytes: Int?
                let is_cover: Bool?
                let created_at: String
            }
            let rows: [Row] = try await client
                .from("trip_activity_attachments")
                .select("id, activity_id, storage_path, mime_type, attachment_type, original_filename, file_size_bytes, is_cover, created_at")
                .eq("activity_id", value: activityId.uuidString.lowercased())
                .order("is_cover", ascending: false)
                .order("created_at", ascending: true)
                .execute()
                .value
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let isoFallback = ISO8601DateFormatter()
            isoFallback.formatOptions = [.withInternetDateTime]
            self.attachments = rows.compactMap { row in
                guard let id = UUID(uuidString: row.id),
                      let activityId = UUID(uuidString: row.activity_id),
                      let storagePath = row.storage_path else { return nil }
                let date = iso.date(from: row.created_at) ?? isoFallback.date(from: row.created_at) ?? Date()
                return ActivityAttachment(
                    id: id,
                    activityId: activityId,
                    storagePath: storagePath,
                    mimeType: row.mime_type ?? "application/octet-stream",
                    attachmentType: row.attachment_type,
                    originalFilename: row.original_filename,
                    fileSizeBytes: row.file_size_bytes,
                    isCover: row.is_cover ?? false,
                    createdAt: date,
                    signedURL: nil
                )
            }
            // Eagerly resolve signed URLs in parallel; non-blocking for UI.
            await resolveSignedURLs()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Resolve signed download URLs in parallel. Cache for 50 minutes
    /// (signed-URL TTL is 60 — leave buffer).
    func resolveSignedURLs() async {
        guard let client = AuthSessionService.shared.client else { return }
        let now = Date()
        let pending = attachments.enumerated().filter { _, att in
            if let cached = signedURLCache[att.id], cached.expiry > now { return false }
            return att.signedURL == nil
        }
        guard !pending.isEmpty else {
            // Apply cached URLs into the array.
            attachments = attachments.map { att in
                var copy = att
                if let cached = signedURLCache[att.id], cached.expiry > now {
                    copy.signedURL = cached.url
                }
                return copy
            }
            return
        }

        await withTaskGroup(of: (Int, URL?).self) { group in
            for (idx, att) in pending {
                group.addTask { [weak self] in
                    guard let self else { return (idx, nil) }
                    do {
                        let signed = try await client.storage
                            .from("activity-attachments")
                            .createSignedURL(path: att.storagePath, expiresIn: 60 * 60)
                        return (idx, signed)
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

    // MARK: – Writes

    /// Upload a freshly-processed image. Returns the pending upload
    /// handle so the view can show progress; on completion we refresh.
    @discardableResult
    func uploadImage(processed: ProcessedImage, isCover: Bool) async throws -> PendingAttachmentUpload {
        let imageCount = attachments.filter { $0.isImage }.count
        if imageCount >= 5 {
            throw ActivityAttachmentError.quotaReached
        }
        let descriptor = AttachmentUploadDescriptor(
            surface: .tripActivityAttachment,
            parentId: activityId,
            tripId: tripId,
            fileName: processed.fileName,
            mimeType: processed.mimeType,
            bytes: processed.data,
            attachmentType: "photo",
            isCover: isCover && imageCount == 0,
            title: nil,
            category: nil
        )
        let pending = BackgroundUploader.shared.enqueue(
            descriptor: descriptor,
            dataService: dataService,
            displayName: processed.fileName
        )
        // Watch the pending status off-main and reload when complete.
        Task { [weak self] in
            await self?.observe(pending: pending)
        }
        return pending
    }

    /// Promote a non-cover image to the timeline cover. We update both
    /// the new cover row and demote the previous cover in a single
    /// transaction-style sequence (Supabase JS-style: two updates wrapped
    /// in a Promise.all is fine here because RLS scopes by user_id).
    func setCover(attachmentId: UUID) async {
        guard let client = AuthSessionService.shared.client else { return }
        guard let target = attachments.first(where: { $0.id == attachmentId }) else { return }
        guard target.isImage else { return }
        do {
            // 1. Demote any existing covers for this activity.
            let _: [SupabaseEmptyRow] = try await client
                .from("trip_activity_attachments")
                .update(["is_cover": false])
                .eq("activity_id", value: activityId.uuidString.lowercased())
                .eq("is_cover", value: true)
                .select()
                .execute()
                .value
            // 2. Promote the chosen row.
            let _: [SupabaseEmptyRow] = try await client
                .from("trip_activity_attachments")
                .update(["is_cover": true])
                .eq("id", value: attachmentId.uuidString.lowercased())
                .select()
                .execute()
                .value
            await reload()
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Delete the row. The DB trigger added in
    /// `20260602110000_pending_storage_deletions.sql` enqueues the
    /// storage path for nightly GC.
    func delete(attachmentId: UUID) async {
        guard let client = AuthSessionService.shared.client else { return }
        do {
            try await client
                .from("trip_activity_attachments")
                .delete()
                .eq("id", value: attachmentId.uuidString.lowercased())
                .execute()
            attachments.removeAll { $0.id == attachmentId }
            signedURLCache.removeValue(forKey: attachmentId)
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: – Helpers

    private func observe(pending: PendingAttachmentUpload) async {
        // Poll the @Observable status; SwiftUI normally drives this but a
        // detached task needs to wait until completion before reloading.
        // We sleep in 200ms ticks because the upload completes on a
        // separate task and we just need a low-overhead wait here.
        for _ in 0..<600 { // up to ~2 min
            try? await Task.sleep(nanoseconds: 200_000_000)
            switch pending.status {
            case .completed:
                await reload()
                return
            case .failed:
                return
            default:
                continue
            }
        }
    }
}

/// Empty row used when Supabase returns the row payload but we don't
/// care about its fields. Decodes anything (including `{}`).
private struct SupabaseEmptyRow: Decodable, Sendable {}
