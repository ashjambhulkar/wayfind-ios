import XCTest
@testable import wayfind

final class ObservabilityServiceTests: XCTestCase {
    func testSanitizeDropsSecretsAndPayloads() {
        let sanitized = ObservabilityService.sanitize([
            "http_status": 502,
            "trace_id": "abc-123",
            "email": "traveler@example.com",
            "authorization": "Bearer secret",
            "request_body": "{\"note\":\"private\"}",
            "api_key": "secret",
            "is_retry": true,
        ])

        XCTAssertEqual(sanitized["http_status"] as? Int, 502)
        XCTAssertEqual(sanitized["trace_id"] as? String, "abc-123")
        XCTAssertEqual(sanitized["is_retry"] as? Bool, true)
        XCTAssertNil(sanitized["email"])
        XCTAssertNil(sanitized["authorization"])
        XCTAssertNil(sanitized["request_body"])
        XCTAssertNil(sanitized["api_key"])
    }

    func testSanitizeTruncatesLongStringsAndDropsObjects() {
        let long = String(repeating: "x", count: 300)
        let sanitized = ObservabilityService.sanitize([
            "reason": long,
            "metadata": ["raw": "object"],
        ])

        XCTAssertEqual((sanitized["reason"] as? String)?.count, 240)
        XCTAssertNil(sanitized["metadata"])
    }
}
