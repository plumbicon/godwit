import Foundation

private enum RunningMode {
    case localProxy
    #if os(iOS)
    case packetTunnel
    #endif
}

@MainActor
public final class ClientViewModel: ObservableObject {
    @Published public private(set) var profiles: [ConnectionProfile]
    @Published public var selectedProfileID: UUID?
    @Published public var draft: ConnectionProfile
    @Published public private(set) var status: ClientStatus = .stopped
    @Published public private(set) var logs: [String] = []
    #if os(iOS)
    @Published public var useSystemProxy: Bool
    #else
    @Published public var useSystemProxy = true
    #endif
    @Published public var selectedNetworkService = "Wi-Fi"
    @Published public private(set) var networkServices: [String] = ["Wi-Fi"]
    @Published public private(set) var isImporting = false
    @Published public private(set) var importErrorMessage: String?
    @Published public private(set) var refreshingSubscriptionIDs: Set<UUID> = []
    @Published public private(set) var pingingProfileIDs: Set<UUID> = []
    @Published public private(set) var pingResults: [UUID: ProfilePingState] = [:]

    private let engine: OlcRTCEngine
    private let store: ProfileStore
    private let uriParser: OlcRTCURIParser
    private let subscriptionParser: OlcRTCSubscriptionParser
    private let subscriptionFetcher: SubscriptionFetcher
    private let profilePinger: any ProfilePinging
    private let systemProxyManager: SystemProxyManager
    #if os(iOS)
    private let packetTunnelManager = PacketTunnelManager()
    private let backgroundRuntimeKeeper = BackgroundRuntimeKeeper()
    #endif
    private var eventTask: Task<Void, Never>?
    private var startTask: Task<Void, Never>?
    private var importTask: Task<Void, Never>?
    private var refreshTasks: [UUID: Task<Void, Never>] = [:]
    private var pingTasks: [UUID: Task<Void, Never>] = [:]
    private var runningMode: RunningMode?

    public init(
        engine: OlcRTCEngine = OlcRTCEngineFactory.makeDefault(),
        store: ProfileStore = ProfileStore(),
        uriParser: OlcRTCURIParser = OlcRTCURIParser(),
        subscriptionParser: OlcRTCSubscriptionParser? = nil,
        subscriptionFetcher: SubscriptionFetcher = SubscriptionFetcher(),
        profilePinger: any ProfilePinging = ProfilePinger(),
        systemProxyManager: SystemProxyManager = SystemProxyManager()
    ) {
        self.engine = engine
        self.store = store
        self.uriParser = uriParser
        self.subscriptionParser = subscriptionParser ?? OlcRTCSubscriptionParser(uriParser: uriParser)
        self.subscriptionFetcher = subscriptionFetcher
        self.profilePinger = profilePinger
        self.systemProxyManager = systemProxyManager
        #if os(iOS)
        useSystemProxy = false
        #endif

        let storedProfiles = store.loadProfiles()
        let loadedProfiles = storedProfiles.map { $0.normalizedForCurrentDefaults() }
        if loadedProfiles != storedProfiles {
            store.saveProfiles(loadedProfiles)
        }
        let selected = store.loadSelectedProfileID()
        let initialProfile = loadedProfiles.first(where: { $0.id == selected }) ?? loadedProfiles.first

        profiles = loadedProfiles
        selectedProfileID = initialProfile?.id
        draft = initialProfile ?? .empty

        observeEngineEvents()
        loadNetworkServices()
        #if os(iOS)
        enableSystemVPNByDefaultIfAvailable()
        #endif
    }

    deinit {
        eventTask?.cancel()
        startTask?.cancel()
        importTask?.cancel()
        refreshTasks.values.forEach { $0.cancel() }
        pingTasks.values.forEach { $0.cancel() }
        #if os(iOS)
        Task { @MainActor [backgroundRuntimeKeeper] in
            backgroundRuntimeKeeper.stop()
        }
        #endif
    }

