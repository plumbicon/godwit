import XCTest
@testable import OlcRTCClientKit

final class ProfileStoreTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "ProfileStoreTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testLoadsNoProfilesWhenStoreIsEmpty() {
        let store = ProfileStore(defaults: defaults)

        XCTAssertEqual(store.loadProfiles(), [])
    }

    func testLoadsSavedProfiles() {
        let store = ProfileStore(defaults: defaults)
        var profile = ConnectionProfile.empty
        profile.name = "Profile 1"
        store.saveProfiles([profile])

        XCTAssertEqual(store.loadProfiles(), [profile])
    }

    func testPersistsSystemProxyPreference() {
        let store = ProfileStore(defaults: defaults)

        XCTAssertFalse(store.hasUseSystemProxyPreference())
        XCTAssertTrue(store.loadUseSystemProxy(defaultValue: true))

        store.saveUseSystemProxy(false)

        XCTAssertTrue(store.hasUseSystemProxyPreference())
        XCTAssertFalse(ProfileStore(defaults: defaults).loadUseSystemProxy(defaultValue: true))
    }

    func testPersistsSelectedNetworkService() {
        let store = ProfileStore(defaults: defaults)

        XCTAssertEqual(store.loadSelectedNetworkService(), "Wi-Fi")

        store.saveSelectedNetworkService("Thunderbolt Bridge")

        XCTAssertEqual(ProfileStore(defaults: defaults).loadSelectedNetworkService(), "Thunderbolt Bridge")
    }
}
