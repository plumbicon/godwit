import Foundation

#if canImport(CFNetwork)
import CFNetwork
#endif

#if canImport(Mobile)
import Mobile
#endif

public enum ProfilePingState: Equatable {
    case success(milliseconds: Int)
    case failure(message: String)
}

public struct ProfilePingResult: Equatable {
    public var milliseconds: Int
    public var measuredAt: Date

    public init(milliseconds: Int, measuredAt: Date = Date()) {
        self.milliseconds = milliseconds
        self.measuredAt = measuredAt
    }
}

public protocol ProfilePinging {
    func ping(profile: ConnectionProfile) async throws -> ProfilePingResult
}

public enum ProfilePingError: LocalizedError, Equatable {
    case unsupportedPlatform
    case invalidResult
    case invalidHTTPStatus(Int)

    public var errorDescription: String? {
        switch self {
        case .unsupportedPlatform:
            AppLocalization.string("Profile ping is not supported on this platform.")
        case .invalidResult:
            AppLocalization.string("Ping finished without a result.")
        case .invalidHTTPStatus(let status):
            AppLocalization.format("HTTP ping returned status %d.", status)
        }
    }
}

public struct ProfilePinger: ProfilePinging {
    private static let portLeases = ProfilePingPortLeases()

    private let timeoutMillis: Int
    private let pingURL: URL

    public init(
        timeoutMillis: Int = 10_000,
        pingURL: URL = URL(string: "https://www.google.com/generate_204")!
    ) {
        self.timeoutMillis = timeoutMillis
        self.pingURL = pingURL
    }

    public func ping(profile: ConnectionProfile) async throws -> ProfilePingResult {
        let socksPort = await Self.portLeases.reserveTemporaryPort()
        let profile = preparedProfileForPing(profile, socksPort: socksPort)

        do {
            #if canImport(Mobile)
            let result = try await pingWithMobile(profile: profile)
            #elseif os(macOS)
            let result = try await pingWithProcess(profile: profile)
            #else
            throw ProfilePingError.unsupportedPlatform
            #endif
            await Self.portLeases.release(socksPort)
            return result
        } catch {
            await Self.portLeases.release(socksPort)
            throw error
        }
    }

    private func preparedProfileForPing(_ profile: ConnectionProfile, socksPort: Int) -> ConnectionProfile {
        var profile = profile.normalizedForCurrentDefaults()
        let baseClientID = profile.clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? profile.id.uuidString
            : profile.clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.clientID = "\(baseClientID)-ping-\(UUID().uuidString.prefix(8))"
        profile.socksPort = socksPort
        profile.socksUser = ""
        profile.socksPass = ""
        return profile
    }

    #if canImport(Mobile)
    private func pingWithMobile(profile: ConnectionProfile) async throws -> ProfilePingResult {
        let options = OlcRTCStartOptions(profile: profile)
        let measured = try await Task.detached {
            var error: NSError?
            var result: Int64 = -1
            let didPing = MobilePing(
                options.carrierName,
                options.transportName,
                options.roomID,
                options.clientID,
                options.keyHex,
                options.socksPort,
                timeoutMillis,
                pingURL.absoluteString,
                options.vp8FPS,
                options.vp8BatchSize,
                &result,
                &error
            )
            if !didPing {
                throw error ?? ProfilePingError.invalidResult
            }
            return result
        }.value

        guard measured >= 0 else {
            throw ProfilePingError.invalidResult
        }
        return ProfilePingResult(milliseconds: Int(measured))
    }
    #endif

    #if os(macOS)
    private func pingWithProcess(profile: ConnectionProfile) async throws -> ProfilePingResult {
        let engine = ProcessOlcRTCEngine()
        let options = OlcRTCStartOptions(profile: profile)

        do {
            try await engine.start(options: options)
            try await engine.waitReady(timeoutMillis: timeoutMillis)
            let socksPort = await engine.activeSocksPort ?? options.socksPort
            let milliseconds = try await httpPingThroughSOCKS(port: socksPort)
            await engine.stop()
            return ProfilePingResult(milliseconds: milliseconds)
        } catch {
            await engine.stop()
            throw error
        }
    }

    private func httpPingThroughSOCKS(port: Int) async throws -> Int {
        let session = makeSOCKSSession(port: port)
        defer {
            session.invalidateAndCancel()
        }

        _ = try? await singleHTTPPing(session: session, timeout: 1.5)

        var best: Int?
        for index in 0..<3 {
            if index > 0 {
                try await Task.sleep(nanoseconds: 80_000_000)
            }
            let measured = try await singleHTTPPing(session: session, timeout: 1.5)
            best = min(best ?? measured, measured)
        }

        guard let best else {
            throw ProfilePingError.invalidResult
        }
        return best
    }

    private func makeSOCKSSession(port: Int) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 1.5
        configuration.timeoutIntervalForResource = 1.5
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        #if canImport(CFNetwork)
        configuration.connectionProxyDictionary = [
            kCFNetworkProxiesSOCKSEnable as String: true,
            kCFNetworkProxiesSOCKSProxy as String: "127.0.0.1",
            kCFNetworkProxiesSOCKSPort as String: port,
        ]
        #endif

        return URLSession(configuration: configuration)
    }

    private func singleHTTPPing(session: URLSession, timeout: TimeInterval) async throws -> Int {
        var request = URLRequest(url: pingURL, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: timeout)
        request.httpMethod = "GET"

        let startedAt = Date()
        let (_, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ProfilePingError.invalidResult
        }
        guard (200..<400).contains(httpResponse.statusCode) else {
            throw ProfilePingError.invalidHTTPStatus(httpResponse.statusCode)
        }
        return max(1, Int(Date().timeIntervalSince(startedAt) * 1_000))
    }
    #endif
}

private actor ProfilePingPortLeases {
    private var leasedPorts: Set<Int> = []

    func reserveTemporaryPort() -> Int {
        let range = 49_152...65_535
        for port in Array(range).shuffled() where !leasedPorts.contains(port) && PortAvailability.isLocalTCPPortAvailable(port) {
            leasedPorts.insert(port)
            return port
        }

        for port in ConnectionProfile.socksPortRange where !leasedPorts.contains(port) && PortAvailability.isLocalTCPPortAvailable(port) {
            leasedPorts.insert(port)
            return port
        }

        let fallback = PortAvailability.randomAvailableTCPPort()
        leasedPorts.insert(fallback)
        return fallback
    }

    func release(_ port: Int) {
        leasedPorts.remove(port)
    }
}