    public var selectedProfileName: String {
        guard selectedProfileID != nil else {
            return AppLocalization.string("No profile")
        }

        return draft.name.isEmpty ? AppLocalization.string("Untitled") : draft.name
    }

    public var canStart: Bool {
        selectedProfileID != nil && !status.isRunning && validationMessage == nil
    }

    public var validationMessage: String? {
        validate(profile: draft)
    }

    public func validationMessage(for profile: ConnectionProfile) -> String? {
        validate(profile: profile)
    }

    public func selectProfile(_ id: UUID?) {
        saveDraft()
        guard let id, let profile = profiles.first(where: { $0.id == id }) else {
            return
        }

        selectedProfileID = id
        draft = profile
        store.saveSelectedProfileID(id)
    }

    public func addProfile() {
        saveDraft()

        var profile = ConnectionProfile.empty
        profile.name = AppLocalization.format("Profile %d", profiles.count + 1)
        profiles.append(profile)
        selectedProfileID = profile.id
        draft = profile
        persistProfiles()
    }

    public func createProfile(_ profile: ConnectionProfile) {
        saveDraft()

        var newProfile = profile.normalizedForCurrentDefaults()
        newProfile.id = UUID()
        newProfile.subscription = nil
        if newProfile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            newProfile.name = AppLocalization.format("Profile %d", profiles.count + 1)
        }

