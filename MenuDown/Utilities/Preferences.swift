import Foundation
import Combine

enum InteractionFallbackMode: String, CaseIterable {
    case ask
    case alwaysUseSafeSwap
    case neverUseSafeSwap
}

/// Persisted user preferences for MenuDown.
final class Preferences: ObservableObject {

    static let shared = Preferences()

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let refreshInterval = "refreshInterval"
        static let launchAtLogin = "launchAtLogin"
        static let excludedBundleIDs = "excludedBundleIDs"
        static let customNames = "customNames"
        static let hasLaunchedBefore = "hasLaunchedBefore"
        static let itemOrder = "itemOrder"
        static let interactionFallbackMode = "interactionFallbackMode"
        static let hasShownRevealTooltip = "hasShownRevealTooltip"
    }

    /// How frequently (seconds) to refresh the item list.
    @Published var refreshInterval: TimeInterval {
        didSet { defaults.set(refreshInterval, forKey: Keys.refreshInterval) }
    }

    /// Whether the app should launch at login.
    @Published var launchAtLogin: Bool {
        didSet { defaults.set(launchAtLogin, forKey: Keys.launchAtLogin) }
    }

    /// Whether the first-time reveal tooltip has been shown.
    var hasShownRevealTooltip: Bool {
        get { defaults.bool(forKey: Keys.hasShownRevealTooltip) }
        set { defaults.set(newValue, forKey: Keys.hasShownRevealTooltip) }
    }

    /// Bundle IDs the user has chosen to exclude from the vertical panel.
    @Published var excludedBundleIDs: Set<String> {
        didSet { defaults.set(Array(excludedBundleIDs), forKey: Keys.excludedBundleIDs) }
    }

    /// Policy for handling blocked menubar interactions.
    @Published var interactionFallbackMode: InteractionFallbackMode {
        didSet { defaults.set(interactionFallbackMode.rawValue, forKey: Keys.interactionFallbackMode) }
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
        self.refreshInterval = defaults.object(forKey: Keys.refreshInterval) as? TimeInterval ?? 5.0
        self.launchAtLogin = defaults.object(forKey: Keys.launchAtLogin) as? Bool ?? false

        let excludedArray = defaults.object(forKey: Keys.excludedBundleIDs) as? [String] ?? []
        self.excludedBundleIDs = Set(excludedArray)
        self.interactionFallbackMode = InteractionFallbackMode(
            rawValue: defaults.string(forKey: Keys.interactionFallbackMode) ?? ""
        ) ?? .ask

        self.customNames = defaults.object(forKey: Keys.customNames) as? [String: String] ?? [:]
    }

    /// Whether this is the first time the app has been launched.
    var isFirstLaunch: Bool {
        !defaults.bool(forKey: Keys.hasLaunchedBefore)
    }

    /// Mark that the app has been launched at least once.
    func markLaunched() {
        defaults.set(true, forKey: Keys.hasLaunchedBefore)
    }

    // MARK: - Item Order

    /// Saved ordering of menubar items, stored as an array of bundle IDs.
    /// Items not in this list appear at the end in their natural order.
    var itemOrder: [String] {
        get { defaults.object(forKey: Keys.itemOrder) as? [String] ?? [] }
        set { defaults.set(newValue, forKey: Keys.itemOrder) }
    }

    /// Returns true if the user has set a custom order.
    var hasCustomOrder: Bool {
        !itemOrder.isEmpty
    }
}
