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
    @Published public var useSystemProxy = false
    #else
    @Published public var useSystemProxy = true
    #endif
    @Published public var selectedNetworkService = "Wi-Fi"
    @Published public private(set) var networkServices: [String] = ["Wi-Fi"]
    @Published public private(set) var isImporting = false
    @Published public private(set) var importErrorMessage: String?
    @Published public private(set) var refreshingSubscriptionIDs: Set<UUID> = []

    private let engine: OlcRTCEngine
    private let store: ProfileStore
    private let uriParser: OlcRTCURIParser
    private let subscriptionParser: OlcRTCSubscriptionParser
    private let subscriptionFetcher: SubscriptionFetcher
    private let systemProxyManager: SystemProxyManager
    #if os(iOS)
    private let packetTunnelManager = PacketTunnelManager()
    private let backgroundRuntimeKeeper = BackgroundRuntimeKeeper()
    #endif
    private var eventTask: Task<Void, Never>?
    private var startTask: Task<Void, Never>?
    private var importTask: Task<Void, Never>?
    private var refreshTasks: [UUID: Task<Void, Never>] = [:]
    private var runningMode: RunningMode?

    public init(
        engine: OlcRTCEngine = OlcRTCEngineFactory.makeDefault(),
        store: ProfileStore = ProfileStore(),
        uriParser: OlcRTCURIParser = OlcRTCURIParser(),
        subscriptionParser: OlcRTCSubscriptionParser? = nil,
        subscriptionFetcher: SubscriptionFetcher = SubscriptionFetcher(),
        systemProxyManager: SystemProxyManager = SystemProxyManager()
    ) {
        self.engine = engine
        self.store = store
        self.uriParser = uriParser
        self.subscriptionParser = subscriptionParser ?? OlcRTCSubscriptionParser(uriParser: uriParser)
        self.subscriptionFetcher = subscriptionFetcher
        self.systemProxyManager = systemProxyManager

        let loadedProfiles = store.loadProfiles().map { $0.normalizedForCurrentDefaults() }
        let selected = store.loadSelectedProfileID()
        let initialProfile = loadedProfiles.first(where: { $0.id == selected }) ?? loadedProfiles.first

        profiles = loadedProfiles
        selectedProfileID = initialProfile?.id
        draft = initialProfile ?? .empty

        observeEngineEvents()
        loadNetworkServices()
    }

    deinit {
        eventTask?.cancel()
        startTask?.cancel()
        importTask?.cancel()
        refreshTasks.values.forEach { $0.cancel() }
        #if os(iOS)
        Task { @MainActor [backgroundRuntimeKeeper] in
            backgroundRuntimeKeeper.stop()
        }
        #endif
    }

    public var selectedProfileName: String {
        guard selectedProfileID != nil else {
            return "Нет профиля"
        }

        return draft.name.isEmpty ? "Без названия" : draft.name
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
        profile.name = "Профиль \(profiles.count + 1)"
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
            newProfile.name = "Профиль \(profiles.count + 1)"
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
            appendLog("Не удалось обновить подписку: подписка не найдена.")
            return
        }

        guard let sourceURLValue = metadata.sourceURL, let sourceURL = URL(string: sourceURLValue) else {
            appendLog("У подписки \(metadata.name) нет ссылки для обновления.")
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
                appendLog("Не удалось обновить подписку: \(error.localizedDescription)")
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
                let message = "Не удалось импортировать подписку: \(error.localizedDescription)"
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
            appendLog("Импортирована olcRTC-ссылка профиля.")
        } catch {
            let message = "Не удалось импортировать профиль: \(error.localizedDescription)"
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

        var profileToStart = draft.normalizedForCurrentDefaults()
        let availableSocksPort = PortAvailability.nextAvailableTCPPort(startingAt: profileToStart.socksPort)
        if availableSocksPort != profileToStart.socksPort {
            appendLog("SOCKS-порт \(profileToStart.socksPort) занят; используется \(availableSocksPort).")
            profileToStart.socksPort = availableSocksPort
        }
        if profileToStart != draft {
            draft = profileToStart
            saveDraft()
        }

        if let validationMessage = validate(profile: profileToStart) {
            status = .failed(validationMessage)
            appendLog("Профиль заполнен не полностью: \(validationMessage)")
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
        appendLog("Подключение: \(selectedProfileName).")

        startTask = Task { [weak self] in
            guard let self else { return }

            do {
                try await engine.start(options: options)
                try await engine.waitReady(
                    timeoutMillis: max(options.startTimeoutMillis, ConnectionProfile.defaultStartTimeoutMillis)
                )
                let activePort = await engine.activeSocksPort ?? options.socksPort
                if activePort != draft.socksPort {
                    draft.socksPort = activePort
                    saveDraft()
                }
                status = .ready
                appendLog("SOCKS-прокси готов на 127.0.0.1:\(activePort).")
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
                appendLog("Не удалось подключиться: \(error.localizedDescription)")
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
        appendLog("Отключение: \(selectedProfileName).")

        Task { [weak self] in
            guard let self else { return }
            switch runningMode {
            #if os(iOS)
            case .packetTunnel:
                await packetTunnelManager.stop()
                appendLog("iOS VPN-туннель остановлен.")
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

    public func clearLogs() {
        logs.removeAll()
    }

    private func persistProfiles() {
        store.saveProfiles(profiles)
        store.saveSelectedProfileID(selectedProfileID)
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
        appendLog("Импортирована подписка \(imported.name): \(imported.profiles.count) сервер(ов).")
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
            "Подписка \(imported.name) обновлена: " +
            "\(matchedExistingIDs.count) обновлено, " +
            "\(refreshedProfiles.count - matchedExistingIDs.count) добавлено, " +
            "\(deletedIDs.count) удалено."
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
            profile.clientID,
            profile.keyHex,
        ].joined(separator: "|")
        let connectionKey = [
            profile.carrier.rawValue,
            profile.transport.rawValue,
            profile.roomID,
            profile.clientID,
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
        appendLog("Загрузка подписки: \(url.absoluteString).")
        do {
            return try await subscriptionFetcher.fetchWithURLSession(from: url)
        } catch {
            guard subscriptionFetcher.shouldRetryThroughResolvedEndpoint(error),
                  let host = url.host(percentEncoded: false),
                  url.scheme?.lowercased() == "https" else {
                throw error
            }

            appendLog("DNS-запрос для \(host) не прошел; повтор через DNS-over-HTTPS.")
            do {
                return try await subscriptionFetcher.fetchThroughResolvedEndpoint(from: url)
            } catch {
                appendLog("Повтор через DNS-over-HTTPS не прошел: \(error.localizedDescription)")
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
    private func startLocalProxyBackgroundRuntime() {
        do {
            try backgroundRuntimeKeeper.start()
            appendLog("Фоновый режим iOS активен для локального SOCKS.")
        } catch {
            appendLog("Не удалось включить фоновый режим iOS: \(error.localizedDescription)")
        }
    }

    private func startPacketTunnel(profile: ConnectionProfile) {
        status = .starting
        runningMode = .packetTunnel
        appendLog("Подключение \(selectedProfileName) через iOS VPN.")

        startTask = Task { [weak self] in
            guard let self else { return }

            do {
                try await packetTunnelManager.start(profile: profile)
                status = .ready
                appendLog("iOS VPN-туннель подключен. Системный трафик идет через olcRTC.")
            } catch {
                if error is CancellationError {
                    await packetTunnelManager.stop()
                    return
                }

                runningMode = nil
                status = .failed(error.localizedDescription)
                appendLog("Не удалось запустить VPN: \(vpnStartFailureMessage(error))")
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
            appendLog("Системный SOCKS-прокси выключен. Настройте приложения вручную на 127.0.0.1:\(port).")
            return
        }

        do {
            try await systemProxyManager.enable(service: selectedNetworkService, host: "127.0.0.1", port: port)
            appendLog("Системный SOCKS-прокси включен для \(selectedNetworkService) на 127.0.0.1:\(port).")
        } catch {
            appendLog("Не удалось настроить системный прокси: \(error.localizedDescription)")
        }
        #else
        appendLog("Системный трафик iOS не перенаправляется автоматически. Настройте приложения вручную на 127.0.0.1:\(port).")
        #endif
    }

    private func disableSystemProxyIfNeeded() async {
        #if os(macOS)
        guard useSystemProxy else {
            return
        }

        do {
            try await systemProxyManager.disable(service: selectedNetworkService)
            appendLog("Системный SOCKS-прокси отключен для \(selectedNetworkService).")
        } catch {
            appendLog("Не удалось очистить настройки системного прокси: \(error.localizedDescription)")
        }
        #endif
    }

    private func validate(profile: ConnectionProfile) -> String? {
        if profile.clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Укажите Client ID."
        }
        if profile.keyHex.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Укажите ключ шифрования."
        }
        if profile.keyHex.count != 64 || !profile.keyHex.allSatisfy(\.isHexDigit) {
            return "Ключ должен содержать 64 шестнадцатеричных символа."
        }
        if profile.carrier != .jazz && profile.roomID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return profile.carrier == .jitsi
                ? "Для Jitsi укажите Room URL."
                : "Для этого провайдера нужен Room ID."
        }
        if !(1...65_535).contains(profile.socksPort) {
            return "SOCKS-порт должен быть от 1 до 65535."
        }
        if profile.transport == .videochannel {
            if !["qrcode", "tile"].contains(profile.videoCodec) {
                return "Video codec должен быть qrcode или tile."
            }
            if profile.videoWidth <= 0 || profile.videoHeight <= 0 {
                return "Укажите размер videochannel."
            }
            if profile.videoFPS <= 0 {
                return "Укажите FPS videochannel."
            }
            if profile.videoBitrate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "Укажите битрейт videochannel."
            }
            if !["none", "nvenc"].contains(profile.videoHardwareAcceleration) {
                return "Аппаратное ускорение должно быть none или nvenc."
            }
            if !["low", "medium", "high", "highest"].contains(profile.videoQRRecovery) {
                return "QR коррекция должна быть low, medium, high или highest."
            }
            if profile.videoCodec == "tile" && (profile.videoWidth != 1080 || profile.videoHeight != 1080) {
                return "Для tile codec нужен размер 1080x1080."
            }
        }

        return nil
    }
}
