import Cocoa
import ApplicationServices
import Combine
import os.log

private let logger = Logger(subsystem: "com.menudown.app", category: "scanner")

private func debugLog(_ message: String) {
    let line = "[\(Date())] [Scanner] \(message)\n"
    let path = "/tmp/menudown_debug.log"
    if let handle = FileHandle(forWritingAtPath: path) {
        handle.seekToEndOfFile()
        handle.write(line.data(using: .utf8)!)
        handle.closeFile()
    } else {
        try? line.write(toFile: path, atomically: true, encoding: .utf8)
    }
}

/// Discovers third-party menubar items using the Accessibility API.
final class MenuBarScanner: ObservableObject {

    @Published private(set) var items: [MenuBarItem] = []
    @Published private(set) var lastScanDate: Date?
    @Published private(set) var isScanning: Bool = false

    private var scanTimer: Timer?
    private let scanQueue = DispatchQueue(label: "com.menudown.scanner", qos: .userInitiated)

    /// Bundle IDs that had menubar extras on a previous scan — checked first for speed.
    private var knownExtraBundleIDs: Set<String> = []

    /// Thread-safe flag to prevent overlapping scans (accessed from multiple queues).
    private let scanLock = NSLock()
    private var _isScanningInternal = false

    /// When true, scanning is temporarily paused (e.g. while a forwarded menu is open).
    private(set) var isPaused = false

    /// MenuDown's own NSStatusItem, set by AppDelegate so we can include
    /// ourselves in the item list (AX can't discover our own extras).
    var selfStatusItem: NSStatusItem?

    // MARK: - Public API

    /// Temporarily pause scanning (e.g. while a forwarded menu is open).
    func pause() {
        isPaused = true
        debugLog("Scanning paused.")
    }

    /// Resume scanning after a pause.
    func resume() {
        isPaused = false
        debugLog("Scanning resumed.")
    }

