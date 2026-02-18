import Cocoa
import ApplicationServices

private func clickLog(_ message: String) {
    let line = "[\(Date())] [Click] \(message)\n"
    let path = "/tmp/menudown_debug.log"
    if let handle = FileHandle(forWritingAtPath: path) {
        handle.seekToEndOfFile()
        handle.write(line.data(using: .utf8)!)
        handle.closeFile()
    } else {
        try? line.write(toFile: path, atomically: true, encoding: .utf8)
    }
}

/// Forwards user clicks from the vertical panel to the original menubar items
/// via the Accessibility API.
final class ClickForwarder {

    private let spacerManager: SpacerManager
    private weak var scanner: MenuBarScanner?

    /// Monotonically increasing generation counter. Every call to `click()`
    /// increments this. All delayed closures capture the generation at the
    /// time they were created and bail out if it no longer matches, which
    /// prevents stale closures from a prior click from interfering.
    private var clickGeneration: UInt64 = 0

    // Dismissal monitors — stored as instance vars so we can tear them
    // down explicitly when a new click starts.
    private var dismissalKeyMonitor: Any?
    private var dismissalClickMonitor: Any?
    private var activationObserver: Any?

    init(spacerManager: SpacerManager, scanner: MenuBarScanner) {
        self.spacerManager = spacerManager
        self.scanner = scanner
    }

    // MARK: - Public API

    /// Simulate a click on the given menubar item.
    /// Stops scanning, reveals hidden items, performs a synthetic click at the
    /// item's position, then waits for menu dismissal to restore scanning.
    func click(_ item: MenuBarItem) {
        // Don't forward clicks to MenuDown's own status item
        guard !item.isSelf else { return }

        // ── 0. Invalidate any previous click ──────────────────────────
        // Cancel stale dismissal monitors from a prior click so they
        // can't fire during this new click's activation sequence.
        cancelDismissalMonitors()
        clickGeneration &+= 1
        let gen = clickGeneration

        clickLog("=== Click forwarding: \(item.appName) (pid \(item.pid)) gen=\(gen) ===")

        // ── 1. Silence all periodic AX / screenshot work ─────────────
        scanner?.stopScanning()
        scanner?.pause()
        AccessibilityHelper.shared.pausePolling()
        clickLog("Scanner stopped + paused, AH polling paused.")

        // ── 2. Reveal original status items ──────────────────────────
        spacerManager.reveal()

        // ── 3. After menubar redraws + any in-flight scan finishes ───
        //       (~0.5 s is enough: scans take ≤ 0.37 s)
        after(0.5, gen: gen) {
            // ── 4. Clear overlapping app menus ───────────────────────
            //       MenuDown is an LSUIElement — activating it has zero
            //       visible effect except removing text-menu overflow.
            NSApp.activate(ignoringOtherApps: true)

            self.after(0.15, gen: gen) {
                // ── 5. Read current on-screen geometry ───────────────
                let pos  = self.currentPosition(of: item.axElement) ?? item.position
                let size = self.currentSize(of: item.axElement) ?? item.size

                // ── 6. Warp cursor + synthetic click ─────────────────
                //       A real mouseDown at the status-item position
                //       makes macOS start a proper menu-tracking loop.
                //       AXPress doesn't do this, which is why it lets
                //       menus auto-dismiss.
                self.warpCursor(to: pos, size: size)
                self.syntheticClick(at: pos, size: size)
                clickLog("Synthetic click sent.")

                // ── 7. Install dismissal monitors after a delay ──────
                //       Give menu tracking ~1.5 s to stabilise before
                //       we start listening for dismissal signals.
                self.installDismissalMonitors(
                    targetPID: item.pid,
                    generation: gen,
                    delay: 1.5
                )
            }
        }
    }

    // MARK: - Restoration

    /// Restore scanner, spacer, and AH polling after the menu closes.
    private func restoreAfterMenuDismissal() {
        clickLog("Menu dismissed — restoring scanner + spacer.")
        spacerManager.hide()
        scanner?.resume()
        scanner?.startScanning(interval: Preferences.shared.refreshInterval)
        AccessibilityHelper.shared.resumePolling()
    }

    // MARK: - Generation-safe delayed dispatch

