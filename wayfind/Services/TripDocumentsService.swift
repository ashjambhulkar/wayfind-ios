//
//  TripDocumentsService.swift
//  wayfind
//
//  Wave 1.4 — owner of `trip_documents` for one trip. Sibling of
//  `BookingAttachmentService` and `ExpenseAttachmentService`. Uses the
//  shared upload chassis (commit-attachment + BackgroundUploader +
//  ImageProcessor + PDFThumbnailService) so the *only* surface-specific
//  knowledge is which table / bucket / parent column to write.
//
//  Pro-gating policy (Wave 4.5 — hard gate):
//    * Free users: HARD 5 docs / user / trip cap + 25 docs / trip
//      ceiling. The per-user cap is a paywall trigger; the UI
//      intercepts the FAB tap and presents the paywall via
//      `PaywallPresenter`. The service still throws `userQuotaReached`
//      as a defence-in-depth check in case a caller bypasses the UI
//      (e.g. resumed background upload from a Pro user who churned
//      after enqueue).
//    * Pro users: only the 25 docs / trip ceiling applies. Pro is a
//      "no per-user limit" unlock, not "more storage" — both tiers
//      share the trip ceiling.
//    * The service surfaces both numbers via `quotaSnapshot` so the
//      UI can show the upgrade pill without re-querying the row count.
//

import Foundation
import Observation
import Supabase

enum DocumentCategory: String, CaseIterable, Identifiable, Sendable {
    case visa
    case insurance
    case lodging
    case flight
    case transport
    case tickets
    case other

    var id: String { rawValue }

    var displayLabel: String {
        switch self {
        case .visa: return "Visa"
        case .insurance: return "Insurance"
        case .lodging: return "Lodging"
        case .flight: return "Flight"
        case .transport: return "Transport"
        case .tickets: return "Tickets"
        case .other: return "Other"
        }
    }

    var sfSymbol: String {
        switch self {
        case .visa: return "person.text.rectangle"
        case .insurance: return "cross.case"
        case .lodging: return "bed.double"
        case .flight: return "airplane"
        case .transport: return "tram"
        case .tickets: return "ticket"
        case .other: return "doc"
        }
    }
}

struct TripDocument: Identifiable, Hashable, Sendable {
    let id: UUID
    let tripId: UUID
    let uploadedBy: UUID
    let storagePath: String
    let fileName: String
    let mimeType: String
    let byteSize: Int
    let title: String?
    let category: DocumentCategory?
    let createdAt: Date
    var signedURL: URL?

    var isImage: Bool { mimeType.lowercased().hasPrefix("image/") }
    var isPDF: Bool { mimeType.lowercased() == "application/pdf" }

    var displayTitle: String {
        if let t = title, !t.isEmpty { return t }
        return fileName
    }

    var sizeLabel: String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(byteSize))
    }
}

struct TripDocumentQuotaSnapshot: Sendable {
    let perUserUploadCount: Int
    let perUserSoftLimit: Int
    let totalUploadCount: Int
    let totalCeiling: Int

    var hitsPerUserSoftLimit: Bool { perUserUploadCount >= perUserSoftLimit }
    var hitsHardCeiling: Bool { totalUploadCount >= totalCeiling }
}

enum TripDocumentError: LocalizedError, Sendable {
    case ceilingReached
    /// Wave 4.5 — Free user attempted an upload while at or above
    /// `perUserSoftLimit`. The UI intercepts this with the paywall
    /// before the call gets here; this error path is for defensive
    /// catches (background-resumed upload after entitlement change,
    /// scripted automation, etc).
    case userQuotaReached
    case noClient

    var errorDescription: String? {
        switch self {
        case .ceilingReached:
            return String(
                localized: "This trip already has \(TripDocumentsService.tripCeiling) documents. Delete some to add more.",
                comment: "Error shown when ANY user (Free or Pro) tries to upload past the per-trip document ceiling. The interpolated value is the ceiling count (currently 25)."
            )
        case .userQuotaReached:
            return String(
                localized: "You've reached the free plan limit of \(TripDocumentsService.perUserSoftLimit) documents per trip. Upgrade to Wayfind Pro to add more.",
                comment: "Error shown to free users hitting the per-user document cap. Interpolated value is the cap (currently 5). Defence-in-depth path — UI normally intercepts before this error fires."
            )
        case .noClient:
            return String(
                localized: "Sign in to add documents.",
                comment: "Shown when the documents service tries to mutate without an authenticated session."
            )
        }
    }
}

@MainActor
@Observable
final class TripDocumentsService {
    static let perUserSoftLimit: Int = 5
    static let tripCeiling: Int = 25

    let tripId: UUID
    let currentUserId: UUID

    private let dataService: DataService
    private var signedURLCache: [UUID: (url: URL, expiry: Date)] = [:]

    private(set) var documents: [TripDocument] = []
    private(set) var isLoading: Bool = false
    private(set) var lastError: String?

    var searchText: String = ""
    var selectedCategory: DocumentCategory?

    init(tripId: UUID, currentUserId: UUID, dataService: DataService) {
        self.tripId = tripId
        self.currentUserId = currentUserId
        self.dataService = dataService
    }

