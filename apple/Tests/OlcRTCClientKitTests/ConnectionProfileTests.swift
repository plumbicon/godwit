import Foundation
import XCTest
@testable import OlcRTCClientKit

final class ConnectionProfileTests: XCTestCase {
    func testEmptyProfileUsesDefaultSocksPort() {
        XCTAssertEqual(ConnectionProfile.empty.socksPort, 21_080)
        XCTAssertEqual(ConnectionProfile.empty.socksPort, ConnectionProfile.defaultSocksPort)
    }

    func testDecodingMissingSocksPortUsesDefaultSocksPort() throws {
        let id = UUID()
        let data = Data(
            """
            {
              "id": "\(id.uuidString)",
              "name": "Legacy"
            }
            """.utf8
        )

        let profile = try JSONDecoder().decode(ConnectionProfile.self, from: data)

        XCTAssertEqual(profile.socksPort, ConnectionProfile.defaultSocksPort)
    }

    func testDecodingMissingPacketTunnelUDPModeUsesTCPRelay() throws {
        let id = UUID()
        let data = Data(
            """
            {
              "id": "\(id.uuidString)",
              "name": "Legacy"
            }
            """.utf8
        )

        let profile = try JSONDecoder().decode(ConnectionProfile.self, from: data)

        XCTAssertEqual(profile.packetTunnelUDPMode, .tcp)
    }

    func testKeepsConfiguredPacketTunnelUDPMode() throws {
        let id = UUID()
        let data = Data(
            """
            {
              "id": "\(id.uuidString)",
              "name": "UDP",
              "packetTunnelUDPMode": "udp"
            }
            """.utf8
        )

        let profile = try JSONDecoder().decode(ConnectionProfile.self, from: data)

        XCTAssertEqual(profile.packetTunnelUDPMode, .udp)
    }

    func testDecodingReservedSocksPortUsesDefaultSocksPort() throws {
        let id = UUID()
        let data = Data(
            """
            {
              "id": "\(id.uuidString)",
              "name": "Legacy",
              "socksPort": 65
            }
            """.utf8
        )

        let profile = try JSONDecoder().decode(ConnectionProfile.self, from: data)

        XCTAssertEqual(profile.socksPort, ConnectionProfile.defaultSocksPort)
    }

    func testKeepsCustomUserSpaceSocksPort() {
        let profile = ConnectionProfile(name: "Custom", socksPort: 21_081)

        XCTAssertEqual(profile.socksPort, 21_081)
    }
}
