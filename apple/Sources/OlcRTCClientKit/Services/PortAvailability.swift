import Foundation

#if canImport(Darwin)
import Darwin
#endif

public enum PortAvailability {
    public static func nextAvailableTCPPort(
        startingAt preferredPort: Int = ConnectionProfile.defaultSocksPort,
        host: String = "127.0.0.1"
    ) -> Int {
        let start = ConnectionProfile.clampedSocksPort(preferredPort)

        for port in start...ConnectionProfile.maximumSocksPort where isLocalTCPPortAvailable(port, host: host) {
            return port
        }

        if start > ConnectionProfile.minimumSocksPort {
            for port in ConnectionProfile.minimumSocksPort..<start where isLocalTCPPortAvailable(port, host: host) {
                return port
            }
        }

        return ConnectionProfile.defaultSocksPort
    }

    public static func randomAvailableTCPPort(
        in range: ClosedRange<Int> = 49_152...65_535,
        host: String = "127.0.0.1"
    ) -> Int {
        let lowerBound = max(range.lowerBound, ConnectionProfile.minimumSocksPort)
        let upperBound = min(range.upperBound, ConnectionProfile.maximumSocksPort)
        guard lowerBound <= upperBound else {
            return nextAvailableTCPPort(host: host)
        }

        for port in Array(lowerBound...upperBound).shuffled() where isLocalTCPPortAvailable(port, host: host) {
            return port
        }

        return nextAvailableTCPPort(host: host)
    }

    public static func isLocalTCPPortAvailable(_ port: Int, host: String = "127.0.0.1") -> Bool {
        guard ConnectionProfile.socksPortRange.contains(port) else {
            return false
        }

        #if canImport(Darwin)
        let fileDescriptor = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fileDescriptor >= 0 else {
            return false
        }
        defer { close(fileDescriptor) }

        var reuseAddress: Int32 = 1
        _ = setsockopt(
            fileDescriptor,
            SOL_SOCKET,
            SO_REUSEADDR,
            &reuseAddress,
            socklen_t(MemoryLayout<Int32>.size)
        )

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.stride)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian

        guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else {
            return false
        }

        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                bind(fileDescriptor, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.stride))
            }
        }

        guard result == 0 else {
            return false
        }

        return listen(fileDescriptor, 1) == 0
        #else
        return true
        #endif
    }
}
