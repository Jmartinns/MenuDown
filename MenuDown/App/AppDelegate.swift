import Cocoa
import SwiftUI
import Combine
import os.log
import Sparkle
import Carbon

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
    private var globalHotKeyRef: EventHotKeyRef?
    private var hotKeyHandlerRef: EventHandlerRef?
    private var welcomeWindow: NSWindow?
    private let updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

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
        unregisterGlobalHotkey()
    }

    // MARK: - Status Item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.autosaveName = "com.menudown.main"

        if let button = statusItem.button {
            let icon = NSImage(named: "MenuBarIcon")
            icon?.isTemplate = true
            button.image = icon
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
            // Re-register the global hotkey after trust changes.
            self?.setupGlobalHotkey()
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
        // Avoid reveal/re-hide flashes while hidden; capture can happen when shown.
        guard !spacerManager.isHiding else { return }
        let items = scanner.items
        guard !items.isEmpty else { return }

        // Only capture for items that don't already have an icon
        let needsCapture = items.filter { $0.capturedIcon == nil }
        guard !needsCapture.isEmpty else { return }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            self.iconCapturer.captureIcons(for: needsCapture)
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

        // Refresh
        let refreshItem = NSMenuItem(title: "Refresh Now", action: #selector(refreshNow), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        menu.addItem(.separator())

        // Check for Updates
        let updateItem = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        updateItem.target = self
        menu.addItem(updateItem)

        // Getting Started
        let welcomeItem = NSMenuItem(title: "Getting Started…", action: #selector(openWelcome), keyEquivalent: "")
        welcomeItem.target = self
        menu.addItem(welcomeItem)

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

    @objc private func refreshNow() {
        scanner.scanAsync()
        captureIconsInBackground()
    }

    @objc private func openWelcome() {
        showWelcomeWindow()
    }

    @objc private func showAbout() {
        NSApp.orderFrontStandardAboutPanel(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    // MARK: - Global Hotkey (⌃⌥⌘M)

    private func setupGlobalHotkey() {
        unregisterGlobalHotkey()

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let userData = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())

        let installStatus = InstallEventHandler(
            GetEventDispatcherTarget(),
            { _, eventRef, userData in
                guard let userData, let eventRef else { return noErr }
                let app = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()

                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    eventRef,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard status == noErr,
                      hotKeyID.signature == AppDelegate.hotKeySignature,
                      hotKeyID.id == AppDelegate.hotKeyID else {
                    return noErr
                }

                DispatchQueue.main.async {
                    app.togglePanelViaHotkey()
                }
                return noErr
            },
            1,
            &eventType,
            userData,
            &hotKeyHandlerRef
        )

        guard installStatus == noErr else {
            appLogger.error("Failed to install global hotkey handler: \(installStatus)")
            return
        }

        var hotKeyID = EventHotKeyID(
            signature: AppDelegate.hotKeySignature,
            id: AppDelegate.hotKeyID
        )
        let modifiers = UInt32(controlKey | optionKey | cmdKey)
        let registerStatus = RegisterEventHotKey(
            UInt32(kVK_ANSI_M),
            modifiers,
            hotKeyID,
            GetEventDispatcherTarget(),
            0,
            &globalHotKeyRef
        )

        if registerStatus != noErr {
            appLogger.error("Failed to register global hotkey: \(registerStatus)")
            unregisterGlobalHotkey()
        }
    }

    private func unregisterGlobalHotkey() {
        if let hotKey = globalHotKeyRef {
            UnregisterEventHotKey(hotKey)
            globalHotKeyRef = nil
        }
        if let handler = hotKeyHandlerRef {
            RemoveEventHandler(handler)
            hotKeyHandlerRef = nil
        }
    }

    private static let hotKeySignature: OSType = 0x4D4E4457 // "MNDW"
    private static let hotKeyID: UInt32 = 1

    private func togglePanelViaHotkey() {
        guard let button = statusItem.button else { return }
        panelController?.toggle(relativeTo: button)

        if panelController?.isVisible == true {
            scanner.scanAsync()
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
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 460),
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
