import Foundation

public final class ProfileStore {
    private let defaults: UserDefaults
    private let secretStore: ProfileSecretStore
    private let profilesKey = "olcrtc.apple.profiles.v1"
    private let selectedKey = "olcrtc.apple.selectedProfile.v1"
    private let useSystemProxyKey = "olcrtc.apple.useSystemProxy.v1"
    private let selectedNetworkServiceKey = "olcrtc.apple.selectedNetworkService.v1"

    public init(
        defaults: UserDefaults = .standard,
        secretStore: ProfileSecretStore = ProfileSecretStore()
    ) {
        self.defaults = defaults
        self.secretStore = secretStore
    }

    public func loadProfiles() -> [ConnectionProfile] {
        guard let data = defaults.data(forKey: profilesKey) else {
            return []
        }

        do {
            var profiles = try JSONDecoder().decode([ConnectionProfile].self, from: data)
            secretStore.loadSecrets(into: &profiles)
            return profiles
        } catch {
            return []
        }
    }

    public func saveProfiles(_ profiles: [ConnectionProfile]) {
        secretStore.saveSecrets(from: profiles)
        let publicProfiles = profiles.map { profile in
            var profile = profile
            profile.keyHex = ""
            profile.socksPass = ""
            return profile
        }

        guard let data = try? JSONEncoder().encode(publicProfiles) else {
            return
        }

        defaults.set(data, forKey: profilesKey)
    }

    public func deleteSecrets(profileIDs: [UUID]) {
        profileIDs.forEach(secretStore.deleteSecrets)
    }

    public func loadSelectedProfileID() -> UUID? {
        guard let value = defaults.string(forKey: selectedKey) else {
            return nil
        }

        return UUID(uuidString: value)
    }

    public func saveSelectedProfileID(_ id: UUID?) {
        defaults.set(id?.uuidString, forKey: selectedKey)
    }

    public func hasUseSystemProxyPreference() -> Bool {
        defaults.object(forKey: useSystemProxyKey) != nil
    }

    public func loadUseSystemProxy(defaultValue: Bool) -> Bool {
        guard let value = defaults.object(forKey: useSystemProxyKey) as? Bool else {
            return defaultValue
        }
        return value
    }

    public func saveUseSystemProxy(_ value: Bool) {
        defaults.set(value, forKey: useSystemProxyKey)
    }

    public func loadSelectedNetworkService(defaultValue: String = "Wi-Fi") -> String {
        guard let value = defaults.string(forKey: selectedNetworkServiceKey),
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return defaultValue
        }
        return value
    }

    public func saveSelectedNetworkService(_ value: String) {
        defaults.set(value, forKey: selectedNetworkServiceKey)
    }
}
