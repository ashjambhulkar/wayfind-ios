//
//  AvatarRemoteImageCache.swift
//  wayfind
//
//  Memory + disk cache for remote avatar URLs (profile hero, edit preview,
//  collaborator stacks). `AsyncImage` always re-fetches; this stores bytes
//  under a stable key derived from the full URL so repeat visits are cheap.
//

import CryptoKit
import Foundation
import UIKit

actor AvatarRemoteImageCache {
    static let shared = AvatarRemoteImageCache()

    private var memory: [String: UIImage] = [:]
    private let memoryEntryLimit = 48
    private let folder: URL

    private init() {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        folder = base.appendingPathComponent("AvatarRemoteImages", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    func image(for url: URL) -> UIImage? {
        let key = Self.cacheKey(for: url)
        if let img = memory[key] { return img }
        let path = fileURL(forKey: key)
        guard let data = try? Data(contentsOf: path),
              let img = UIImage(data: data) else { return nil }
        insertIntoMemory(key: key, image: img)
        return img
    }

    func store(data: Data, for url: URL) {
        let key = Self.cacheKey(for: url)
        let path = fileURL(forKey: key)
        try? data.write(to: path, options: .atomic)
        if let img = UIImage(data: data) {
            insertIntoMemory(key: key, image: img)
        }
    }

    private func fileURL(forKey key: String) -> URL {
        folder.appendingPathComponent(Self.fileName(forKey: key), isDirectory: false)
    }

    private func insertIntoMemory(key: String, image: UIImage) {
        if memory.count >= memoryEntryLimit, memory[key] == nil, let evict = memory.keys.first {
            memory.removeValue(forKey: evict)
        }
        memory[key] = image
    }

    nonisolated static func cacheKey(for url: URL) -> String {
        url.absoluteString
    }

    nonisolated private static func fileName(forKey key: String) -> String {
        let digest = SHA256.hash(data: Data(key.utf8))
        return digest.map { String(format: "%02x", $0) }.joined() + ".img"
    }
}
