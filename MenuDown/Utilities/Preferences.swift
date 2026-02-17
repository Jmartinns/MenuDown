import Foundation
import Combine

/// Persisted user preferences for MenuDown.
final class Preferences: ObservableObject {

    static let shared = Preferences()

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let isSpacerEnabled = "isSpacerEnabled"
        static let refreshInterval = "refreshInterval"
        static let launchAtLogin = "launchAtLogin"
        static let excludedBundleIDs = "excludedBundleIDs"
        static let customNames = "customNames"
    }

    /// Whether the spacer that hides third-party items is active.
    @Published var isSpacerEnabled: Bool {
        didSet { defaults.set(isSpacerEnabled, forKey: Keys.isSpacerEnabled) }
    }

    /// How frequently (seconds) to refresh the item list.
    @Published var refreshInterval: TimeInterval {
        didSet { defaults.set(refreshInterval, forKey: Keys.refreshInterval) }
    }

    /// Whether the app should launch at login.
    @Published var launchAtLogin: Bool {
        didSet { defaults.set(launchAtLogin, forKey: Keys.launchAtLogin) }
    }

    /// Bundle IDs the user has chosen to exclude from the vertical panel.
    @Published var excludedBundleIDs: Set<String> {
        didSet { defaults.set(Array(excludedBundleIDs), forKey: Keys.excludedBundleIDs) }
    }

    /// User-defined custom display names, keyed by bundle ID.
    private var customNames: [String: String] {
        didSet { defaults.set(customNames, forKey: Keys.customNames) }
    }

    /// Get the custom name for a bundle ID, if one has been set.
    func customName(for bundleID: String) -> String? {
        let name = customNames[bundleID]
        return (name?.isEmpty == true) ? nil : name
    }

    /// Set (or clear) a custom display name for a bundle ID.
    func setCustomName(_ name: String?, for bundleID: String) {
        if let name = name, !name.isEmpty {
            customNames[bundleID] = name
        } else {
            customNames.removeValue(forKey: bundleID)
        }
        objectWillChange.send()
    }

    private init() {
        self.isSpacerEnabled = defaults.object(forKey: Keys.isSpacerEnabled) as? Bool ?? true
        self.refreshInterval = defaults.object(forKey: Keys.refreshInterval) as? TimeInterval ?? 5.0
        self.launchAtLogin = defaults.object(forKey: Keys.launchAtLogin) as? Bool ?? false

        let excludedArray = defaults.object(forKey: Keys.excludedBundleIDs) as? [String] ?? []
        self.excludedBundleIDs = Set(excludedArray)

        self.customNames = defaults.object(forKey: Keys.customNames) as? [String: String] ?? [:]
    }
}
