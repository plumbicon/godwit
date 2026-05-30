import XCTest
@testable import OlcRTCClientKit

final class SubscriptionRefreshIntervalTests: XCTestCase {
    func testParsesDocumentedRefreshIntervals() {
        XCTAssertEqual(SubscriptionRefreshInterval.seconds(from: "5s"), 5)
        XCTAssertEqual(SubscriptionRefreshInterval.seconds(from: "10m"), 600)
        XCTAssertEqual(SubscriptionRefreshInterval.seconds(from: "6h"), 21_600)
        XCTAssertEqual(SubscriptionRefreshInterval.seconds(from: "1d"), 86_400)
    }

    func testTrimsWhitespaceAndAcceptsUppercaseUnits() {
        XCTAssertEqual(SubscriptionRefreshInterval.seconds(from: " 2 H "), 7_200)
    }

    func testRejectsInvalidIntervals() {
        XCTAssertNil(SubscriptionRefreshInterval.seconds(from: nil))
        XCTAssertNil(SubscriptionRefreshInterval.seconds(from: ""))
        XCTAssertNil(SubscriptionRefreshInterval.seconds(from: "10"))
        XCTAssertNil(SubscriptionRefreshInterval.seconds(from: "0s"))
        XCTAssertNil(SubscriptionRefreshInterval.seconds(from: "10ms"))
    }

    func testFormatsRefreshIntervalUsingLocaleSpecificSuffixes() {
        XCTAssertEqual(
            SubscriptionRefreshInterval.localizedString(from: "12h", languageCode: "en"),
            "12h"
        )
        XCTAssertEqual(
            SubscriptionRefreshInterval.localizedString(from: "12h", languageCode: "ru"),
            "12ч"
        )
        XCTAssertEqual(
            SubscriptionRefreshInterval.localizedString(from: "10m", languageCode: "en"),
            "10m"
        )
        XCTAssertEqual(
            SubscriptionRefreshInterval.localizedString(from: "10m", languageCode: "ru"),
            "10м"
        )
        XCTAssertEqual(
            SubscriptionRefreshInterval.localizedString(from: "1d", languageCode: "en"),
            "1d"
        )
        XCTAssertNil(SubscriptionRefreshInterval.localizedString(from: nil, languageCode: "ru"))
    }

    func testFormatsElapsedDurationUsingLocaleSpecificSuffixes() {
        XCTAssertEqual(
            SubscriptionRefreshInterval.abbreviatedString(from: 3_600, languageCode: "en"),
            "1h"
        )
        XCTAssertEqual(
            SubscriptionRefreshInterval.abbreviatedString(from: 3_600, languageCode: "ru"),
            "1ч"
        )
        XCTAssertEqual(
            SubscriptionRefreshInterval.abbreviatedString(from: 42, languageCode: "en"),
            "42s"
        )
        XCTAssertEqual(
            SubscriptionRefreshInterval.abbreviatedString(from: 42, languageCode: "ru"),
            "42с"
        )
        XCTAssertEqual(
            SubscriptionRefreshInterval.abbreviatedString(from: 0, languageCode: "en"),
            "0s"
        )
    }
}
