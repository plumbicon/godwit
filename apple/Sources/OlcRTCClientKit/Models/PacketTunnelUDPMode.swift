import Foundation

public enum PacketTunnelUDPMode: String, CaseIterable, Codable, Identifiable {
    case tcp
    case udp

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .tcp:
            "TCP relay"
        case .udp:
            "UDP relay"
        }
    }
}
