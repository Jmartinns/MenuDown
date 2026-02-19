import Cocoa
import ApplicationServices
import os.log

private let reorderLogger = Logger(subsystem: "com.menudown.app", category: "reorderer")

private func debugLog(_ message: String) {
    let line = "[\(Date())] [Reorderer] \(message)\n"
    let path = "/tmp/menudown_debug.log"
    if let handle = FileHandle(forWritingAtPath: path) {
        handle.seekToEndOfFile()
        handle.write(line.data(using: .utf8)!)
        handle.closeFile()
    } else {
        try? line.write(toFile: path, atomically: true, encoding: .utf8)
    }
}

/// Physically rearranges macOS menubar icons by synthesizing Command-drag
/// events (the same gesture a user performs manually to reorder status items).
final class MenuBarReorderer {

    private weak var scanner: MenuBarScanner?
    var onBoundaryBlocked: ((String) -> Void)?

    /// Reference to MenuDown's own status item for live position reading.
    var selfStatusItem: NSStatusItem?

    init(scanner: MenuBarScanner) {
        self.scanner = scanner
    }

    /// Rearrange the physical menubar to match the desired order (left → right).
    ///
    /// Uses a greedy direct-placement algorithm: each iteration finds the
    /// item that is farthest from its target slot and drags it there in a
    /// single Cmd-drag.  macOS automatically shifts all intermediate items,
    /// so one long drag replaces many short ones.
    ///
    /// - Parameter desiredOrder: Items in the order they should appear
    ///   from left to right in the menubar.
    func applyOrder(_ desiredOrder: [MenuBarItem]) {
        guard !desiredOrder.isEmpty else { return }

        // Pause scanning so AX queries don't interfere
        scanner?.pause()

        debugLog("Starting reorder for \(desiredOrder.count) items.")

        // Perform reorder on a background queue with delays between each move
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            // ── Clear the menu bar: activate Finder so the active app's
            //    text menus (File, Edit, …) retract and don't overlap the
            //    status-item zone.  We restore the previous app afterward. ──
            let previousApp = NSWorkspace.shared.frontmostApplication
            let finder = NSWorkspace.shared.runningApplications.first {
                $0.bundleIdentifier == "com.apple.finder"
            }

            if let finder {
                DispatchQueue.main.sync { finder.activate() }
                Thread.sleep(forTimeInterval: 0.3)
                debugLog("Activated Finder to clear app menus.")
            }

            // Wait for the menubar to redraw after revealing
            Thread.sleep(forTimeInterval: 0.3)

            // ── Pre-expose: ensure every item's CENTER is reachable ──
            // Drag the rightmost visible item left repeatedly until all
            // items clear the notch.  Each drag pushes the whole row right.
            self.preExposeAllItems(desiredOrder)
            Thread.sleep(forTimeInterval: 0.3)

            let desiredBundleOrder = desiredOrder.map(\.bundleID)

            // Log initial state
            let initialPositions = self.readPositions(for: desiredOrder)
            let initialOrder = initialPositions.sorted { $0.x < $1.x }.map(\.bundleID)
            debugLog("Current order: \(initialOrder)")
            debugLog("Desired order: \(desiredBundleOrder)")
            self.logPositions(initialPositions, label: "Initial positions")

            // ── Greedy direct-placement loop ──
            // Each iteration picks the most-displaced *reachable* item and
            // drags it straight to its target slot.  Items behind the notch
            // are only exposed on-demand when no reachable item can make
            // progress — and after an expose the iteration restarts with
            // fresh positions.
            var skippedItems: Set<String> = []
            var consecutiveFailures: [String: Int] = [:]
            let maxRetries = 3
            let maxIterations = desiredOrder.count * 4 // generous safety limit
            var previousStates: [String] = [] // detect infinite loops

            for iteration in 1...maxIterations {
                let freshPositions = self.readPositions(for: desiredOrder)
                let freshSortedByX = freshPositions.sorted { $0.x < $1.x }
                let currentBundleOrder = freshSortedByX.map(\.bundleID)

                self.logPositions(freshPositions, label: "Iteration \(iteration)")

                if currentBundleOrder == desiredBundleOrder {
                    debugLog("Order matches desired after \(iteration - 1) drags. Done.")
                    break
                }

                // Detect infinite loops: if we've seen this exact state
                // before, we're stuck.
                let stateKey = currentBundleOrder.joined(separator: ",")
                let stateOccurrences = previousStates.filter { $0 == stateKey }.count
                if stateOccurrences >= 2 {
                    debugLog("State repeated \(stateOccurrences + 1) times, breaking to avoid infinite loop.")
                    break
                }
                previousStates.append(stateKey)

                // Build list of out-of-place items, separated into reachable
                // vs unreachable.
                struct Candidate {
                    let bundleID: String
                    let currentSlot: Int
                    let desiredSlot: Int
                    let distance: Int
                    let dragStart: CGPoint
                }

                var reachableCandidates: [Candidate] = []
                var unreachableBundleIDs: [(bundleID: String, distance: Int)] = []

                for (desiredSlot, bundleID) in desiredBundleOrder.enumerated() {
                    guard !skippedItems.contains(bundleID) else { continue }
                    guard let currentSlot = currentBundleOrder.firstIndex(of: bundleID) else { continue }
                    guard currentSlot != desiredSlot else { continue }
                    let distance = abs(currentSlot - desiredSlot)

                    let info = freshSortedByX[currentSlot]
                    let center = CGPoint(x: info.x + info.width / 2,
                                         y: info.y + info.height / 2)

                    // Try center, then bestReachablePoint
                    var start: CGPoint?
                    if self.hitTestPID(at: center) == self.itemPID(for: bundleID, in: desiredOrder) {
                        start = center
                    } else if let reachable = self.bestReachablePoint(
                        forPID: self.itemPID(for: bundleID, in: desiredOrder),
                        x: info.x, y: info.y,
                        width: info.width, height: info.height
                    ) {
                        start = reachable
                    }

                    if let start {
                        reachableCandidates.append(Candidate(
                            bundleID: bundleID,
                            currentSlot: currentSlot,
                            desiredSlot: desiredSlot,
                            distance: distance,
                            dragStart: start
                        ))
                    } else {
                        unreachableBundleIDs.append((bundleID, distance))
                    }
                }

                // Prefer the reachable item with the greatest displacement.
                if let move = reachableCandidates.max(by: { $0.distance < $1.distance }) {
                    let y = move.dragStart.y

                    // Build waypoints using fresh positions.
                    let movingLeft = move.currentSlot > move.desiredSlot
                    var waypointXs: [CGFloat] = []
                    if movingLeft {
                        for i in stride(from: move.currentSlot - 1, through: move.desiredSlot, by: -1) {
                            waypointXs.append(freshSortedByX[i].x + freshSortedByX[i].width / 2)
                        }
                        waypointXs.append(freshSortedByX[move.desiredSlot].x - 6)
                    } else {
                        for i in (move.currentSlot + 1)...move.desiredSlot {
                            waypointXs.append(freshSortedByX[i].x + freshSortedByX[i].width / 2)
                        }
                        waypointXs.append(freshSortedByX[move.desiredSlot].x + freshSortedByX[move.desiredSlot].width + 4)
                    }

                    debugLog("Drag \(move.bundleID): slot \(move.currentSlot)→\(move.desiredSlot) (distance \(move.distance)) x=\(Int(move.dragStart.x)) → \(waypointXs.map { Int($0) })")

                    self.syntheticCommandDrag(
                        from: move.dragStart,
                        waypoints: waypointXs.map { CGPoint(x: $0, y: y) }
                    )

                    Thread.sleep(forTimeInterval: 0.4)

                    // Verify
                    let afterPositions = self.readPositions(for: desiredOrder).sorted { $0.x < $1.x }
                    self.logPositions(afterPositions, label: "After drag \(iteration)")

                    if let afterSlot = afterPositions.firstIndex(where: { $0.bundleID == move.bundleID }) {
                        if afterSlot == move.desiredSlot {
                            debugLog("\(move.bundleID) placed at slot \(move.desiredSlot) ✓")
                            consecutiveFailures[move.bundleID] = 0
                        } else {
                            let beforeX = freshSortedByX[move.currentSlot].x
                            let afterX = afterPositions[afterSlot].x
                            if abs(afterX - beforeX) < 0.5 {
                                let failures = (consecutiveFailures[move.bundleID] ?? 0) + 1
                                consecutiveFailures[move.bundleID] = failures
                                debugLog("No progress for \(move.bundleID) (failure \(failures)/\(maxRetries)).")
                                if failures >= maxRetries {
                                    debugLog("\(move.bundleID) failed \(maxRetries) times, skipping permanently.")
                                    skippedItems.insert(move.bundleID)
                                }
                            } else {
                                consecutiveFailures[move.bundleID] = 0
                                debugLog("\(move.bundleID) moved to slot \(afterSlot), wanted \(move.desiredSlot). Will retry.")
                            }
                        }
                    }

                } else if let toExpose = unreachableBundleIDs.max(by: { $0.distance < $1.distance }) {
                    // No reachable items to move — try exposing one.
                    debugLog("No reachable items to move. Exposing \(toExpose.bundleID).")
                    if !self.exposeItem(toExpose.bundleID, among: desiredOrder, positions: freshSortedByX) {
                        debugLog("\(toExpose.bundleID) expose failed, skipping permanently.")
                        skippedItems.insert(toExpose.bundleID)
                    }
                    // After expose, loop restarts with fresh positions —
                    // no drag attempted this iteration.
                    Thread.sleep(forTimeInterval: 0.3)

                } else {
                    debugLog("No movable items remain (iteration \(iteration)).")
                    break
                }
            }

            debugLog("Reorder complete.")

            DispatchQueue.main.async { [weak self] in
                // Restore the previously-active app
                if let previousApp, previousApp.bundleIdentifier != "com.apple.finder" {
                    previousApp.activate()
                }
                self?.scanner?.resume()
                self?.scanner?.scanAsync()
            }
        }
    }

    // MARK: - Pre-expose all items

    /// Shift the entire status item row right until every item's CENTER
    /// is hit-testable (i.e. not behind the notch).
    ///
    /// Strategy: find the LEFTMOST reachable item and Cmd-drag it as far
    /// left as possible (past all blocked items).  macOS pushes the blocked
    /// items rightward.  Repeat up to N rounds.  This is monotonic —
    /// each round only pushes items to the RIGHT, unlike the old approach
    /// which could cycle by picking different drag handles.
    private func preExposeAllItems(_ items: [MenuBarItem]) {
        let selfBundleID = Bundle.main.bundleIdentifier ?? "com.menudown.app"

        for round in 1...5 {
            let positions = readPositions(for: items).sorted { $0.x < $1.x }

            // Find all blocked items (center doesn't hit-test).
            let blockedItems = positions.filter { posInfo in
                guard posInfo.bundleID != selfBundleID else { return false }
                guard let item = items.first(where: { $0.bundleID == posInfo.bundleID }) else { return false }
                let center = CGPoint(x: posInfo.x + posInfo.width / 2,
                                     y: posInfo.y + posInfo.height / 2)
                return hitTestPID(at: center) != item.pid
            }

            if blockedItems.isEmpty {
                debugLog("Pre-expose: all items reachable (round \(round)).")
                return
            }

            debugLog("Pre-expose round \(round): \(blockedItems.count) blocked items, leftmost = \(blockedItems.first!.bundleID)@x=\(Int(blockedItems.first!.x))")

            // Find the LEFTMOST reachable item — drag it as far left as
            // possible.  This is the closest reachable item to the notch
            // boundary, so it covers the most blocked items in one drag.
            var dragCandidate: (info: ItemPosition, item: MenuBarItem, center: CGPoint)?
            for posInfo in positions {
                guard posInfo.bundleID != selfBundleID else { continue }
                guard let item = items.first(where: { $0.bundleID == posInfo.bundleID }) else { continue }
                let center = CGPoint(x: posInfo.x + posInfo.width / 2,
                                     y: posInfo.y + posInfo.height / 2)
                if hitTestPID(at: center) == item.pid {
                    dragCandidate = (posInfo, item, center)
                    break
                }
            }

            guard let drag = dragCandidate else {
                debugLog("Pre-expose: no reachable item found at all.")
                return
            }

            // Drag it to the left of ALL blocked items.
            let leftmostBlockedX = blockedItems.first!.x
            let dragEndX = max(leftmostBlockedX - 30, 0)

            debugLog("Pre-expose: Cmd-dragging \(drag.info.bundleID) from (\(Int(drag.center.x)),\(Int(drag.center.y))) to x=\(Int(dragEndX))")

            syntheticCommandDrag(
                from: drag.center,
                waypoints: [CGPoint(x: dragEndX, y: drag.center.y)]
            )

            Thread.sleep(forTimeInterval: 0.4)
        }

        debugLog("Pre-expose: max rounds reached.")
    }

    // MARK: - On-demand expose

    /// Try to expose a single blocked item by dragging a visible neighbour
    /// left past it.  Returns `true` if the blocked item appears to have
    /// moved into visible space.
    private func exposeItem(
        _ bundleID: String,
        among items: [MenuBarItem],
        positions: [ItemPosition]
    ) -> Bool {
        let selfBundleID = Bundle.main.bundleIdentifier ?? "com.menudown.app"

        guard let blockedInfo = positions.first(where: { $0.bundleID == bundleID }),
              let blockedItem = items.first(where: { $0.bundleID == bundleID }) else {
            return false
        }

        debugLog("Expose: \(bundleID) unreachable at x=\(Int(blockedInfo.x)).")

        // Find the rightmost item whose CENTER hit-tests correctly —
        // this is our drag handle.
        var dragCandidate: (info: ItemPosition, center: CGPoint)?
        for posInfo in positions.reversed() {
            guard posInfo.bundleID != selfBundleID,
                  posInfo.bundleID != bundleID else { continue }
            guard let item = items.first(where: { $0.bundleID == posInfo.bundleID }) else { continue }

            let center = CGPoint(x: posInfo.x + posInfo.width / 2,
                                 y: posInfo.y + posInfo.height / 2)
            if hitTestPID(at: center) == item.pid {
                dragCandidate = (posInfo, center)
                break
            }
        }

        guard let drag = dragCandidate else {
            debugLog("Expose: no visible drag candidate found.")
            return false
        }

        let dragEndX = max(blockedInfo.x - 30, 0)
        debugLog("Expose: Cmd-dragging \(drag.info.bundleID) from (\(Int(drag.center.x)),\(Int(drag.center.y))) to x=\(Int(dragEndX))")

        syntheticCommandDrag(
            from: drag.center,
            waypoints: [CGPoint(x: dragEndX, y: drag.center.y)]
        )

        Thread.sleep(forTimeInterval: 0.4)

        // Verify the blocked item moved.
        if let newPos = currentPosition(of: blockedItem.axElement) {
            let moved = abs(newPos.x - blockedInfo.x)
            debugLog("Expose: \(bundleID) moved from x=\(Int(blockedInfo.x)) to x=\(Int(newPos.x)) (delta=\(Int(moved)))")
            return moved >= 5
        }
        return false
    }

    // MARK: - Position reading

    private struct ItemPosition {
        let bundleID: String
        let x: CGFloat
        let y: CGFloat
        let width: CGFloat
        let height: CGFloat
    }

    private func readPositions(for items: [MenuBarItem]) -> [ItemPosition] {
        var positions: [ItemPosition] = []
        let selfBundleID = Bundle.main.bundleIdentifier ?? "com.menudown.app"

        for item in items {
            let pos: CGPoint
            let size: CGSize

            if item.bundleID == selfBundleID {
                // MenuDown's own item — read live position from NSStatusItem
                if let button = selfStatusItem?.button,
                   let win = button.window {
                    let frame = win.frame
                    let screenHeight = NSScreen.main?.frame.height ?? 0
                    pos = CGPoint(x: frame.origin.x, y: screenHeight - frame.maxY)
                    size = CGSize(width: frame.width, height: frame.height)
                } else {
                    pos = item.position
                    size = item.size
                }
            } else if let axPos = currentPosition(of: item.axElement),
                      let axSize = currentSize(of: item.axElement) {
                pos = axPos
                size = axSize
            } else {
                // Fallback to stored values
                pos = item.position
                size = item.size
            }

            positions.append(ItemPosition(
                bundleID: item.bundleID,
                x: pos.x,
                y: pos.y,
                width: size.width,
                height: size.height
            ))
        }
        return positions
    }

    private func logPositions(_ positions: [ItemPosition], label: String) {
        let line = positions
            .sorted { $0.x < $1.x }
            .map { "\($0.bundleID)@x=\(Int($0.x)) w=\(Int($0.width))" }
            .joined(separator: " | ")
        debugLog("\(label): \(line)")
    }

    private func itemPID(for bundleID: String, in items: [MenuBarItem]) -> pid_t? {
        items.first(where: { $0.bundleID == bundleID })?.pid
    }

    private func bestReachablePoint(
        forPID targetPID: pid_t?,
        x: CGFloat,
        y: CGFloat,
        width: CGFloat,
        height: CGFloat
    ) -> CGPoint? {
        guard let targetPID, width > 0, height > 0 else { return nil }
        let baseMinX = Int(floor(x + 1))
        let baseMaxX = Int(ceil(x + width - 1))
        let baseMinY = Int(floor(y + 1))
        let baseMaxY = Int(ceil(y + height - 1))

        guard baseMinX <= baseMaxX, baseMinY <= baseMaxY else { return nil }

        let minX = baseMinX - 24
        let maxX = baseMaxX + 24
        let minY = baseMinY
        let maxY = baseMaxY

        for scanX in stride(from: maxX, through: minX, by: -1) {
            for scanY in stride(from: maxY, through: minY, by: -1) {
                let candidate = CGPoint(x: CGFloat(scanX), y: CGFloat(scanY))
                if hitTestPID(at: candidate) == targetPID {
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

    private func currentPosition(of element: AXUIElement) -> CGPoint? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &value) == .success,
              let axValue = value else { return nil }
        var point = CGPoint.zero
        AXValueGetValue(axValue as! AXValue, .cgPoint, &point)
        return point
    }

    private func currentSize(of element: AXUIElement) -> CGSize? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &value) == .success,
              let axValue = value else { return nil }
        var size = CGSize.zero
        AXValueGetValue(axValue as! AXValue, .cgSize, &size)
        return size
    }

    // MARK: - Synthetic Command-Drag

    /// Synthesize a Command-drag that pauses at each waypoint so macOS
    /// can register the swap at every intermediate item boundary.
    private func syntheticCommandDrag(from start: CGPoint, waypoints: [CGPoint]) {
        guard !waypoints.isEmpty else { return }
        let source = CGEventSource(stateID: .combinedSessionState)

        // 1. Move cursor to start position
        let moveToStart = CGEvent(mouseEventSource: source,
                                   mouseType: .mouseMoved,
                                   mouseCursorPosition: start,
                                   mouseButton: .left)
        moveToStart?.post(tap: .cghidEventTap)
        usleep(50_000) // 50ms

        // 2. Command + mouse down at start
        let mouseDown = CGEvent(mouseEventSource: source,
                                mouseType: .leftMouseDown,
                                mouseCursorPosition: start,
                                mouseButton: .left)
        mouseDown?.flags = .maskCommand
        mouseDown?.post(tap: .cghidEventTap)
        usleep(200_000) // 200ms — give the system time to enter drag mode

        // 3. Drag through each waypoint, pausing at each one for macOS to
        //    register the swap. We smoothly interpolate between waypoints
        //    and dwell at each midpoint crossing.
        var current = start
        for waypoint in waypoints {
            let segmentDist = abs(waypoint.x - current.x)
            let segmentSteps = max(8, Int(segmentDist / 3))

            for i in 1...segmentSteps {
                let fraction = CGFloat(i) / CGFloat(segmentSteps)
                let intermediate = CGPoint(
                    x: current.x + (waypoint.x - current.x) * fraction,
                    y: current.y + (waypoint.y - current.y) * fraction
                )
                let drag = CGEvent(mouseEventSource: source,
                                   mouseType: .leftMouseDragged,
                                   mouseCursorPosition: intermediate,
                                   mouseButton: .left)
                drag?.flags = .maskCommand
                drag?.post(tap: .cghidEventTap)
                usleep(15_000) // 15ms between micro-steps
            }

            // Dwell at the waypoint so macOS processes the swap
            usleep(120_000) // 120ms pause at each item boundary
            current = waypoint
        }

        usleep(50_000) // 50ms settle

        // 4. Mouse up at final position
        let end = waypoints.last!
        let mouseUp = CGEvent(mouseEventSource: source,
                              mouseType: .leftMouseUp,
                              mouseCursorPosition: end,
                              mouseButton: .left)
        mouseUp?.flags = .maskCommand
        mouseUp?.post(tap: .cghidEventTap)
        usleep(50_000)
    }
}
