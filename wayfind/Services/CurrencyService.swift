//
//  CurrencyService.swift
//  wayfind
//
//  Wave 2.2b — exchange-rate fetcher + cache for the budget views.
//
//  Plan tags:
//    S2.2  CurrencyService (Frankfurter primary, daily on-disk cache,
//          yesterday-fallback if today not yet published; pr-5 retries)
//    S2.2a When Frankfurter doesn't list a code (AED today) we delegate
//          to the `currency-rates` Edge Function which fans out to
//          exchangerate.host as backup. In-app provider disclosure: Profile
//          → Exchange rate data (`ExchangeRateAttributionSheet`, pr-7).
//
//  Caching strategy:
//    • One JSON blob on disk per (base, date), pruned to the last 30 days.
//    • In-memory cache keyed by `(base, symbol)` → resolved rate.
//    • A "today" lookup first tries today's date; on 404 it tries
//      yesterday (Frankfurter publishes around 16:00 CET so morning
//      callers in Asia hit yesterday). The returned snapshot tells the
//      caller which date was actually used so the receipt-capture flow
//      can persist `fx_rate_at_capture` + `fx_rate_date` with the truth.
//
//  Pro-gating: the SERVICE itself is unrestricted (we want every user
//  to be able to convert at least one currency for receipts). What's
//  Pro is the *multi-currency budget header*, gated at the call site.
//
//  Resilience (pr-5): each network day fetch retries transient failures
//  with bounded backoff before falling back to yesterday / disk cache.
//
//  Cost (pr-8): identical in-flight network requests share one `Task`
//  (`CurrencyRateFetchDedupeKey`); at most two FX network sessions run
//  concurrently app-wide (permits). Supabase Edge volume: see
//  `currency-rates/index.ts` ops comment.
//

import Foundation
import Observation

struct CurrencyRateSnapshot: Sendable, Hashable {
    let base: String
    let date: String
    let rates: [String: Decimal]
    let usedFallbackProviders: [String]

    func rate(for code: String) -> Decimal? {
        rates[code.uppercased()]
    }
}

enum CurrencyServiceError: LocalizedError, Sendable {
    case noCoverage(String)
    case providerDown
    case malformedResponse

    var errorDescription: String? {
        switch self {
        case .noCoverage(let code): return "Couldn't find a rate for \(code)."
        case .providerDown: return "Exchange rates are unavailable. Try again later."
        case .malformedResponse: return "Got an unexpected response from the rates server."
        }
    }
}

private struct CurrencyNetworkFetchOutcome: Sendable {
    let snapshot: CurrencyRateSnapshot
    let provider: BudgetFxTelemetry.QuoteProvider
    let latencyMs: Int
    let succeededOnAttempt: Int
    let frankfurterHadPayloadBeforeEdge: Bool
}

@MainActor
@Observable
final class CurrencyService {
    static let shared = CurrencyService()

    /// In-memory snapshots keyed by "BASE|DATE".
    private var snapshots: [String: CurrencyRateSnapshot] = [:]
    private let cacheDir: URL
    private let session: URLSession

    /// pr-8 — coalesce concurrent identical network fetches (see `CurrencyRateFetchDedupeKey`).
    private var networkInflight: [String: Task<CurrencyNetworkFetchOutcome?, Never>] = [:]

    /// pr-8 — counting semaphore for concurrent FX network stacks (Frankfurter + Edge).
    private var fxNetworkPermitsAvailable: Int = CurrencyService.maxConcurrentFXNetworkFetches
    private var fxNetworkWaiters: [CheckedContinuation<Void, Never>] = []

    /// Flip this to false in tests to bypass the network entirely.
    var allowNetwork: Bool = true

    private static let maxConcurrentFXNetworkFetches = 2

