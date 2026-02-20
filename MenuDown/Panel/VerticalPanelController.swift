import Cocoa
import SwiftUI

/// Manages the floating panel that displays menu items vertically.
/// Anchored below the MenuDown status item in the menubar.
final class VerticalPanelController {

    private var panel: NSPanel?
    private var eventMonitor: Any?

    private let scanner: MenuBarScanner
    private let clickForwarder: ClickForwarder
    private let onItemClicked: (MenuBarItem) -> Void
    private let onSettingsClicked: () -> Void
    private let onReorderApplied: (([MenuBarItem]) -> Void)?

    var isVisible: Bool {
        panel?.isVisible ?? false
    }

    init(
        scanner: MenuBarScanner,
        clickForwarder: ClickForwarder,
        onItemClicked: @escaping (MenuBarItem) -> Void,
        onSettingsClicked: @escaping () -> Void,
        onReorderApplied: (([MenuBarItem]) -> Void)? = nil
    ) {
        self.scanner = scanner
        self.clickForwarder = clickForwarder
        self.onItemClicked = onItemClicked
        self.onSettingsClicked = onSettingsClicked
        self.onReorderApplied = onReorderApplied
    }

    /// Show the panel anchored below the given status item button.
    func show(relativeTo button: NSStatusBarButton) {
        if let existing = panel, existing.isVisible {
            dismiss()
            return
        }

        let contentView = VerticalPanelView(
            scanner: scanner,
            clickForwarder: clickForwarder,
            onItemClicked: { [weak self] item in
                self?.dismiss()
                self?.onItemClicked(item)
            },
            onSettingsClicked: { [weak self] in
                self?.dismiss()
                self?.onSettingsClicked()
            },
            onReorderApplied: onReorderApplied.map { callback in
                { [weak self] items in
                    self?.dismiss()
                    callback(items)
                }
            }
        )

        // Use NSHostingController which handles sizing correctly
        let hostingController = NSHostingController(rootView: contentView)
        // Force layout to get the correct size
        hostingController.view.layoutSubtreeIfNeeded()
        let contentSize = hostingController.view.fittingSize

        // Create a borderless, non-activating panel
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        // Add visual effect background with rounded corners
        let visualEffect = NSVisualEffectView(frame: NSRect(origin: .zero, size: contentSize))
        visualEffect.material = .popover
        visualEffect.state = .active
        visualEffect.wantsLayer = true
        visualEffect.layer?.cornerRadius = 10
        visualEffect.layer?.masksToBounds = true
        visualEffect.autoresizingMask = [.width, .height]

        // Add the SwiftUI content on top of the visual effect
        let hostingView: NSView = hostingController.view
        hostingView.frame = NSRect(origin: .zero, size: contentSize)
        hostingView.autoresizingMask = [.width, .height]

        // Make the SwiftUI hosting view transparent
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear

        visualEffect.addSubview(hostingView)
        panel.contentView = visualEffect

        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false

        // Round the window itself
        panel.contentView?.wantsLayer = true
        panel.contentView?.layer?.cornerRadius = 10
        panel.contentView?.layer?.masksToBounds = true

        // Position below the status item button using screen coordinates
        if let buttonWindow = button.window {
            let buttonScreenFrame = buttonWindow.frame
            let panelX = buttonScreenFrame.midX - contentSize.width / 2
            let panelY = buttonScreenFrame.minY - contentSize.height - 4
            panel.setFrameOrigin(NSPoint(x: panelX, y: panelY))
        }

        panel.orderFrontRegardless()
        self.panel = panel

        setupClickAwayMonitor()
    }

    /// Dismiss the panel.
    func dismiss() {
        panel?.orderOut(nil)
        panel = nil
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
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

    private func setupClickAwayMonitor() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
        }
        eventMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            guard let self = self, let panel = self.panel else { return }
            let clickLocation = NSEvent.mouseLocation
            if !panel.frame.contains(clickLocation) {
                self.dismiss()
            }
        }
    }

    deinit {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}
