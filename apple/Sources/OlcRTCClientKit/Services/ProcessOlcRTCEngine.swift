import Foundation
#if canImport(Darwin)
import Darwin
#endif

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
    private var activePort: Int?
    private var lastOutputLine: String?
    private var configURL: URL?

    public init() {}

    deinit {
        process?.terminate()
        #if canImport(Darwin)
        if let process, process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
        #endif
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        removeConfigFile()
    }

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
            throw OlcRTCEngineError.cliMissing(
                "olcRTC support files were not found. Set OLCRTC_REPO_ROOT or build the app with --olcrtc-root."
            )
        }
        guard let cliURL = cliURL(supportRoot: supportRoot) else {
            throw OlcRTCEngineError.cliMissing(
                "macOS CLI binary was not found. Run ./apple/Scripts/build-macos-cli.sh."
            )
        }

        withLock {
            activePort = options.socksPort
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
                if state.portConflict, let port = state.activePort {
                    throw OlcRTCEngineError.invalidProfile(
                        AppLocalization.format(
                            "SOCKS port %d is busy. Stop the existing process or choose another port.",
                            port
                        )
                    )
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

        await waitForExitOrKill(task)

        clearProcess()
    }

    private func validate(_ options: OlcRTCStartOptions) throws {
        if options.keyHex.count != 64 || !options.keyHex.allSatisfy(\.isHexDigit) {
            throw OlcRTCEngineError.invalidProfile("Encryption key must be 64 hexadecimal characters.")
        }
        if options.roomID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
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
        let yaml = OlcRTCConfigYAMLBuilder(options: options, socksPort: socksPort).yaml()
        try yaml.write(to: url, atomically: true, encoding: .utf8)
        return url
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
        emit("olcRTC profile provider=\(options.carrierName) transport=\(options.transportName)")
        do {
            try task.run()
        } catch {
            clearProcess()
            throw error
        }
    }

    private func waitForExitOrKill(_ task: Process) async {
        let didExit = await Task.detached {
            let deadline = Date().addingTimeInterval(2)
            while task.isRunning && Date() < deadline {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            return !task.isRunning
        }.value

        guard !didExit, task.isRunning else {
            return
        }

        emit("olcRTC process did not exit after terminate; killing it.")
        #if canImport(Darwin)
        kill(task.processIdentifier, SIGKILL)
        #else
        task.terminate()
        #endif

        await Task.detached {
            task.waitUntilExit()
        }.value
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
            activePort = nil
            lastOutputLine = nil
            removeConfigFile()
        }
    }

    private func startFailureMessage(lastOutputLine: String?) -> String {
        guard let lastOutputLine, !lastOutputLine.isEmpty else {
            return "olcRTC exited before SOCKS became ready."
        }

        if lastOutputLine.contains("read welcome") || lastOutputLine.contains("SERVER_WELCOME") {
            return "olcRTC handshake timed out waiting for the server. Check that srv is running with the same provider, room, transport, and encryption key."
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

        var candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("olcrtc-macos"),
            supportRoot.appendingPathComponent("build/olcrtc-darwin-arm64"),
            supportRoot.appendingPathComponent("build/olcrtc-darwin-amd64"),
            supportRoot.appendingPathComponent("build/olcrtc"),
        ]
        .compactMap { $0 }

        let bundleURL = Bundle.main.resourceURL ?? Bundle.main.bundleURL
        if let root = walkUpForSupportRoot(from: bundleURL) {
            candidates.append(root.appendingPathComponent("olcrtc-macos"))
        }

        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private func supportRoot() -> URL? {
        let environment = ProcessInfo.processInfo.environment

        if let value = environment["OLCRTC_REPO_ROOT"], !value.isEmpty {
            return URL(fileURLWithPath: value)
        }

        var candidates = [
            Bundle.main.resourceURL,
            Bundle.main.bundleURL,
        ]
        .compactMap { $0 }

        for candidate in candidates {
            if let root = walkUpForSupportRoot(from: candidate) {
                return root
            }
        }

        candidates.removeAll()
        if environment["OLCRTC_ALLOW_CWD_SUPPORT_ROOT"] == "1" {
            candidates.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
        }

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