    private init() {
        let base = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory
        cacheDir = base.appendingPathComponent("currency-rates", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 16
        session = URLSession(configuration: config)
    }

    // MARK: - Public

    /// Fetch (or return cached) rates for the given symbols. Tries today,
    /// falls back to yesterday on 404. Always returns the snapshot the
    /// caller actually got — never throws unless every avenue fails.
    func rates(
        base: String,
        symbols: [String],
        date: Date = Date()
    ) async throws -> CurrencyRateSnapshot {
        let baseUpper = base.uppercased()
        let symbolsUpper = symbols.map { $0.uppercased() }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        let todayKey = formatter.string(from: date)
        let yesterdayKey = formatter.string(from: date.addingTimeInterval(-24 * 60 * 60))

        // 1. In-memory snapshot for today.
        if let inMemory = snapshots["\(baseUpper)|\(todayKey)"],
           symbolsUpper.allSatisfy({ inMemory.rates[$0] != nil }) {
            BudgetFxTelemetry.recordCacheHit(
                layer: .memory,
                base: baseUpper,
                quoteDate: inMemory.date,
                symbolsCount: symbolsUpper.count
            )
            return inMemory
        }

        // 2. Disk snapshot for today.
        if let disk = readSnapshot(base: baseUpper, dateKey: todayKey),
           symbolsUpper.allSatisfy({ disk.rates[$0] != nil }) {
            snapshots["\(baseUpper)|\(todayKey)"] = disk
            BudgetFxTelemetry.recordCacheHit(
                layer: .disk,
                base: baseUpper,
                quoteDate: disk.date,
                symbolsCount: symbolsUpper.count
            )
            return disk
        }

        // 3. Network — today.
        if allowNetwork {
            if let outcome = await fetchSnapshotWithRetries(
                base: baseUpper,
                symbols: symbolsUpper,
                dateKey: todayKey
            ) {
                writeSnapshot(outcome.snapshot)
                snapshots["\(baseUpper)|\(todayKey)"] = outcome.snapshot
                BudgetFxTelemetry.recordNetworkFetchSuccess(
                    day: .today,
                    provider: outcome.provider,
                    latencyMs: outcome.latencyMs,
                    base: baseUpper,
                    quoteDate: outcome.snapshot.date,
                    symbolsCount: symbolsUpper.count,
                    succeededOnAttempt: outcome.succeededOnAttempt,
                    frankfurterHadPayloadBeforeEdge: outcome.frankfurterHadPayloadBeforeEdge
                )
                return outcome.snapshot
            }
            // 4. Network — yesterday.
            if let outcome = await fetchSnapshotWithRetries(
                base: baseUpper,
                symbols: symbolsUpper,
                dateKey: yesterdayKey
            ) {
                writeSnapshot(outcome.snapshot)
                snapshots["\(baseUpper)|\(yesterdayKey)"] = outcome.snapshot
                BudgetFxTelemetry.recordFetchFallback(
                    kind: .networkTodayToYesterday,
                    base: baseUpper,
                    quoteDate: outcome.snapshot.date,
                    symbolsCount: symbolsUpper.count
                )
                BudgetFxTelemetry.recordNetworkFetchSuccess(
                    day: .yesterday,
                    provider: outcome.provider,
                    latencyMs: outcome.latencyMs,
                    base: baseUpper,
                    quoteDate: outcome.snapshot.date,
                    symbolsCount: symbolsUpper.count,
                    succeededOnAttempt: outcome.succeededOnAttempt,
                    frankfurterHadPayloadBeforeEdge: outcome.frankfurterHadPayloadBeforeEdge
                )
                return outcome.snapshot
            }
        }

        // 5. Disk yesterday.
        if let yesterday = readSnapshot(base: baseUpper, dateKey: yesterdayKey),
           symbolsUpper.allSatisfy({ yesterday.rates[$0] != nil }) {
            snapshots["\(baseUpper)|\(yesterdayKey)"] = yesterday
            BudgetFxTelemetry.recordFetchFallback(
                kind: .diskYesterdayAfterNetworkMiss,
                base: baseUpper,
                quoteDate: yesterday.date,
                symbolsCount: symbolsUpper.count
            )
            BudgetFxTelemetry.recordCacheHit(
                layer: .disk,
                base: baseUpper,
                quoteDate: yesterday.date,
                symbolsCount: symbolsUpper.count
            )
            return yesterday
        }

        throw CurrencyServiceError.providerDown
    }

    /// Convert `amount` from `fromCode` to `toCode`. Convenience built on
    /// top of `rates`. Returns nil if the snapshot is missing either code.
    func convert(
        amount: Decimal,
        from fromCode: String,
        to toCode: String,
        on date: Date = Date()
    ) async -> (amount: Decimal, snapshot: CurrencyRateSnapshot)? {
        let from = fromCode.uppercased()
        let to = toCode.uppercased()
        if from == to { return nil }
        do {
            // Quote in `from` so toCode is a 1:N rate against the source.
            let snap = try await rates(base: from, symbols: [to], date: date)
            guard let rate = snap.rate(for: to) else { return nil }
            return (amount * rate, snap)
        } catch {
            return nil
        }
    }

    // MARK: - Network

    /// Coalesces concurrent callers on the same dedupe key, then runs
    /// `fetchSnapshotWithRetriesPerformingNetwork` under a global FX
    /// concurrency cap (pr-8).
    private func fetchSnapshotWithRetries(
        base: String,
        symbols: [String],
        dateKey: String
    ) async -> CurrencyNetworkFetchOutcome? {
        let dedupeKey = CurrencyRateFetchDedupeKey.make(base: base, symbols: symbols, dateKey: dateKey)
        if let existing = networkInflight[dedupeKey] {
            return await existing.value
        }
        let task = Task { [dedupeKey] in
            defer { self.networkInflight.removeValue(forKey: dedupeKey) }
            return await self.fetchSnapshotWithRetriesPerformingNetwork(
                base: base,
                symbols: symbols,
                dateKey: dateKey
            )
        }
        networkInflight[dedupeKey] = task
        return await task.value
    }

    /// Retries the private `fetchWithMeta` entry point with backoff for flaky Wi‑Fi / cold DNS.
    private func fetchSnapshotWithRetriesPerformingNetwork(
        base: String,
        symbols: [String],
        dateKey: String
    ) async -> CurrencyNetworkFetchOutcome? {
        await acquireFXNetworkSlot()
        defer { releaseFXNetworkSlot() }
        let maxAttempts = CurrencyRateFetchRetryPolicy.maxAttempts
        for attempt in 0..<maxAttempts {
            let delay = CurrencyRateFetchRetryPolicy.preAttemptDelayNanoseconds(attemptIndex: attempt)
            if delay > 0 {
                try? await Task.sleep(nanoseconds: delay)
            }
            let started = Date()
            guard let packed = try? await fetchWithMeta(base: base, symbols: symbols, dateKey: dateKey) else {
                continue
            }
            let rawLatencyMs = Date().timeIntervalSince(started) * 1000
            let latencyMs: Int
            if rawLatencyMs.isFinite, rawLatencyMs >= 0 {
                latencyMs = min(Int(rawLatencyMs), 300_000)
            } else {
                latencyMs = 0
            }
            return CurrencyNetworkFetchOutcome(
                snapshot: packed.snapshot,
                provider: packed.provider,
                latencyMs: max(0, latencyMs),
                succeededOnAttempt: attempt + 1,
                frankfurterHadPayloadBeforeEdge: packed.frankfurterHadPayloadBeforeEdge
            )
        }
        return nil
    }

    private func acquireFXNetworkSlot() async {
        if fxNetworkPermitsAvailable > 0 {
            fxNetworkPermitsAvailable -= 1
            return
        }
        await withCheckedContinuation { continuation in
            fxNetworkWaiters.append(continuation)
        }
    }

    private func releaseFXNetworkSlot() {
        if let next = fxNetworkWaiters.first {
            fxNetworkWaiters.removeFirst()
            next.resume()
        } else {
            fxNetworkPermitsAvailable += 1
        }
    }

    private func fetchWithMeta(
        base: String,
        symbols: [String],
        dateKey: String
    ) async throws -> (
        snapshot: CurrencyRateSnapshot,
        provider: BudgetFxTelemetry.QuoteProvider,
        frankfurterHadPayloadBeforeEdge: Bool
    ) {
        // Try Frankfurter directly first because (a) we don't pay for
        // Edge Function invocations and (b) it's faster from European
        // POPs. Only fall back to our currency-rates function when we
        // detect a missing symbol.
        let frank = try await fetchFrankfurter(base: base, symbols: symbols, dateKey: dateKey)
        if let frank, symbols.allSatisfy({ frank.rates[$0] != nil }) {
            return (frank, .frankfurter, false)
        }
        let edgeSnap = try await fetchEdgeFunction(base: base, symbols: symbols, dateKey: dateKey)
        return (edgeSnap, .edge, frank != nil)
    }

    private func fetchFrankfurter(
        base: String,
        symbols: [String],
        dateKey: String
    ) async throws -> CurrencyRateSnapshot? {
        let path = dateKey == "latest" ? "latest" : dateKey
        let symbolsParam = symbols.joined(separator: ",")
        let url = URL(string: "https://api.frankfurter.app/\(path)?from=\(base)&to=\(symbolsParam)")!
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
        return decodeFrankfurter(data: data, base: base)
    }

    private func fetchEdgeFunction(
        base: String,
        symbols: [String],
        dateKey: String
    ) async throws -> CurrencyRateSnapshot {
        guard let baseURL = URL(string: AppConfig.supabaseURL) else {
            throw CurrencyServiceError.providerDown
        }
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.path = "/functions/v1/currency-rates"
        components.queryItems = [
            URLQueryItem(name: "base", value: base),
            URLQueryItem(name: "symbols", value: symbols.joined(separator: ",")),
            URLQueryItem(name: "date", value: dateKey == "latest" ? "latest" : dateKey),
        ]
        guard let url = components.url else { throw CurrencyServiceError.providerDown }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(AppConfig.supabaseAnonKey)", forHTTPHeaderField: "Authorization")
        request.setValue(AppConfig.supabaseAnonKey, forHTTPHeaderField: "apikey")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw CurrencyServiceError.providerDown
        }
        return try decodeEdge(data: data)
    }

