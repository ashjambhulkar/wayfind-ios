//
//  PlatformUsageTelemetry.swift
//  wayfind
//
//  Phase G.1 of the places-cost-and-owned-data plan.
//
//  Lightweight wrapper around `os_signpost` for every external
//  Google + MapKit call we make on-device. Two reasons we keep this
//  client-side rather than mirroring the server's RPC pipeline:
//
//    1. Instruments lights up out-of-the-box — `xcrun xctrace
//       record --template "Time Profiler"` captures these signposts
//       with zero extra plumbing, which is the fastest way to spot
//       a regression where some new view starts spamming MapKit.
//
//    2. We deliberately do NOT phone home from the device for every
//       autocomplete keystroke. The server already aggregates
//       `places_usage_events` from every Edge-Function-mediated
//       call; the iOS layer only needs *local* observability so an
//       engineer can confirm "yes, this view triggered N MapKit
//       calls" during dev/QA without burning network or battery.
//
//  Categories mirror the server's `api` column so a developer can
//  flip between Instruments and the cost dashboard without context-
//  switching the vocabulary.
//

import Foundation
import os.signpost

enum PlatformUsageTelemetry {
    /// Logical API name. Mirrors the server's `places_usage_events.api`
    /// column so signpost names align with dashboard rows.
    enum API: String {
        case mkLocalSearchCompleter = "mk_local_search_completer"
        case mkLocalSearch          = "mk_local_search"
        case mkDirections           = "mk_directions"
        case googleAutocomplete     = "google_autocomplete"
        case googlePlaceDetails     = "google_place_details"
        case lookupPlaceIdEdge      = "lookup_place_id_edge"
        case uploadTravelLegEdge    = "upload_travel_leg_edge"
    }

    /// Coarse outcome classifier. Mirrors `places_usage_events.status`.
    enum Status: String {
        case ok
        case empty
        case error
        case rateLimited = "rate_limited"
        case skipped
        case cached
    }

    /// Signpost subsystem. Filter Instruments by this to see only
    /// our externally-billed calls.
    private static let log = OSLog(
        subsystem: "app.wayfind.usage",
        category: "PlacesAPI"
    )

    /// Emits a one-shot `event` signpost. Use for completed calls
    /// where we don't need start/end pairing.
    static func record(_ api: API, status: Status, count: Int = 1) {
        os_signpost(
            .event,
            log: log,
            name: "PlacesAPI",
            "api=%{public}s status=%{public}s n=%{public}d",
            api.rawValue,
            status.rawValue,
            count
        )
    }

    /// Begin a long-running interval (e.g. a network call). Pair with
    /// the returned id passed back to `end(_:)`.
    static func begin(_ api: API) -> OSSignpostID {
        let id = OSSignpostID(log: log)
        os_signpost(
            .begin,
            log: log,
            name: "PlacesAPI",
            signpostID: id,
            "api=%{public}s",
            api.rawValue
        )
        return id
    }

    /// End an interval started by `begin(_:)`.
    static func end(_ api: API, id: OSSignpostID, status: Status) {
        os_signpost(
            .end,
            log: log,
            name: "PlacesAPI",
            signpostID: id,
            "api=%{public}s status=%{public}s",
            api.rawValue,
            status.rawValue
        )
    }

    // MARK: - Map search redesign events
    //
    // Free-form `event` signposts on a separate category so an engineer
    // running Instruments on Map Search Redesign can isolate the UX
    // funnel events from raw API call counts.

    enum MapSearchEvent: String {
        case previewShown          = "preview_shown"
        case addToDayTapped        = "add_to_day_tapped"
        case searchThisAreaTapped  = "search_this_area_tapped"
        case lookAroundFetched     = "look_around_fetched"
        case bridgeResolved        = "bridge_resolved"
        case bridgeSkippedOwnedRow = "bridge_skipped_owned_row"
        case dbResultMerged        = "db_result_merged"
        case dbResultDeduped       = "db_result_deduped"
    }

    private static let mapSearchLog = OSLog(
        subsystem: "app.wayfind.usage",
        category: "MapSearch"
    )

    /// Record a discrete map-search funnel event. Optional `origin`
    /// surfaces in Instruments so we can split previewShown by Apple
    /// vs cityPlaces.
    static func mapSearch(
        _ event: MapSearchEvent,
        origin: MapSearchPreview.Origin? = nil
    ) {
        if let origin {
            os_signpost(
                .event,
                log: mapSearchLog,
                name: "MapSearch",
                "event=%{public}s origin=%{public}s",
                event.rawValue,
                origin.rawValue
            )
        } else {
            os_signpost(
                .event,
                log: mapSearchLog,
                name: "MapSearch",
                "event=%{public}s",
                event.rawValue
            )
        }
    }
}
