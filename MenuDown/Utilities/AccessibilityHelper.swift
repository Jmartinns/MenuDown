import Cocoa
import ApplicationServices
import Combine

/// Handles checking and requesting Accessibility permissions.
/// Includes polling support since AXIsProcessTrusted() can cache its result.
final class AccessibilityHelper: ObservableObject {

    static let shared = AccessibilityHelper()

    @Published private(set) var isAccessibilityGranted: Bool = false
    @Published private(set) var isScreenRecordingGranted: Bool = false

    private var pollTimer: Timer?

    private init() {
        refresh()
    }

    /// Re-check all permissions (call after user may have changed settings).
    func refresh() {
        isAccessibilityGranted = AXIsProcessTrusted()
        isScreenRecordingGranted = Self.checkScreenRecording()
    }

    /// Start polling for permission changes (e.g. every 2 seconds).
    /// Calls `onChange` when accessibility becomes granted.
    func startPolling(interval: TimeInterval = 2.0, onChange: @escaping () -> Void) {
        stopPolling()
        pollTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let wasGranted = self.isAccessibilityGranted
            self.refresh()
            if !wasGranted && self.isAccessibilityGranted {
                onChange()
            }
        }
    }

    /// Stop polling.
    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    /// Returns `true` if the app currently has Accessibility access.
    /// Use the instance property `isAccessibilityGranted` for observable/cached checks.
    static var isAccessibilityEnabled: Bool {
        AXIsProcessTrusted()
    }

    /// Prompts the user to grant Accessibility access if not already granted.
    @discardableResult
    static func requestAccessibilityPermission() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Opens System Settings to the Accessibility privacy pane.
    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Opens System Settings to the Screen Recording privacy pane.
    static func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Checks if Screen Recording permission is likely granted.
    /// There's no official API for this; we attempt a minimal capture.
    static var isScreenRecordingEnabled: Bool {
        checkScreenRecording()
    }

    private static func checkScreenRecording() -> Bool {
        let testRect = CGRect(x: 0, y: 0, width: 1, height: 1)
        guard let image = CGWindowListCreateImage(
            testRect,
            .optionOnScreenOnly,
            kCGNullWindowID,
            .bestResolution
        ) else {
            return false
        }
        return image.width > 0
    }
}