    // MARK: - Decoding

    private func decodeFrankfurter(data: Data, base: String) -> CurrencyRateSnapshot? {
        struct Frank: Decodable {
            let date: String
            let rates: [String: Double]
        }
        guard let body = try? JSONDecoder().decode(Frank.self, from: data) else { return nil }
        let mapped = body.rates.mapValues { Decimal($0) }
        return CurrencyRateSnapshot(
            base: base,
            date: body.date,
            rates: mapped,
            usedFallbackProviders: []
        )
    }

    private func decodeEdge(data: Data) throws -> CurrencyRateSnapshot {
        struct Source: Decodable { let primary: String; let fallback: [String] }
        struct Edge: Decodable {
            let base: String
            let date: String
            let rates: [String: Double]
            let missing: [String]?
            let source: Source?
        }
        guard let body = try? JSONDecoder().decode(Edge.self, from: data) else {
            throw CurrencyServiceError.malformedResponse
        }
        let mapped = body.rates.mapValues { Decimal($0) }
        return CurrencyRateSnapshot(
            base: body.base.uppercased(),
            date: body.date,
            rates: mapped,
            usedFallbackProviders: body.source?.fallback ?? []
        )
    }

    // MARK: - Disk cache

    private func snapshotURL(base: String, dateKey: String) -> URL {
        cacheDir.appendingPathComponent("\(base)_\(dateKey).json")
    }

