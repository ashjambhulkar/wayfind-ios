//
//  ExpenseCSVExporter.swift
//  wayfind
//
//  Wave 2.3 — Pro feature. Exports the trip's `trip_expenses` ledger
//  as a CSV file ready for hand-off to Excel, Google Sheets, Numbers,
//  YNAB, etc.
//
//  RFC 4180 compliance:
//    • CRLF (\r\n) line endings.
//    • Fields containing commas, quotes, CR or LF are wrapped in
//      double-quotes; embedded quotes are doubled-up.
//    • UTF-8 BOM (EF BB BF) is prepended so Excel-on-Windows opens the
//      file in UTF-8 instead of Windows-1252 (Numbers/Sheets ignore it).
//
//  Locale handling:
//    • Dates are written in ISO 8601 (YYYY-MM-DD) — language-neutral and
//      sorts lexicographically. We DO NOT use the user's locale here on
//      purpose; the user's home spreadsheet will reformat.
//    • Amounts are written with `.` as the decimal separator (en_US_POSIX)
//      so European users opening it in their localized Excel still get
//      machine-readable numbers (Excel auto-detects).
//
//  Pro gating: this entire path is Pro-only. The button is visible to
//  free users but routes them to the upsell sheet (Wave 4.5 flips it
//  hard). We log a `pro_gate_attempted` event when a free user taps the
//  CSV button so we can size demand.
//

import Foundation
import UIKit

enum ExpenseCSVExporter {
    /// Top-level entry point. Returns the URL of a temporary `.csv` file
    /// suitable for `UIActivityViewController` / `ShareLink`.
    /// The temp file is auto-cleaned by the OS after a few hours.
    static func export(
        expenses: [TripExpense],
        splits: [ExpenseSplit] = [],
        members: [TripCollaborator],
        tripName: String
    ) throws -> URL {
        let names = memberLookup(members)
        let csv = makeCSV(expenses: expenses, splits: splits, names: names)
        let url = temporaryURL(for: tripName)
        // BOM + CRLF body. Use .data(using:) to round-trip via UTF-8.
        var bytes = Data([0xEF, 0xBB, 0xBF])
        if let payload = csv.data(using: .utf8) {
            bytes.append(payload)
        }
        try bytes.write(to: url, options: .atomic)
        return url
    }

    /// Pure-string CSV body. Exposed `internal` for unit tests so we can
    /// assert escaping without touching the filesystem.
    static func makeCSV(
        expenses: [TripExpense],
        splits: [ExpenseSplit],
        names: [UUID: String]
    ) -> String {
        let header = [
            "Date",
            "Title",
            "Category",
            "Ledger amount",
            "Ledger currency",
            "Original amount",
            "Original currency",
            "FX rate (orig→ledger)",
            "FX date",
            "Paid by",
            "Split type",
            "Notes",
        ]
        var lines: [String] = [header.map(escape).joined(separator: ",")]

        // Sort by date ascending so the CSV reads chronologically.
        let sorted = expenses.sorted { $0.expenseDate < $1.expenseDate }
        for expense in sorted {
            let row: [String] = [
                isoDate(expense.expenseDate),
                expense.title,
                expense.category.displayLabel,
                amountString(expense.amount),
                expense.currencyCode.uppercased(),
                amountString(expense.originalAmount),
                expense.originalCurrencyCode.uppercased(),
                amountString(expense.fxRateAtCapture),
                isoDate(expense.fxRateDate),
                expense.payerUserId.flatMap { names[$0] } ?? "",
                expense.splitType.displayLabel,
                expense.notes ?? "",
            ]
            lines.append(row.map(escape).joined(separator: ","))
        }
        // RFC 4180 explicitly says CRLF; many naive parsers (Numbers,
        // Excel) silently fix LF-only files but the spec is the spec.
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    // MARK: - Internals

    /// Escape a single field. Lifts to a quoted string when ANY of:
    /// comma, quote, CR, LF appears.
    static func escape(_ raw: String) -> String {
        let needsQuoting = raw.contains(",")
            || raw.contains("\"")
            || raw.contains("\n")
            || raw.contains("\r")
        if !needsQuoting { return raw }
        let escaped = raw.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }

    private static func memberLookup(_ members: [TripCollaborator]) -> [UUID: String] {
        var dict: [UUID: String] = [:]
        for member in members {
            guard let uid = member.userId else { continue }
            dict[uid] = member.resolvedDisplayName
        }
        return dict
    }

    private static func isoDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    /// `Decimal` → fixed-point string with a dot separator regardless of
    /// the user's locale. Two decimal places (most consumer currencies)
    /// but trims trailing zeros for tidiness.
    private static func amountString(_ amount: Decimal) -> String {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.numberStyle = .decimal
        f.usesGroupingSeparator = false
        f.minimumFractionDigits = 2
        f.maximumFractionDigits = 6
        return f.string(from: amount as NSDecimalNumber) ?? "0"
    }

    private static func temporaryURL(for tripName: String) -> URL {
        let safeName = tripName
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let stamp: String = {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyyMMdd-HHmm"
            return f.string(from: Date())
        }()
        let label = safeName.isEmpty ? "wayfind-trip" : safeName
        let filename = "\(label) — expenses \(stamp).csv"
        return FileManager.default
            .temporaryDirectory
            .appendingPathComponent(filename)
    }
}
