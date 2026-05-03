//
//  BudgetFxTelemetry.swift
//  wayfind
//
//  pr-6 — local Instruments signposts plus Sentry breadcrumbs (no high-volume
//  error capture) for FX fetch outcomes and save failures. Aligns with
//  `PlatformUsageTelemetry` patterns: subsystem `app.wayfind.budget`.
//

import Foundation
import os.signpost

enum BudgetFxTelemetry {

    enum QuoteProvider: String, Sendable {
        case frankfurter
        case edge
    }

    enum CacheLayer: String, Sendable {
        case memory
        case disk
    }

    enum NetworkDay: String, Sendable {
        case today
        case yesterday
    }

    enum FallbackKind: String, Sendable {
        case frankfurterToEdge = "frankfurter_to_edge"
        case frankfurterMissToEdge = "frankfurter_miss_to_edge"
        case networkTodayToYesterday = "network_today_to_yesterday"
        case diskYesterdayAfterNetworkMiss = "disk_yesterday_after_network_miss"
    }

    private static let signpostLog = OSLog(
        subsystem: "app.wayfind.budget",
        category: "FX"
    )

    private static let maxLatencyMsForTelemetry = 300_000

    // MARK: - Fetch

    static func recordCacheHit(
        layer: CacheLayer,
        base: String,
        quoteDate: String,
        symbolsCount: Int
    ) {
        let lat = 0
        emitSignpostFetchSuccess(
            cacheLayer: layer.rawValue,
            networkDay: "none",
            provider: "cache",
            latencyMs: lat,
            base: base,
            quoteDate: quoteDate,
            symbolsCount: symbolsCount,
            attempt: 0
        )
        ObservabilityService.breadcrumb(
            "fx_fetch_success",
            category: "budget_fx",
            level: .info,
            context: [
                "cache_layer": layer.rawValue,
                "base": base,
                "quote_date": quoteDate,
                "symbols_count": symbolsCount,
                "latency_ms": lat,
            ]
        )
    }

    static func recordNetworkFetchSuccess(
        day: NetworkDay,
        provider: QuoteProvider,
        latencyMs: Int,
        base: String,
        quoteDate: String,
        symbolsCount: Int,
        succeededOnAttempt: Int,
        frankfurterHadPayloadBeforeEdge: Bool
    ) {
        let clamped = clampLatency(latencyMs)
        emitSignpostFetchSuccess(
            cacheLayer: "none",
            networkDay: day.rawValue,
            provider: provider.rawValue,
            latencyMs: clamped,
            base: base,
            quoteDate: quoteDate,
            symbolsCount: symbolsCount,
            attempt: succeededOnAttempt
        )
        ObservabilityService.breadcrumb(
            "fx_fetch_success",
            category: "budget_fx",
            level: .info,
            context: [
                "network_day": day.rawValue,
                "provider": provider.rawValue,
                "latency_ms": clamped,
                "base": base,
                "quote_date": quoteDate,
                "symbols_count": symbolsCount,
                "network_attempt": succeededOnAttempt,
            ]
        )
        if provider == .edge {
            let kind: FallbackKind = frankfurterHadPayloadBeforeEdge
                ? .frankfurterToEdge
                : .frankfurterMissToEdge
            recordFetchFallback(kind: kind, base: base, quoteDate: quoteDate, symbolsCount: symbolsCount)
        }
    }

    static func recordFetchFallback(
        kind: FallbackKind,
        base: String,
        quoteDate: String,
        symbolsCount: Int
    ) {
        os_signpost(
            .event,
            log: signpostLog,
            name: "FX",
            "event=fx_fetch_fallback kind=%{public}s base=%{public}s date=%{public}s n=%{public}d",
            kind.rawValue,
            base,
            quoteDate,
            symbolsCount
        )
        ObservabilityService.breadcrumb(
            "fx_fetch_fallback",
            category: "budget_fx",
            level: .info,
            context: [
                "kind": kind.rawValue,
                "base": base,
                "quote_date": quoteDate,
                "symbols_count": symbolsCount,
            ]
        )
    }

    // MARK: - Save

    static func recordSaveBlocked(
        supportReference: String,
        base: String,
        quoteDate: String,
        symbolsCount: Int
    ) {
        os_signpost(
            .event,
            log: signpostLog,
            name: "FX",
            "event=fx_save_blocked ref=%{public}s base=%{public}s date=%{public}s n=%{public}d",
            supportReference,
            base,
            quoteDate,
            symbolsCount
        )
        ObservabilityService.breadcrumb(
            "fx_save_blocked",
            category: "budget_fx",
            level: .warning,
            context: [
                "support_reference": supportReference,
                "base": base,
                "quote_date": quoteDate,
                "symbols_count": symbolsCount,
            ]
        )
    }

    // MARK: - Private

    private static func clampLatency(_ raw: Int) -> Int {
        min(max(0, raw), maxLatencyMsForTelemetry)
    }

    private static func emitSignpostFetchSuccess(
        cacheLayer: String,
        networkDay: String,
        provider: String,
        latencyMs: Int,
        base: String,
        quoteDate: String,
        symbolsCount: Int,
        attempt: Int
    ) {
        os_signpost(
            .event,
            log: signpostLog,
            name: "FX",
            "event=fx_fetch_success cache=%{public}s day=%{public}s prov=%{public}s lat_ms=%{public}d base=%{public}s date=%{public}s n=%{public}d att=%{public}d",
            cacheLayer,
            networkDay,
            provider,
            latencyMs,
            base,
            quoteDate,
            symbolsCount,
            attempt
        )
    }
}


// =============================================================================
