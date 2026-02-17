import Cocoa
import ApplicationServices

/// Captures icons from the menubar region via screenshots and slices them
/// into individual item images based on AX-reported positions.
final class IconCapturer {

    /// Capture icons for all provided items by screenshotting the menubar.
    /// The items must have valid positions and sizes.
    func captureIcons(for items: [MenuBarItem]) {
        guard !items.isEmpty else { return }
        guard let screen = NSScreen.main else { return }

        // Use NSStatusBar.system.thickness for menu bar height to avoid touching NSApplication.mainMenu off the main thread
        let menuBarHeight: CGFloat = NSStatusBar.system.thickness

        // Capture the entire menubar strip
        let captureRect = CGRect(
            x: 0,
            y: 0, // In CG coords, top of screen
            width: screen.frame.width,
            height: menuBarHeight
        )

        guard let fullImage = CGWindowListCreateImage(
            captureRect,
            .optionOnScreenOnly,
            kCGNullWindowID,
            [.bestResolution, .boundsIgnoreFraming]
        ) else {
            print("[IconCapturer] Failed to capture menubar screenshot.")
            return
        }

        let scale = CGFloat(fullImage.width) / screen.frame.width

        // Slice individual item icons
        for item in items {
            let sliceRect = CGRect(
                x: item.position.x * scale,
                y: 0,
                width: item.size.width * scale,
                height: CGFloat(fullImage.height)
            )

            guard sliceRect.maxX <= CGFloat(fullImage.width) else { continue }

            if let croppedCG = fullImage.cropping(to: sliceRect) {
                let nsImage = NSImage(
                    cgImage: croppedCG,
                    size: NSSize(width: item.size.width, height: menuBarHeight)
                )
                DispatchQueue.main.async {
                    item.capturedIcon = nsImage
                }
            }
        }
    }

    /// Capture a single item's icon.
    func captureIcon(for item: MenuBarItem) {
        captureIcons(for: [item])
    }
}

