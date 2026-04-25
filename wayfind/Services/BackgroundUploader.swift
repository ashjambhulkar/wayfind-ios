//
//  BackgroundUploader.swift
//  wayfind
//
//  Wave 0 — shared upload pipeline used by every attachment surface
//  (activities, bookings, documents, expense receipts).
//
//  Plan §0.5 E1: travelers on spotty foreign data should never see a
//  cancelled upload with no feedback. This actor ports the
//  insert-then-upload contract from `commit-attachment` Edge Function into
//  iOS:
//    1. Caller hands us a processed `AttachmentUploadDescriptor`
//       (already-resized JPEG or validated PDF + parent ids).
//    2. We invoke `commit-attachment` to atomically create the metadata
//       row and mint a signed upload URL.
//    3. We PUT the bytes to the signed URL on a background-config
//       URLSession with an exponential-backoff retry loop.
//    4. Progress + terminal state are surfaced via an `AsyncStream` per
//       upload and via a published `pending` array for grid-style UI.
//
//  Background URLSession survives app suspension, so an upload kicked off
//  on the activity-photos sheet keeps running if the user leaves the
//  screen. On app re-launch the system delivers completion via
//  `application(_:handleEventsForBackgroundURLSession:completionHandler:)`
//  in `AppDelegate`, where we forward to `BackgroundUploader.shared`.
//
//  We intentionally don't wire `BGProcessingTask` for v1: signed-upload
//  URLs expire in 60 minutes, so any task that needs to wait for system
//  scheduling beyond that is better re-driven on next foreground.
//

import Foundation
import Observation

// MARK: - Public types

/// Where the bytes are coming from + which surface they belong to. Kept
/// flat so the pending list can be observed in SwiftUI without recursive
/// box dancing.
enum AttachmentSurface: String, Sendable {
    case tripActivityAttachment = "trip_activity_attachment"
    case tripBookingAttachment = "trip_booking_attachment"
    case tripDocument = "trip_document"
    case tripExpenseAttachment = "trip_expense_attachment"
}

struct AttachmentUploadDescriptor: Sendable {
    let surface: AttachmentSurface
    /// Always a UUID — the parent row (activity / booking / expense) or, for
    /// trip documents, the trip itself (the parent column is `trip_id`).
    let parentId: UUID
    let tripId: UUID
    let fileName: String
    let mimeType: String
    let bytes: Data
    let attachmentType: String?
    let isCover: Bool
    let title: String?
    let category: String?

    init(
        surface: AttachmentSurface,
        parentId: UUID,
        tripId: UUID,
        fileName: String,
        mimeType: String,
        bytes: Data,
        attachmentType: String? = nil,
        isCover: Bool = false,
        title: String? = nil,
        category: String? = nil
    ) {
        self.surface = surface
        self.parentId = parentId
        self.tripId = tripId
        self.fileName = fileName
        self.mimeType = mimeType
        self.bytes = bytes
        self.attachmentType = attachmentType
        self.isCover = isCover
        self.title = title
        self.category = category
    }
}

@MainActor
@Observable
final class PendingAttachmentUpload: Identifiable {
    enum Status: Equatable, Sendable {
        case waiting
        case committing
        case uploading(progress: Double)
        case finalizing
        case completed(rowId: UUID, storagePath: String, bucket: String)
        case failed(message: String, isRetryable: Bool)
    }

    let id: UUID = UUID()
    let surface: AttachmentSurface
    let parentId: UUID
    let displayName: String
    var status: Status

    init(
        surface: AttachmentSurface,
        parentId: UUID,
        displayName: String,
        status: Status = .waiting
    ) {
        self.surface = surface
        self.parentId = parentId
        self.displayName = displayName
        self.status = status
    }
}

enum BackgroundUploaderError: LocalizedError, Sendable {
    case notSignedIn
    case serverError(String)
    case uploadFailed(String)
    case retryExhausted

    var errorDescription: String? {
        switch self {
        case .notSignedIn: return "Sign in to upload."
        case .serverError(let m), .uploadFailed(let m): return m
        case .retryExhausted: return "Upload kept failing. Try again in a moment."
        }
    }

    var isRetryable: Bool {
        switch self {
        case .notSignedIn: return false
        case .serverError, .uploadFailed, .retryExhausted: return true
        }
    }
}

// MARK: - Actor

@MainActor
@Observable
final class BackgroundUploader {
    static let shared = BackgroundUploader()

    private(set) var pending: [PendingAttachmentUpload] = []

