import Cocoa
import ApplicationServices

/// Forwards user clicks from the vertical panel to the original menubar items
/// via the Accessibility API.
final class ClickForwarder {

    private let spacerManager: SpacerManager
    private weak var scanner: MenuBarScanner?

    init(spacerManager: SpacerManager, scanner: MenuBarScanner) {
        self.spacerManager = spacerManager
        self.scanner = scanner
    }

    /// Simulate a click on the given menubar item.
    /// Reveals hidden items, pauses scanning, performs the click, then waits for
    /// menu dismissal to re-hide and resume scanning.
    func click(_ item: MenuBarItem) {
        // Don't forward clicks to MenuDown's own status item
        guard !item.isSelf else { return }

        // Pause scanning — AX queries from the scanner can interrupt
        // another app's menu tracking and cause the menu to close.
        scanner?.pause()

        // Reveal the original items so the menu and its target are on-screen
        spacerManager.reveal()

        // Wait for the menubar to redraw with items visible
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            // Re-read the item's current position now that it's on-screen
            let clickPosition = self.currentPosition(of: item.axElement) ?? item.position
            let clickSize = self.currentSize(of: item.axElement) ?? item.size

            // Activate the target app — macOS requires it for menu tracking.
            if let app = NSRunningApplication(processIdentifier: item.pid) {
                app.activate(options: [])
            }

            // Use a synthetic mouse click at the item's actual screen position.
            // This is more reliable than AXPress for menu tracking — it mimics
            // what the user does when clicking the status item directly.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.syntheticClick(at: clickPosition, size: clickSize)

                // Re-hide and resume scanning only after menu dismissal
                self.monitorMenuDismissal { [weak self] in
                    self?.spacerManager.hide()
                    self?.scanner?.resume()
                }
            }
        }
    }

    /// Get the current on-screen position of an AX element.
    private func currentPosition(of element: AXUIElement) -> CGPoint? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &value) == .success,
              let axValue = value else { return nil }
        var point = CGPoint.zero
        AXValueGetValue(axValue as! AXValue, .cgPoint, &point)
        return point
    }

    /// Get the current size of an AX element.
    private func currentSize(of element: AXUIElement) -> CGSize? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &value) == .success,
              let axValue = value else { return nil }
        var size = CGSize.zero
        AXValueGetValue(axValue as! AXValue, .cgSize, &size)
        return size
    }

    /// Synthesize a mouse click event at the given menubar item position.
    private func syntheticClick(at position: CGPoint, size: CGSize) {
        let clickPoint = CGPoint(
            x: position.x + size.width / 2,
            y: position.y + size.height / 2
        )

        let mouseDown = CGEvent(
            mouseEventSource: nil,
            mouseType: .leftMouseDown,
            mouseCursorPosition: clickPoint,
            mouseButton: .left
        )
        let mouseUp = CGEvent(
            mouseEventSource: nil,
            mouseType: .leftMouseUp,
            mouseCursorPosition: clickPoint,
            mouseButton: .left
        )

        mouseDown?.post(tap: .cghidEventTap)
        usleep(50_000) // 50ms
        mouseUp?.post(tap: .cghidEventTap)
    }

    /// Monitor for menu dismissal so we can re-hide the spacer and resume scanning.
    /// Polls for the menu closing rather than using event monitors that can
    /// interfere with menu tracking.
    private func monitorMenuDismissal(completion: @escaping () -> Void) {
        var didFire = false

        let cleanup: () -> Void = {
            guard !didFire else { return }
            didFire = true
            completion()
        }

        // Poll every 0.5s: check if any app still has an open menu.
        // This avoids global event monitors that can interfere with menus.
        var pollCount = 0
        let maxPolls = 120 // 60 seconds max

        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { timer in
            pollCount += 1

            // Check if any menubar-related menu is currently open
            // by looking at the frontmost app's AX focused element
            let hasOpenMenu = self.isAnyMenuOpen()

            if !hasOpenMenu || pollCount >= maxPolls {
                timer.invalidate()
                // Small delay to let the menu close animation finish
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    cleanup()
                }
            }
        }
    }

    /// Check if any status item menu appears to be currently open.
    private func isAnyMenuOpen() -> Bool {
        // Look for windows that look like menus (borderless, small, at top of screen)
        // by checking the window list for menu-type windows.
        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[CFString: Any]] else {
            return false
        }

        for window in windowList {
            let layer = window[kCGWindowLayer] as? Int ?? 0
            // NSMenu windows are on layer 101 (kCGPopUpMenuWindowLevel)
            // and status item menus on similar high levels
            if layer >= 101 {
                let name = window[kCGWindowName as CFString] as? String ?? ""
                // Skip known non-menu windows
                if name.isEmpty || name == "Notification Center" {
                    return true
                }
            }
        }
        return false
    }
}