        replacePlaceholderIfNeeded()
        profiles.append(newProfile)
        selectedProfileID = newProfile.id
        draft = newProfile
        persistProfiles()
    }

    public func deleteProfiles(at offsets: IndexSet) {
        let removedIDs = offsets.compactMap { profiles.indices.contains($0) ? profiles[$0].id : nil }
        for offset in offsets.sorted(by: >) {
            if profiles.indices.contains(offset) {
                profiles.remove(at: offset)
            }
        }
        store.deleteSecrets(profileIDs: removedIDs)
        selectProfileAfterDeletion()
    }

    public func deleteProfiles(ids: [UUID]) {
        let removedIDs = profiles.compactMap { ids.contains($0.id) ? $0.id : nil }
        profiles.removeAll { ids.contains($0.id) }
        store.deleteSecrets(profileIDs: removedIDs)
        selectProfileAfterDeletion()
    }

    public func deleteSubscription(_ id: UUID) {
        let ids = profiles.compactMap { profile in
            profile.subscription?.id == id ? profile.id : nil
        }
        deleteProfiles(ids: ids)
    }

    public func refreshSubscription(_ id: UUID) {
        saveDraft()

        guard let metadata = profiles.compactMap(\.subscription).first(where: { $0.id == id }) else {
            appendLog(AppLocalization.string("Could not refresh subscription: subscription was not found."))
            return
        }

        guard let sourceURLValue = metadata.sourceURL, let sourceURL = URL(string: sourceURLValue) else {
            appendLog(AppLocalization.format("Subscription %@ has no refresh URL.", metadata.name))
            return
        }

        refreshTasks[id]?.cancel()
        refreshTasks[id] = Task { [weak self] in
            guard let self else { return }
            refreshingSubscriptionIDs.insert(id)
            defer {
                refreshingSubscriptionIDs.remove(id)
                refreshTasks[id] = nil
            }

            do {
                let content = try await fetchSubscription(from: sourceURL)
                try refreshSubscription(content, sourceURL: sourceURL, existingSubscriptionID: id)
            } catch {
                appendLog(AppLocalization.format("Could not refresh subscription: %@", error.localizedDescription))
            }
        }
    }

    public func updateSubscriptionSource(_ id: UUID, sourceURL: String?) {
        let normalizedURL = sourceURL?.trimmingCharacters(in: .whitespacesAndNewlines)
        let storedURL = normalizedURL?.isEmpty == true ? nil : normalizedURL

        for index in profiles.indices where profiles[index].subscription?.id == id {
            profiles[index].subscription?.sourceURL = storedURL
        }

        if draft.subscription?.id == id {
            draft.subscription?.sourceURL = storedURL
        }

        persistProfiles()
    }

    public func pingProfile(_ id: UUID) {
        saveDraft()
        guard let profile = profiles.first(where: { $0.id == id }) else {
            appendLog(AppLocalization.string("Could not ping: profile was not found."))
            return
        }
        startPing(profile)
    }

    public func pingSubscription(_ id: UUID) {
        saveDraft()
        let profilesToPing = profiles.filter { $0.subscription?.id == id }
        guard !profilesToPing.isEmpty else {
            appendLog(AppLocalization.string("Could not ping subscription: no profiles found."))
            return
        }

        let subscriptionName = profilesToPing.first?.subscription?.name ?? AppLocalization.string("subscription")
        appendLog(AppLocalization.format("Pinging subscription %@: %d profile(s).", subscriptionName, profilesToPing.count))
        profilesToPing.forEach(startPing)
    }

    public func importValue(_ value: String) {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            return
        }

        importTask?.cancel()
        importTask = Task { [weak self] in
            guard let self else { return }
            importErrorMessage = nil
            isImporting = true
            defer { isImporting = false }

            do {
                if let url = subscriptionURL(from: value) {
                    let content = try await fetchSubscription(from: url)
                    try importSubscription(content, sourceURL: url)
                    return
                }

                if value.lowercased().hasPrefix("olcrtc://") && !value.contains("\n") {
                    importURI(value)
                    return
                }

                try importSubscription(value, sourceURL: nil)
            } catch {
                let message = AppLocalization.format(
                    "Could not import subscription: %@",
                    error.localizedDescription
                )
                importErrorMessage = message
                appendLog(message)
            }
        }
    }

    public func importURI(_ value: String) {
        do {
            importErrorMessage = nil
            saveDraft()
            var profile = try uriParser.parse(value, into: .empty)
            profile.id = UUID()
            profile.subscription = nil
            replacePlaceholderIfNeeded()
            profiles.append(profile)
            selectedProfileID = profile.id
            draft = profile
            persistProfiles()
            appendLog(AppLocalization.string("Imported olcRTC profile link."))
        } catch {
            let message = AppLocalization.format("Could not import profile: %@", error.localizedDescription)
            importErrorMessage = message
            appendLog(message)
        }
    }

    public func clearImportError() {
        importErrorMessage = nil
    }

    public func saveDraft() {
        guard let index = profiles.firstIndex(where: { $0.id == draft.id }) else {
            return
        }

        profiles[index] = draft
        persistProfiles()
    }

    public func start() {
        saveDraft()
        startTask?.cancel()

        let profileToStart = draft.normalizedForCurrentDefaults()
        if profileToStart != draft {
            draft = profileToStart
            saveDraft()
        }

        if let validationMessage = validate(profile: profileToStart) {
            status = .failed(validationMessage)
            appendLog(AppLocalization.format("Profile is incomplete: %@", validationMessage))
            return
        }

        if !PortAvailability.isLocalTCPPortAvailable(profileToStart.socksPort) {
            let message = AppLocalization.format(
                "SOCKS port %d is busy. Stop the existing process or choose another port.",
                profileToStart.socksPort
            )
            status = .failed(message)
            appendLog(message)
            return
        }

        #if os(iOS)
        if useSystemProxy {
            startPacketTunnel(profile: profileToStart)
            return
        }
        #endif

        let options = OlcRTCStartOptions(profile: profileToStart)
        status = .starting
        runningMode = .localProxy
        appendLog(AppLocalization.format("Connecting: %@.", selectedProfileName))

        startTask = Task { [weak self] in
            guard let self else { return }

            do {
                try await engine.start(options: options)
                try await engine.waitReady(
                    timeoutMillis: max(options.startTimeoutMillis, ConnectionProfile.defaultStartTimeoutMillis)
                )
                let activePort = await engine.activeSocksPort ?? options.socksPort
                status = .ready
                appendLog(AppLocalization.format("SOCKS proxy is ready on 127.0.0.1:%d.", activePort))
                #if os(iOS)
                startLocalProxyBackgroundRuntime()
                #endif
                await enableSystemProxyIfNeeded(port: activePort)
            } catch {
                if error is CancellationError {
                    await engine.stop()
                    return
                }

                runningMode = nil
                status = .failed(error.localizedDescription)
                appendLog(AppLocalization.format("Could not connect: %@", error.localizedDescription))
                #if os(iOS)
                backgroundRuntimeKeeper.stop()
                #endif
                await engine.stop()
            }
        }
    }

    public func stop() {
        startTask?.cancel()
        status = .stopping
        appendLog(AppLocalization.format("Disconnecting: %@.", selectedProfileName))

        Task { [weak self] in
            guard let self else { return }
            switch runningMode {
            #if os(iOS)
            case .packetTunnel:
                await packetTunnelManager.stop()
                appendLog(AppLocalization.string("iOS VPN tunnel stopped."))
            #endif
            case .localProxy, nil:
                #if os(iOS)
                backgroundRuntimeKeeper.stop()
                #endif
                await disableSystemProxyIfNeeded()
                await engine.stop()
            }
            runningMode = nil
            status = .stopped
        }
    }

    public func shutdownForAppTermination() {
        guard status.isRunning || runningMode != nil else {
            return
        }
        stop()
    }

    public func clearLogs() {
        logs.removeAll()
    }

    private func persistProfiles() {
        store.saveProfiles(profiles)
        store.saveSelectedProfileID(selectedProfileID)
    }

    private func startPing(_ profile: ConnectionProfile) {
        guard pingTasks[profile.id] == nil else {
            return
        }

        if let validationMessage = validate(profile: profile) {
            pingResults[profile.id] = .failure(message: validationMessage)
            appendLog(
                AppLocalization.format(
                    "Ping for %@ was not started: %@",
                    profileLogName(profile),
                    validationMessage
                )
            )
            return
        }

        let profileID = profile.id
        let profileName = profileLogName(profile)
        pingingProfileIDs.insert(profileID)
        pingResults[profileID] = nil

        pingTasks[profileID] = Task { [weak self] in
            guard let self else { return }
            defer {
                pingingProfileIDs.remove(profileID)
                pingTasks[profileID] = nil
            }

            do {
                let result = try await profilePinger.ping(profile: profile)
                guard !Task.isCancelled else { return }
                pingResults[profileID] = .success(milliseconds: result.milliseconds)
                appendLog(AppLocalization.format("Ping %@: %d ms.", profileName, result.milliseconds))
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                pingResults[profileID] = .failure(message: error.localizedDescription)
                appendLog(AppLocalization.format("Ping %@ failed: %@", profileName, error.localizedDescription))
            }
        }
    }

    private func profileLogName(_ profile: ConnectionProfile) -> String {
        profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? AppLocalization.string("Untitled")
            : profile.name
    }

    private func selectProfileAfterDeletion() {
        if let selectedProfileID, profiles.contains(where: { $0.id == selectedProfileID }) {
            persistProfiles()
            return
        }

        if let profile = profiles.first {
            selectedProfileID = profile.id
            draft = profile
        } else {
            selectedProfileID = nil
            draft = .empty
        }
        persistProfiles()
    }

    private func importSubscription(_ value: String, sourceURL: URL?) throws {
        saveDraft()

        let imported = try subscriptionParser.parse(value, sourceURL: sourceURL)
        let existingIDs: Set<UUID>
        if let sourceURL {
            existingIDs = Set(
                profiles.compactMap { profile in
                    profile.subscription?.sourceURL == sourceURL.absoluteString ? profile.id : nil
                }
            )
        } else {
            existingIDs = []
        }

        if !existingIDs.isEmpty {
            profiles.removeAll { existingIDs.contains($0.id) }
            store.deleteSecrets(profileIDs: Array(existingIDs))
        }

        replacePlaceholderIfNeeded()
        profiles.append(contentsOf: imported.profiles)
        if let firstProfile = imported.profiles.first {
            selectedProfileID = firstProfile.id
            draft = firstProfile
        }
        persistProfiles()
        appendLog(AppLocalization.format("Imported subscription %@: %d server(s).", imported.name, imported.profiles.count))
    }

    private func refreshSubscription(_ value: String, sourceURL: URL, existingSubscriptionID: UUID) throws {
        saveDraft()

        let imported = try subscriptionParser.parse(value, sourceURL: sourceURL)
        let existingIndices = profiles.indices.filter { index in
            profiles[index].subscription?.id == existingSubscriptionID
        }
        let existingProfiles = existingIndices.map { profiles[$0] }
        guard let insertionIndex = existingIndices.min() else {
            try importSubscription(value, sourceURL: sourceURL)
            return
        }

        var existingByKey: [String: ConnectionProfile] = [:]
        for profile in existingProfiles {
            for key in subscriptionProfileKeys(profile) where existingByKey[key] == nil {
                existingByKey[key] = profile
            }
        }

        var matchedExistingIDs: Set<UUID> = []
        var refreshedProfiles: [ConnectionProfile] = []
        for importedProfile in imported.profiles {
            var profile = importedProfile
            profile.subscription?.id = existingSubscriptionID

            if let existingProfile = subscriptionProfileKeys(importedProfile).compactMap({ existingByKey[$0] }).first {
                profile = mergeImportedSubscriptionProfile(profile, preservingLocalSettingsFrom: existingProfile)
                matchedExistingIDs.insert(existingProfile.id)
            }

            refreshedProfiles.append(profile)
        }

        let deletedIDs = existingProfiles
            .map(\.id)
            .filter { !matchedExistingIDs.contains($0) }

        profiles.removeAll { profile in
            profile.subscription?.id == existingSubscriptionID
        }
        profiles.insert(contentsOf: refreshedProfiles, at: min(insertionIndex, profiles.count))

        if !deletedIDs.isEmpty {
            store.deleteSecrets(profileIDs: deletedIDs)
        }

        if let selectedProfileID, let selectedProfile = profiles.first(where: { $0.id == selectedProfileID }) {
            draft = selectedProfile
        } else if let firstProfile = refreshedProfiles.first {
            selectedProfileID = firstProfile.id
            draft = firstProfile
        }

        persistProfiles()
        appendLog(
            AppLocalization.format(
                "Subscription %@ refreshed: %d updated, %d added, %d removed.",
                imported.name,
                matchedExistingIDs.count,
                refreshedProfiles.count - matchedExistingIDs.count,
                deletedIDs.count
            )
        )
    }

    private func mergeImportedSubscriptionProfile(
        _ importedProfile: ConnectionProfile,
        preservingLocalSettingsFrom existingProfile: ConnectionProfile
    ) -> ConnectionProfile {
        var profile = importedProfile
        profile.id = existingProfile.id
        profile.socksPort = existingProfile.socksPort
        profile.socksUser = existingProfile.socksUser
        profile.socksPass = existingProfile.socksPass
        profile.dnsServer = existingProfile.dnsServer
        profile.debugLogging = existingProfile.debugLogging
        profile.startTimeoutMillis = existingProfile.startTimeoutMillis
        return profile
    }

    private func subscriptionProfileKeys(_ profile: ConnectionProfile) -> [String] {
        let nodeURI = profile.subscription?.nodeURI?.trimmingCharacters(in: .whitespacesAndNewlines)
        let fullConnectionKey = [
            profile.carrier.rawValue,
            profile.transport.rawValue,
            profile.roomID,
            profile.keyHex,
        ].joined(separator: "|")
        let connectionKey = [
            profile.carrier.rawValue,
            profile.transport.rawValue,
            profile.roomID,
        ].joined(separator: "|")

        var keys: [String] = []
        if let nodeURI, !nodeURI.isEmpty {
            keys.append("uri:\(nodeURI)")
        }
        keys.append("connection-full:\(fullConnectionKey)")
        keys.append("connection:\(connectionKey)")
        return keys
    }

    private func replacePlaceholderIfNeeded() {
        guard profiles.count == 1, isEmptyPlaceholder(profiles[0]) else {
            return
        }

        let profileID = profiles[0].id
        profiles.removeAll()
        store.deleteSecrets(profileIDs: [profileID])
    }

    private func isEmptyPlaceholder(_ profile: ConnectionProfile) -> Bool {
        let empty = ConnectionProfile.empty
        var comparable = profile
        comparable.id = empty.id
        return comparable == empty
    }

    private func subscriptionURL(from value: String) -> URL? {
        if let url = URL(string: value),
           let scheme = url.scheme?.lowercased(),
           ["http", "https"].contains(scheme),
           url.host(percentEncoded: false) != nil {
            return url
        }

        guard !value.contains("\n"),
              !value.lowercased().hasPrefix("olcrtc://"),
              value.contains("."),
              let url = URL(string: "https://\(value)"),
              url.host(percentEncoded: false) != nil else {
            return nil
        }
        return url
    }

    private func fetchSubscription(from url: URL) async throws -> String {
        appendLog(AppLocalization.format("Loading subscription: %@.", url.absoluteString))
        do {
            return try await subscriptionFetcher.fetchWithURLSession(from: url)
        } catch {
            guard subscriptionFetcher.shouldRetryThroughResolvedEndpoint(error),
                  let host = url.host(percentEncoded: false),
                  url.scheme?.lowercased() == "https" else {
                throw error
            }

            appendLog(AppLocalization.format("DNS lookup for %@ failed; retrying through DNS-over-HTTPS.", host))
            do {
                return try await subscriptionFetcher.fetchThroughResolvedEndpoint(from: url)
            } catch {
                appendLog(AppLocalization.format("Retry through DNS-over-HTTPS failed: %@", error.localizedDescription))
                throw error
            }
        }
    }

    private func observeEngineEvents() {
        eventTask = Task { [weak self] in
            guard let self else { return }
            for await message in engine.events {
                appendLog(message)
            }
        }
    }

    private func appendLog(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        logs.append("[\(formatter.string(from: Date()))] \(message)")
        if logs.count > 300 {
            logs.removeFirst(logs.count - 300)
        }
    }

    private func loadNetworkServices() {
        Task { [weak self] in
            guard let self else { return }
            let services = await systemProxyManager.networkServices()
            networkServices = services.isEmpty ? ["Wi-Fi"] : services
            if !networkServices.contains(selectedNetworkService) {
                selectedNetworkService = networkServices.first ?? "Wi-Fi"
            }
        }
    }

    #if os(iOS)
    private func enableSystemVPNByDefaultIfAvailable() {
        Task { [weak self] in
            guard let self,
                  await PacketTunnelManager.canAccessPacketTunnelPreferences() else {
                return
            }
            useSystemProxy = true
        }
    }

    private func startLocalProxyBackgroundRuntime() {
        do {
            try backgroundRuntimeKeeper.start()
            appendLog(AppLocalization.string("iOS background mode is active for local SOCKS."))
        } catch {
            appendLog(AppLocalization.format("Could not enable iOS background mode: %@", error.localizedDescription))
        }
    }

    private func startPacketTunnel(profile: ConnectionProfile) {
        status = .starting
        runningMode = .packetTunnel
        appendLog(AppLocalization.format("Connecting %@ through iOS VPN.", selectedProfileName))

        startTask = Task { [weak self] in
            guard let self else { return }

            do {
                try await packetTunnelManager.start(profile: profile)
                status = .ready
                appendLog(AppLocalization.string("iOS VPN tunnel connected. System traffic is routed through olcRTC."))
            } catch {
                if error is CancellationError {
                    await packetTunnelManager.stop()
                    return
                }

                runningMode = nil
                status = .failed(error.localizedDescription)
                appendLog(AppLocalization.format("Could not start VPN: %@", vpnStartFailureMessage(error)))
                await packetTunnelManager.stop()
            }
        }
    }

    private func vpnStartFailureMessage(_ error: Error) -> String {
        let message = error.localizedDescription
        guard message.localizedCaseInsensitiveContains("IPC failed") else {
            return message
        }

        #if targetEnvironment(simulator)
        return "\(message). Rebuild the simulator app with signing enabled so the Packet Tunnel extension gets simulated entitlements."
        #else
        return "\(message). Check that the app and Packet Tunnel extension profiles include the Network Extension packet-tunnel-provider entitlement."
        #endif
    }
    #endif

    private func enableSystemProxyIfNeeded(port: Int) async {
        #if os(macOS)
        guard useSystemProxy else {
            appendLog(
                AppLocalization.format(
                    "System SOCKS proxy is off. Configure apps manually for 127.0.0.1:%d.",
                    port
                )
            )
            return
        }

        do {
            try await systemProxyManager.enable(service: selectedNetworkService, host: "127.0.0.1", port: port)
            appendLog(
                AppLocalization.format(
                    "System SOCKS proxy is enabled for %@ on 127.0.0.1:%d.",
                    selectedNetworkService,
                    port
                )
            )
        } catch {
            appendLog(AppLocalization.format("Could not configure system proxy: %@", error.localizedDescription))
        }
        #else
        appendLog(
            AppLocalization.format(
                "iOS system traffic is not routed automatically. Configure apps manually for 127.0.0.1:%d.",
                port
            )
        )
        #endif
    }

    private func disableSystemProxyIfNeeded() async {
        #if os(macOS)
        guard useSystemProxy else {
            return
        }

        do {
            try await systemProxyManager.disable(service: selectedNetworkService)
            appendLog(AppLocalization.format("System SOCKS proxy is disabled for %@.", selectedNetworkService))
        } catch {
            appendLog(AppLocalization.format("Could not clear system proxy settings: %@", error.localizedDescription))
        }
        #endif
    }

    private func validate(profile: ConnectionProfile) -> String? {
        if profile.keyHex.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return AppLocalization.string("Enter the encryption key.")
        }
        if profile.keyHex.count != 64 || !profile.keyHex.allSatisfy(\.isHexDigit) {
            return AppLocalization.string("The key must contain 64 hexadecimal characters.")
        }
        if profile.carrier != .jazz && profile.roomID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return profile.carrier == .jitsi
                ? AppLocalization.string("Enter a Room URL for Jitsi.")
                : AppLocalization.string("This provider requires a Room ID.")
        }
        if !ConnectionProfile.socksPortRange.contains(profile.socksPort) {
            return AppLocalization.string("SOCKS port must be between 1024 and 65535.")
        }
        if profile.transport == .videochannel {
            if !["qrcode", "tile"].contains(profile.videoCodec) {
                return AppLocalization.string("Video codec must be qrcode or tile.")
            }
            if profile.videoWidth <= 0 || profile.videoHeight <= 0 {
                return AppLocalization.string("Enter the videochannel size.")
            }
            if profile.videoFPS <= 0 {
                return AppLocalization.string("Enter the videochannel FPS.")
            }
            if profile.videoBitrate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return AppLocalization.string("Enter the videochannel bitrate.")
            }
            if !["none", "nvenc"].contains(profile.videoHardwareAcceleration) {
                return AppLocalization.string("Hardware acceleration must be none or nvenc.")
            }
            if !["low", "medium", "high", "highest"].contains(profile.videoQRRecovery) {
                return AppLocalization.string("QR correction must be low, medium, high, or highest.")
            }
            if profile.videoCodec == "tile" && (profile.videoWidth != 1080 || profile.videoHeight != 1080) {
                return AppLocalization.string("Tile codec requires 1080x1080 size.")
            }
        }

        return nil
    }
}
