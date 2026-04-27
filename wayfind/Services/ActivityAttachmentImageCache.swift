//
//  ActivityAttachmentImageCache.swift
//  wayfind
//
//  Caches activity attachment image bytes by attachment id (stable) so reopening
//  ActivityPhotosSheet does not re-hit the network for every tile. Signed download
//  URLs rotate; the id does not.
//

import Foundation
import UIKit

actor ActivityAttachmentImageCache {
    static let shared = ActivityAttachmentImageCache()

    private var memory: [UUID: UIImage] = [:]
    private let folder: URL
    /// Rough cap to avoid unbounded RAM if a user opens many trips in one session.
    private let memoryEntryLimit = 48

    private init() {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        folder = base.appendingPathComponent("ActivityAttachmentImages", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    func image(for id: UUID) -> UIImage? {
        if let img = memory[id] { return img }
        let url = fileURL(for: id)
        guard let data = try? Data(contentsOf: url), let img = UIImage(data: data) else { return nil }
        insertIntoMemory(id: id, image: img)
        return img
    }

    func store(data: Data, for id: UUID) {
        let url = fileURL(for: id)
        try? data.write(to: url, options: .atomic)
        if let img = UIImage(data: data) {
            insertIntoMemory(id: id, image: img)
        }
    }

    func remove(for id: UUID) {
        memory.removeValue(forKey: id)
        try? FileManager.default.removeItem(at: fileURL(for: id))
    }

    private func fileURL(for id: UUID) -> URL {
        folder.appendingPathComponent("\(id.uuidString.lowercased()).img", isDirectory: false)
    }

    private func insertIntoMemory(id: UUID, image: UIImage) {
        if memory.count >= memoryEntryLimit, memory[id] == nil, let evict = memory.keys.first {
            memory.removeValue(forKey: evict)
        }
        memory[id] = image
    }
}
