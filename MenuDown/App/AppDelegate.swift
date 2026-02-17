import Cocoa
import SwiftUI
import Combine
import os.log

private let appLogger = Logger(subsystem: "com.menudown.app", category: "app")

/// The main application delegate. Sets up the status item, scanner, spacer,
/// and vertical panel — the core of MenuDown.
final class AppDelegate: NSObject, NSApplicationDelegate {

    // MARK: - Components
    private var statusItem: NSStatusItem!
    private let scanner = MenuBarScanner()
    private let spacerManager = SpacerManager()
    private let iconCapturer = IconCapturer()
    private lazy var clickForwarder = ClickForwarder(spacerManager: spacerManager, scanner: scanner)
    private var changeMonitor: ChangeMonitor?
    private var panelController: VerticalPanelController?
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Write debug info to a file we can easily read
        let trusted = AXIsProcessTrusted()
        debugLog("=== MenuDown launched. AXIsProcessTrusted: \(trusted) ===")
        
        setupStatusItem()
        
        // Check and request permissions
        checkPermissions()
        debugLog("AX enabled: \(AccessibilityHelper.isAccessibilityEnabled)")
        debugLog("Screen recording: \(AccessibilityHelper.isScreenRecordingEnabled)")
        
        setupPanel()
        setupChangeMonitor()
        startScanning()
        
