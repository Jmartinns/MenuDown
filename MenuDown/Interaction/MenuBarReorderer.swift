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

    private let spacerManager: SpacerManager
    private weak var scanner: MenuBarScanner?

    /// Reference to MenuDown's own status item for live position reading.
    var selfStatusItem: NSStatusItem?

    init(spacerManager: SpacerManager, scanner: MenuBarScanner) {
        self.spacerManager = spacerManager
        self.scanner = scanner
    }

    /// Rearrange the physical menubar to match the desired order (left → right).
    /// This works by identifying which items need to move and performing
    /// synthetic Command-drags one at a time.
    ///
    /// - Parameter desiredOrder: Items in the order they should appear
    ///   from left to right in the menubar.
    func applyOrder(_ desiredOrder: [MenuBarItem]) {
        guard !desiredOrder.isEmpty else { return }

        // Pause scanning so AX queries don't interfere
        scanner?.pause()

        // Reveal all items so they're on-screen
        spacerManager.reveal()

        debugLog("Starting reorder for \(desiredOrder.count) items.")

        // Perform reorder on a background queue with delays between each move
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            // Wait for the menubar to redraw after revealing
            Thread.sleep(forTimeInterval: 0.3)

            // Read current positions and determine the current left-to-right order
            let currentPositions = self.readPositions(for: desiredOrder)
            let currentOrder = currentPositions.sorted { $0.x < $1.x }
            let currentBundleOrder = currentOrder.map(\.bundleID)
            let desiredBundleOrder = desiredOrder.map(\.bundleID)

            debugLog("Current order: \(currentBundleOrder)")
            debugLog("Desired order: \(desiredBundleOrder)")

            // Find items that are out of place and need a single direct drag.
            // Compare current vs desired — only drag items that aren't already
            // in their target position.
            // We process from left to right. For each slot, if the wrong item
            // is there, find the correct item and drag it directly across
            // in one move (macOS shifts everything in between automatically).

            for desiredIdx in 0..<desiredOrder.count {
                let targetBundleID = desiredOrder[desiredIdx].bundleID

                // Retry up to 3 times if the drag doesn't land correctly
                for attempt in 0..<3 {
                    // Re-read positions to account for shifts from previous drags
                    let freshPositions = self.readPositions(for: desiredOrder)
                    let freshSortedByX = freshPositions.sorted { $0.x < $1.x }

                    guard desiredIdx < freshSortedByX.count else { break }

                    let currentAtSlot = freshSortedByX[desiredIdx]

                    if currentAtSlot.bundleID == targetBundleID {
                        debugLog("\(targetBundleID) already at slot \(desiredIdx)\(attempt > 0 ? " (after \(attempt) retries)" : "")")
                        break
                    }

                    // Find the item that belongs here
                    guard let sourceIdx = freshSortedByX.firstIndex(where: { $0.bundleID == targetBundleID }) else {
                        debugLog("Could not find \(targetBundleID), skipping.")
                        break
                    }

                    let sourceInfo = freshSortedByX[sourceIdx]
                    let fromX = sourceInfo.x + sourceInfo.width / 2
                    let y = sourceInfo.y + sourceInfo.height / 2

                    // Collect midpoints of all intermediate items between source
                    // and target. We'll pause at each one so macOS registers the swap.
                    let movingLeft = sourceIdx > desiredIdx
                    var waypointXs: [CGFloat] = []
                    if movingLeft {
                        // Moving left: pass through items at indices desiredIdx..<sourceIdx
                        for i in stride(from: sourceIdx - 1, through: desiredIdx, by: -1) {
                            waypointXs.append(freshSortedByX[i].x + freshSortedByX[i].width / 2)
                        }
                        // Final overshoot past the left edge
                        waypointXs.append(freshSortedByX[desiredIdx].x - 4)
                    } else {
                        // Moving right: pass through items at indices (sourceIdx+1)...desiredIdx
                        for i in (sourceIdx + 1)...desiredIdx {
                            waypointXs.append(freshSortedByX[i].x + freshSortedByX[i].width / 2)
                        }
                        // Final overshoot past the right edge
                        waypointXs.append(freshSortedByX[desiredIdx].x + freshSortedByX[desiredIdx].width + 4)
                    }

                    debugLog("Drag \(targetBundleID): x=\(Int(fromX)) → \(waypointXs.map { Int($0) }) (attempt \(attempt + 1))")
                    self.syntheticCommandDrag(
                        from: CGPoint(x: fromX, y: y),
                        waypoints: waypointXs.map { CGPoint(x: $0, y: y) }
                    )

                    // Wait for the menubar to settle
                    Thread.sleep(forTimeInterval: 0.5)
                }
            }

            debugLog("Reorder complete.")

            DispatchQueue.main.async { [weak self] in
                // Keep originals visible and resume scanning.
                self?.spacerManager.reveal()
                self?.scanner?.resume()
                self?.scanner?.scanAsync()
            }
        }
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
