import Foundation

#if os(macOS)
public final class ProcessOlcRTCEngine: OlcRTCEngine {
    private let eventPair = AsyncStream<String>.makeStream(of: String.self)
    private let lock = NSLock()
    private var process: Process?
    private var outputPipe: Pipe?
    private var outputBuffer = Data()
    private var ready = false
    private var stopping = false
    private var portConflictDetected = false
    private var retryCount = 0
    private var activePort: Int?
    private var lastOptions: OlcRTCStartOptions?
    private var lastSupportRoot: URL?
    private var lastCliURL: URL?
    private var lastOutputLine: String?
    private var configURL: URL?
    private let maxPortRetries = 20

    public init() {}

    public var events: AsyncStream<String> {
        eventPair.stream
    }

    public var isRunning: Bool {
        get async {
            withLock { process?.isRunning == true }
        }
    }

    public var activeSocksPort: Int? {
        get async {
            withLock { activePort }
        }
    }

    public func start(options: OlcRTCStartOptions) async throws {
        try validate(options)

        let alreadyRunning = withLock { process?.isRunning == true }
        if alreadyRunning {
            throw OlcRTCEngineError.invalidProfile("olcRTC is already running.")
        }

        guard let supportRoot = supportRoot() else {
            throw OlcRTCEngineError.cliMissing("olcRTC support files were not found. Set OLCRTC_REPO_ROOT.")
        }
        guard let cliURL = cliURL(supportRoot: supportRoot) else {
            throw OlcRTCEngineError.cliMissing(
                "macOS CLI binary was not found. Run ./apple/Scripts/build-macos-cli.sh."
            )
        }

        withLock {
            lastOptions = options
            lastSupportRoot = supportRoot
            lastCliURL = cliURL
            activePort = options.socksPort
            retryCount = 0
        }

        try launchProcess(options: options, supportRoot: supportRoot, cliURL: cliURL, socksPort: options.socksPort)
    }

    public func waitReady(timeoutMillis: Int) async throws {
        let deadline = Date().addingTimeInterval(Double(timeoutMillis) / 1_000)
        while Date() < deadline {
            let state = withLock {
                (
                    isReady: ready,
                    isRunning: process?.isRunning == true,
                    portConflict: portConflictDetected,
                    activePort: activePort,
                    lastOutputLine: lastOutputLine
                )
            }

            if state.isReady {
                return
            }
            if !state.isRunning {
                if state.portConflict,
                   let port = state.activePort,
                   try await retryAfterPortConflict(currentPort: port) {
                    continue
                }
                throw OlcRTCEngineError.invalidProfile(startFailureMessage(lastOutputLine: state.lastOutputLine))
            }

            try await Task.sleep(nanoseconds: 200_000_000)
        }

        throw OlcRTCEngineError.invalidProfile("olcRTC start timed out.")
    }

    public func stop() async {
        let task = withLock {
            stopping = true
            return process
        }

        guard let task, task.isRunning else {
            clearProcess()
            return
        }

        emit("Terminating olcRTC process.")
        task.terminate()

        await Task.detached {
            task.waitUntilExit()
        }.value

        clearProcess()
    }

