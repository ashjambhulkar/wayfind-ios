//
//  CurrencyService.swift
//  wayfind
//
//  Wave 2.2b — exchange-rate fetcher + cache for the budget views.
//
//  Plan tags:
//    §2.2  CurrencyService (Frankfurter primary, daily on-disk cache,
//          yesterday-fallback if today not yet published)
//    §2.2a When Frankfurter doesn't list a code (AED today) we delegate
//          to the `currency-rates` Edge Function which fans out to
//          exchangerate.host as backup.
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

@MainActor
@Observable
final class CurrencyService {
    static let shared = CurrencyService()

    /// In-memory snapshots keyed by "BASE|DATE".
    private var snapshots: [String: CurrencyRateSnapshot] = [:]
    private let cacheDir: URL
    private let session: URLSession

    /// Flip this to false in tests to bypass the network entirely.
    var allowNetwork: Bool = true

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
            return inMemory
        }

        // 2. Disk snapshot for today.
        if let disk = readSnapshot(base: baseUpper, dateKey: todayKey),
           symbolsUpper.allSatisfy({ disk.rates[$0] != nil }) {
            snapshots["\(baseUpper)|\(todayKey)"] = disk
            return disk
        }

        // 3. Network — today.
        if allowNetwork {
            if let fresh = try? await fetch(base: baseUpper, symbols: symbolsUpper, dateKey: todayKey) {
                writeSnapshot(fresh)
                snapshots["\(baseUpper)|\(todayKey)"] = fresh
                return fresh
            }
            // 4. Network — yesterday.
            if let fresh = try? await fetch(base: baseUpper, symbols: symbolsUpper, dateKey: yesterdayKey) {
                writeSnapshot(fresh)
                snapshots["\(baseUpper)|\(yesterdayKey)"] = fresh
                return fresh
            }
        }

        // 5. Disk yesterday.
        if let yesterday = readSnapshot(base: baseUpper, dateKey: yesterdayKey),
           symbolsUpper.allSatisfy({ yesterday.rates[$0] != nil }) {
            snapshots["\(baseUpper)|\(yesterdayKey)"] = yesterday
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

    private func fetch(
        base: String,
        symbols: [String],
        dateKey: String
    ) async throws -> CurrencyRateSnapshot {
        // Try Frankfurter directly first because (a) we don't pay for
        // Edge Function invocations and (b) it's faster from European
        // POPs. Only fall back to our currency-rates function when we
        // detect a missing symbol.
        if let direct = try await fetchFrankfurter(base: base, symbols: symbols, dateKey: dateKey),
           symbols.allSatisfy({ direct.rates[$0] != nil }) {
            return direct
        }
        return try await fetchEdgeFunction(base: base, symbols: symbols, dateKey: dateKey)
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
