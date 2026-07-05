import Foundation
import NetworkExtension
import OlcRTCClientKit
import Tun2SocksKit

final class PacketTunnelProvider: NEPacketTunnelProvider {
    private enum Constants {
        static let tunnelAddress = "198.18.0.1"
        static let tunnelSubnetMask = "255.255.255.0"
        static let mapDNSAddress = "198.18.0.2"
        static let mapDNSNetwork = "198.18.0.0"
        static let mapDNSNetmask = "255.255.0.0"
        static let mtu = 8500
    }

    private var engine: GomobileOlcRTCEngine?
    private var tun2socksTask: Task<Void, Never>?
    private var configFileURL: URL?

    override func startTunnel(
        options: [String: NSObject]?,
        completionHandler: @escaping (Error?) -> Void
    ) {
        Task {
            do {
                let configuration = try PacketTunnelConfiguration(
                    providerConfiguration: (protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration,
                    startOptions: options
                )
                try await startOlcRTC(configuration: configuration)
                try await applyNetworkSettings()
                try await startTun2Socks(configuration: configuration)
                completionHandler(nil)
            } catch {
                completionHandler(error)
                await stopRuntime()
            }
        }
    }

    override func stopTunnel(
        with reason: NEProviderStopReason,
        completionHandler: @escaping () -> Void
    ) {
        Task {
            await stopRuntime()
            completionHandler()
        }
    }

    private func startOlcRTC(configuration: PacketTunnelConfiguration) async throws {
        let profile = configuration.connectionProfile
        let startOptions = OlcRTCStartOptions(profile: profile)
        let engine = GomobileOlcRTCEngine()
        self.engine = engine

        try await engine.start(options: startOptions)
        try await engine.waitReady(
            timeoutMillis: max(
                configuration.startTimeoutMillis,
                ConnectionProfile.defaultStartTimeoutMillis
            )
        )
    }

    private func applyNetworkSettings() async throws {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: Constants.tunnelAddress)
        settings.mtu = Constants.mtu as NSNumber

        let ipv4Settings = NEIPv4Settings(
            addresses: [Constants.tunnelAddress],
            subnetMasks: [Constants.tunnelSubnetMask]
        )
        ipv4Settings.includedRoutes = [NEIPv4Route.default()]
        ipv4Settings.excludedRoutes = [
            NEIPv4Route(destinationAddress: "127.0.0.0", subnetMask: "255.0.0.0"),
        ]
        settings.ipv4Settings = ipv4Settings

        let dnsSettings = NEDNSSettings(servers: [Constants.mapDNSAddress])
        dnsSettings.matchDomains = [""]
        settings.dnsSettings = dnsSettings

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            setTunnelNetworkSettings(settings) { error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: ())
            }
        }
    }

    private func startTun2Socks(configuration: PacketTunnelConfiguration) async throws {
        let socksPort = await engine?.activeSocksPort ?? configuration.socksPort
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("olcrtc-tun2socks.yml")
        try tun2socksConfiguration(
            socksPort: socksPort,
            udpMode: configuration.packetTunnelUDPMode,
            debugLogging: configuration.debugLogging
        ).write(to: fileURL, atomically: true, encoding: .utf8)
        configFileURL = fileURL

        tun2socksTask = Task.detached(priority: .userInitiated) {
            _ = Socks5Tunnel.run(withConfig: .file(path: fileURL))
        }
    }

    private func stopRuntime() async {
        tun2socksTask?.cancel()
        tun2socksTask = nil
        Socks5Tunnel.quit()

        if let configFileURL {
            try? FileManager.default.removeItem(at: configFileURL)
            self.configFileURL = nil
        }

        await engine?.stop()
        engine = nil
    }

    private func tun2socksConfiguration(
        socksPort: Int,
        udpMode: PacketTunnelUDPMode,
        debugLogging: Bool
    ) -> String {
        """
        tunnel:
          mtu: \(Constants.mtu)
          ipv4: \(Constants.tunnelAddress)
        socks5:
          port: \(socksPort)
          address: 127.0.0.1
          udp: '\(udpMode.rawValue)'
        mapdns:
          address: \(Constants.mapDNSAddress)
          port: 53
          network: \(Constants.mapDNSNetwork)
          netmask: \(Constants.mapDNSNetmask)
          cache-size: 10000
        misc:
          task-stack-size: 24576
          tcp-buffer-size: 4096
          connect-timeout: 10000
          tcp-read-write-timeout: 300000
          udp-read-write-timeout: 60000
          log-file: stderr
          log-level: \(debugLogging ? "debug" : "warn")
          limit-nofile: 65535
        """
    }
}
