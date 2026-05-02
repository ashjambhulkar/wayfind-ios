//
//  ExpenseCategoryTests.swift
//  wayfindTests
//
//  Phase 10 — Locks the iOS booking-kind → expense-category mapping in
//  `Models/ExpenseCategory.swift` against the SQL trigger
//  `tg_sync_booking_expense` (in `20260501120000_collaborative_budget_v1.sql`).
//
//  If you change the mapping in either side, update the other and rerun
//  these tests. The `unknown` case must always fall back to `.other` so a
//  new server-side booking kind never blocks the client.
//

import XCTest
@testable import wayfind

final class ExpenseCategoryTests: XCTestCase {
    func testFromBookingKind_FlightSynonyms() {
        XCTAssertEqual(ExpenseCategory.fromBookingKind("flight"), .flight)
        XCTAssertEqual(ExpenseCategory.fromBookingKind("Flights"), .flight)
        XCTAssertEqual(ExpenseCategory.fromBookingKind("AIRLINE"), .flight)
    }

    func testFromBookingKind_LodgingSynonyms() {
        XCTAssertEqual(ExpenseCategory.fromBookingKind("hotel"), .lodging)
        XCTAssertEqual(ExpenseCategory.fromBookingKind("lodging"), .lodging)
        XCTAssertEqual(ExpenseCategory.fromBookingKind("accommodation"), .lodging)
        XCTAssertEqual(ExpenseCategory.fromBookingKind("Hotels"), .lodging)
    }

    func testFromBookingKind_CarSynonyms() {
        XCTAssertEqual(ExpenseCategory.fromBookingKind("car"), .car)
        XCTAssertEqual(ExpenseCategory.fromBookingKind("CarRental"), .car)
        XCTAssertEqual(ExpenseCategory.fromBookingKind("car_rental"), .car)
    }

    func testFromBookingKind_FoodSynonyms() {
        XCTAssertEqual(ExpenseCategory.fromBookingKind("restaurant"), .food)
        XCTAssertEqual(ExpenseCategory.fromBookingKind("food"), .food)
        XCTAssertEqual(ExpenseCategory.fromBookingKind("dining"), .food)
    }

    func testFromBookingKind_TransportSynonyms() {
        XCTAssertEqual(ExpenseCategory.fromBookingKind("train"), .transport)
        XCTAssertEqual(ExpenseCategory.fromBookingKind("bus"), .transport)
        XCTAssertEqual(ExpenseCategory.fromBookingKind("ferry"), .transport)
        XCTAssertEqual(ExpenseCategory.fromBookingKind("transit"), .transport)
        XCTAssertEqual(ExpenseCategory.fromBookingKind("cruise"), .transport)
    }

    func testFromBookingKind_ActivitiesSynonyms() {
        XCTAssertEqual(ExpenseCategory.fromBookingKind("concert"), .activities)
        XCTAssertEqual(ExpenseCategory.fromBookingKind("theater"), .activities)
        XCTAssertEqual(ExpenseCategory.fromBookingKind("tour"), .activities)
        XCTAssertEqual(ExpenseCategory.fromBookingKind("activity"), .activities)
    }

    func testFromBookingKind_Shopping() {
        XCTAssertEqual(ExpenseCategory.fromBookingKind("shopping"), .shopping)
    }

    /// Unknown / nil / empty all collapse to `.other` so a new backend kind
    /// never crashes the client.
    func testFromBookingKind_UnknownFallsBackToOther() {
        XCTAssertEqual(ExpenseCategory.fromBookingKind(nil), .other)
        XCTAssertEqual(ExpenseCategory.fromBookingKind(""), .other)
        XCTAssertEqual(ExpenseCategory.fromBookingKind("   "), .other)
        XCTAssertEqual(ExpenseCategory.fromBookingKind("spa"), .other)
        XCTAssertEqual(ExpenseCategory.fromBookingKind("rocketship"), .other)
    }

    /// The reverse path — `from(rawValue:)` should round-trip every known
    /// case and treat unknown server values as `.other` instead of crashing.
    func testFromRawValueRoundTrips() {
        for category in ExpenseCategory.allCases {
            XCTAssertEqual(ExpenseCategory.from(rawValue: category.rawValue), category)
        }
        XCTAssertEqual(ExpenseCategory.from(rawValue: nil), .other)
        XCTAssertEqual(ExpenseCategory.from(rawValue: "INSURANCE"), .other)
    }
}
