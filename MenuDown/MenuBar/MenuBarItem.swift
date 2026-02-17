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
        // MenuDown's own status item should not appear in its own list
        if bundleID == Bundle.main.bundleIdentifier ?? "com.menudown.app" {
            return true
        }

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
