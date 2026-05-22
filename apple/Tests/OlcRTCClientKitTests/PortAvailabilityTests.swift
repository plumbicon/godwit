import Foundation
#if canImport(Darwin)
import Darwin
#endif
import XCTest
@testable import OlcRTCClientKit

final class PortAvailabilityTests: XCTestCase {
    func testBusyListenerIsUnavailable() throws {
        #if canImport(Darwin)
        let fileDescriptor = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        XCTAssertGreaterThanOrEqual(fileDescriptor, 0)
        defer { close(fileDescriptor) }

        var reuseAddress: Int32 = 1
        XCTAssertEqual(
            setsockopt(
                fileDescriptor,
                SOL_SOCKET,
                SO_REUSEADDR,
                &reuseAddress,
                socklen_t(MemoryLayout<Int32>.size)
            ),
            0
        )

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.stride)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(0).bigEndian
        XCTAssertEqual(inet_pton(AF_INET, "127.0.0.1", &address.sin_addr), 1)

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.bind(fileDescriptor, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.stride))
            }
        }
        XCTAssertEqual(bindResult, 0)
        XCTAssertEqual(listen(fileDescriptor, 1), 0)

        var boundAddress = sockaddr_in()
        var boundAddressLength = socklen_t(MemoryLayout<sockaddr_in>.stride)
        let getNameResult = withUnsafeMutablePointer(to: &boundAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                getsockname(fileDescriptor, socketAddress, &boundAddressLength)
            }
        }
        XCTAssertEqual(getNameResult, 0)

        let port = Int(UInt16(bigEndian: boundAddress.sin_port))
        XCTAssertFalse(PortAvailability.isLocalTCPPortAvailable(port))
        #else
        throw XCTSkip("Port availability uses Darwin sockets.")
        #endif
    }
}
