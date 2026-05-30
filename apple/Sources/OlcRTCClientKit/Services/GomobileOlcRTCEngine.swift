import Foundation

#if canImport(Mobile)
import Mobile
#endif

public final class GomobileOlcRTCEngine: OlcRTCEngine {
    private let eventPair = AsyncStream<String>.makeStream(of: String.self)
    private let lock = NSLock()
    private var currentSocksPort: Int?
    #if canImport(Mobile)
    private var logRelay: MobileLogRelay?
    #endif

    public init() {}

    deinit {
        #if canImport(Mobile)
        MobileStop()
        MobileSetLogWriter(nil)
        #endif
    }

    public var events: AsyncStream<String> {
        eventPair.stream
    }

    public var isRunning: Bool {
        get async {
            #if canImport(Mobile)
            return await Task.detached {
                MobileIsRunning()
            }.value
            #else
            return false
            #endif
        }
    }

    public var activeSocksPort: Int? {
        get async {
            withLock { currentSocksPort }
        }
    }

    public func start(options: OlcRTCStartOptions) async throws {
        try validate(options)

        #if canImport(Mobile)
        emit("Starting olcRTC on 127.0.0.1:\(options.socksPort)")
        do {
            try await startMobile(options: options)
            withLock {
                currentSocksPort = options.socksPort
            }
        } catch {
            if isPortConflict(error) {
                MobileStop()
                throw OlcRTCEngineError.invalidProfile(
                    AppLocalization.format(
                        "SOCKS port %d is busy. Stop the existing process or choose another port.",
                        options.socksPort
                    )
                )
            }
            throw error
        }
        #else
        emit("Starting olcRTC on 127.0.0.1:\(options.socksPort)")
        throw OlcRTCEngineError.frameworkMissing
        #endif
    }

    #if canImport(Mobile)
    private func startMobile(options: OlcRTCStartOptions) async throws {
        let relay = MobileLogRelay { [weak self] message in
            self?.emit(message)
        }
        withLock {
            logRelay = relay
        }

        try await Task.detached {
            MobileSetLogWriter(relay)
            MobileSetProviders()
            MobileSetDebug(options.debugLogging)
            MobileSetTransport(options.transportName)
            MobileSetDNS(options.dnsServer)
            MobileSetVP8Options(options.vp8FPS, options.vp8BatchSize)
            var error: NSError?
            let didStart = MobileStart(
                options.carrierName,
                options.roomID,
                options.clientID,
                options.keyHex,
                options.socksPort,
                options.socksUser,
                options.socksPass,
                &error
            )
            if !didStart {
                throw error ?? OlcRTCEngineError.frameworkMissing
            }
        }.value
    }
    #endif

    public func waitReady(timeoutMillis: Int) async throws {
        #if canImport(Mobile)
        try await Task.detached {
            var error: NSError?
            let isReady = MobileWaitReady(timeoutMillis, &error)
            if !isReady {
                throw error ?? OlcRTCEngineError.frameworkMissing
            }
        }.value
        emit("olcRTC is ready.")
        #else
        _ = timeoutMillis
        throw OlcRTCEngineError.frameworkMissing
        #endif
    }

    public func stop() async {
        emit("Stopping olcRTC.")

        #if canImport(Mobile)
        await Task.detached {
            MobileStop()
            MobileSetLogWriter(nil)
        }.value
        #endif
        withLock {
            currentSocksPort = nil
            #if canImport(Mobile)
            logRelay = nil
            #endif
        }

        emit("olcRTC stopped.")
    }

    private func validate(_ options: OlcRTCStartOptions) throws {
        if options.keyHex.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw OlcRTCEngineError.invalidProfile("Encryption key is required.")
        }
        if options.keyHex.count != 64 || !options.keyHex.allSatisfy(\.isHexDigit) {
            throw OlcRTCEngineError.invalidProfile("Encryption key must be 64 hexadecimal characters.")
        }
        if options.roomID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let fieldName = options.carrierName == "jitsi" ? "Room URL" : "Room ID"
            throw OlcRTCEngineError.invalidProfile("\(fieldName) is required for this carrier.")
        }
        if !ConnectionProfile.socksPortRange.contains(options.socksPort) {
            throw OlcRTCEngineError.invalidProfile("SOCKS port must be between 1024 and 65535.")
        }
    }

    private func isPortConflict(_ error: Error) -> Bool {
        error.localizedDescription.localizedCaseInsensitiveContains("address already in use") ||
            error.localizedDescription.localizedCaseInsensitiveContains("bind")
    }

    private func emit(_ message: String) {
        eventPair.continuation.yield(message)
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

#if canImport(Mobile)
private final class MobileLogRelay: NSObject, MobileLogWriterProtocol {
    private let onLog: (String) -> Void

    init(onLog: @escaping (String) -> Void) {
        self.onLog = onLog
    }

    func writeLog(_ msg: String?) {
        guard let msg else { return }
        msg
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .forEach(onLog)
    }
}
#endif