        // Check after a delay to let async scan complete
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.debugLog("Items after 3s: \(self?.scanner.items.count ?? -1)")
        }
    }
    
    private func debugLog(_ message: String) {
        let line = "[\(Date())] \(message)\n"
        let path = "/tmp/menudown_debug.log"
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(line.data(using: .utf8)!)
            handle.closeFile()
        } else {
            try? line.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        scanner.stopScanning()
        spacerManager.reveal() // Ensure items are visible when we quit
        spacerManager.uninstall()
        changeMonitor?.stopMonitoring()
    }

    // MARK: - Status Item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.autosaveName = "com.menudown.main"

        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "arrow.down.circle",
                accessibilityDescription: "MenuDown"
            )
            button.action = #selector(statusItemClicked(_:))
            button.target = self
        }
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        // Show panel immediately with cached data — don't block on scan
        panelController?.toggle(relativeTo: sender)

        // Refresh items and icons in background for next time
        if panelController?.isVisible == true {
            scanner.scanAsync()
            captureIconsInBackground()
        }
    }

    // MARK: - Panel

    private func setupPanel() {
        panelController = VerticalPanelController(
            scanner: scanner,
            onItemClicked: { [weak self] item in
                self?.clickForwarder.click(item)
            },
            onSettingsClicked: { [weak self] in
                self?.showSettings()
            }
        )
    }

    // MARK: - Permissions

    private func checkPermissions() {
        if !AccessibilityHelper.isAccessibilityEnabled {
            promptForAccessibility()
        }

        // Poll for accessibility permission changes — the user may grant
        // it while the app is running.
        AccessibilityHelper.shared.startPolling(interval: 2.0) { [weak self] in
            self?.debugLog("Accessibility permission detected via polling — starting scan.")
            self?.scanner.scanAsync()
        }

        if !AccessibilityHelper.isScreenRecordingEnabled {
            let alert = NSAlert()
            alert.messageText = "Screen Recording Permission"
            alert.informativeText = "MenuDown needs Screen Recording access to capture menubar item icons. Without it, app icons will be used as fallback."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "Open Settings")
            alert.addButton(withTitle: "Later")

            if alert.runModal() == .alertFirstButtonReturn {
                AccessibilityHelper.openScreenRecordingSettings()
            }
        }
    }

    /// Prompt the user to grant Accessibility, with a loop for "recheck".
    private func promptForAccessibility() {
        // Trigger the system prompt (adds the app to System Settings list)
        AccessibilityHelper.requestAccessibilityPermission()

        while !AXIsProcessTrusted() {
            let alert = NSAlert()
            alert.messageText = "Accessibility Permission Required"
            alert.informativeText = """
            MenuDown needs Accessibility access to discover menubar items.

            Please toggle MenuDown ON in:
            System Settings → Privacy & Security → Accessibility

            Tip: If you just rebuilt the app, you may need to remove the old \
            MenuDown entry (−) and re-add it (+).
            """
            alert.alertStyle = .informational
            alert.addButton(withTitle: "Open Settings")
            alert.addButton(withTitle: "Recheck Now")
            alert.addButton(withTitle: "Skip")

            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                AccessibilityHelper.openAccessibilitySettings()
            } else if response == .alertThirdButtonReturn {
                // User chose Skip
                debugLog("User skipped accessibility prompt.")
                break
            }
            // For "Recheck Now" or after opening settings, loop back
            // and re-check AXIsProcessTrusted()
            if AXIsProcessTrusted() {
                debugLog("Recheck: AX is now trusted!")
                scanner.scanAsync()
                break
            }
        }
    }

    // MARK: - Scanning

    private func startScanning() {
        // Install the spacer
        spacerManager.install()

        // Start periodic scanning (now runs on background queue)
        let interval = Preferences.shared.refreshInterval
        scanner.startScanning(interval: interval)

        // Capture icons once after initial scan completes
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.captureIconsInBackground()
        }

        // If spacer is enabled in prefs, hide items
        if Preferences.shared.isSpacerEnabled {
            // Delay slightly to let the scanner do a first pass
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                self?.spacerManager.hide()
            }
        }
    }

    private func captureIconsIfNeeded() {
        guard AccessibilityHelper.isScreenRecordingEnabled else { return }
        let items = scanner.items

        if spacerManager.isHiding {
            // Items are off-screen — briefly reveal to capture
            spacerManager.brieflyReveal(duration: 0.1) { [weak self] in
                self?.iconCapturer.captureIcons(for: items)
            }
        } else {
            iconCapturer.captureIcons(for: items)
        }
    }

    /// Capture icons on a background queue without blocking the UI.
    private func captureIconsInBackground() {
        guard AccessibilityHelper.isScreenRecordingEnabled else { return }
        let items = scanner.items
        guard !items.isEmpty else { return }

        // Only capture for items that don't already have an icon
        let needsCapture = items.filter { $0.capturedIcon == nil }
        guard !needsCapture.isEmpty else { return }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            if self.spacerManager.isHiding {
                DispatchQueue.main.async {
                    self.spacerManager.brieflyReveal(duration: 0.08) {
                        self.iconCapturer.captureIcons(for: needsCapture)
                    }
                }
            } else {
                self.iconCapturer.captureIcons(for: needsCapture)
            }
        }
    }

    // MARK: - Change Monitor

    private func setupChangeMonitor() {
        changeMonitor = ChangeMonitor { [weak self] in
            self?.scanner.scanAsync()
        }
        changeMonitor?.startMonitoring()
    }

    // MARK: - Settings

    private func showSettings() {
        let menu = NSMenu()

        // Toggle spacer
        let spacerTitle = spacerManager.isHiding ? "Show Original Items" : "Hide Original Items"
        let spacerMenuItem = NSMenuItem(title: spacerTitle, action: #selector(toggleSpacer), keyEquivalent: "")
        spacerMenuItem.target = self
        menu.addItem(spacerMenuItem)

        menu.addItem(.separator())

        // Refresh
        let refreshItem = NSMenuItem(title: "Refresh Now", action: #selector(refreshNow), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        menu.addItem(.separator())

        // About
        let aboutItem = NSMenuItem(title: "About MenuDown", action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)

        // Quit
        let quitItem = NSMenuItem(title: "Quit MenuDown", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        // Remove the menu after it's shown so clicks go back to the action handler
        DispatchQueue.main.async { [weak self] in
            self?.statusItem.menu = nil
        }
    }

    @objc private func toggleSpacer() {
        if spacerManager.isHiding {
            spacerManager.reveal()
            Preferences.shared.isSpacerEnabled = false
        } else {
            spacerManager.hide()
            Preferences.shared.isSpacerEnabled = true
        }
    }

    @objc private func refreshNow() {
        scanner.scanAsync()
        captureIconsInBackground()
    }

    @objc private func showAbout() {
        NSApp.orderFrontStandardAboutPanel(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}
