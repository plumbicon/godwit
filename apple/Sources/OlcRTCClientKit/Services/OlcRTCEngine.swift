import Foundation

public struct OlcRTCStartOptions: Equatable {
    public var carrierName: String
    public var transportName: String
    public var roomID: String
    public var clientID: String
    public var keyHex: String
    public var socksPort: Int
    public var socksUser: String
    public var socksPass: String
    public var dnsServer: String
    public var debugLogging: Bool
    public var vp8FPS: Int
    public var vp8BatchSize: Int
    public var seiFPS: Int
    public var seiBatchSize: Int
    public var seiFragmentSize: Int
    public var seiAckTimeoutMillis: Int
    public var videoCodec: String
    public var videoWidth: Int
    public var videoHeight: Int
    public var videoFPS: Int
    public var videoBitrate: String
    public var videoHardwareAcceleration: String
    public var videoQRRecovery: String
    public var videoQRSize: Int
    public var videoTileModule: Int
    public var videoTileRS: Int
    public var startTimeoutMillis: Int

    public init(profile: ConnectionProfile) {
        carrierName = profile.carrier.rawValue
        transportName = profile.transport.rawValue
        roomID = profile.roomID
        clientID = profile.clientID
        keyHex = profile.keyHex
        socksPort = profile.socksPort
        socksUser = profile.socksUser
        socksPass = profile.socksPass
        dnsServer = Self.normalizedDNSServer(profile.dnsServer)
        debugLogging = profile.debugLogging
        vp8FPS = profile.vp8FPS
        vp8BatchSize = profile.vp8BatchSize
        seiFPS = profile.seiFPS
        seiBatchSize = profile.seiBatchSize
        seiFragmentSize = profile.seiFragmentSize
        seiAckTimeoutMillis = profile.seiAckTimeoutMillis
        videoCodec = profile.videoCodec
        videoWidth = profile.videoWidth
        videoHeight = profile.videoHeight
        videoFPS = profile.videoFPS
        videoBitrate = profile.videoBitrate
        videoHardwareAcceleration = profile.videoHardwareAcceleration
        videoQRRecovery = profile.videoQRRecovery
        videoQRSize = profile.videoQRSize
        videoTileModule = profile.videoTileModule
        videoTileRS = profile.videoTileRS
        startTimeoutMillis = profile.startTimeoutMillis
    }

    private static func normalizedDNSServer(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(":") else {
            return trimmed
        }
        return "\(trimmed):53"
    }
}

public enum OlcRTCEngineError: LocalizedError, Equatable {
    case frameworkMissing
    case invalidProfile(String)
    case cliMissing(String)
    case unsupportedOption(String)

    public var errorDescription: String? {
        switch self {
        case .frameworkMissing:
            "Mobile.xcframework is not linked yet."
        case .invalidProfile(let message):
            message
        case .cliMissing(let message):
            message
        case .unsupportedOption(let message):
            message
        }
    }
}

public protocol OlcRTCEngine: AnyObject {
    var events: AsyncStream<String> { get }
    var isRunning: Bool { get async }
    var activeSocksPort: Int? { get async }

    func start(options: OlcRTCStartOptions) async throws
    func waitReady(timeoutMillis: Int) async throws
    func stop() async
}

public enum OlcRTCEngineFactory {
    public static func makeDefault() -> OlcRTCEngine {
        #if canImport(Mobile)
        return GomobileOlcRTCEngine()
        #elseif os(macOS)
        return ProcessOlcRTCEngine()
        #else
        return GomobileOlcRTCEngine()
        #endif
    }
}
