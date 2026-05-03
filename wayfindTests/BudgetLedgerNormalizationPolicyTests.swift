//
//  BudgetLedgerNormalizationPolicyTests.swift
//  wayfindTests
//

import XCTest
@testable import wayfind

final class BudgetLedgerNormalizationPolicyTests: XCTestCase {

    func testManualComposerUsesClientNormalization() {
        XCTAssertTrue(
            BudgetLedgerNormalizationPolicy.appliesClientTripLedgerNormalization(.manualComposer)
        )
    }

    func testIosBookingCompanionUsesClientNormalization() {
        XCTAssertTrue(
            BudgetLedgerNormalizationPolicy.appliesClientTripLedgerNormalization(.iosBookingCompanion)
        )
    }

    func testDatabaseAutoSyncDoesNotUseClientNormalization() {
        XCTAssertFalse(
            BudgetLedgerNormalizationPolicy.appliesClientTripLedgerNormalization(.databaseAutoSync)
        )
    }

    func testEmailImportForwardDoesNotUseClientNormalization() {
        XCTAssertFalse(
            BudgetLedgerNormalizationPolicy.appliesClientTripLedgerNormalization(.emailImportForward)
        )
    }

    func testUnknownSourceDoesNotUseClientNormalization() {
        XCTAssertFalse(
            BudgetLedgerNormalizationPolicy.appliesClientTripLedgerNormalization(.unknown)
        )
    }

    func testAllSourcesClassifiedExhaustively() {
        for source in BudgetExpenseWriteSource.allCases {
            _ = BudgetLedgerNormalizationPolicy.appliesClientTripLedgerNormalization(source)
            let note = BudgetLedgerNormalizationPolicy.engineeringNote(for: source)
            XCTAssertFalse(note.isEmpty, "Missing engineering note for \(source)")
        }
    }

    func testServerAutoSyncFlagDocumentsPR2Debt() {
        XCTAssertTrue(
            BudgetLedgerNormalizationPolicy.serverAutoSyncUsesBookingLineAsLedgerUntilPR2,
            "Flip to false when pr-2 lands and booking rows convert to trip cap currency."
        )
    }

    func testTripCapCurrencyChangeV1IsExplicitlyNoMassReconversion() {
        XCTAssertEqual(
            BudgetLedgerNormalizationPolicy.tripBudgetCapCurrencyChangeBehavior,
            .existingRowsUnchangedNewWritesUseNewCap
        )
    }

    func testEngineeringNotesMentionKeyRiskWords() {
        XCTAssertTrue(
            BudgetLedgerNormalizationPolicy.engineeringNote(for: .databaseAutoSync)
                .lowercased()
                .contains("pr-2")
        )
        XCTAssertTrue(
            BudgetLedgerNormalizationPolicy.engineeringNote(for: .unknown)
                .lowercased()
                .contains("unknown")
        )
    }

    // MARK: - pr-2 (booking sync vs trip cap)

    func testInferWriteSourceMapsAutoSyncedToDatabase() {
        let expense = makeExpense(isAutoSynced: true, currency: "EUR")
        XCTAssertEqual(BudgetLedgerNormalizationPolicy.inferWriteSource(from: expense), .databaseAutoSync)
    }

    func testInferWriteSourceMapsManualToComposer() {
        let expense = makeExpense(isAutoSynced: false, currency: "EUR")
        XCTAssertEqual(BudgetLedgerNormalizationPolicy.inferWriteSource(from: expense), .manualComposer)
    }

    func testBookingSyncedLedgerDiffersWhenCurrenciesMismatch() {
        let expense = makeExpense(isAutoSynced: true, currency: "GBP")
        XCTAssertTrue(
            BudgetLedgerNormalizationPolicy.bookingSyncedLedgerDiffersFromTripBudgetCap(
                expense: expense,
                tripBudgetCurrency: "USD"
            )
        )
    }

    func testBookingSyncedLedgerMatchesWhenSameAsTripCap() {
        let expense = makeExpense(isAutoSynced: true, currency: "usd")
        XCTAssertFalse(
            BudgetLedgerNormalizationPolicy.bookingSyncedLedgerDiffersFromTripBudgetCap(
                expense: expense,
                tripBudgetCurrency: "USD"
            )
        )
    }

