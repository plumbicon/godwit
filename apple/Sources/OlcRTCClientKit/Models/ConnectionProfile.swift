import Foundation

public enum Carrier: String, CaseIterable, Codable, Identifiable {
    case jitsi
    case telemost
    case jazz
    case wbstream

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .jitsi: "Jitsi"
        case .telemost: "Telemost"
        case .jazz: "Jazz"
        case .wbstream: "WBStream"
        }
    }

    public var recommendedTransport: Transport {
        switch self {
        case .jitsi, .jazz:
            .datachannel
        case .telemost, .wbstream:
            .vp8channel
        }
    }
}

public enum Transport: String, CaseIterable, Codable, Identifiable {
    case vp8channel
    case datachannel
    case seichannel
    case videochannel

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .vp8channel: "vp8"
        case .datachannel: "datachannel"
        case .seichannel: "seichannel"
        case .videochannel: "videochannel"
        }
    }
}

public struct ConnectionProfile: Codable, Equatable, Identifiable {
    public static let defaultStartTimeoutMillis = 60_000

    public var id: UUID
    public var subscription: SubscriptionMetadata?
    public var name: String
    public var carrier: Carrier
    public var transport: Transport
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

    public init(
        id: UUID = UUID(),
        subscription: SubscriptionMetadata? = nil,
        name: String,
        carrier: Carrier = .wbstream,
        transport: Transport = .vp8channel,
        roomID: String = "",
        clientID: String = "",
        keyHex: String = "",
        socksPort: Int = 60_180,
        socksUser: String = "",
        socksPass: String = "",
        dnsServer: String = "77.88.8.8:53",
        debugLogging: Bool = false,
        vp8FPS: Int = 60,
        vp8BatchSize: Int = 64,
        seiFPS: Int = 60,
        seiBatchSize: Int = 64,
        seiFragmentSize: Int = 900,
        seiAckTimeoutMillis: Int = 2_000,
        videoCodec: String = "qrcode",
        videoWidth: Int = 1080,
        videoHeight: Int = 1080,
        videoFPS: Int = 60,
        videoBitrate: String = "5000k",
        videoHardwareAcceleration: String = "none",
        videoQRRecovery: String = "low",
        videoQRSize: Int = 0,
        videoTileModule: Int = 4,
        videoTileRS: Int = 20,
        startTimeoutMillis: Int = Self.defaultStartTimeoutMillis
    ) {
        self.id = id
        self.subscription = subscription
        self.name = name
        self.carrier = carrier
        self.transport = transport
        self.roomID = roomID
        self.clientID = clientID
        self.keyHex = keyHex
        self.socksPort = socksPort
        self.socksUser = socksUser
        self.socksPass = socksPass
        self.dnsServer = dnsServer
        self.debugLogging = debugLogging
        self.vp8FPS = vp8FPS
        self.vp8BatchSize = vp8BatchSize
        self.seiFPS = seiFPS
        self.seiBatchSize = seiBatchSize
        self.seiFragmentSize = seiFragmentSize
        self.seiAckTimeoutMillis = seiAckTimeoutMillis
        self.videoCodec = videoCodec
        self.videoWidth = videoWidth
        self.videoHeight = videoHeight
        self.videoFPS = videoFPS
        self.videoBitrate = videoBitrate
        self.videoHardwareAcceleration = videoHardwareAcceleration
        self.videoQRRecovery = videoQRRecovery
        self.videoQRSize = videoQRSize
        self.videoTileModule = videoTileModule
        self.videoTileRS = videoTileRS
        self.startTimeoutMillis = startTimeoutMillis
    }

