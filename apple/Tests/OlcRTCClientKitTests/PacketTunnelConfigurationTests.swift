import XCTest
@testable import OlcRTCClientKit

final class PacketTunnelConfigurationTests: XCTestCase {
    private let key = "258aa76a14d8e5d22a9eeb57190e454d4062c5185ec4b5f9a3631de76f3001a2"

    func testDefaultsPacketTunnelUDPModeToTCPRelay() throws {
        let configuration = try PacketTunnelConfiguration(
            providerConfiguration: baseProviderConfiguration(removing: "packetTunnelUDPMode"),
            startOptions: nil
        )

        XCTAssertEqual(configuration.packetTunnelUDPMode, .tcp)
        XCTAssertEqual(configuration.connectionProfile.packetTunnelUDPMode, .tcp)
    }

    func testPersistsPacketTunnelUDPModeThroughProviderConfiguration() throws {
        let profile = ConnectionProfile(
            name: "UDP",
            roomID: "room-01",
            keyHex: key,
            packetTunnelUDPMode: .udp
        )
        let configuration = PacketTunnelConfiguration(profile: profile)

        XCTAssertEqual(configuration.providerConfiguration["packetTunnelUDPMode"] as? String, "udp")
        XCTAssertEqual(configuration.providerMetadata["packetTunnelUDPMode"] as? String, "udp")

        let restored = try PacketTunnelConfiguration(
            providerConfiguration: configuration.providerMetadata,
            startOptions: configuration.providerConfiguration
        )

        XCTAssertEqual(restored.packetTunnelUDPMode, .udp)
        XCTAssertEqual(restored.connectionProfile.packetTunnelUDPMode, .udp)
    }

    func testInvalidPacketTunnelUDPModeFallsBackToTCPRelay() throws {
        var values = baseProviderConfiguration()
        values["packetTunnelUDPMode"] = "unknown" as NSString

        let configuration = try PacketTunnelConfiguration(
            providerConfiguration: values,
            startOptions: nil
        )

        XCTAssertEqual(configuration.packetTunnelUDPMode, .tcp)
    }

    private func baseProviderConfiguration(removing key: String? = nil) -> [String: NSObject] {
        var values: [String: NSObject] = [
            "carrierName": "wbstream" as NSString,
            "transportName": "vp8channel" as NSString,
            "roomID": "room-01" as NSString,
            "clientID": "" as NSString,
            "keyHex": self.key as NSString,
            "socksPort": 21_080 as NSNumber,
            "socksUser": "" as NSString,
            "socksPass": "" as NSString,
            "packetTunnelUDPMode": "tcp" as NSString,
            "dnsServer": "77.88.8.8:53" as NSString,
            "debugLogging": false as NSNumber,
        ]

        if let key {
            values.removeValue(forKey: key)
        }

        return values
    }
}