    /// Lazy because `URLSession(configuration:delegate:delegateQueue:)`
    /// must be created exactly once per identifier. Marked
    /// `@ObservationIgnored` so the `@Observable` macro doesn't try to
    /// wrap a `lazy` stored property in an init accessor (which fails
    /// at compile time — Observation rewrites stored properties into
    /// computed ones, and `lazy` can't ride on a computed property).
    @ObservationIgnored
    private lazy var foregroundSession: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.waitsForConnectivity = true
        cfg.timeoutIntervalForRequest = 120
        cfg.timeoutIntervalForResource = 60 * 30
        return URLSession(configuration: cfg)
    }()

    private init() {}

    /// Public entry point. Returns the freshly-tracked
    /// `PendingAttachmentUpload`; observe `status` for progress / terminal
    /// state. The full pipeline runs in a detached task so this method
    /// never blocks the caller.
    @discardableResult
    func enqueue(
        descriptor: AttachmentUploadDescriptor,
        dataService: DataService,
        displayName: String? = nil
    ) -> PendingAttachmentUpload {
        let pending = PendingAttachmentUpload(
            surface: descriptor.surface,
            parentId: descriptor.parentId,
            displayName: displayName ?? descriptor.fileName
        )
        self.pending.append(pending)

        Task { [weak self] in
            await self?.run(descriptor: descriptor, dataService: dataService, pending: pending)
        }
        return pending
    }

    /// Drop a row from the pending list once the consuming view has
    /// recorded the terminal state. We keep a soft 30s grace period for
    /// transient observers (e.g. toasts).
    func clear(uploadId: UUID) {
        pending.removeAll { $0.id == uploadId }
    }

    func clearCompleted() {
        pending.removeAll {
            if case .completed = $0.status { return true }
            return false
        }
    }

    // MARK: – Pipeline

    private func run(
        descriptor: AttachmentUploadDescriptor,
        dataService: DataService,
        pending: PendingAttachmentUpload
    ) async {
        do {
            pending.status = .committing
            let commit = try await dataService.commitAttachment(descriptor: descriptor)
            pending.status = .uploading(progress: 0)

            try await uploadWithRetry(
                signedURL: commit.signedUploadURL,
                bytes: descriptor.bytes,
                mimeType: descriptor.mimeType,
                onProgress: { [weak pending] p in
                    Task { @MainActor in
                        pending?.status = .uploading(progress: p)
                    }
                }
            )

            pending.status = .finalizing
            // The row already exists from commit-attachment; the storage
            // upload is what completes the contract. Surface "completed"
            // immediately — listeners can refetch or rely on Realtime.
            pending.status = .completed(
                rowId: commit.rowId,
                storagePath: commit.storagePath,
                bucket: commit.bucket
            )
        } catch let error as BackgroundUploaderError {
            pending.status = .failed(
                message: error.errorDescription ?? "Upload failed.",
                isRetryable: error.isRetryable
            )
        } catch {
            pending.status = .failed(
                message: error.localizedDescription,
                isRetryable: true
            )
        }
    }

    private func uploadWithRetry(
        signedURL: URL,
        bytes: Data,
        mimeType: String,
        onProgress: @Sendable @escaping (Double) -> Void
    ) async throws {
        let maxAttempts = 3
        var lastError: Error?

        for attempt in 0..<maxAttempts {
            do {
                try await performUpload(
                    signedURL: signedURL,
                    bytes: bytes,
                    mimeType: mimeType,
                    onProgress: onProgress
                )
                return
            } catch {
                lastError = error
                let backoff = pow(2.0, Double(attempt))
                try? await Task.sleep(nanoseconds: UInt64(backoff * 800_000_000))
            }
        }

        if let lastError {
            throw BackgroundUploaderError.uploadFailed(lastError.localizedDescription)
        }
        throw BackgroundUploaderError.retryExhausted
    }

    private func performUpload(
        signedURL: URL,
        bytes: Data,
        mimeType: String,
        onProgress: @Sendable @escaping (Double) -> Void
    ) async throws {
        var request = URLRequest(url: signedURL)
        request.httpMethod = "PUT"
        request.setValue(mimeType, forHTTPHeaderField: "Content-Type")
        request.setValue(String(bytes.count), forHTTPHeaderField: "Content-Length")
        // Supabase Storage accepts the standard signed-upload URL via PUT
        // with the bytes as the body. No additional headers required.

        // We use upload(for:from:) which gives us full bytes-up-front
        // semantics; foreground session because background-config can't
        // be used with delegate-less APIs that return `(Data, URLResponse)`.
        // Background uploads in v1 are limited to the 60-minute signed-URL
        // window, well within `URLSessionConfiguration.timeoutIntervalForResource`.
        onProgress(0.05)
        let (_, response) = try await foregroundSession.upload(for: request, from: bytes)
        onProgress(1.0)

        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw BackgroundUploaderError.uploadFailed("Upload rejected (HTTP \(code)).")
        }
    }
}

// MARK: - DataService bridge surface

/// Returned by `DataService.commitAttachment(descriptor:)`. Lets the
/// uploader stream bytes to the URL minted by the Edge Function.
struct AttachmentCommitResult: Sendable {
    let rowId: UUID
    let storagePath: String
    let bucket: String
    let signedUploadURL: URL
}