    func testManualExpenseNeverTriggersBookingMismatchEvenIfCurrencyDiffers() {
        let expense = makeExpense(isAutoSynced: false, currency: "JPY")
        XCTAssertFalse(
            BudgetLedgerNormalizationPolicy.bookingSyncedLedgerDiffersFromTripBudgetCap(
                expense: expense,
                tripBudgetCurrency: "USD"
            )
        )
    }

    func testHasBookingSyncTripCapMismatchAggregates() {
        let usdAuto = makeExpense(isAutoSynced: true, currency: "USD")
        let eurAuto = makeExpense(isAutoSynced: true, currency: "EUR")
        let manualEur = makeExpense(isAutoSynced: false, currency: "EUR")
        XCTAssertTrue(
            BudgetLedgerNormalizationPolicy.hasBookingSyncTripCapMismatch(
                expenses: [usdAuto, eurAuto, manualEur],
                tripBudgetCurrency: "USD"
            )
        )
        XCTAssertFalse(
            BudgetLedgerNormalizationPolicy.hasBookingSyncTripCapMismatch(
                expenses: [usdAuto, manualEur],
                tripBudgetCurrency: "USD"
            )
        )
    }

    func testUserFacingExplanationMentionsNormalizedTripCap() {
        let text = BudgetLedgerNormalizationPolicy.userFacingBookingSyncTripCapMismatchExplanation(
            tripBudgetCurrency: " cad "
        )
        XCTAssertTrue(text.contains("CAD"))
        let cadOccurrences = text.components(separatedBy: "CAD").count - 1
        XCTAssertGreaterThanOrEqual(cadOccurrences, 2, text)
    }

    private let tripId = UUID()
    private let userId = UUID()

    // MARK: - pr-3 (trip cap currency change)

    func testTripCapCurrencyChangeSkipsConfirmWhenNoExpenses() {
        XCTAssertFalse(
            BudgetLedgerNormalizationPolicy.shouldConfirmTripCapCurrencyChange(
                previousCapCurrency: "USD",
                nextCapCurrency: "EUR",
                existingExpenseCount: 0
            )
        )
    }

    func testTripCapCurrencyChangeSkipsConfirmWhenIsoUnchanged() {
        XCTAssertFalse(
            BudgetLedgerNormalizationPolicy.shouldConfirmTripCapCurrencyChange(
                previousCapCurrency: "usd",
                nextCapCurrency: "USD",
                existingExpenseCount: 5
            )
        )
    }

    func testTripCapCurrencyChangeRequiresConfirmWhenIsoChangesWithExpenses() {
        XCTAssertTrue(
            BudgetLedgerNormalizationPolicy.shouldConfirmTripCapCurrencyChange(
                previousCapCurrency: "USD",
                nextCapCurrency: "JPY",
                existingExpenseCount: 1
            )
        )
    }

    func testTripCapCurrencyChangeConfirmationCopyMentionsBothIsos() {
        let text = BudgetLedgerNormalizationPolicy.userFacingTripCapCurrencyChangeConfirmationDetail(
            previousCapCurrency: "gbp",
            nextCapCurrency: " cad "
        )
        XCTAssertTrue(text.contains("GBP"))
        XCTAssertTrue(text.contains("CAD"))
    }

    // MARK: - pr-4 (manual edit: preserve vs refresh FX)

    func testPreserveLockedFxWhenSameOrigIsoAndSameExpenseDay() {
        let day = ExpenseDateFormatter.parse("2024-06-15")!
        let fx = Decimal(string: "1.085000")!
        let persisted = TripExpense(
            id: UUID(),
            tripId: tripId,
            userId: userId,
            payerUserId: userId,
            bookingId: nil,
            title: "Train",
            amount: 108.50,
            currencyCode: "USD",
            category: .transport,
            splitType: .equal,
            expenseDate: day,
            notes: nil,
            isAutoSynced: false,
            createdAt: nil,
            updatedAt: nil,
            originalAmount: 100,
            originalCurrencyCode: "EUR",
            fxRateAtCapture: fx,
            fxRateDate: day
        )
        let composer = TripExpense(
            id: persisted.id,
            tripId: tripId,
            userId: userId,
            payerUserId: userId,
            bookingId: nil,
            title: "Train ticket",
            amount: 120,
            currencyCode: "eur",
            category: .transport,
            splitType: .equal,
            expenseDate: day,
            notes: "note",
            isAutoSynced: false,
            createdAt: nil,
            updatedAt: nil
        )
        XCTAssertTrue(
            BudgetLedgerNormalizationPolicy.shouldPreserveLockedFxQuoteOnManualExpenseUpdate(
                persistedRow: persisted,
                composerEntry: composer,
                tripBudgetCurrency: "USD"
            )
        )
    }

