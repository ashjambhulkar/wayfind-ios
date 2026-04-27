//
//  ImageProcessor.swift
//  wayfind
//
//  Wave 0 — shared image pipeline used by every photo-upload surface
//  (activity attachments, booking attachments, expense receipts, trip
//  documents). Mirrors the conventions established by
//  `PlacePhotoUploadService` so user-facing behavior is consistent across
//  the app.
//
//  Pipeline guarantees, in order:
//    1. HEIC / HEIF → JPEG conversion (Apple Camera → Files-friendly).
//    2. EXIF GPS strip — we never upload location metadata implicitly.
//       (Lat/long that the user explicitly chose to attach is passed
//        alongside the bytes, not embedded in them.)
//    3. Long-edge downscale to `Constants.maxLongEdge` (2048 px).
//    4. JPEG re-encode at `Constants.jpegQuality` (0.8).
//    5. Hard 25 MB ceiling per plan §0.5 E4. Any input that re-encodes
//       larger than the cap is rejected — clients should never see this in
//       practice because the downscale + re-encode brings everything well
//       under 5 MB, but we keep the guard for defensive correctness.
//
//  Threading: the heavy work runs in `Task.detached(priority: .utility)`
//  so callers stay responsive even when batch-processing 5+ photos.
//

import Foundation
import ImageIO
import MobileCoreServices
import UIKit
import UniformTypeIdentifiers

/// Shared image-pipeline result. Bytes are always JPEG; `mimeType` is
/// always `image/jpeg`; `fileName` is a safe filename derived from the
/// caller-supplied source (or a default if none was provided).
struct ProcessedImage: Sendable {
    let data: Data
    let mimeType: String
    let fileName: String
    let width: Int
    let height: Int
}

enum ImageProcessorError: LocalizedError, Sendable {
    case emptyInput
    case unsupportedFormat
    case downscaleFailed
    case encodingFailed
    case sizeLimitExceeded(byteCount: Int, limit: Int)

    var errorDescription: String? {
        switch self {
        case .emptyInput:
            return "Couldn't read that photo. Try a different one."
        case .unsupportedFormat:
            return "That photo format isn't supported. JPEG, PNG, HEIC, or WebP only."
        case .downscaleFailed, .encodingFailed:
            return "Couldn't prepare the photo. Try again."
        case .sizeLimitExceeded(_, let limit):
            let mb = limit / (1024 * 1024)
            return "Photo is too large. Try one under \(mb) MB."
        }
    }
}

enum ImageProcessor {
    enum Constants {
        static let maxLongEdge: CGFloat = 1_600
        static let targetByteCount: Int = 1 * 1024 * 1024
        static let maxJpegQuality: CGFloat = 0.8
        static let minJpegQuality: CGFloat = 0.68
        static let jpegQualityStep: CGFloat = 0.04
        static let maxByteCount: Int = 25 * 1024 * 1024
        static let defaultFileName = "photo.jpg"
    }

    /// Run the full pipeline on `data`. Off main thread; safe to await
    /// directly from the UI layer.
    /// - Parameters:
    ///   - data: Source bytes — JPEG, PNG, HEIC, or WebP.
    ///   - sourceFileName: Original picker filename. We sanitize it and
    ///                     swap the extension to `.jpg`.
    static func process(
        data: Data,
        sourceFileName: String? = nil
    ) async throws -> ProcessedImage {
        try await Task.detached(priority: .utility) { () throws -> ProcessedImage in
            try processSync(data: data, sourceFileName: sourceFileName)
        }.value
    }

    // MARK: – Synchronous core (only call from a detached Task).

    private static func processSync(
        data: Data,
        sourceFileName: String?
    ) throws -> ProcessedImage {
        guard !data.isEmpty else { throw ImageProcessorError.emptyInput }

        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw ImageProcessorError.unsupportedFormat
        }

