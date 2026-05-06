//
//  ActivityAttachmentImageCache.swift
//  wayfind
//
//  Two-tier image cache for activity attachments keyed by stable attachment id.
//
//  Memory tier (NSCache): thread-safe, synchronously readable so SwiftUI views
//  can render cached images on the very first body call without a placeholder
//  flash. NSCache auto-evicts on memory pressure — no fixed entry limit.
//
//  Disk tier: persists across app launches in Caches/. Reads/writes are
//  serialized on a background queue.
//
//  The `image(for:)` method (async) checks memory first, then disk, promoting
//  disk hits into memory. The `cachedImage(for:)` method (sync) returns memory
//  hits only — use it from view init for zero-latency rendering.
//

import Foundation
import UIKit

final class ActivityAttachmentImageCache: @unchecked Sendable {
    static let shared = ActivityAttachmentImageCache()

    private let memory: NSCache<NSUUID, UIImage> = {
        let c = NSCache<NSUUID, UIImage>()
        // 64 MB soft cap — NSCache also evicts on system memory pressure.
        c.totalCostLimit = 64 * 1024 * 1024
        return c
    }()
    private let folder: URL
    private let diskQueue = DispatchQueue(label: "wayfind.attachment-image-cache.disk", qos: .utility)

    private init() {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        folder = base.appendingPathComponent("ActivityAttachmentImages", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    // MARK: - Synchronous memory access

    /// Synchronous memory-tier read. Returns nil on memory miss without touching disk.
    /// Safe to call from any thread, including view init.
    func cachedImage(for id: UUID) -> UIImage? {
        memory.object(forKey: id as NSUUID)
    }

    // MARK: - Async two-tier access

    /// Returns the cached image, checking memory first and disk second.
    /// Promotes disk hits into the memory tier.
    func image(for id: UUID) async -> UIImage? {
        if let img = cachedImage(for: id) { return img }
        return await withCheckedContinuation { (continuation: CheckedContinuation<UIImage?, Never>) in
            diskQueue.async {
                let url = self.fileURL(for: id)
                guard let data = try? Data(contentsOf: url), let img = UIImage(data: data) else {
                    continuation.resume(returning: nil)
                    return
                }
                self.insertIntoMemory(id: id, image: img, dataCount: data.count)
                continuation.resume(returning: img)
            }
        }
    }

    // MARK: - Writes

    /// Stores image bytes into both tiers. Disk write is performed asynchronously.
    func store(data: Data, for id: UUID) {
        if let img = UIImage(data: data) {
            insertIntoMemory(id: id, image: img, dataCount: data.count)
        }
        diskQueue.async {
            let url = self.fileURL(for: id)
            try? data.write(to: url, options: .atomic)
        }
    }

    func remove(for id: UUID) {
        memory.removeObject(forKey: id as NSUUID)
        diskQueue.async {
            try? FileManager.default.removeItem(at: self.fileURL(for: id))
        }
    }

    // MARK: - Private

    private func insertIntoMemory(id: UUID, image: UIImage, dataCount: Int) {
        memory.setObject(image, forKey: id as NSUUID, cost: dataCount)
    }

    private func fileURL(for id: UUID) -> URL {
        folder.appendingPathComponent("\(id.uuidString.lowercased()).img", isDirectory: false)
    }
}