    /// Start periodic scanning at the given interval.
    func startScanning(interval: TimeInterval = 5.0) {
        scanAsync() // Initial scan
        scanTimer?.invalidate()
        scanTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.scanAsync()
        }
    }

    /// Stop periodic scanning.
    func stopScanning() {
        scanTimer?.invalidate()
        scanTimer = nil
    }

    /// Perform a scan on a background queue (preferred — non-blocking).
    func scanAsync() {
        guard !isPaused else {
            debugLog("scanAsync: paused, skipping.")
            return
        }
        guard AXIsProcessTrusted() else {
            debugLog("scanAsync: Accessibility not enabled.")
            return
        }

        // Thread-safe check-and-set to prevent overlapping scans
        scanLock.lock()
        guard !_isScanningInternal else {
            scanLock.unlock()
            debugLog("scanAsync: already scanning, skipping.")
            return
        }
        _isScanningInternal = true
        scanLock.unlock()

        DispatchQueue.main.async { self.isScanning = true }

        scanQueue.async { [weak self] in
            guard let self = self else { return }
            let start = CFAbsoluteTimeGetCurrent()
            let newItems = self.discoverThirdPartyItems()
            let elapsed = CFAbsoluteTimeGetCurrent() - start
            debugLog("scanAsync finished in \(String(format: "%.2f", elapsed))s — \(newItems.count) items")

            DispatchQueue.main.async {
                // Only update if we found items, or if there truly are none
                // (don't overwrite good results with an empty scan that may have failed)
                if !newItems.isEmpty || self.items.isEmpty {
                    self.items = newItems
                }
                self.lastScanDate = Date()
                self.isScanning = false

                // Resolve app icons on the main thread where AppKit APIs are safe.
                // Icons are cached permanently so this is fast after the first pass.
                for item in self.items {
                    item.resolveIconIfNeeded()
                }

                self.scanLock.lock()
                self._isScanningInternal = false
                self.scanLock.unlock()
            }
        }
    }

    // MARK: - Discovery

    private func discoverThirdPartyItems() -> [MenuBarItem] {
        let allExtras = getMenuBarExtras()
        guard !allExtras.isEmpty else { return [] }

        var thirdPartyItems: [MenuBarItem] = []
        var indexByBundle: [String: Int] = [:]

        for element in allExtras {
            var pid: pid_t = 0
            guard AXUIElementGetPid(element, &pid) == .success else { continue }
            guard let app = NSRunningApplication(processIdentifier: pid) else { continue }

            let bundleID = app.bundleIdentifier ?? "unknown.\(pid)"

            // Skip system items early — before any further AX calls
            guard !MenuBarItem.isSystemProcess(bundleID: bundleID) else { continue }
            guard !Preferences.shared.excludedBundleIDs.contains(bundleID) else { continue }

            let appName = app.localizedName ?? "Unknown"
            let position = getPosition(of: element) ?? .zero
            let size = getSize(of: element) ?? CGSize(width: 22, height: 22)
            let title = getStringAttribute(element, attribute: kAXTitleAttribute as CFString)
                ?? getStringAttribute(element, attribute: kAXDescriptionAttribute as CFString)

            let idx = indexByBundle[bundleID, default: 0]
            indexByBundle[bundleID] = idx + 1

            thirdPartyItems.append(MenuBarItem(
                axElement: element,
                pid: pid,
                bundleID: bundleID,
                appName: appName,
                position: position,
                size: size,
                title: title,
                index: idx
            ))
        }

        thirdPartyItems.sort { $0.position.x < $1.position.x }

        // Inject MenuDown's own item — AX can't discover our own extras
        let selfBundleID = Bundle.main.bundleIdentifier ?? "com.menudown.app"
        thirdPartyItems.removeAll { $0.bundleID == selfBundleID }
        if let selfItem = selfStatusItem,
           let button = selfItem.button,
           let buttonWindow = button.window {
            let frame = buttonWindow.frame
            // Convert from bottom-left (AppKit) to top-left (AX/CG) coordinates
            let screenHeight = NSScreen.main?.frame.height ?? 0
            let axY = screenHeight - frame.maxY
            let selfElement = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
            let selfMenuItem = MenuBarItem(
                axElement: selfElement,
                pid: ProcessInfo.processInfo.processIdentifier,
                bundleID: selfBundleID,
                appName: "MenuDown",
                position: CGPoint(x: frame.origin.x, y: axY),
                size: CGSize(width: frame.width, height: frame.height),
                title: "MenuDown",
                index: 0
            )
            thirdPartyItems.append(selfMenuItem)
            thirdPartyItems.sort { $0.position.x < $1.position.x }
        }

        let snapshot = thirdPartyItems
            .map { "\($0.bundleID)@x=\(Int($0.position.x)) w=\(Int($0.size.width)) title=\($0.title ?? "-")" }
            .joined(separator: " | ")
        debugLog("Item snapshot: \(snapshot)")

        return thirdPartyItems
    }

    /// Get all AXUIElements representing menubar extras across all running apps.
    /// Each app's kAXExtrasMenuBarAttribute returns only that app's own extras,
    /// so we must iterate all running apps. Uses concurrent dispatch for speed.
    private func getMenuBarExtras() -> [AXUIElement] {
        let apps = NSWorkspace.shared.runningApplications

        // Filter to apps worth querying
        let candidateApps = apps.filter { app in
            guard let bundleID = app.bundleIdentifier else { return false }
            // Always query known-good apps
            if knownExtraBundleIDs.contains(bundleID) { return true }
            // Skip .prohibited (background daemons) — they almost never have status items
            if app.activationPolicy == .prohibited { return false }
            return true
        }

        // Query all apps concurrently — AX queries are IPC-bound, not CPU-bound
        let group = DispatchGroup()
        let resultsLock = NSLock()
        var allExtras: [AXUIElement] = []
        var newKnownBundleIDs = Set<String>()
        var appsWithExtras = 0
        let concurrentQueue = DispatchQueue(label: "com.menudown.axquery", attributes: .concurrent)

        for app in candidateApps {
            guard let bundleID = app.bundleIdentifier else { continue }
            let pid = app.processIdentifier

            group.enter()
            concurrentQueue.async { [weak self] in
                defer { group.leave() }

                // Abort early if scanning was paused while we're mid-flight
                guard self?.isPaused != true else { return }

                let appElement = AXUIElementCreateApplication(pid)
                AXUIElementSetMessagingTimeout(appElement, 0.3) // 300ms max

                var extrasValue: CFTypeRef?
                let result = AXUIElementCopyAttributeValue(
                    appElement,
                    kAXExtrasMenuBarAttribute as CFString,
                    &extrasValue
                )
                guard result == .success, let extrasElement = extrasValue else { return }

                var children: CFTypeRef?
                guard AXUIElementCopyAttributeValue(
                    extrasElement as! AXUIElement,
                    kAXChildrenAttribute as CFString,
                    &children
                ) == .success, let childArray = children as? [AXUIElement], !childArray.isEmpty else {
                    return
                }

                resultsLock.lock()
                appsWithExtras += 1
                newKnownBundleIDs.insert(bundleID)
                allExtras.append(contentsOf: childArray)
                resultsLock.unlock()
            }
        }

        // Wait for all concurrent queries (worst case: 300ms + dispatch overhead)
        group.wait()

        knownExtraBundleIDs = newKnownBundleIDs

        debugLog("Scanned \(candidateApps.count) apps concurrent, "
                 + "\(appsWithExtras) had extras, \(allExtras.count) total elements")
        return allExtras
    }

    // MARK: - AX Attribute Helpers

    private func getPosition(of element: AXUIElement) -> CGPoint? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &value) == .success,
              let axValue = value else { return nil }
        var point = CGPoint.zero
        AXValueGetValue(axValue as! AXValue, .cgPoint, &point)
        return point
    }

    private func getSize(of element: AXUIElement) -> CGSize? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &value) == .success,
              let axValue = value else { return nil }
        var size = CGSize.zero
        AXValueGetValue(axValue as! AXValue, .cgSize, &size)
        return size
    }

    private func getStringAttribute(_ element: AXUIElement, attribute: CFString) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
        return value as? String
    }
}