    func testPreserveLockedFxFalseWhenExpenseDayChanges() {
        let oldDay = ExpenseDateFormatter.parse("2024-06-15")!
        let newDay = ExpenseDateFormatter.parse("2024-06-16")!
        let fx = Decimal(string: "1.1")!
        let persisted = TripExpense(
            id: UUID(),
            tripId: tripId,
            userId: userId,
            payerUserId: userId,
            bookingId: nil,
            title: "Meal",
            amount: 110,
            currencyCode: "USD",
            category: .food,
            splitType: .equal,
            expenseDate: oldDay,
            notes: nil,
            isAutoSynced: false,
            createdAt: nil,
            updatedAt: nil,
            originalAmount: 100,
            originalCurrencyCode: "EUR",
            fxRateAtCapture: fx,
            fxRateDate: oldDay
        )
        let composer = TripExpense(
            id: persisted.id,
            tripId: tripId,
            userId: userId,
            payerUserId: userId,
            bookingId: nil,
            title: "Meal",
            amount: 100,
            currencyCode: "EUR",
            category: .food,
            splitType: .equal,
            expenseDate: newDay,
            notes: nil,
            isAutoSynced: false,
            createdAt: nil,
            updatedAt: nil
        )
        XCTAssertFalse(
            BudgetLedgerNormalizationPolicy.shouldPreserveLockedFxQuoteOnManualExpenseUpdate(
                persistedRow: persisted,
                composerEntry: composer,
                tripBudgetCurrency: "USD"
            )
        )
    }

    func testPreserveLockedFxFalseWhenOriginalIsoChanges() {
        let day = ExpenseDateFormatter.parse("2024-03-01")!
        let fx = Decimal(string: "1.1")!
        let persisted = TripExpense(
            id: UUID(),
            tripId: tripId,
            userId: userId,
            payerUserId: userId,
            bookingId: nil,
            title: "X",
            amount: 110,
            currencyCode: "USD",
            category: .other,
            splitType: .equal,
            expenseDate: day,
            notes: nil,
            isAutoSynced: false,
            createdAt: nil,
            updatedAt: nil,
            originalAmount: 100,
            originalCurrencyCode: "EUR",
            fxRateAtCapture: fx,
            fxRateDate: day
        )
        let composer = TripExpense(
            id: persisted.id,
            tripId: tripId,
            userId: userId,
            payerUserId: userId,
            bookingId: nil,
            title: "X",
            amount: 100,
            currencyCode: "GBP",
            category: .other,
            splitType: .equal,
            expenseDate: day,
            notes: nil,
            isAutoSynced: false,
            createdAt: nil,
            updatedAt: nil
        )
        XCTAssertFalse(
            BudgetLedgerNormalizationPolicy.shouldPreserveLockedFxQuoteOnManualExpenseUpdate(
                persistedRow: persisted,
                composerEntry: composer,
                tripBudgetCurrency: "USD"
            )
        )
    }

