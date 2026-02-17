import Cocoa
import ApplicationServices

/// Represents a discovered third-party menubar item.
final class MenuBarItem: Identifiable, ObservableObject {
    let id: String  // bundleID + index for uniqueness
    let pid: pid_t
    let bundleID: String
    let appName: String
    let axElement: AXUIElement

    @Published var position: CGPoint
    @Published var size: CGSize
    @Published var title: String?
    @Published var capturedIcon: NSImage?
    @Published var isVisible: Bool = true

    /// The app's icon, resolved eagerly at init time so the UI never
    /// shows a placeholder while waiting for the screenshot-based capture.
    @Published var appIcon: NSImage?

    /// Permanent icon cache shared across all MenuBarItem instances.
    /// Uses a plain dictionary (not NSCache) so icons are never auto-evicted.
    private static var iconStore: [String: NSImage] = [:]
    private static let iconLock = NSLock()

    /// Look up a cached icon, thread-safe.
    private static func cachedIcon(for bundleID: String) -> NSImage? {
        iconLock.lock()
        defer { iconLock.unlock() }
        return iconStore[bundleID]
    }

    /// Store an icon in the cache, thread-safe.
    private static func cacheIcon(_ icon: NSImage, for bundleID: String) {
        iconLock.lock()
        iconStore[bundleID] = icon
        iconLock.unlock()
    }

    init(
        axElement: AXUIElement,
        pid: pid_t,
        bundleID: String,
        appName: String,
        position: CGPoint,
        size: CGSize,
        title: String?,
        index: Int
    ) {
        self.axElement = axElement
        self.pid = pid
        self.bundleID = bundleID
        self.appName = appName
        self.position = position
        self.size = size
        self.title = title
        self.id = "\(bundleID)_\(index)"

        // Use the permanent cache — icons resolved once stay forever.
        // This avoids issues with NSRunningApplication.icon returning nil
        // on background threads.
        self.appIcon = Self.cachedIcon(for: bundleID)
    }

    /// Resolve and cache this item's icon. Must be called on the main thread
    /// (AppKit icon APIs are not thread-safe).
    func resolveIconIfNeeded() {
        guard appIcon == nil else { return }

        // Check cache again (another item with the same bundle ID may have resolved it)
        if let cached = Self.cachedIcon(for: bundleID) {
            appIcon = cached
            return
        }

        if let icon = NSRunningApplication(processIdentifier: pid)?.icon {
            Self.cacheIcon(icon, for: bundleID)
            appIcon = icon
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            Self.cacheIcon(icon, for: bundleID)
            appIcon = icon
        }
    }

    /// Whether this item represents MenuDown itself.
    var isSelf: Bool {
        bundleID == (Bundle.main.bundleIdentifier ?? "com.menudown.app")
    }

    /// Display name: prefer user override, then app name.
    /// The AX title is often an internal identifier (e.g. "menubaricon_v3"),
    /// so we use the app's localized name by default.
    var displayName: String {
        // User override takes priority
        if let custom = Preferences.shared.customName(for: bundleID) {
            return custom
        }
        return appName
    }

    /// The raw AX title, useful as a subtitle to disambiguate
    /// apps with multiple status items.
    var subtitle: String? {
        if let title = title, !title.isEmpty, title != appName {
            return title
        }
        return nil
    }

    /// Whether this item belongs to a system (Apple) process.
    static func isSystemProcess(bundleID: String) -> Bool {
        // Known system menubar processes
        let alwaysSystem: Set<String> = [
            "com.apple.controlcenter",
            "com.apple.systemuiserver",
            "com.apple.Siri",
            "com.apple.TextInputMenuAgent",
            "com.apple.ViewBridgeAuxiliary",
            "com.apple.notificationcenterui",
            "com.apple.AccessibilityUIServer",
            "com.apple.WiFiAgent",
            "com.apple.BluetoothUIService",
        ]

        // Apple apps that act like third-party (have optional status items)
        let appleButThirdParty: Set<String> = [
            "com.apple.dt.Xcode",
            "com.apple.FinalCut",
            "com.apple.Logic10",
        ]

        if alwaysSystem.contains(bundleID) { return true }
        if appleButThirdParty.contains(bundleID) { return false }

        return bundleID.hasPrefix("com.apple.")
    }
}
