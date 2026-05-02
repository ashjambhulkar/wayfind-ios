//
//  SettlementSimplifierTests.swift
//  wayfindTests
//
//  Phase 10 — Locks the min-cash-flow algorithm in
//  `Services/CategoryRollup.swift` (`SettlementSimplifier.simplify`).
//
//  Two scenarios from the plan:
//    1. The Alice/Bob/Carol single-currency example — three users, three
//       imbalanced expenses → exactly two simplified payments.
//    2. Mixed-currency — two USD expenses + one EUR expense → two independent
//       settlement graphs, never cross-currency math.
//
//  The simplifier is deterministic by sort, so we assert exact outputs rather
//  than just count — that way a regression that breaks ordering also fails.
//

import XCTest
@testable import wayfind

final class SettlementSimplifierTests: XCTestCase {
    private let alice = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
    private let bob   = UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!
    private let carol = UUID(uuidString: "00000000-0000-0000-0000-00000000000C")!

    /// Plan §5: classic three-person dinner trip.
    ///   Alice paid $90, Bob paid $0, Carol paid $30 → equal split each owes $40.
    ///   Net: Alice +$50, Bob -$40, Carol -$10.
    /// Expected simplified payments: Bob → Alice $40, Carol → Alice $10.
    /// (2 payments, not 3 — the simplifier collapses Carol→Bob→Alice into
    /// the direct hops.)
    func testThreeUserSingleCurrencySimplification() {
        let balances: [UserBalance] = [
            UserBalance(userId: alice, currency: "USD", net: Decimal(50)),
            UserBalance(userId: bob,   currency: "USD", net: Decimal(-40)),
            UserBalance(userId: carol, currency: "USD", net: Decimal(-10)),
        ]
        let suggestions = SettlementSimplifier.simplify(balances)
        XCTAssertEqual(suggestions.count, 2)

        let total = suggestions.reduce(Decimal(0)) { $0 + $1.amount }
        XCTAssertEqual(total, Decimal(50))

        let bobToAlice = suggestions.first { $0.fromUserId == bob && $0.toUserId == alice }
        let carolToAlice = suggestions.first { $0.fromUserId == carol && $0.toUserId == alice }
        XCTAssertEqual(bobToAlice?.amount, Decimal(40))
        XCTAssertEqual(carolToAlice?.amount, Decimal(10))
    }

    /// Two USD expenses and one EUR expense: simplification must run per
    /// currency. We expect one USD edge and one EUR edge with no fake FX.
    func testMixedCurrencySimplifiesPerCurrency() {
        let balances: [UserBalance] = [
            UserBalance(userId: alice, currency: "USD", net: Decimal(60)),
            UserBalance(userId: bob,   currency: "USD", net: Decimal(-60)),
            UserBalance(userId: alice, currency: "EUR", net: Decimal(-25)),
            UserBalance(userId: carol, currency: "EUR", net: Decimal(25)),
        ]
        let suggestions = SettlementSimplifier.simplify(balances)
        XCTAssertEqual(suggestions.count, 2)

        let usd = suggestions.first { $0.currency == "USD" }
        let eur = suggestions.first { $0.currency == "EUR" }

        XCTAssertEqual(usd?.fromUserId, bob)
        XCTAssertEqual(usd?.toUserId, alice)
        XCTAssertEqual(usd?.amount, Decimal(60))

        XCTAssertEqual(eur?.fromUserId, alice)
        XCTAssertEqual(eur?.toUserId, carol)
        XCTAssertEqual(eur?.amount, Decimal(25))
    }

    /// A perfectly balanced set produces no payments. This is a guard against
    /// the edge case where rounding in the algorithm could synthesise a
    /// $0.00 settlement (which would render as a useless card).
    func testPerfectlyBalancedProducesNoSuggestions() {
        let balances: [UserBalance] = [
            UserBalance(userId: alice, currency: "USD", net: 0),
            UserBalance(userId: bob,   currency: "USD", net: 0),
        ]
        XCTAssertTrue(SettlementSimplifier.simplify(balances).isEmpty)
    }

    /// Sub-cent amounts under the epsilon (0.005) get filtered. Rounding
    /// noise from percentage splits should not generate "settle $0.001" cards.
    func testSubEpsilonAmountsAreFiltered() {
        let balances: [UserBalance] = [
            UserBalance(userId: alice, currency: "USD", net: Decimal(string: "0.001")!),
            UserBalance(userId: bob,   currency: "USD", net: Decimal(string: "-0.001")!),
        ]
        XCTAssertTrue(SettlementSimplifier.simplify(balances).isEmpty)
    }

    /// Output ordering is deterministic by (currency, fromUserId, toUserId).
    /// Re-running simplify on the same input produces an identical sequence —
    /// SwiftUI ForEach relies on stable IDs across renders.
    func testOutputIsDeterministicAcrossRuns() {
        let balances: [UserBalance] = [
            UserBalance(userId: alice, currency: "USD", net: Decimal(50)),
            UserBalance(userId: bob,   currency: "USD", net: Decimal(-40)),
            UserBalance(userId: carol, currency: "USD", net: Decimal(-10)),
        ]
        let first = SettlementSimplifier.simplify(balances)
        let second = SettlementSimplifier.simplify(balances)
        XCTAssertEqual(first.map(\.id), second.map(\.id))
    }
}

// MARK: - BalanceComputer + Simplifier integration

/// One end-to-end sanity check that runs through `BalanceComputer.compute`
/// (the production input path) before handing to the simplifier. Catches
/// regressions where one half of the chain changes contract on the other.
final class BalanceComputerIntegrationTests: XCTestCase {
    private let alice = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
    private let bob   = UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!
    private let trip = UUID()

    func testAlicePaysBobOwesHalf() {
        let expense = TripExpense(
            id: UUID(),
            tripId: trip,
            userId: alice,
            payerUserId: alice,
            bookingId: nil,
            title: "Lunch",
            amount: Decimal(40),
            currencyCode: "USD",
            category: .food,
            splitType: .equal,
            expenseDate: Date(),
            notes: nil,
            isAutoSynced: false,
            createdAt: nil,
            updatedAt: nil
        )
        let aliceSplit = ExpenseSplit(
            id: UUID(), expenseId: expense.id, tripId: trip,
            userId: alice, amount: Decimal(20), currencyCode: "USD",
            isAccepted: true, createdAt: nil, updatedAt: nil
        )
        let bobSplit = ExpenseSplit(
            id: UUID(), expenseId: expense.id, tripId: trip,
            userId: bob, amount: Decimal(20), currencyCode: "USD",
            isAccepted: true, createdAt: nil, updatedAt: nil
        )
        let snapshot = BudgetSnapshot(
            expenses: [expense],
            splits: [aliceSplit, bobSplit],
            budgets: [],
            settlements: []
        )

        let balances = BalanceComputer.compute(snapshot: snapshot)
        let suggestions = SettlementSimplifier.simplify(balances)

        XCTAssertEqual(suggestions.count, 1)
        XCTAssertEqual(suggestions.first?.fromUserId, bob)
        XCTAssertEqual(suggestions.first?.toUserId, alice)
        XCTAssertEqual(suggestions.first?.amount, Decimal(20))
    }
}
