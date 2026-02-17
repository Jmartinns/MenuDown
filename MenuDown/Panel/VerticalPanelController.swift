import Cocoa
import SwiftUI

/// Manages the floating NSPanel that displays menu items vertically.
/// Anchored below the MenuDown status item in the menubar.
final class VerticalPanelController {

    private var panel: NSPanel?
    private var hostingView: NSHostingView<VerticalPanelView>?

    private let scanner: MenuBarScanner
    private let onItemClicked: (MenuBarItem) -> Void
    private let onSettingsClicked: () -> Void

    var isVisible: Bool {
        panel?.isVisible ?? false
    }

    init(
        scanner: MenuBarScanner,
        onItemClicked: @escaping (MenuBarItem) -> Void,
        onSettingsClicked: @escaping () -> Void
    ) {
        self.scanner = scanner
        self.onItemClicked = onItemClicked
        self.onSettingsClicked = onSettingsClicked
    }

    /// Show the panel anchored below the given status item button.
    func show(relativeTo button: NSStatusBarButton) {
        if let existing = panel, existing.isVisible {
            dismiss()
            return
        }

        let contentView = VerticalPanelView(
            scanner: scanner,
            onItemClicked: { [weak self] item in
                self?.dismiss()
                self?.onItemClicked(item)
            },
            onSettingsClicked: { [weak self] in
                self?.dismiss()
                self?.onSettingsClicked()
            }
        )

        let hosting = NSHostingView(rootView: contentView)
        hosting.setFrameSize(hosting.fittingSize)

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: hosting.fittingSize),
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hosting
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false

        // Determine position: below the status item button
        if let buttonWindow = button.window {
            let buttonFrame = buttonWindow.frame
            let panelSize = hosting.fittingSize

            let origin = NSPoint(
                x: buttonFrame.midX - panelSize.width / 2,
                y: buttonFrame.minY - panelSize.height - 4
            )
            panel.setFrameOrigin(origin)
        }

        panel.orderFrontRegardless()
        self.panel = panel
        self.hostingView = hosting

        // Set up click-away dismissal
        setupClickAwayMonitor()
    }

    /// Dismiss the panel.
    func dismiss() {
        panel?.orderOut(nil)
        panel = nil
        hostingView = nil
        removeClickAwayMonitor()
    }

    /// Toggle visibility.
    func toggle(relativeTo button: NSStatusBarButton) {
        if isVisible {
            dismiss()
        } else {
            show(relativeTo: button)
        }
    }

    // MARK: - Click-away dismissal

    private var clickAwayMonitor: Any?

    private func setupClickAwayMonitor() {
        removeClickAwayMonitor()
        clickAwayMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self = self, let panel = self.panel else { return }
            // If the click is outside the panel, dismiss it
            let clickLocation = NSEvent.mouseLocation
            if !panel.frame.contains(clickLocation) {
                self.dismiss()
            }
        }
    }

    private func removeClickAwayMonitor() {
        if let monitor = clickAwayMonitor {
            NSEvent.removeMonitor(monitor)
            clickAwayMonitor = nil
        }
    }

    deinit {
        removeClickAwayMonitor()
    }
}
