//
//  ExpenseCSVExporterTests.swift
//  wayfindTests
//
//  Wave 2.3 — RFC 4180 escaping is the part of CSV export most likely to
//  break user data. These tests pin down the exact escaping behaviour so
//  a future "tidy up the regex" refactor can't silently corrupt notes
//  containing commas, quotes, or newlines.
//
//  Coverage:
//    1. Bare strings pass through untouched.
//    2. Commas force quoting.
//    3. Embedded quotes are doubled-up AND wrapped in outer quotes.
//    4. Newlines (LF and CR) force quoting.
//    5. Header + body integration produces CRLF row separators.
//    6. UTF-8 BOM is the first three bytes of the on-disk file (Excel).
//

import XCTest
@testable import wayfind

final class ExpenseCSVExporterTests: XCTestCase {

    // MARK: - Field-level escaping

    func testPlainFieldIsNotQuoted() {
        XCTAssertEqual(ExpenseCSVExporter.escape("Lunch"), "Lunch")
    }

    func testFieldWithCommaIsQuoted() {
        XCTAssertEqual(
            ExpenseCSVExporter.escape("Coffee, croissant"),
            "\"Coffee, croissant\""
        )
    }

    func testFieldWithEmbeddedDoubleQuoteIsEscaped() {
        // RFC 4180: replace " with "" and wrap the whole field in quotes.
        XCTAssertEqual(
            ExpenseCSVExporter.escape("She said \"hi\""),
            "\"She said \"\"hi\"\"\""
        )
    }

    func testFieldWithNewlineIsQuoted() {
        XCTAssertEqual(
            ExpenseCSVExporter.escape("line1\nline2"),
            "\"line1\nline2\""
        )
    }

    func testFieldWithCarriageReturnIsQuoted() {
        XCTAssertEqual(
            ExpenseCSVExporter.escape("line1\rline2"),
            "\"line1\rline2\""
        )
    }

    func testEmptyFieldIsEmpty() {
        XCTAssertEqual(ExpenseCSVExporter.escape(""), "")
    }

    // MARK: - Body integration

    func testCSVUsesCRLFAndIncludesHeader() {
        let body = ExpenseCSVExporter.makeCSV(
            expenses: [],
            splits: [],
            names: [:]
        )
        // Header only + trailing CRLF.
        XCTAssertTrue(body.hasPrefix("Date,Title,Category,Amount,Currency,Paid by,Split type,Notes\r\n"))
        XCTAssertTrue(body.hasSuffix("\r\n"))
    }

    func testCSVQuotesNoteWithCommasAndNewlines() {
        let payer = UUID()
        let expense = TripExpense(
            id: UUID(),
            tripId: UUID(),
            userId: payer,
            payerUserId: payer,
            bookingId: nil,
            title: "Dinner, fancy",
            amount: Decimal(string: "82.50")!,
            currencyCode: "EUR",
            category: .food,
            splitType: .equal,
            expenseDate: Date(timeIntervalSince1970: 1_700_000_000), // 2023-11-14
            notes: "Note with,\nnewline and \"quotes\"",
            isAutoSynced: false,
            createdAt: nil,
            updatedAt: nil
        )

        let csv = ExpenseCSVExporter.makeCSV(
            expenses: [expense],
            splits: [],
            names: [payer: "Alice"]
        )

        // The fancy title contains a comma → must be quoted.
        XCTAssertTrue(csv.contains("\"Dinner, fancy\""))
        // The notes field should keep the newline INSIDE the quotes,
        // doubled-up internal quotes, and stay one CSV row.
        XCTAssertTrue(csv.contains("\"Note with,\nnewline and \"\"quotes\"\"\""))
        // Payer name resolved through the lookup.
        XCTAssertTrue(csv.contains(",Alice,"))
        // Decimal stays dot-separated regardless of host locale.
        XCTAssertTrue(csv.contains(",82.50,EUR,"))
    }

    func testExportWritesUTF8BOM() throws {
        let url = try ExpenseCSVExporter.export(
            expenses: [],
            splits: [],
            members: [],
            tripName: "Test Trip"
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let bytes = try Data(contentsOf: url)
        XCTAssertGreaterThanOrEqual(bytes.count, 3)
        XCTAssertEqual(bytes[0], 0xEF)
        XCTAssertEqual(bytes[1], 0xBB)
        XCTAssertEqual(bytes[2], 0xBF)
    }
}