    func testPreserveLockedFxFalseWhenPersistedRowIsAutoSynced() {
        let day = ExpenseDateFormatter.parse("2024-05-20")!
        let persisted = TripExpense(
            id: UUID(),
            tripId: tripId,
            userId: userId,
            payerUserId: userId,
            bookingId: UUID(),
            title: "Hotel",
            amount: 200,
            currencyCode: "EUR",
            category: .lodging,
            splitType: .full,
            expenseDate: day,
            notes: nil,
            isAutoSynced: true,
            createdAt: nil,
            updatedAt: nil,
            originalAmount: 200,
            originalCurrencyCode: "EUR",
            fxRateAtCapture: 1,
            fxRateDate: day
        )
        let composer = TripExpense(
            id: persisted.id,
            tripId: tripId,
            userId: userId,
            payerUserId: userId,
            bookingId: persisted.bookingId,
            title: "Hotel",
            amount: 200,
            currencyCode: "EUR",
            category: .lodging,
            splitType: .full,
            expenseDate: day,
            notes: "edited",
            isAutoSynced: true,
            createdAt: nil,
            updatedAt: nil
        )
        XCTAssertFalse(
            BudgetLedgerNormalizationPolicy.shouldPreserveLockedFxQuoteOnManualExpenseUpdate(
                persistedRow: persisted,
                composerEntry: composer,
                tripBudgetCurrency: "USD"
            )
        )
    }

    func testPreserveLockedFxFalseWhenLedgerCurrencyDiffersFromTripCap() {
        let day = ExpenseDateFormatter.parse("2024-07-01")!
        let persisted = TripExpense(
            id: UUID(),
            tripId: tripId,
            userId: userId,
            payerUserId: userId,
            bookingId: nil,
            title: "Legacy",
            amount: 100,
            currencyCode: "GBP",
            category: .other,
            splitType: .equal,
            expenseDate: day,
            notes: nil,
            isAutoSynced: false,
            createdAt: nil,
            updatedAt: nil,
            originalAmount: 100,
            originalCurrencyCode: "GBP",
            fxRateAtCapture: 1,
            fxRateDate: day
        )
        let composer = TripExpense(
            id: persisted.id,
            tripId: tripId,
            userId: userId,
            payerUserId: userId,
            bookingId: nil,
            title: "Legacy",
            amount: 100,
            currencyCode: "GBP",
            category: .other,
            splitType: .equal,
            expenseDate: day,
            notes: nil,
            isAutoSynced: false,
            createdAt: nil,
            updatedAt: nil
        )
        XCTAssertFalse(
            BudgetLedgerNormalizationPolicy.shouldPreserveLockedFxQuoteOnManualExpenseUpdate(
                persistedRow: persisted,
                composerEntry: composer,
                tripBudgetCurrency: "USD"
            )
        )
    }

    func testPreserveLockedFxFalseWhenComposerUsesTripCurrencyOnly() {
        let day = ExpenseDateFormatter.parse("2024-08-01")!
        let persisted = TripExpense(
            id: UUID(),
            tripId: tripId,
            userId: userId,
            payerUserId: userId,
            bookingId: nil,
            title: "Coffee",
            amount: 5,
            currencyCode: "USD",
            category: .food,
            splitType: .full,
            expenseDate: day,
            notes: nil,
            isAutoSynced: false,
            createdAt: nil,
            updatedAt: nil,
            originalAmount: 5,
            originalCurrencyCode: "USD",
            fxRateAtCapture: 1,
            fxRateDate: day
        )
        let composer = TripExpense(
            id: persisted.id,
            tripId: tripId,
            userId: userId,
            payerUserId: userId,
            bookingId: nil,
            title: "Coffee",
            amount: 6,
            currencyCode: "USD",
            category: .food,
            splitType: .full,
            expenseDate: day,
            notes: nil,
            isAutoSynced: false,
            createdAt: nil,
            updatedAt: nil
        )
        XCTAssertFalse(
            BudgetLedgerNormalizationPolicy.shouldPreserveLockedFxQuoteOnManualExpenseUpdate(
                persistedRow: persisted,
                composerEntry: composer,
                tripBudgetCurrency: "USD"
            )
        )
    }

    private func makeExpense(isAutoSynced: Bool, currency: String) -> TripExpense {
        TripExpense(
            id: UUID(),
            tripId: tripId,
            userId: userId,
            payerUserId: userId,
            bookingId: isAutoSynced ? UUID() : nil,
            title: "Line",
            amount: 100,
            currencyCode: currency,
            category: .other,
            splitType: .full,
            expenseDate: Date(),
            notes: nil,
            isAutoSynced: isAutoSynced,
            createdAt: nil,
            updatedAt: nil
        )
    }
}


// =============================================================================