    /// Execute `body` on the main queue after `seconds`, but only if the
    /// current click generation still matches `gen`.
    private func after(_ seconds: Double, gen: UInt64, _ body: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self = self, self.clickGeneration == gen else {
                clickLog("Stale closure skipped (gen mismatch).")
                return
            }
            body()
        }
    }

    // MARK: - Cursor & Click helpers

    /// Warp the visible cursor to a menubar item's centre.
    private func warpCursor(to position: CGPoint, size: CGSize) {
        let center = CGPoint(
            x: position.x + size.width / 2,
            y: position.y + size.height / 2
        )
        CGWarpMouseCursorPosition(center)
        // Post a mouseMoved so the window server updates tracking areas.
        let move = CGEvent(mouseEventSource: nil,
                           mouseType: .mouseMoved,
                           mouseCursorPosition: center,
                           mouseButton: .left)
        move?.post(tap: .cghidEventTap)
        clickLog("Warped cursor to (\(Int(center.x)), \(Int(center.y)))")
    }

    /// Synthesize a mouse click at the centre of the given rect.
    private func syntheticClick(at position: CGPoint, size: CGSize) {
        let pt = CGPoint(
            x: position.x + size.width / 2,
            y: position.y + size.height / 2
        )
        let down = CGEvent(mouseEventSource: nil,
                           mouseType: .leftMouseDown,
                           mouseCursorPosition: pt,
                           mouseButton: .left)
        let up   = CGEvent(mouseEventSource: nil,
                           mouseType: .leftMouseUp,
                           mouseCursorPosition: pt,
                           mouseButton: .left)
        down?.post(tap: .cghidEventTap)
        usleep(50_000) // 50 ms
        up?.post(tap: .cghidEventTap)
    }

    // MARK: - AX helpers

    private func currentPosition(of element: AXUIElement) -> CGPoint? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &value) == .success,
              let axValue = value else { return nil }
        var pt = CGPoint.zero
        AXValueGetValue(axValue as! AXValue, .cgPoint, &pt)
        return pt
    }

    private func currentSize(of element: AXUIElement) -> CGSize? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &value) == .success,
              let axValue = value else { return nil }
        var sz = CGSize.zero
        AXValueGetValue(axValue as! AXValue, .cgSize, &sz)
        return sz
    }

    // MARK: - Dismissal monitoring

    /// Forcibly tear down any existing dismissal monitors.
    /// Called at the start of every `click()` so stale observers from a
    /// prior click can never fire during the new click's sequence.
    private func cancelDismissalMonitors() {
        if let m = dismissalKeyMonitor   { NSEvent.removeMonitor(m); dismissalKeyMonitor = nil }
        if let m = dismissalClickMonitor { NSEvent.removeMonitor(m); dismissalClickMonitor = nil }
        if let o = activationObserver    {
            NSWorkspace.shared.notificationCenter.removeObserver(o)
            activationObserver = nil
        }
    }

    /// Install dismissal monitors after `delay` seconds.
    /// All monitors capture `generation` and are ignored if it no longer
    /// matches, preventing double-fire if the user clicks another item
    /// before the delay expires.
    private func installDismissalMonitors(targetPID: pid_t, generation gen: UInt64, delay: Double) {

        after(delay, gen: gen) { [weak self] in
            guard let self = self else { return }

            // 1) App-activation change — another app became frontmost
            self.activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] note in
                guard let self = self, self.clickGeneration == gen else { return }
                if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                   app.processIdentifier != targetPID {
                    clickLog("Dismissal: different app activated (\(app.localizedName ?? "?"))")
                    self.finishDismissal(generation: gen)
                }
            }

            // 2) Key press (Escape / Return / etc.)
            self.dismissalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) {
                [weak self] _ in
                guard let self = self, self.clickGeneration == gen else { return }
                clickLog("Dismissal: keyDown")
                self.finishDismissal(generation: gen)
            }

            // 3) Mouse click outside the menu
            self.dismissalClickMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown]
            ) { [weak self] _ in
                guard let self = self, self.clickGeneration == gen else { return }
                clickLog("Dismissal: mouse click")
                self.finishDismissal(generation: gen)
            }

            clickLog("Dismissal monitors installed (gen=\(gen)).")

            // Safety timeout: 60 seconds
            self.after(60.0, gen: gen) {
                clickLog("Dismissal: safety timeout.")
                self.finishDismissal(generation: gen)
            }
        }
    }

    /// Cleanup + restore, guarded by generation to prevent double-fire.
    private func finishDismissal(generation gen: UInt64) {
        guard clickGeneration == gen else {
            clickLog("finishDismissal skipped (gen mismatch: current=\(clickGeneration), got=\(gen)).")
            return
        }
        // Bump generation so no other delayed closure can fire.
        clickGeneration &+= 1
        cancelDismissalMonitors()

        // Short delay so macOS finishes any menu-item action animation.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.restoreAfterMenuDismissal()
        }
    }
}
