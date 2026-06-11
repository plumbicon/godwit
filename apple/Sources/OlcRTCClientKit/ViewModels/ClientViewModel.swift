import Foundation

private enum RunningMode {
    case localProxy
    #if os(iOS)
    case packetTunnel
    #endif
}

private let portConflictRetryAttempts = 10
private let portConflictRetryDelayNanoseconds: UInt64 = 200_000_000

private enum SubscriptionRefreshTrigger {
    case manual
    case automatic
}

private struct SubscriptionRefreshRequest {
    var id: UUID
    var sourceURL: URL
}

private struct AutomaticSubscriptionRefreshState {
    var id: UUID
    var sourceURL: URL
    var intervalSeconds: TimeInterval
    var lastFetchedAtUnix: TimeInterval?
}

private struct AutomaticSubscriptionRefreshConfiguration: Equatable {
    var id: UUID
    var sourceURL: String
    var intervalSeconds: TimeInterval
}

@MainActor
public final class ClientViewModel: ObservableObject {
    @Published public private(set) var profiles: [ConnectionProfile]
    @Published public var selectedProfileID: UUID?
    @Published public var draft: ConnectionProfile
    @Published public private(set) var status: ClientStatus = .stopped
    @Published public private(set) var logs: [String] = []
    @Published public var useSystemProxy: Bool {
        didSet {
            store.saveUseSystemProxy(useSystemProxy)
        }
    }
    @Published public var selectedNetworkService: String {
        didSet {
            store.saveSelectedNetworkService(selectedNetworkService)
        }
    }
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
    private var refreshTaskTokens: [UUID: UUID] = [:]
    private var automaticRefreshTasks: [UUID: Task<Void, Never>] = [:]
    private var automaticRefreshTaskTokens: [UUID: UUID] = [:]
    private var automaticRefreshConfigurations: [UUID: AutomaticSubscriptionRefreshConfiguration] = [:]
    private var automaticRefreshAttemptedAt: [UUID: Date] = [:]
    private var pingTasks: [UUID: Task<Void, Never>] = [:]
    private var subscriptionPingTasks: [UUID: Task<Void, Never>] = [:]
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
        let defaultUseSystemProxy = false
        #else
        let defaultUseSystemProxy = true
        #endif
        let hasStoredUseSystemProxy = store.hasUseSystemProxyPreference()
        useSystemProxy = store.loadUseSystemProxy(defaultValue: defaultUseSystemProxy)
        selectedNetworkService = store.loadSelectedNetworkService()

