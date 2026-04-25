//
//  PlacePhotoUploadService.swift
//  wayfind
//
//  Phase F.6 — Service that owns the iOS side of the user-photo
//  moderation pipeline. Built around three guarantees:
//
//   1. Pre-flight quota check via `check_photo_upload_quota` RPC so we
//      never burn moderation cost on uploads we'd reject anyway.
//   2. On-device pre-screen using `SCSensitivityAnalyzer`
//      (SensitiveContentAnalysis framework) when available so obvious
//      NSFW content is rejected without ever leaving the device. Falls
//      back gracefully on devices that haven't enabled the feature
//      (Settings → Privacy & Security → Sensitive Content Warning).
//   3. Background `URLSession` upload to the `place-photos-quarantine`
//      bucket so the user can leave the screen — and the app — without
//      losing their upload.
//
//  After the upload completes we call `moderate-place-photo` Edge
//  Function. Its response drives the client-side state machine
//  (`PendingUpload` → approved / pending_review / rejected). Local UI
//  surfaces the in-flight + post-decision state immediately; the
//  PlaceDetailSheet picks up promoted photos via the Phase H.5 trigger
//  on its next .task refetch.
//

import Foundation
import Observation
import SensitiveContentAnalysis
import UIKit

/// One outstanding upload owned by the service. Mirrors
/// `place_user_photos.status` but adds local-only states (`uploading`,
/// `awaiting_moderation`).
@MainActor
@Observable
final class PendingUpload: Identifiable {
    enum Status: Equatable {
        case prescreening
        case uploading(progress: Double)
        case awaitingModeration
        case approved(publicURL: URL)
        case pendingReview(reason: String?)
        case rejected(reason: String, detail: String?)
        case failed(message: String)
    }

    let id: UUID = UUID()
    let cityPlaceId: UUID
    let placeName: String
    var status: Status
    /// Server-issued `place_user_photos.id` once the upload row has been
    /// inserted. Required for the DSA appeal flow (Phase F.7) — the
    /// rejection card surfaces an "Appeal" CTA that targets this id.
    var serverPhotoId: UUID?

    init(cityPlaceId: UUID, placeName: String, status: Status = .prescreening) {
        self.cityPlaceId = cityPlaceId
        self.placeName = placeName
        self.status = status
    }
}

/// Errors callers may surface to the UI via inline text. CSAM-suspect
/// rejections never reach this enum — the server's reject_reason='csam'
/// is funnelled into `.rejected(reason:"violates community guidelines")`
/// per the runbook (we never tell the uploader what tripped).
enum PlacePhotoUploadError: LocalizedError {
    case requiresSignedInBackend
    case quotaDenied(String)
    case localPrescreenFailed
    case couldNotReadImage
    case uploadFailed(String)
    case moderationFailed(String)

    var errorDescription: String? {
        switch self {
        case .requiresSignedInBackend:
            return "Photo uploads require signing in."
        case .quotaDenied(let reason):
            return Self.quotaCopy(for: reason)
        case .localPrescreenFailed:
            return "This photo can't be uploaded."
        case .couldNotReadImage:
            return "Couldn't read that photo. Try a different one."
        case .uploadFailed(let m), .moderationFailed(let m):
            return m
        }
    }

    private static func quotaCopy(for reason: String) -> String {
        switch reason {
        case "place_daily_cap":
            return "You've already uploaded a photo here today. Try again tomorrow."
        case "user_daily_cap":
            return "You've hit today's photo limit. Pro members can upload more."
        case "account_too_new":
            return "Photo uploads unlock 24 hours after sign-up."
        case "account_locked":
            return "This account can't upload photos right now."
        case "unknown_place":
            return "We don't have this place in our system yet."
        default:
            return "Photo upload is unavailable right now."
        }
    }
}

@MainActor
@Observable
final class PlacePhotoUploadService {
    private let dataService: DataService
    private(set) var pending: [PendingUpload] = []

    init(dataService: DataService) {
        self.dataService = dataService
    }

    /// Kicks off the entire pipeline for a freshly-picked image. The
    /// returned `PendingUpload` updates its `status` reactively as the
    /// pipeline progresses — the UI only needs to observe it.
    func upload(
        imageData: Data,
        cityPlaceId: UUID,
        placeName: String,
        exifLat: Double? = nil,
        exifLng: Double? = nil
    ) async -> PendingUpload {
        let pending = PendingUpload(cityPlaceId: cityPlaceId, placeName: placeName)
        self.pending.append(pending)

        // Step 1: quota check (server-authoritative).
        let quota = await dataService.checkPhotoUploadQuota(cityPlaceId: cityPlaceId)
        guard quota.allowed else {
            pending.status = .failed(message: PlacePhotoUploadError
                .quotaDenied(quota.reason)
                .localizedDescription)
            return pending
        }

        // Step 2: on-device pre-screen (best-effort).
        pending.status = .prescreening
        let blocked = await Self.runOnDevicePrescreen(imageData: imageData)
        if blocked {
            pending.status = .failed(message: PlacePhotoUploadError
                .localPrescreenFailed.localizedDescription)
            return pending
        }

        // Step 3: background upload to quarantine bucket + DB row insert.
        pending.status = .uploading(progress: 0)
        let result = await dataService.uploadQuarantinedPlacePhoto(
            cityPlaceId: cityPlaceId,
            imageData: imageData,
            exifLat: exifLat,
            exifLng: exifLng,
            progress: { p in
                Task { @MainActor in pending.status = .uploading(progress: p) }
            }
        )
        guard case .success(let upload) = result else {
            if case .failure(let err) = result {
                pending.status = .failed(message: err.localizedDescription)
            }
            return pending
        }

        pending.serverPhotoId = upload.photoId
        pending.status = .awaitingModeration

        // Step 4: trigger moderation. The Edge Function is synchronous —
        // it returns the final state of the row by the time it responds.
        let outcome = await dataService.invokeModeratePlacePhoto(photoId: upload.photoId)
        switch outcome {
        case .approved(let url):
            pending.status = .approved(publicURL: url)
        case .pendingReview(let reason):
            pending.status = .pendingReview(reason: reason)
        case .rejected(let reason, let detail):
            pending.status = .rejected(reason: reason, detail: detail)
        case .failure(let message):
            pending.status = .failed(message: message)
        }
        return pending
    }

    // MARK: – On-device pre-screen
    //
    // Apple's SensitiveContentAnalysis framework does on-device NSFW
    // classification when the user has Sensitive Content Warning enabled.
    // This is opt-in at the OS level and silently no-ops otherwise — we
    // treat that as "screen passed" and let server-side moderation handle
    // it. The point of doing it client-side is fast feedback for the 80%
    // of users who DO have the OS feature on and to keep server cost down.

    private static func runOnDevicePrescreen(imageData: Data) async -> Bool {
        let analyzer = SCSensitivityAnalyzer()
        let policy = analyzer.analysisPolicy
        guard policy != .disabled else { return false }
        guard let image = UIImage(data: imageData)?.cgImage else { return false }
        do {
            let response = try await analyzer.analyzeImage(image)
            return response.isSensitive
        } catch {
            // If the analyzer errors we DON'T block — server-side
            // moderation is the canonical gate.
            return false
        }
    }
}
