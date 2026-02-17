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
    private lazy var reorderer = MenuBarReorderer(spacerManager: spacerManager, scanner: scanner)
    private var changeMonitor: ChangeMonitor?
    private var panelController: VerticalPanelController?
    private var cancellables = Set<AnyCancellable>()
    private var globalHotkeyMonitor: Any?
    private var localHotkeyMonitor: Any?
    private var welcomeWindow: NSWindow?

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
        setupGlobalHotkey()
        startScanning()

        // Show welcome window on first launch
        if Preferences.shared.isFirstLaunch {
            Preferences.shared.markLaunched()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.showWelcomeWindow()
            }
        }
        
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
        if let monitor = globalHotkeyMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let monitor = localHotkeyMonitor {
            NSEvent.removeMonitor(monitor)
        }
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

        // Let the scanner include MenuDown in its own list
        scanner.selfStatusItem = statusItem
        reorderer.selfStatusItem = statusItem
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
            },
            onReorderApplied: { [weak self] items in
                self?.reorderer.applyOrder(items)
            }
        )
    }

    // MARK: - Permissions

    private func checkPermissions() {
        // Trigger the native macOS accessibility prompt if not yet trusted.
        // No custom alert loops — the system prompt is sufficient.
        if !AccessibilityHelper.isAccessibilityEnabled {
            AccessibilityHelper.requestAccessibilityPermission()
        }

        // Poll for accessibility permission changes — the user may grant
        // it while the app is running.
        AccessibilityHelper.shared.startPolling(interval: 2.0) { [weak self] in
            self?.debugLog("Accessibility permission detected via polling — starting scan.")
            self?.scanner.scanAsync()
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

    // MARK: - Global Hotkey (⌥M)

    private func setupGlobalHotkey() {
        // Monitor key events when MenuDown is NOT the active app
        globalHotkeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleHotkey(event)
        }
        // Monitor key events when MenuDown IS the active app
        localHotkeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if self?.handleHotkey(event) == true {
                return nil // Consume the event
            }
            return event
        }
    }

    /// Returns true if the event was the ⌥M hotkey and was handled.
    @discardableResult
    private func handleHotkey(_ event: NSEvent) -> Bool {
        // ⌥M: keyCode 46 = 'm', check for Option modifier only
        guard event.keyCode == 46,
              event.modifierFlags.contains(.option),
              !event.modifierFlags.contains(.command),
              !event.modifierFlags.contains(.control) else {
            return false
        }
        DispatchQueue.main.async { [weak self] in
            self?.togglePanelViaHotkey()
        }
        return true
    }

    private func togglePanelViaHotkey() {
        guard let button = statusItem.button else { return }
        panelController?.toggle(relativeTo: button)

        if panelController?.isVisible == true {
            scanner.scanAsync()
            captureIconsInBackground()
        }
    }

    // MARK: - Welcome Window

    private func showWelcomeWindow() {
        let welcomeView = WelcomeView(onDismiss: { [weak self] in
            self?.welcomeWindow?.close()
            self?.welcomeWindow = nil
        })

        let hostingController = NSHostingController(rootView: welcomeView)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 340),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = hostingController
        window.title = "Welcome to MenuDown"
        window.center()
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        self.welcomeWindow = window
    }
}
