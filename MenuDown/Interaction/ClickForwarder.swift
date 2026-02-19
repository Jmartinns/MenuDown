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
    private var hasShownBlockedNotice = false

    private enum SafeSwapPromptDecision {
        case useOnce
        case alwaysAllow
        case dontUse
    }

    init(scanner: MenuBarScanner) {
        self.scanner = scanner
    }

    // MARK: - Public API

    /// Cancel any in-flight forwarded-click lifecycle so other interactions
    /// (like reorder drags) can proceed without stale dismissal monitors.
    func cancelActiveForwarding() {
        clickGeneration &+= 1
        cancelDismissalMonitors()
        scanner?.resume()
        scanner?.startScanning(interval: Preferences.shared.refreshInterval)
        AccessibilityHelper.shared.resumePolling()
        clickLog("Active forwarding cancelled.")
    }

    /// Simulate a click on the given menubar item.
    /// Stops scanning, performs a synthetic click at the item's position, then
    /// waits for menu dismissal to restore scanning.
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

        // ── 2. After any in-flight scan finishes ─────────────────────
        //       (~0.5 s is enough: scans take ≤ 0.37 s)
        after(0.5, gen: gen) {
            let pos  = self.currentPosition(of: item.axElement) ?? item.position
            let size = self.currentSize(of: item.axElement) ?? item.size

            // ── 3. Quick reachability check ──────────────────────────
            let clickPoint = self.bestReachableClickPoint(
                targetPID: item.pid,
                position: pos,
                size: size
            )

            if clickPoint != nil {
                // Item is directly reachable — use the normal path.
                // Activate MenuDown first to clear any overlapping text menus,
                // then perform the synthetic click.
                clickLog("Item reachable at (\(Int(clickPoint!.x)),\(Int(clickPoint!.y))); using normal click path.")
                NSApp.activate(ignoringOtherApps: true)

                self.after(0.15, gen: gen) {
                    self.performForwardClick(
                        for: item,
                        position: pos,
                        size: size,
                        reachablePoint: clickPoint,
                        generation: gen
                    )
                }
            } else {
                // Item is NOT reachable (likely behind the notch).
                // Skip NSApp.activate — it would make MenuDown frontmost
                // and interfere with the target app's menu tracking.
                // Instead, activate the target app directly and send a
                // synthetic click at the AX-reported center coordinates.
                clickLog("Item unreachable; using notch-bypass click path.")
                self.performNotchBypassClick(
                    for: item,
                    position: pos,
                    size: size,
                    generation: gen
                )
            }
        }
    }

    // MARK: - Restoration

    /// Restore scanner and AH polling after the menu closes.
    private func restoreAfterMenuDismissal() {
        clickLog("Menu dismissed — restoring scanner.")
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

    /// Warp the visible cursor to the exact click point.
    private func warpCursor(to point: CGPoint) {
        CGWarpMouseCursorPosition(point)
        // Post a mouseMoved so the window server updates tracking areas.
        let move = CGEvent(mouseEventSource: nil,
                           mouseType: .mouseMoved,
                           mouseCursorPosition: point,
                           mouseButton: .left)
        move?.post(tap: .cghidEventTap)
        clickLog("Warped cursor to (\(Int(point.x)), \(Int(point.y)))")
    }

    /// Synthesize a mouse click at a specific point. If the target under the
    /// cursor shifts between mouseDown and mouseUp, retarget mouseUp.
    private func syntheticClick(
        targetPID: pid_t,
        at pt: CGPoint,
        fallbackPosition: CGPoint,
        fallbackSize: CGSize,
        skipRetarget: Bool = false
    ) {
        let down = CGEvent(mouseEventSource: nil,
                           mouseType: .leftMouseDown,
                           mouseCursorPosition: pt,
                           mouseButton: .left)
        logHitTest(at: pt, label: "before syntheticClick")
        down?.post(tap: .cghidEventTap)

        usleep(40_000) // 40 ms
        var upPoint = pt
        if !skipRetarget,
           hitTestPID(at: pt) != targetPID,
           let retargeted = bestReachableClickPoint(
            targetPID: targetPID,
            position: fallbackPosition,
            size: fallbackSize
           ) {
            upPoint = retargeted
            clickLog("Retargeted mouseUp to (\(Int(upPoint.x)),\(Int(upPoint.y)))")
        }

        let up = CGEvent(mouseEventSource: nil,
                         mouseType: .leftMouseUp,
                         mouseCursorPosition: upPoint,
                         mouseButton: .left)
        up?.post(tap: .cghidEventTap)
        logHitTest(at: upPoint, label: "after syntheticClick")
    }

    private func performForwardClick(
        for item: MenuBarItem,
        position: CGPoint,
        size: CGSize,
        reachablePoint clickPoint: CGPoint?,
        generation gen: UInt64
    ) {
        let center = CGPoint(x: position.x + size.width / 2, y: position.y + size.height / 2)
        clickLog("Target \(item.bundleID) pos=(\(Int(position.x)),\(Int(position.y))) size=(\(Int(size.width))x\(Int(size.height))) center=(\(Int(center.x)),\(Int(center.y)))")

        if let clickPoint {
            clickLog("Reachable target point at (\(Int(clickPoint.x)),\(Int(clickPoint.y)))")
        }

        // If the item is blocked by another app's text menu, use safe swap.
        if clickPoint == nil || isLikelyBlockedByActiveMenu(targetPID: item.pid, position: position, size: size) {
            performBlockedOrDirectClick(
                for: item,
                clickPoint: clickPoint,
                position: position,
                size: size,
                generation: gen
            )
            return
        }

        sendSyntheticClickAndMonitor(
            item: item,
            position: position,
            size: size,
            preferredPoint: clickPoint,
            generation: gen
        )
    }

    // MARK: - Notch-bypass click

    /// Handles clicking a status item that is entirely behind the notch.
    ///
    /// CGEvent clicks in the notch exclusion zone are silently discarded by
    /// the window server, even though AX hit-tests resolve correctly.
    /// The only reliable approach is to physically reorder items so the
    /// target ends up in visible space.  The user can then click it
    /// directly in the menu bar.
    ///
    /// 1. Find a clearly-visible item to the target's RIGHT.
    /// 2. Command-drag it to the LEFT (past the notch-blocked items).
    /// 3. macOS reflows the status area — blocked items shift RIGHT into
    ///    visible space.
    /// 4. Resume scanning so the panel updates with new positions.
    private func performNotchBypassClick(
        for item: MenuBarItem,
        position: CGPoint,
        size: CGSize,
        generation gen: UInt64
    ) {
        clickLog("Notch-bypass: starting drag-to-expose for \(item.bundleID) at x=\(Int(position.x))")

        // Activate Finder so the active app's text menus (File, Edit, …)
        // retract and don't overlap the status-item zone.
        let previousApp = NSWorkspace.shared.frontmostApplication
        let finder = NSWorkspace.shared.runningApplications.first {
            $0.bundleIdentifier == "com.apple.finder"
        }
        if let finder {
            finder.activate()
            Thread.sleep(forTimeInterval: 0.3)
            clickLog("Notch-bypass: activated Finder to clear app menus.")
        }

        performDragToExpose(
            for: item,
            position: position,
            size: size,
            generation: gen,
            attempt: 1,
            previousApp: previousApp
        )
    }

    /// Command-drag a clearly-visible item to the LEFT (past the blocked
    /// items), causing macOS to reflow and push the target into visible space.
    /// Once exposed, scanning resumes so positions update and the user can
    /// click the item directly.  Repeats up to 3 times if the first drag
    /// doesn't expose the target.
    private func performDragToExpose(
        for item: MenuBarItem,
        position: CGPoint,
        size: CGSize,
        generation gen: UInt64,
        attempt: Int,
        previousApp: NSRunningApplication? = nil
    ) {
        guard attempt <= 3 else {
            clickLog("Notch-bypass drag: max attempts reached, giving up.")
            showBlockedNoticeIfNeeded()
            self.restorePreviousApp(previousApp)
            restoreAfterMenuDismissal()
            return
        }

        guard let scanner = scanner else {
            clickLog("Notch-bypass drag: no scanner, giving up.")
            self.restorePreviousApp(previousApp)
            restoreAfterMenuDismissal()
            return
        }

        // Re-read all current positions.
        let allItems = scanner.items.filter { !$0.isSelf }

        let targetX = currentPosition(of: item.axElement)?.x ?? position.x

        // We need an item whose CENTER is clearly hit-testable (i.e. the
        // item is fully in visible space, not just a sliver at the notch
        // edge).  macOS won't enter Cmd-drag reorder mode if the grab
        // point is in the notch exclusion zone.
        //
        // Iterate from RIGHT to LEFT among items that are to the right
        // of the target.  The rightmost items are most likely to be fully
        // visible.  We test the item's CENTER — if it hit-tests to the
        // correct PID, the item is solidly visible and reliable for dragging.
        var dragCandidate: MenuBarItem?
        var dragCandidateCenter: CGPoint?

        let rightOfTarget = allItems.filter { candidate in
            guard candidate.bundleID != item.bundleID else { return false }
            let cPos = currentPosition(of: candidate.axElement) ?? candidate.position
            return cPos.x > targetX
        }.sorted { a, b in
            let aPos = currentPosition(of: a.axElement) ?? a.position
            let bPos = currentPosition(of: b.axElement) ?? b.position
            return aPos.x > bPos.x  // rightmost first
        }

        for candidate in rightOfTarget {
            let cPos = currentPosition(of: candidate.axElement) ?? candidate.position
            let cSize = currentSize(of: candidate.axElement) ?? candidate.size
            let center = CGPoint(x: cPos.x + cSize.width / 2, y: cPos.y + cSize.height / 2)

            // The CENTER must hit-test to the candidate's PID — this
            // proves the item is genuinely visible, not a notch-edge
            // sliver where only the extreme right pixels are reachable.
            if hitTestPID(at: center) == candidate.pid {
                dragCandidate = candidate
                dragCandidateCenter = center
                clickLog("Notch-bypass drag: candidate \(candidate.bundleID) center (\(Int(center.x)),\(Int(center.y))) hit-tests correctly.")
                break
            } else {
                clickLog("Notch-bypass drag: candidate \(candidate.bundleID) center (\(Int(center.x)),\(Int(center.y))) NOT reachable, skipping.")
            }
        }

        guard let dragItem = dragCandidate, let startPt = dragCandidateCenter else {
            clickLog("Notch-bypass drag: no fully-visible item found to drag. Giving up.")
            showBlockedNoticeIfNeeded()
            self.restorePreviousApp(previousApp)
            restoreAfterMenuDismissal()
            return
        }

        // Drag the candidate LEFT — well past all blocked items.
        // We drag to ~30px left of the target's current position so
        // macOS inserts the dragged item before the target.
        let dragEndX = max(targetX - 30, 0)
        let dragY = startPt.y

        clickLog("Notch-bypass drag (attempt \(attempt)): will Cmd-drag \(dragItem.bundleID) from center (\(Int(startPt.x)),\(Int(startPt.y))) to x=\(Int(dragEndX)) to expose \(item.bundleID)")

        // Perform the Command-drag on a background queue (it uses Thread.sleep)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            self.syntheticCommandDrag(
                from: startPt,
                to: CGPoint(x: dragEndX, y: dragY)
            )

            // Wait for the menubar to settle after the drag
            Thread.sleep(forTimeInterval: 0.5)

            DispatchQueue.main.async { [weak self] in
                guard let self = self, self.clickGeneration == gen else { return }

                // Re-read the target item's position after the shift
                let newPos = self.currentPosition(of: item.axElement) ?? position
                let newSize = self.currentSize(of: item.axElement) ?? size
                let center = CGPoint(x: newPos.x + newSize.width / 2,
                                     y: newPos.y + newSize.height / 2)

                clickLog("Notch-bypass drag: target \(item.bundleID) now at x=\(Int(newPos.x))  (was x=\(Int(position.x))), center=(\(Int(center.x)),\(Int(center.y)))")

                // Check if the target is now reachable.
                let isExposed = self.hitTestPID(at: center) == item.pid
                    || self.bestReachableClickPoint(
                        targetPID: item.pid,
                        position: newPos,
                        size: newSize
                    ) != nil

                if isExposed {
                    clickLog("Notch-bypass drag: target is now visible. Resuming scanner so user can click it.")
                    self.restorePreviousApp(previousApp)
                    self.restoreAfterMenuDismissal()
                } else if attempt < 3 {
                    clickLog("Notch-bypass drag: target still not visible, retrying (attempt \(attempt + 1)).")
                    self.performDragToExpose(
                        for: item,
                        position: newPos,
                        size: newSize,
                        generation: gen,
                        attempt: attempt + 1,
                        previousApp: previousApp
                    )
                } else {
                    clickLog("Notch-bypass drag: max attempts reached, giving up.")
                    self.showBlockedNoticeIfNeeded()
                    self.restorePreviousApp(previousApp)
                    self.restoreAfterMenuDismissal()
                }
            }
        }
    }

    /// Restore the previously-active app after a notch-bypass operation.
    private func restorePreviousApp(_ app: NSRunningApplication?) {
        guard let app, app.bundleIdentifier != "com.apple.finder" else { return }
        app.activate()
    }

    /// Simple two-point Command-drag (no waypoints).
    private func syntheticCommandDrag(from start: CGPoint, to end: CGPoint) {
        let source = CGEventSource(stateID: .combinedSessionState)

        let moveToStart = CGEvent(mouseEventSource: source,
                                   mouseType: .mouseMoved,
                                   mouseCursorPosition: start,
                                   mouseButton: .left)
        moveToStart?.post(tap: .cghidEventTap)
        usleep(50_000)

        let mouseDown = CGEvent(mouseEventSource: source,
                                mouseType: .leftMouseDown,
                                mouseCursorPosition: start,
                                mouseButton: .left)
        mouseDown?.flags = .maskCommand
        mouseDown?.post(tap: .cghidEventTap)
        usleep(200_000)

        let dist = abs(end.x - start.x)
        let steps = max(10, Int(dist / 3))

        for i in 1...steps {
            let fraction = CGFloat(i) / CGFloat(steps)
            let intermediate = CGPoint(
                x: start.x + (end.x - start.x) * fraction,
                y: start.y + (end.y - start.y) * fraction
            )
            let drag = CGEvent(mouseEventSource: source,
                               mouseType: .leftMouseDragged,
                               mouseCursorPosition: intermediate,
                               mouseButton: .left)
            drag?.flags = .maskCommand
            drag?.post(tap: .cghidEventTap)
            usleep(15_000)
        }

        usleep(120_000)

        let mouseUp = CGEvent(mouseEventSource: source,
                              mouseType: .leftMouseUp,
                              mouseCursorPosition: end,
                              mouseButton: .left)
        mouseUp?.flags = .maskCommand
        mouseUp?.post(tap: .cghidEventTap)
        usleep(50_000)
    }

    /// Handles the blocked-by-active-menu check and either uses safe swap
    /// or sends a direct synthetic click.
    private func performBlockedOrDirectClick(
        for item: MenuBarItem,
        clickPoint: CGPoint?,
        position: CGPoint,
        size: CGSize,
        generation gen: UInt64
    ) {
        if clickPoint == nil || isLikelyBlockedByActiveMenu(targetPID: item.pid, position: position, size: size) {
            switch Preferences.shared.interactionFallbackMode {
            case .alwaysUseSafeSwap:
                clickLog("Blocked preflight detected. Using safe swap (always mode).")
                performSafeSwapAndClick(
                    item: item,
                    position: position,
                    size: size,
                    preferredPoint: clickPoint,
                    generation: gen
                )

            case .ask:
                switch promptForSafeSwapPermission() {
                case .useOnce:
                    clickLog("User selected safe swap: use once.")
                    performSafeSwapAndClick(
                        item: item,
                        position: position,
                        size: size,
                        preferredPoint: clickPoint,
                        generation: gen
                    )
                case .alwaysAllow:
                    clickLog("User selected safe swap: always allow.")
                    Preferences.shared.interactionFallbackMode = .alwaysUseSafeSwap
                    performSafeSwapAndClick(
                        item: item,
                        position: position,
                        size: size,
                        preferredPoint: clickPoint,
                        generation: gen
                    )
                case .dontUse:
                    clickLog("User declined safe swap.")
                    Preferences.shared.interactionFallbackMode = .neverUseSafeSwap
                    showBlockedNoticeIfNeeded()
                    restoreAfterMenuDismissal()
                }

            case .neverUseSafeSwap:
                clickLog("Blocked preflight detected. Safe swap disabled by user.")
                showBlockedNoticeIfNeeded()
                restoreAfterMenuDismissal()
            }
            return
        }

        sendSyntheticClickAndMonitor(
            item: item,
            position: position,
            size: size,
            preferredPoint: clickPoint,
            generation: gen
        )
    }

    private func sendSyntheticClickAndMonitor(
        item: MenuBarItem,
        position: CGPoint,
        size: CGSize,
        preferredPoint: CGPoint?,
        generation gen: UInt64
    ) {
        let clickPoint = preferredPoint ?? CGPoint(
            x: position.x + size.width / 2,
            y: position.y + size.height / 2
        )
        // A real mouseDown at the status-item position makes macOS start a
        // proper menu-tracking loop. AXPress doesn't reliably do this.
        warpCursor(to: clickPoint)
        let fallbackPosition = currentPosition(of: item.axElement) ?? position
        let fallbackSize = currentSize(of: item.axElement) ?? size
        syntheticClick(
            targetPID: item.pid,
            at: clickPoint,
            fallbackPosition: fallbackPosition,
            fallbackSize: fallbackSize
        )
        clickLog("Synthetic click sent.")

        // Give menu tracking time to stabilise before listening for dismissal.
        installDismissalMonitors(
            targetPID: item.pid,
            generation: gen,
            delay: 1.5
        )
    }

    private func performSafeSwapAndClick(
        item: MenuBarItem,
        position: CGPoint,
        size: CGSize,
        preferredPoint: CGPoint?,
        generation gen: UInt64
    ) {
        activateFinderForSafeSwap()
        after(0.18, gen: gen) {
            let refreshedPos = self.currentPosition(of: item.axElement) ?? position
            let refreshedSize = self.currentSize(of: item.axElement) ?? size
            let reachableAfterSwap = self.bestReachableClickPoint(
                targetPID: item.pid,
                position: refreshedPos,
                size: refreshedSize
            )
            if let reachableAfterSwap {
                clickLog("Reachable point after safe swap: (\(Int(reachableAfterSwap.x)),\(Int(reachableAfterSwap.y)))")
            } else {
                clickLog("Still no reachable point after safe swap; skipping synthetic click.")
            }

            guard reachableAfterSwap != nil || preferredPoint != nil else {
                clickLog("No immediate reachable point; retrying briefly for dynamic menubar shift.")
                self.retryReachableClick(
                    item: item,
                    generation: gen,
                    remainingAttempts: 8
                )
                return
            }
            self.sendSyntheticClickAndMonitor(
                item: item,
                position: refreshedPos,
                size: refreshedSize,
                preferredPoint: reachableAfterSwap ?? preferredPoint,
                generation: gen
            )
        }
    }

    private func retryReachableClick(
        item: MenuBarItem,
        generation gen: UInt64,
        remainingAttempts: Int
    ) {
        guard remainingAttempts > 0 else {
            clickLog("Reachability retry exhausted; attempting center fallback probe.")
            let pos = currentPosition(of: item.axElement) ?? item.position
            let size = currentSize(of: item.axElement) ?? item.size
            let center = CGPoint(x: pos.x + size.width / 2, y: pos.y + size.height / 2)
            if hitTestPID(at: center) == item.pid {
                clickLog("Center fallback probe found target at (\(Int(center.x)),\(Int(center.y))); sending click.")
                sendSyntheticClickAndMonitor(
                    item: item,
                    position: pos,
                    size: size,
                    preferredPoint: center,
                    generation: gen
                )
                return
            }
            clickLog("Center fallback probe failed; showing blocked notice.")
            showBlockedNoticeIfNeeded()
            restoreAfterMenuDismissal()
            return
        }

        after(0.12, gen: gen) {
            let pos = self.currentPosition(of: item.axElement) ?? item.position
            let size = self.currentSize(of: item.axElement) ?? item.size
            if let point = self.bestReachableClickPoint(
                targetPID: item.pid,
                position: pos,
                size: size
            ) {
                clickLog("Reachable point found on retry: (\(Int(point.x)),\(Int(point.y)))")
                self.sendSyntheticClickAndMonitor(
                    item: item,
                    position: pos,
                    size: size,
                    preferredPoint: point,
                    generation: gen
                )
            } else {
                self.retryReachableClick(
                    item: item,
                    generation: gen,
                    remainingAttempts: remainingAttempts - 1
                )
            }
        }
    }

    private func activateFinderForSafeSwap() {
        guard let finder = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.apple.finder"
        ).first else {
            clickLog("Safe swap requested, but Finder process not found.")
            return
        }
        let activated = finder.activate(options: [.activateIgnoringOtherApps])
        clickLog("Safe swap activate Finder: \(activated)")
    }

    private func isLikelyBlockedByActiveMenu(
        targetPID: pid_t,
        position: CGPoint,
        size: CGSize
    ) -> Bool {
        let center = CGPoint(x: position.x + size.width / 2, y: position.y + size.height / 2)
        let systemWide = AXUIElementCreateSystemWide()
        var hitElement: AXUIElement?
        guard AXUIElementCopyElementAtPosition(
            systemWide,
            Float(center.x),
            Float(center.y),
            &hitElement
        ) == .success,
        let hitElement else {
            return false
        }

        var hitPID: pid_t = 0
        guard AXUIElementGetPid(hitElement, &hitPID) == .success else { return false }
        guard hitPID != targetPID else { return false }

        let frontmost = NSWorkspace.shared.frontmostApplication
        let frontmostPID = frontmost?.processIdentifier ?? -1
        let frontmostBundle = frontmost?.bundleIdentifier ?? "unknown"

        // If we hit another app at the target point, the click is not going to
        // reach the status item reliably.
        clickLog("Preflight blocked: hit pid \(hitPID), target pid \(targetPID), frontmost pid \(frontmostPID) bid \(frontmostBundle)")
        return true
    }

    private func bestReachableClickPoint(
        targetPID: pid_t,
        position: CGPoint,
        size: CGSize
    ) -> CGPoint? {
        guard size.width > 0, size.height > 0 else { return nil }
        let baseMinX = Int(floor(position.x + 1))
        let baseMaxX = Int(ceil(position.x + size.width - 1))
        let baseMinY = Int(floor(position.y + 1))
        let baseMaxY = Int(ceil(position.y + size.height - 1))

        guard baseMinX <= baseMaxX, baseMinY <= baseMaxY else { return nil }

        // AX frames can be stale near the notch. Search a halo around the
        // reported frame and prefer rightmost points where slivers remain visible.
        let minX = baseMinX - 24
        let maxX = baseMaxX + 24
        let minY = baseMinY
        let maxY = baseMaxY

        for x in stride(from: maxX, through: minX, by: -1) {
            for y in stride(from: maxY, through: minY, by: -1) {
                let candidate = CGPoint(x: CGFloat(x), y: CGFloat(y))
                if hitTestPID(at: candidate) == targetPID {
                    if x < baseMinX || x > baseMaxX || y < baseMinY || y > baseMaxY {
                        clickLog("Reachable point found outside AX frame at (\(x),\(y)).")
                    }
                    return candidate
                }
            }
        }

        return nil
    }

    private func hitTestPID(at point: CGPoint) -> pid_t? {
        let systemWide = AXUIElementCreateSystemWide()
        var hitElement: AXUIElement?
        guard AXUIElementCopyElementAtPosition(
            systemWide,
            Float(point.x),
            Float(point.y),
            &hitElement
        ) == .success,
        let hitElement else {
            return nil
        }
        var pid: pid_t = 0
        guard AXUIElementGetPid(hitElement, &pid) == .success else { return nil }
        return pid
    }

    private func performAXActionFallback(for item: MenuBarItem) -> Bool {
        if AXUIElementPerformAction(item.axElement, kAXPressAction as CFString) == .success {
            clickLog("AX fallback: kAXPressAction succeeded for \(item.bundleID)")
            return true
        }
        if AXUIElementPerformAction(item.axElement, kAXShowMenuAction as CFString) == .success {
            clickLog("AX fallback: kAXShowMenuAction succeeded for \(item.bundleID)")
            return true
        }
        clickLog("AX fallback: no supported action succeeded for \(item.bundleID)")
        return false
    }

    private func logHitTest(at point: CGPoint, label: String) {
        let systemWide = AXUIElementCreateSystemWide()
        var hitElement: AXUIElement?
        guard AXUIElementCopyElementAtPosition(
            systemWide,
            Float(point.x),
            Float(point.y),
            &hitElement
        ) == .success,
        let hitElement else {
            clickLog("HitTest \(label): no element at (\(Int(point.x)),\(Int(point.y)))")
            return
        }

        var pid: pid_t = 0
        guard AXUIElementGetPid(hitElement, &pid) == .success else {
            clickLog("HitTest \(label): element found but pid unavailable")
            return
        }

        let app = NSRunningApplication(processIdentifier: pid)
        let bid = app?.bundleIdentifier ?? "unknown"
        let name = app?.localizedName ?? "unknown"
        clickLog("HitTest \(label): pid=\(pid) app=\(name) bid=\(bid) at (\(Int(point.x)),\(Int(point.y)))")
    }

    private func promptForSafeSwapPermission() -> SafeSwapPromptDecision {
        let alert = NSAlert()
        alert.messageText = "MenuDown is blocked by the active app menu bar"
        alert.informativeText = """
        The active app's text menu is covering this status item. MenuDown can briefly switch to Finder to make this interaction reliable.

        You can change this later in MenuDown > Interaction Reliability.
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Use Once")
        alert.addButton(withTitle: "Always Allow")
        alert.addButton(withTitle: "Don't Use")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return .useOnce
        case .alertSecondButtonReturn:
            return .alwaysAllow
        default:
            return .dontUse
        }
    }

    private func showBlockedNoticeIfNeeded() {
        guard !hasShownBlockedNotice else { return }
        hasShownBlockedNotice = true
        clickLog("Blocked notice (non-modal): status item unreachable right now.")
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

            // 1) Key press (Escape / Return / etc.)
            self.dismissalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) {
                [weak self] _ in
                guard let self = self, self.clickGeneration == gen else { return }
                clickLog("Dismissal: keyDown")
                self.finishDismissal(generation: gen)
            }

            // 2) Mouse click outside the menu
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