    private func readSnapshot(base: String, dateKey: String) -> CurrencyRateSnapshot? {
        let url = snapshotURL(base: base, dateKey: dateKey)
        guard let data = try? Data(contentsOf: url) else { return nil }
        struct Disk: Codable {
            let base: String
            let date: String
            let rates: [String: Double]
            let fallback: [String]
        }
        guard let body = try? JSONDecoder().decode(Disk.self, from: data) else { return nil }
        return CurrencyRateSnapshot(
            base: body.base,
            date: body.date,
            rates: body.rates.mapValues { Decimal($0) },
            usedFallbackProviders: body.fallback
        )
    }

    private func writeSnapshot(_ snap: CurrencyRateSnapshot) {
        struct Disk: Codable {
            let base: String
            let date: String
            let rates: [String: Double]
            let fallback: [String]
        }
        let payload = Disk(
            base: snap.base,
            date: snap.date,
            rates: snap.rates.mapValues { (NSDecimalNumber(decimal: $0)).doubleValue },
            fallback: snap.usedFallbackProviders
        )
        let url = snapshotURL(base: snap.base, dateKey: snap.date)
        if let data = try? JSONEncoder().encode(payload) {
            try? data.write(to: url, options: .atomic)
        }
        pruneOldSnapshots()
    }

    private func pruneOldSnapshots() {
        let cutoff = Date().addingTimeInterval(-30 * 24 * 60 * 60)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: cacheDir,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        for file in files {
            let attrs = try? file.resourceValues(forKeys: [.contentModificationDateKey])
            if let mtime = attrs?.contentModificationDate, mtime < cutoff {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }
}

// MARK: - Fetch retry (pr-5)

private enum CurrencyRateFetchRetryPolicy {
    static let maxAttempts = 3

    /// Delay **before** this zero-based attempt (0 = no sleep).
    static func preAttemptDelayNanoseconds(attemptIndex: Int) -> UInt64 {
        switch attemptIndex {
        case 0: return 0
        case 1: return 250_000_000
        default: return 750_000_000
        }
    }
}