    var quotaSnapshot: TripDocumentQuotaSnapshot {
        let mine = documents.filter { $0.uploadedBy == currentUserId }.count
        return TripDocumentQuotaSnapshot(
            perUserUploadCount: mine,
            perUserSoftLimit: Self.perUserSoftLimit,
            totalUploadCount: documents.count,
            totalCeiling: Self.tripCeiling
        )
    }

    var filteredDocuments: [TripDocument] {
        let trimmed = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        return documents.filter { doc in
            if let selectedCategory, doc.category != selectedCategory { return false }
            if !trimmed.isEmpty {
                let hay = "\(doc.displayTitle) \(doc.fileName)".lowercased()
                if !hay.contains(trimmed) { return false }
            }
            return true
        }
    }

    func reload() async {
        guard let client = AuthSessionService.shared.client else {
            documents = []
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            struct Row: Decodable {
                let id: String
                let trip_id: String
                let uploaded_by: String
                let storage_path: String
                let file_name: String
                let mime_type: String
                let byte_size: Int
                let title: String?
                let category: String?
                let created_at: String
            }
            let rows: [Row] = try await client
                .from("trip_documents")
                .select("id, trip_id, uploaded_by, storage_path, file_name, mime_type, byte_size, title, category, created_at")
                .eq("trip_id", value: tripId.uuidString.lowercased())
                .order("created_at", ascending: false)
                .execute()
                .value
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let isoFallback = ISO8601DateFormatter()
            isoFallback.formatOptions = [.withInternetDateTime]
            documents = rows.compactMap { row in
                guard let id = UUID(uuidString: row.id),
                      let tripId = UUID(uuidString: row.trip_id),
                      let userId = UUID(uuidString: row.uploaded_by) else { return nil }
                let createdAt = iso.date(from: row.created_at) ?? isoFallback.date(from: row.created_at) ?? Date()
                return TripDocument(
                    id: id,
                    tripId: tripId,
                    uploadedBy: userId,
                    storagePath: row.storage_path,
                    fileName: row.file_name,
                    mimeType: row.mime_type,
                    byteSize: row.byte_size,
                    title: row.title,
                    category: row.category.flatMap { DocumentCategory(rawValue: $0) },
                    createdAt: createdAt,
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
        documents = documents.map { doc in
            var c = doc
            if let cached = signedURLCache[doc.id], cached.expiry > now {
                c.signedURL = cached.url
            }
            return c
        }
        let pending = documents.enumerated().filter { _, d in d.signedURL == nil }
        guard !pending.isEmpty else { return }
        await withTaskGroup(of: (Int, URL?).self) { group in
            for (idx, doc) in pending {
                group.addTask {
                    do {
                        let url = try await client.storage
                            .from("trip-documents")
                            .createSignedURL(path: doc.storagePath, expiresIn: 60 * 60)
                        return (idx, url)
                    } catch {
                        return (idx, nil)
                    }
                }
            }
            for await (idx, url) in group {
                guard idx < documents.count else { continue }
                if let url {
                    let expiry = now.addingTimeInterval(50 * 60)
                    signedURLCache[documents[idx].id] = (url, expiry)
                    documents[idx].signedURL = url
                }
            }
        }
    }

    @discardableResult
    func upload(
        bytes: Data,
        mimeType: String,
        fileName: String,
        title: String?,
        category: DocumentCategory?
    ) async throws -> PendingAttachmentUpload {
        if quotaSnapshot.hitsHardCeiling {
            throw TripDocumentError.ceilingReached
        }
        // Wave 4.5 — defence-in-depth: free users hit the per-user
        // cap as a hard error here too. The UI normally intercepts
        // with the paywall before we get here, but a queued upload
        // that resumes after a Pro→Free transition needs to fail
        // cleanly rather than silently exceed the cap.
        if !EntitlementService.shared.hasPremiumAccess,
           quotaSnapshot.hitsPerUserSoftLimit
        {
            await dataService.recordProGateAttempt(
                gate: .documents,
                surface: "documents_service_blocked",
                metadata: [
                    "trip_id": tripId.uuidString,
                    "user_doc_count": "\(quotaSnapshot.perUserUploadCount)",
                    "trigger": "service_upload_blocked",
                ]
            )
            throw TripDocumentError.userQuotaReached
        }
        try AttachmentValidator.validate(data: bytes, mimeType: mimeType)
        let descriptor = AttachmentUploadDescriptor(
            surface: .tripDocument,
            parentId: tripId,
            tripId: tripId,
            fileName: fileName,
            mimeType: mimeType,
            bytes: bytes,
            attachmentType: nil,
            isCover: false,
            title: title,
            category: category?.rawValue
        )
        let pending = BackgroundUploader.shared.enqueue(
            descriptor: descriptor,
            dataService: dataService,
            displayName: title?.isEmpty == false ? title! : fileName
        )
        Task { [weak self] in await self?.observe(pending: pending) }
        return pending
    }

    func delete(documentId: UUID) async {
        guard let client = AuthSessionService.shared.client else { return }
        do {
            try await client
                .from("trip_documents")
                .delete()
                .eq("id", value: documentId.uuidString.lowercased())
                .execute()
            documents.removeAll { $0.id == documentId }
            signedURLCache.removeValue(forKey: documentId)
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
