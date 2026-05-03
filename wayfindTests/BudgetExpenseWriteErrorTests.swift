//
//  BudgetExpenseWriteErrorTests.swift
//  wayfindTests
//

import XCTest
@testable import wayfind

final class BudgetExpenseWriteErrorTests: XCTestCase {

    func testFxUnavailableMessageIncludesSupportReference() {
        let err = BudgetExpenseWriteError.fxUnavailable(supportReference: "A1B2C3D4")
        let msg = err.errorDescription ?? ""
        XCTAssertTrue(msg.contains("A1B2C3D4"), msg)
        XCTAssertTrue(msg.localizedCaseInsensitiveContains("support"), msg)
    }

    func testFxQuoteSupportReferenceFormat() {
        let ref = BudgetFxQuoteSupport.makeReference()
        XCTAssertEqual(ref.count, 8, ref)
        let allowed = CharacterSet(charactersIn: "0123456789ABCDEF")
        XCTAssertNil(ref.rangeOfCharacter(from: allowed.inverted), ref)
    }
}


// =============================================================================
