//
//  PlaceAttributionFormatter.swift
//  wayfind
//
//  Phase I.3 — Stateless helper that turns the raw `image_source` +
//  `thumbnail_attribution` + `ai_source_attribution` payload from
//  `city_places` into a small set of human-readable lines.
//
//  Why a separate file: this logic is reused by PlaceDetailSheet (visible
//  caption) and by FullscreenPhotoViewer's overlay (Phase F.5). Centralising
//  it means CC-BY-SA + DSA disclosure copy stays consistent and is easy to
//  unit test in isolation.
//
//  The formatter never invents text. If the underlying row has no
//  attribution data, it returns `[]` and the calling view should hide the
//  footer entirely — silence is the right answer for fully owned rows.
//

import Foundation

enum PlaceAttributionFormatter {
    /// Returns one line per non-empty attribution category.
    /// Order: photo first (most visible signal), then editorial sources.
    static func lines(
        imageSource: String?,
        thumbnailAttribution: String?,
        ai: SupabaseManager.JSONValue?
    ) -> [String] {
        var out: [String] = []

        if let line = photoLine(
            imageSource: imageSource,
            thumbnailAttribution: thumbnailAttribution
        ) {
            out.append(line)
        }

        for line in editorialLines(from: ai) {
            out.append(line)
        }

        return out
    }

    // MARK: – Photo

    private static func photoLine(
        imageSource: String?,
        thumbnailAttribution: String?
    ) -> String? {
        guard let imageSource else { return nil }
        switch imageSource {
        case "user":
            // We credit the uploader on the photo itself (carousel
            // attribution chip from F.5), so the footer just notes the
            // photo is community-sourced.
            return "Photo by Wayfind community"
        case "wikimedia":
            if let credit = thumbnailAttribution, !credit.isEmpty {
                return "Photo: \(credit)"
            }
            return "Photo via Wikimedia Commons (CC)"
        case "google", "serpapi":
            return "Photo via Google Maps"
        case "unknown":
            return nil
        default:
            return nil
        }
    }

    // MARK: – Editorial / AI

    /// Walks the `ai_source_attribution` payload and surfaces a tight
    /// caption per field. We don't dump every QID — we collapse to the
    /// host (`Wikidata`, `Wikivoyage`, `OpenStreetMap`) so the footer
    /// stays one line. Detail is recoverable from the JSON column for
    /// audit / DSA review.
    private static func editorialLines(
        from value: SupabaseManager.JSONValue?
    ) -> [String] {
        guard case let .object(root)? = value else { return [] }

        var hosts = Set<String>()
        for (_, fieldValue) in root {
            guard case let .object(fieldObj) = fieldValue,
                  case let .array(items)? = fieldObj["sources"] else {
                continue
            }
            for item in items {
                guard case let .string(s) = item else { continue }
                if let host = humanHost(for: s) { hosts.insert(host) }
            }
        }

        if hosts.isEmpty { return [] }
        // Stable display order so the footer doesn't jitter between
        // refreshes.
        let ordered = hosts
            .sorted()
            .joined(separator: ", ")
        return ["Info: \(ordered)"]
    }

    private static func humanHost(for source: String) -> String? {
        let lower = source.lowercased()
        if lower.hasPrefix("wikidata:") { return "Wikidata" }
        if lower.hasPrefix("wikivoyage:") { return "Wikivoyage" }
        if lower.hasPrefix("wikipedia:") { return "Wikipedia" }
        if lower.hasPrefix("wikimedia:") { return "Wikimedia" }
        if lower.hasPrefix("openstreetmap:") || lower.hasPrefix("osm:") {
            return "OpenStreetMap"
        }
        if lower.hasPrefix("openai:") || lower.hasPrefix("anthropic:") {
            return "AI summary"
        }
        // license:* / author:* are decorations that ride alongside a
        // real source line; we don't surface them as standalone hosts.
        if lower.hasPrefix("license:") || lower.hasPrefix("author:") {
            return nil
        }
        return nil
    }
}
