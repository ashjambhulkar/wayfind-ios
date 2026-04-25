//
//  ExpenseAttachmentService.swift
//  wayfind
//
//  Wave 1.3 — owner of all `trip_expense_attachments` reads + writes for
//  one expense. Sibling of `BookingAttachmentService`.
//
//  Surface differences vs. bookings:
//    • Soft cap of 5 receipts per expense (HIG: more than that and the
//      grid overflows; tax authorities don't ask for more either).
//    • The expense row may not exist yet when the user picks a receipt
//      (compose flow). Callers therefore upload AFTER `addExpense`
//      returns the row id; the picker just stages bytes in memory.
//

import Foundation
import Observation
import Supabase

struct ExpenseAttachment: Identifiable, Hashable, Sendable {
    let id: UUID
    let expenseId: UUID
    let storagePath: String
    let mimeType: String
    let originalFilename: String?
    let fileSizeBytes: Int?
    let createdAt: Date
    var signedURL: URL?

    var isImage: Bool { mimeType.lowercased().hasPrefix("image/") }
    var isPDF: Bool { mimeType.lowercased() == "application/pdf" }

    var displayName: String {
        if let n = originalFilename, !n.isEmpty { return n }
        return "Receipt"
    }
}

enum ExpenseAttachmentError: LocalizedError, Sendable {
    case quotaReached
    case underlying(String)

    var errorDescription: String? {
        switch self {
        case .quotaReached: return "You can attach up to 5 receipts per expense."
        case .underlying(let m): return m
        }
    }
}

@MainActor
@Observable
final class ExpenseAttachmentService {
    static let softCap: Int = 5

    let expenseId: UUID
    let tripId: UUID

    private let dataService: DataService
    private var signedURLCache: [UUID: (url: URL, expiry: Date)] = [:]

    private(set) var attachments: [ExpenseAttachment] = []
    private(set) var isLoading: Bool = false
    private(set) var lastError: String?

    init(expenseId: UUID, tripId: UUID, dataService: DataService) {
        self.expenseId = expenseId
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
                let expense_id: String
                let storage_path: String
                let mime_type: String?
                let original_filename: String?
                let file_size_bytes: Int?
                let created_at: String
            }
            let rows: [Row] = try await client
                .from("trip_expense_attachments")
                .select("id, expense_id, storage_path, mime_type, original_filename, file_size_bytes, created_at")
                .eq("expense_id", value: expenseId.uuidString.lowercased())
                .order("created_at", ascending: true)
                .execute()
                .value
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let isoFallback = ISO8601DateFormatter()
            isoFallback.formatOptions = [.withInternetDateTime]
            self.attachments = rows.compactMap { row in
                guard let id = UUID(uuidString: row.id),
                      let expId = UUID(uuidString: row.expense_id) else { return nil }
                let date = iso.date(from: row.created_at) ?? isoFallback.date(from: row.created_at) ?? Date()
                return ExpenseAttachment(
                    id: id,
                    expenseId: expId,
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
        attachments = attachments.map { att in
            var c = att
            if let cached = signedURLCache[att.id], cached.expiry > now {
                c.signedURL = cached.url
            }
            return c
        }
        let pending = attachments.enumerated().filter { _, att in att.signedURL == nil }
        guard !pending.isEmpty else { return }
        await withTaskGroup(of: (Int, URL?).self) { group in
            for (idx, att) in pending {
                group.addTask {
                    do {
                        let url = try await client.storage
                            .from("expense-receipts")
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

    @discardableResult
    func upload(
        bytes: Data,
        mimeType: String,
        fileName: String
    ) async throws -> PendingAttachmentUpload {
        if attachments.count >= Self.softCap {
            throw ExpenseAttachmentError.quotaReached
        }
        try AttachmentValidator.validate(data: bytes, mimeType: mimeType)
        let descriptor = AttachmentUploadDescriptor(
            surface: .tripExpenseAttachment,
            parentId: expenseId,
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
                .from("trip_expense_attachments")
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

/// Pending receipt staged in memory before the host expense exists. Used
/// by the AddExpenseSheet compose flow.
struct StagedReceipt: Identifiable, Sendable {
    let id: UUID = UUID()
    let bytes: Data
    let mimeType: String
    let fileName: String
}