        let storedProfiles = store.loadProfiles()
        var loadedProfiles = storedProfiles.map { $0.normalizedForCurrentDefaults() }
        loadedProfiles = Self.initializedSubscriptionFetchTimes(in: loadedProfiles, now: Date())
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
        rescheduleAutomaticSubscriptionRefreshes()
        #if os(iOS)
        if !hasStoredUseSystemProxy {
            enableSystemVPNByDefaultIfAvailable()
        }
        #endif
    }

    deinit {
        eventTask?.cancel()
        startTask?.cancel()
        importTask?.cancel()
        refreshTasks.values.forEach { $0.cancel() }
        automaticRefreshTasks.values.forEach { $0.cancel() }
        pingTasks.values.forEach { $0.cancel() }
        subscriptionPingTasks.values.forEach { $0.cancel() }
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
        rescheduleAutomaticSubscriptionRefreshes()
    }

    public func deleteProfiles(ids: [UUID]) {
        let removedIDs = profiles.compactMap { ids.contains($0.id) ? $0.id : nil }
        profiles.removeAll { ids.contains($0.id) }
        store.deleteSecrets(profileIDs: removedIDs)
        selectProfileAfterDeletion()
        rescheduleAutomaticSubscriptionRefreshes()
    }

    public func deleteSubscription(_ id: UUID) {
        let ids = profiles.compactMap { profile in
            profile.subscription?.id == id ? profile.id : nil
        }
        deleteProfiles(ids: ids)
    }

    public func refreshSubscription(_ id: UUID) {
        saveDraft()
        startSubscriptionRefresh(id, trigger: .manual)
    }

    public func updateSubscriptionSource(_ id: UUID, sourceURL: String?) {
        let normalizedURL = sourceURL?.trimmingCharacters(in: .whitespacesAndNewlines)
        let storedURL = normalizedURL?.isEmpty == true ? nil : normalizedURL
        let fetchBaseline = Date().timeIntervalSince1970

        for index in profiles.indices where profiles[index].subscription?.id == id {
            profiles[index].subscription?.sourceURL = storedURL
            if storedURL != nil, profiles[index].subscription?.lastFetchedAtUnix == nil {
                profiles[index].subscription?.lastFetchedAtUnix = fetchBaseline
            }
        }

        if draft.subscription?.id == id {
            draft.subscription?.sourceURL = storedURL
            if storedURL != nil, draft.subscription?.lastFetchedAtUnix == nil {
                draft.subscription?.lastFetchedAtUnix = fetchBaseline
            }
        }

        persistProfiles()
        rescheduleAutomaticSubscriptionRefreshes()
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

        guard subscriptionPingTasks[id] == nil else {
            return
        }

        let subscriptionName = profilesToPing.first?.subscription?.name ?? AppLocalization.string("subscription")
        appendLog(AppLocalization.format("Pinging subscription %@: %d profile(s).", subscriptionName, profilesToPing.count))

        // Ping every profile in the subscription at once.
        subscriptionPingTasks[id] = Task { [weak self] in
            guard let self else { return }
            defer { subscriptionPingTasks[id] = nil }

            // Validate up front; queue only the profiles worth pinging.
            var queue: [ConnectionProfile] = []
            for profile in profilesToPing {
                // Skip profiles already being pinged on their own to avoid double work.
                if pingTasks[profile.id] != nil { continue }

                if let validationMessage = validate(profile: profile) {
                    pingResults[profile.id] = .failure(message: validationMessage)
                    appendLog(
                        AppLocalization.format(
                            "Ping for %@ was not started: %@",
                            profileLogName(profile),
                            validationMessage
                        )
                    )
                    continue
                }

                queue.append(profile)
            }

            await withTaskGroup(of: Void.self) { group in
                for profile in queue {
                    group.addTask { await self.performPing(profile) }
                }
            }
        }
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
            appendLog(
                AppLocalization.format(
                    "SOCKS port %d appears busy; trying olcRTC start anyway.",
                    profileToStart.socksPort
                )
            )
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
                let activePort = try await startEngineUntilReady(options: options)
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

    private func startEngineUntilReady(options: OlcRTCStartOptions) async throws -> Int {
        for attempt in 0...portConflictRetryAttempts {
            do {
                try await engine.start(options: options)
                try await engine.waitReady(
                    timeoutMillis: max(options.startTimeoutMillis, ConnectionProfile.defaultStartTimeoutMillis)
                )
                return await engine.activeSocksPort ?? options.socksPort
            } catch {
                await engine.stop()

                guard !(error is CancellationError) else {
                    throw error
                }

                guard attempt < portConflictRetryAttempts,
                      isSocksPortConflict(error, port: options.socksPort) else {
                    throw error
                }

                appendLog(
                    AppLocalization.format(
                        "SOCKS port %d is still being released; retrying.",
                        options.socksPort
                    )
                )
                try await Task.sleep(nanoseconds: portConflictRetryDelayNanoseconds)
            }
        }

        throw OlcRTCEngineError.invalidProfile(
            AppLocalization.format(
                "SOCKS port %d is busy. Stop the existing process or choose another port.",
                options.socksPort
            )
        )
    }

    private func isSocksPortConflict(_ error: Error, port: Int) -> Bool {
        let message = error.localizedDescription.lowercased()
        let localizedBusyPort = AppLocalization.format(
            "SOCKS port %d is busy. Stop the existing process or choose another port.",
            port
        ).lowercased()

        return message.contains(localizedBusyPort) ||
            message.contains("address already in use") ||
            message.contains("failed to listen") ||
            message.contains("bind")
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
        pingTasks[profileID] = Task { [weak self] in
            guard let self else { return }
            defer { pingTasks[profileID] = nil }
            await performPing(profile)
        }
    }

    private func performPing(_ profile: ConnectionProfile) async {
        let profileID = profile.id
        let profileName = profileLogName(profile)
        pingingProfileIDs.insert(profileID)
        pingResults[profileID] = nil
        defer { pingingProfileIDs.remove(profileID) }

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
        let importedProfiles = profilesWithSubscriptionFetchTime(imported.profiles, fetchedAt: Date())
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
        profiles.append(contentsOf: importedProfiles)
        if let firstProfile = importedProfiles.first {
            selectedProfileID = firstProfile.id
            draft = firstProfile
        }
        persistProfiles()
        rescheduleAutomaticSubscriptionRefreshes()
        appendLog(AppLocalization.format("Imported subscription %@: %d server(s).", imported.name, importedProfiles.count))
    }

    private func refreshSubscription(
        _ value: String,
        sourceURL: URL,
        existingSubscriptionID: UUID,
        fetchedAt: Date
    ) throws {
        saveDraft()

        let imported = try subscriptionParser.parse(value, sourceURL: sourceURL)
        let importedProfiles = profilesWithSubscriptionFetchTime(imported.profiles, fetchedAt: fetchedAt)
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
        for importedProfile in importedProfiles {
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
        rescheduleAutomaticSubscriptionRefreshes()
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

    @discardableResult
    private func startSubscriptionRefresh(
        _ id: UUID,
        trigger: SubscriptionRefreshTrigger
    ) -> Task<Void, Never>? {
        if trigger == .automatic, refreshTasks[id] != nil {
            return nil
        }

        guard let request = subscriptionRefreshRequest(for: id, shouldLogFailures: trigger == .manual) else {
            return nil
        }

        if trigger == .manual {
            refreshTasks[id]?.cancel()
        } else if refreshTasks[id] != nil {
            return nil
        }

        let token = UUID()
        refreshTaskTokens[id] = token
        let task = Task { [weak self] in
            guard let self else { return }
            await performSubscriptionRefresh(request, token: token)
        }
        refreshTasks[id] = task
        return task
    }

    private func subscriptionRefreshRequest(
        for id: UUID,
        shouldLogFailures: Bool
    ) -> SubscriptionRefreshRequest? {
        guard let metadata = profiles.compactMap(\.subscription).first(where: { $0.id == id }) else {
            if shouldLogFailures {
                appendLog(AppLocalization.string("Could not refresh subscription: subscription was not found."))
            }
            return nil
        }

        guard let sourceURLValue = metadata.sourceURL, let sourceURL = URL(string: sourceURLValue) else {
            if shouldLogFailures {
                appendLog(AppLocalization.format("Subscription %@ has no refresh URL.", metadata.name))
            }
            return nil
        }

        return SubscriptionRefreshRequest(id: id, sourceURL: sourceURL)
    }

    private func performSubscriptionRefresh(_ request: SubscriptionRefreshRequest, token: UUID) async {
        refreshingSubscriptionIDs.insert(request.id)
        defer {
            if refreshTaskTokens[request.id] == token {
                refreshingSubscriptionIDs.remove(request.id)
                refreshTasks[request.id] = nil
                refreshTaskTokens[request.id] = nil
            }
        }

        do {
            let content = try await fetchSubscription(from: request.sourceURL)
            guard !Task.isCancelled else {
                return
            }
            try refreshSubscription(
                content,
                sourceURL: request.sourceURL,
                existingSubscriptionID: request.id,
                fetchedAt: Date()
            )
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else {
                return
            }
            appendLog(AppLocalization.format("Could not refresh subscription: %@", error.localizedDescription))
        }
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

    private func rescheduleAutomaticSubscriptionRefreshes() {
        let states = automaticSubscriptionRefreshStates()
        let desiredIDs = Set(states.map(\.id))

        for id in Array(automaticRefreshTasks.keys) where !desiredIDs.contains(id) {
            automaticRefreshTasks[id]?.cancel()
            automaticRefreshTasks[id] = nil
            automaticRefreshTaskTokens[id] = nil
            automaticRefreshConfigurations[id] = nil
            automaticRefreshAttemptedAt[id] = nil
        }

        for state in states {
            let configuration = AutomaticSubscriptionRefreshConfiguration(
                id: state.id,
                sourceURL: state.sourceURL.absoluteString,
                intervalSeconds: state.intervalSeconds
            )
            if automaticRefreshConfigurations[state.id] == configuration,
               automaticRefreshTasks[state.id] != nil {
                continue
            }

            automaticRefreshTasks[state.id]?.cancel()
            automaticRefreshAttemptedAt[state.id] = nil

            let token = UUID()
            automaticRefreshTaskTokens[state.id] = token
            automaticRefreshConfigurations[state.id] = configuration
            automaticRefreshTasks[state.id] = Task { [weak self] in
                await self?.runAutomaticSubscriptionRefreshLoop(subscriptionID: state.id, token: token)
            }
        }
    }

    private func runAutomaticSubscriptionRefreshLoop(subscriptionID id: UUID, token: UUID) async {
        defer {
            if automaticRefreshTaskTokens[id] == token {
                automaticRefreshTasks[id] = nil
                automaticRefreshTaskTokens[id] = nil
                automaticRefreshConfigurations[id] = nil
                automaticRefreshAttemptedAt[id] = nil
            }
        }

        while !Task.isCancelled {
            guard let state = automaticSubscriptionRefreshState(for: id) else {
                return
            }

            let delay = automaticRefreshDelay(for: state, now: Date())
            guard await sleepForAutomaticRefresh(seconds: delay) else {
                return
            }
            guard !Task.isCancelled, automaticRefreshTaskTokens[id] == token else {
                return
            }

            guard automaticSubscriptionRefreshState(for: id) != nil else {
                return
            }
            automaticRefreshAttemptedAt[id] = Date()

            if let refreshTask = startSubscriptionRefresh(id, trigger: .automatic) {
                await refreshTask.value
            }
        }
    }

    private func automaticSubscriptionRefreshState(for id: UUID) -> AutomaticSubscriptionRefreshState? {
        automaticSubscriptionRefreshStates().first { $0.id == id }
    }

    private func automaticSubscriptionRefreshStates() -> [AutomaticSubscriptionRefreshState] {
        var seenIDs: Set<UUID> = []
        var states: [AutomaticSubscriptionRefreshState] = []

        for profile in profiles {
            guard let metadata = profile.subscription,
                  !seenIDs.contains(metadata.id),
                  let sourceURLValue = metadata.sourceURL?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !sourceURLValue.isEmpty,
                  let sourceURL = URL(string: sourceURLValue),
                  let intervalSeconds = SubscriptionRefreshInterval.seconds(from: metadata.refreshInterval),
                  SubscriptionRefreshInterval.nanoseconds(from: intervalSeconds) != nil else {
                continue
            }

            seenIDs.insert(metadata.id)
            states.append(
                AutomaticSubscriptionRefreshState(
                    id: metadata.id,
                    sourceURL: sourceURL,
                    intervalSeconds: intervalSeconds,
                    lastFetchedAtUnix: metadata.lastFetchedAtUnix
                )
            )
        }

        return states
    }

    private func automaticRefreshDelay(
        for state: AutomaticSubscriptionRefreshState,
        now: Date
    ) -> TimeInterval {
        let anchors = [
            state.lastFetchedAtUnix.map(Date.init(timeIntervalSince1970:)),
            automaticRefreshAttemptedAt[state.id],
        ].compactMap { $0 }

        guard let anchor = anchors.max() else {
            return state.intervalSeconds
        }

        return max(0, anchor.addingTimeInterval(state.intervalSeconds).timeIntervalSince(now))
    }

    private func sleepForAutomaticRefresh(seconds: TimeInterval) async -> Bool {
        guard seconds > 0 else {
            return !Task.isCancelled
        }
        guard let nanoseconds = SubscriptionRefreshInterval.nanoseconds(from: seconds) else {
            return false
        }

        do {
            try await Task.sleep(nanoseconds: nanoseconds)
            return !Task.isCancelled
        } catch {
            return false
        }
    }

    private func profilesWithSubscriptionFetchTime(
        _ profiles: [ConnectionProfile],
        fetchedAt: Date
    ) -> [ConnectionProfile] {
        let fetchedAtUnix = fetchedAt.timeIntervalSince1970
        return profiles.map { profile in
            var profile = profile
            profile.subscription?.lastFetchedAtUnix = fetchedAtUnix
            return profile
        }
    }

    private static func initializedSubscriptionFetchTimes(
        in profiles: [ConnectionProfile],
        now: Date
    ) -> [ConnectionProfile] {
        let fetchedAtUnix = now.timeIntervalSince1970
        return profiles.map { profile in
            var profile = profile
            let sourceURL = profile.subscription?.sourceURL?.trimmingCharacters(in: .whitespacesAndNewlines)
            if profile.subscription?.lastFetchedAtUnix == nil,
               sourceURL?.isEmpty == false,
               SubscriptionRefreshInterval.seconds(from: profile.subscription?.refreshInterval) != nil {
                profile.subscription?.lastFetchedAtUnix = fetchedAtUnix
            }
            return profile
        }
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
        if profile.roomID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
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