    enum CodingKeys: String, CodingKey {
        case id
        case subscription
        case name
        case carrier
        case transport
        case roomID
        case clientID
        case keyHex
        case socksPort
        case socksUser
        case socksPass
        case dnsServer
        case debugLogging
        case vp8FPS
        case vp8BatchSize
        case seiFPS
        case seiBatchSize
        case seiFragmentSize
        case seiAckTimeoutMillis
        case videoCodec
        case videoWidth
        case videoHeight
        case videoFPS
        case videoBitrate
        case videoHardwareAcceleration
        case videoQRRecovery
        case videoQRSize
        case videoTileModule
        case videoTileRS
        case startTimeoutMillis
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        subscription = try container.decodeIfPresent(SubscriptionMetadata.self, forKey: .subscription)
        name = try container.decode(String.self, forKey: .name)
        carrier = try container.decodeIfPresent(Carrier.self, forKey: .carrier) ?? .wbstream
        transport = try container.decodeIfPresent(Transport.self, forKey: .transport) ?? .vp8channel
        roomID = try container.decodeIfPresent(String.self, forKey: .roomID) ?? ""
        clientID = try container.decodeIfPresent(String.self, forKey: .clientID) ?? ""
        keyHex = try container.decodeIfPresent(String.self, forKey: .keyHex) ?? ""
        socksPort = try container.decodeIfPresent(Int.self, forKey: .socksPort) ?? 60_180
        socksUser = try container.decodeIfPresent(String.self, forKey: .socksUser) ?? ""
        socksPass = try container.decodeIfPresent(String.self, forKey: .socksPass) ?? ""
        dnsServer = try container.decodeIfPresent(String.self, forKey: .dnsServer) ?? "77.88.8.8:53"
        debugLogging = try container.decodeIfPresent(Bool.self, forKey: .debugLogging) ?? false
        vp8FPS = try container.decodeIfPresent(Int.self, forKey: .vp8FPS) ?? 60
        vp8BatchSize = try container.decodeIfPresent(Int.self, forKey: .vp8BatchSize) ?? 64
        seiFPS = try container.decodeIfPresent(Int.self, forKey: .seiFPS) ?? 60
        seiBatchSize = try container.decodeIfPresent(Int.self, forKey: .seiBatchSize) ?? 64
        seiFragmentSize = try container.decodeIfPresent(Int.self, forKey: .seiFragmentSize) ?? 900
        seiAckTimeoutMillis = try container.decodeIfPresent(Int.self, forKey: .seiAckTimeoutMillis) ?? 2_000
        videoCodec = try container.decodeIfPresent(String.self, forKey: .videoCodec) ?? "qrcode"
        videoWidth = try container.decodeIfPresent(Int.self, forKey: .videoWidth) ?? 1080
        videoHeight = try container.decodeIfPresent(Int.self, forKey: .videoHeight) ?? 1080
        videoFPS = try container.decodeIfPresent(Int.self, forKey: .videoFPS) ?? 60
        videoBitrate = try container.decodeIfPresent(String.self, forKey: .videoBitrate) ?? "5000k"
        videoHardwareAcceleration = try container.decodeIfPresent(
            String.self,
            forKey: .videoHardwareAcceleration
        ) ?? "none"
        videoQRRecovery = try container.decodeIfPresent(String.self, forKey: .videoQRRecovery) ?? "low"
        videoQRSize = try container.decodeIfPresent(Int.self, forKey: .videoQRSize) ?? 0
        videoTileModule = try container.decodeIfPresent(Int.self, forKey: .videoTileModule) ?? 4
        videoTileRS = try container.decodeIfPresent(Int.self, forKey: .videoTileRS) ?? 20
        startTimeoutMillis = try container.decodeIfPresent(Int.self, forKey: .startTimeoutMillis)
            ?? Self.defaultStartTimeoutMillis
    }

    public static var empty: ConnectionProfile {
        ConnectionProfile(name: "Новый профиль")
    }

    public func normalizedForCurrentDefaults() -> ConnectionProfile {
        var profile = self
        if profile.startTimeoutMillis < Self.defaultStartTimeoutMillis {
            profile.startTimeoutMillis = Self.defaultStartTimeoutMillis
        }
        return profile
    }
}

public struct SubscriptionMetadata: Codable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var sourceURL: String?
    public var updatedAtUnix: TimeInterval?
    public var refreshInterval: String?
    public var color: String?
    public var icon: String?
    public var used: String?
    public var available: String?
    public var nodeColor: String?
    public var nodeIcon: String?
    public var nodeUsed: String?
    public var nodeAvailable: String?
    public var nodeIP: String?
    public var nodeComment: String?
    public var nodeURI: String?

    public init(
        id: UUID = UUID(),
        name: String,
        sourceURL: String? = nil,
        updatedAtUnix: TimeInterval? = nil,
        refreshInterval: String? = nil,
        color: String? = nil,
        icon: String? = nil,
        used: String? = nil,
        available: String? = nil,
        nodeColor: String? = nil,
        nodeIcon: String? = nil,
        nodeUsed: String? = nil,
        nodeAvailable: String? = nil,
        nodeIP: String? = nil,
        nodeComment: String? = nil,
        nodeURI: String? = nil
    ) {
        self.id = id
        self.name = name
        self.sourceURL = sourceURL
        self.updatedAtUnix = updatedAtUnix
        self.refreshInterval = refreshInterval
        self.color = color
        self.icon = icon
        self.used = used
        self.available = available
        self.nodeColor = nodeColor
        self.nodeIcon = nodeIcon
        self.nodeUsed = nodeUsed
        self.nodeAvailable = nodeAvailable
        self.nodeIP = nodeIP
        self.nodeComment = nodeComment
        self.nodeURI = nodeURI
    }
}
