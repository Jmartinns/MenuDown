import Cocoa

/// Manages an invisible NSStatusItem spacer that pushes third-party menubar
/// items off-screen, using the same technique as Hidden Bar.
final class SpacerManager: ObservableObject {

    @Published private(set) var isHiding: Bool = false

    private var spacerItem: NSStatusItem?
    private let normalLength: CGFloat = 0
    private let expandedLength: CGFloat = 10_000

    /// Create and install the spacer status item.
    func install() {
        guard spacerItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.length = normalLength
        item.isVisible = true

        // Optional: set an autosaveName so macOS remembers its position
        item.autosaveName = "com.menudown.spacer"

        spacerItem = item
    }

    /// Remove the spacer from the menubar.
    func uninstall() {
        if let item = spacerItem {
            NSStatusBar.system.removeStatusItem(item)
        }
        spacerItem = nil
        isHiding = false
    }

    /// Expand the spacer to push third-party items off-screen.
    func hide() {
        guard let item = spacerItem else { return }
        item.length = expandedLength
        isHiding = true
    }

    /// Collapse the spacer to reveal third-party items.
    func reveal() {
        guard let item = spacerItem else { return }
        item.length = normalLength
        isHiding = false
    }

    /// Briefly reveal items, execute a closure, then re-hide.
    /// Used for icon capture and click forwarding.
    func brieflyReveal(duration: TimeInterval = 0.1, action: @escaping () -> Void) {
        reveal()
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            action()
            DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
                self?.hide()
            }
        }
    }

    /// Briefly reveal with async/await support.
    func brieflyReveal(duration: TimeInterval = 0.1) async {
        reveal()
        try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
    }

    /// Re-hide after an async operation.
    func reHide(after duration: TimeInterval = 0.1) async {
        try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
        await MainActor.run { hide() }
    }
}