    private func validate(_ options: OlcRTCStartOptions) throws {
        if options.clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw OlcRTCEngineError.invalidProfile("Client ID is required.")
        }
        if options.keyHex.count != 64 || !options.keyHex.allSatisfy(\.isHexDigit) {
            throw OlcRTCEngineError.invalidProfile("Encryption key must be 64 hexadecimal characters.")
        }
        if options.carrierName != "jazz" && options.roomID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let fieldName = options.carrierName == "jitsi" ? "Room URL" : "Room ID"
            throw OlcRTCEngineError.invalidProfile("\(fieldName) is required for this carrier.")
        }
    }

    private func writeConfiguration(options: OlcRTCStartOptions, supportRoot: URL, socksPort: Int) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Godwit", isDirectory: true)
            .appendingPathComponent("olcrtc", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let url = directory.appendingPathComponent("client-\(UUID().uuidString).yaml")
        let yaml = configurationYAML(options: options, supportRoot: supportRoot, socksPort: socksPort)
        try yaml.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func configurationYAML(options: OlcRTCStartOptions, supportRoot: URL, socksPort: Int) -> String {
        """
        mode: cnc
        auth:
          provider: \(yamlString(options.carrierName))
        room:
          id: \(yamlString(options.roomID))
        crypto:
          key: \(yamlString(options.keyHex))
        net:
          transport: \(yamlString(options.transportName))
          dns: \(yamlString(options.dnsServer))
        socks:
          host: "127.0.0.1"
          port: \(socksPort)
          user: \(yamlString(options.socksUser))
          pass: \(yamlString(options.socksPass))
        vp8:
          fps: \(options.vp8FPS)
          batch_size: \(options.vp8BatchSize)
        sei:
          fps: \(options.seiFPS)
          batch_size: \(options.seiBatchSize)
          fragment_size: \(options.seiFragmentSize)
          ack_timeout_ms: \(options.seiAckTimeoutMillis)
        video:
          width: \(options.videoWidth)
          height: \(options.videoHeight)
          fps: \(options.videoFPS)
          bitrate: \(yamlString(options.videoBitrate))
          hw: \(yamlString(options.videoHardwareAcceleration))
          codec: \(yamlString(options.videoCodec))
          qr_size: \(options.videoQRSize)
          qr_recovery: \(yamlString(options.videoQRRecovery))
          tile_module: \(options.videoTileModule)
          tile_rs: \(options.videoTileRS)
        data: \(yamlString(supportRoot.appendingPathComponent("data").path))
        debug: \(options.debugLogging ? "true" : "false")

        """
    }

    private func yamlString(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "''"))'"
    }

    private func launchProcess(options: OlcRTCStartOptions, supportRoot: URL, cliURL: URL, socksPort: Int) throws {
        let configURL = try writeConfiguration(options: options, supportRoot: supportRoot, socksPort: socksPort)

        let task = Process()
        let pipe = Pipe()
        task.executableURL = cliURL
        task.currentDirectoryURL = supportRoot
        task.arguments = [configURL.path]
        task.standardOutput = pipe
        task.standardError = pipe

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.handleOutput(data)
        }

        task.terminationHandler = { [weak self] process in
            self?.handleTermination(status: process.terminationStatus)
        }

        withLock {
            process = task
            outputPipe = pipe
            outputBuffer.removeAll(keepingCapacity: true)
            ready = false
            stopping = false
            portConflictDetected = false
            activePort = socksPort
            lastOutputLine = nil
            removeConfigFile()
            self.configURL = configURL
        }

        emit("Launching \(cliURL.path)")
        emit("Using olcRTC config \(configURL.path)")
        try task.run()
    }

    private func retryAfterPortConflict(currentPort: Int) async throws -> Bool {
        let state = withLock {
            (
                options: lastOptions,
                supportRoot: lastSupportRoot,
                cliURL: lastCliURL,
                retries: retryCount
            )
        }

        guard let options = state.options,
              let supportRoot = state.supportRoot,
              let cliURL = state.cliURL,
              state.retries < maxPortRetries else {
            return false
        }

        let nextPort = currentPort == 65_535 ? 1 : currentPort + 1
        withLock {
            retryCount += 1
        }
        emit("Port \(currentPort) was rejected by macOS; retrying on \(nextPort).")
        try launchProcess(options: options, supportRoot: supportRoot, cliURL: cliURL, socksPort: nextPort)
        return true
    }

    private func handleOutput(_ data: Data) {
        let chunks = withLock {
            outputBuffer.append(data)
            return splitCompleteLines()
        }

        for chunk in chunks {
            guard let line = String(data: chunk, encoding: .utf8)?.trimmingCharacters(in: .newlines),
                  !line.isEmpty else {
                continue
            }
            withLock {
                lastOutputLine = line
            }
            emit(line)
            if line.contains("address already in use") || line.contains("failed to listen") {
                withLock {
                    portConflictDetected = true
                }
            }
            if line.contains("SOCKS5 server listening") {
                withLock {
                    ready = true
                }
            }
        }
    }

    private func splitCompleteLines() -> [Data] {
        var lines: [Data] = []
        while let range = outputBuffer.firstRange(of: Data([0x0A])) {
            lines.append(outputBuffer[..<range.lowerBound])
            outputBuffer.removeSubrange(...range.lowerBound)
        }
        return lines
    }

    private func handleTermination(status: Int32) {
        let state = withLock {
            let state = (wasStopping: stopping, remaining: outputBuffer)
            outputBuffer.removeAll(keepingCapacity: true)
            process = nil
            outputPipe?.fileHandleForReading.readabilityHandler = nil
            outputPipe = nil
            ready = false
            removeConfigFile()
            return state
        }

        if let line = String(data: state.remaining, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !line.isEmpty {
            withLock {
                lastOutputLine = line
            }
            emit(line)
        }
        if !state.wasStopping {
            emit("olcRTC process exited with status \(status).")
        }
    }

    private func clearProcess() {
        withLock {
            process = nil
            outputPipe?.fileHandleForReading.readabilityHandler = nil
            outputPipe = nil
            outputBuffer.removeAll(keepingCapacity: true)
            ready = false
            stopping = false
            portConflictDetected = false
            retryCount = 0
            activePort = nil
            lastOptions = nil
            lastSupportRoot = nil
            lastCliURL = nil
            lastOutputLine = nil
            removeConfigFile()
        }
    }

    private func startFailureMessage(lastOutputLine: String?) -> String {
        guard let lastOutputLine, !lastOutputLine.isEmpty else {
            return "olcRTC exited before SOCKS became ready."
        }

        if lastOutputLine.contains("read welcome") || lastOutputLine.contains("SERVER_WELCOME") {
            return "olcRTC handshake timed out waiting for the server. Check that srv is running with the same provider, room, transport, encryption key, and client ID."
        }

        return "olcRTC exited before SOCKS became ready: \(lastOutputLine)"
    }

    private func removeConfigFile() {
        guard let configURL else {
            return
        }
        try? FileManager.default.removeItem(at: configURL)
        self.configURL = nil
    }

    private func emit(_ message: String) {
        eventPair.continuation.yield(message)
    }

    private func cliURL(supportRoot: URL) -> URL? {
        let environment = ProcessInfo.processInfo.environment
        if let value = environment["OLCRTC_CLI_PATH"], !value.isEmpty {
            return URL(fileURLWithPath: value)
        }

        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("olcrtc-macos"),
            supportRoot.appendingPathComponent("../apple/.build/olcrtc-macos"),
            supportRoot.appendingPathComponent("build/olcrtc-darwin-arm64"),
            supportRoot.appendingPathComponent("build/olcrtc-darwin-amd64"),
            supportRoot.appendingPathComponent("build/olcrtc"),
        ]
        .compactMap { $0 }

        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private func supportRoot() -> URL? {
        let environment = ProcessInfo.processInfo.environment
        if let value = environment["OLCRTC_REPO_ROOT"], !value.isEmpty {
            return URL(fileURLWithPath: value)
        }

        let candidates = [
            Bundle.main.resourceURL,
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
            Bundle.main.bundleURL,
        ]
        .compactMap { $0 }

        for candidate in candidates {
            if let root = walkUpForSupportRoot(from: candidate) {
                return root
            }
        }

        return nil
    }

    private func walkUpForSupportRoot(from url: URL) -> URL? {
        var current = url
        for _ in 0..<10 {
            let names = current.appendingPathComponent("data/names")
            if FileManager.default.fileExists(atPath: names.path) {
                return current
            }
            let nestedNames = current.appendingPathComponent("olcrtc/data/names")
            if FileManager.default.fileExists(atPath: nestedNames.path) {
                return current.appendingPathComponent("olcrtc")
            }
            current.deleteLastPathComponent()
        }
        return nil
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
#endif