        // Honor EXIF orientation when decoding. Without this, photos taken
        // in portrait mode upload sideways on iPhone.
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: Constants.maxLongEdge,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
            throw ImageProcessorError.downscaleFailed
        }

        let uiImage = UIImage(cgImage: cg)
        let jpeg = try encodeJPEG(
            uiImage,
            targetByteCount: Constants.targetByteCount,
            maxQuality: Constants.maxJpegQuality,
            minQuality: Constants.minJpegQuality,
            step: Constants.jpegQualityStep
        )

        if jpeg.count > Constants.targetByteCount {
            // We intentionally keep the best result above the target rather
            // than over-compressing below the visual quality floor.
        }

        if jpeg.count > Constants.maxByteCount {
            throw ImageProcessorError.sizeLimitExceeded(
                byteCount: jpeg.count,
                limit: Constants.maxByteCount
            )
        }

        let safeName = sanitize(fileName: sourceFileName ?? Constants.defaultFileName)
        return ProcessedImage(
            data: jpeg,
            mimeType: "image/jpeg",
            fileName: safeName,
            width: cg.width,
            height: cg.height
        )
    }

    private static func encodeJPEG(
        _ image: UIImage,
        targetByteCount: Int,
        maxQuality: CGFloat,
        minQuality: CGFloat,
        step: CGFloat
    ) throws -> Data {
        var best: Data?
        var quality = maxQuality
        while quality >= minQuality {
            guard let candidate = image.jpegData(compressionQuality: quality) else {
                throw ImageProcessorError.encodingFailed
            }
            best = candidate
            if candidate.count <= targetByteCount {
                return candidate
            }
            quality -= step
        }

        guard let best else {
            throw ImageProcessorError.encodingFailed
        }
        return best
    }

    /// Strip directory components, replace whitespace + slashes, force the
    /// `.jpg` extension. We never want to embed the user's iCloud Drive path
    /// into a server-side filename column.
    private static func sanitize(fileName: String) -> String {
        let base = (fileName as NSString).lastPathComponent
        var stem = (base as NSString).deletingPathExtension
        stem = stem
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if stem.isEmpty { stem = "photo" }
        if stem.count > 80 { stem = String(stem.prefix(80)) }
        return "\(stem).jpg"
    }
}

// MARK: - Generic file validation (PDFs etc.)

/// Light-weight validator for non-image attachments (PDF, images that the
/// caller has already processed via `ImageProcessor`). Used by document /
/// booking-attachment surfaces before kicking off the upload.
enum AttachmentValidator {
    /// Plan §0.5 E4 MIME allowlist.
    static let allowedMimeTypes: Set<String> = [
        "image/jpeg",
        "image/png",
        "image/heic",
        "image/heif",
        "image/webp",
        "application/pdf",
    ]

    static let maxByteCount: Int = ImageProcessor.Constants.maxByteCount

    enum ValidationError: LocalizedError, Sendable {
        case emptyInput
        case unsupportedMime(String)
        case sizeLimitExceeded(byteCount: Int, limit: Int)

        var errorDescription: String? {
            switch self {
            case .emptyInput:
                return "That file is empty."
            case .unsupportedMime(let mime):
                return "Unsupported file type (\(mime)). Use JPEG, PNG, HEIC, WebP, or PDF."
            case .sizeLimitExceeded(_, let limit):
                let mb = limit / (1024 * 1024)
                return "File is too large. Try one under \(mb) MB."
            }
        }
    }

    static func validate(data: Data, mimeType: String) throws {
        guard !data.isEmpty else { throw ValidationError.emptyInput }
        guard allowedMimeTypes.contains(mimeType.lowercased()) else {
            throw ValidationError.unsupportedMime(mimeType)
        }
        if data.count > maxByteCount {
            throw ValidationError.sizeLimitExceeded(byteCount: data.count, limit: maxByteCount)
        }
    }

    /// Best-effort MIME inference from a UTType (returned by DocumentPicker).
    static func mimeType(for utType: UTType) -> String? {
        if utType.conforms(to: .pdf) { return "application/pdf" }
        if utType.conforms(to: .jpeg) { return "image/jpeg" }
        if utType.conforms(to: .png) { return "image/png" }
        if utType.conforms(to: .heic) || utType.identifier == "public.heic" { return "image/heic" }
        if utType.conforms(to: .webP) { return "image/webp" }
        return utType.preferredMIMEType
    }
}
