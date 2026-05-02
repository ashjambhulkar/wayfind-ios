//
//  PDFThumbnailService.swift
//  wayfind
//
//  Wave 0 — shared off-main PDF first-page renderer with on-disk SHA-256
//  cache. Used by `BookingAttachmentService`, `TripDocumentsView`, and any
//  future surface that previews PDFs in a list / grid.
//
//  Plan §0.5 C6 + Section 9.5: rendering happens on
//  `Task.detached(priority: .utility)` so a 50-document scroll never
//  stalls the main thread. Cache key is SHA-256 of `(storagePath + size)`
//  which means renaming a file in storage forces a re-render but keeps
//  the cache intact across launches.
//

import Foundation
import CryptoKit
import PDFKit
import UIKit

@MainActor
final class PDFThumbnailService {
    static let shared = PDFThumbnailService()

    /// In-memory mirror so the same row can render multiple times in a
    /// scroll session without touching disk.
    private var memoryCache: [String: UIImage] = [:]

    private let cacheDirectory: URL
    private let renderQueue = OperationQueue()

    private init() {
        renderQueue.maxConcurrentOperationCount = 2
        renderQueue.qualityOfService = .utility

        let base = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory
        cacheDirectory = base.appendingPathComponent("pdf-thumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    /// Render a thumbnail from the bytes of a PDF document. Returns nil
    /// gracefully on a corrupt / non-PDF input rather than throwing — the
    /// callers (list rows) treat nil as "fall back to icon".
    func thumbnail(
        for storagePath: String,
        bytes: Data,
        targetSize: CGSize = CGSize(width: 240, height: 320)
    ) async -> UIImage? {
        let key = cacheKey(storagePath: storagePath, size: targetSize)
        if let cached = memoryCache[key] { return cached }

        if let onDisk = readDiskCache(key: key) {
            memoryCache[key] = onDisk
            return onDisk
        }

        let rendered = await Self.render(bytes: bytes, targetSize: targetSize)
        if let rendered {
            memoryCache[key] = rendered
            writeDiskCache(image: rendered, key: key)
        }
        return rendered
    }

    /// Convenience: render directly from a remote URL (used by the
    /// documents list when the bytes are streamed from Storage).
    func thumbnail(
        for storagePath: String,
        remoteURL: URL,
        targetSize: CGSize = CGSize(width: 240, height: 320)
    ) async -> UIImage? {
        let key = cacheKey(storagePath: storagePath, size: targetSize)
        if let cached = memoryCache[key] { return cached }
        if let onDisk = readDiskCache(key: key) {
            memoryCache[key] = onDisk
            return onDisk
        }

        do {
            let (data, _) = try await URLSession.shared.data(from: remoteURL)
            return await thumbnail(for: storagePath, bytes: data, targetSize: targetSize)
        } catch {
            return nil
        }
    }

    func clearMemoryCache() {
        memoryCache.removeAll()
    }

    // MARK: – Disk cache plumbing

    private func cacheKey(storagePath: String, size: CGSize) -> String {
        let raw = "\(storagePath)|\(Int(size.width))x\(Int(size.height))"
        let hash = SHA256.hash(data: Data(raw.utf8))
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }

    private func diskURL(for key: String) -> URL {
        cacheDirectory.appendingPathComponent("\(key).png")
    }

    private func readDiskCache(key: String) -> UIImage? {
        let url = diskURL(for: key)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }

    private func writeDiskCache(image: UIImage, key: String) {
        guard let data = image.pngData() else { return }
        try? data.write(to: diskURL(for: key), options: .atomic)
    }

    // MARK: – Off-main render

    nonisolated private static func render(
        bytes: Data,
        targetSize: CGSize
    ) async -> UIImage? {
        await Task.detached(priority: .utility) { () -> UIImage? in
            guard let document = PDFDocument(data: bytes), let page = document.page(at: 0) else {
                return nil
            }
            let pageRect = page.bounds(for: .mediaBox)
            // Aspect-fit into the target size so the thumbnail keeps the
            // page proportions; the list cell crops as needed.
            let scale = min(targetSize.width / pageRect.width, targetSize.height / pageRect.height)
            let renderSize = CGSize(
                width: pageRect.width * scale,
                height: pageRect.height * scale
            )

            let renderer = UIGraphicsImageRenderer(size: renderSize)
            let image = renderer.image { ctx in
                UIColor.systemBackground.setFill()
                ctx.fill(CGRect(origin: .zero, size: renderSize))

                ctx.cgContext.translateBy(x: 0, y: renderSize.height)
                ctx.cgContext.scaleBy(x: scale, y: -scale)
                page.draw(with: .mediaBox, to: ctx.cgContext)
            }
            return image
        }.value
    }
}
