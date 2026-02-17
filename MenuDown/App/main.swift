import Cocoa

/// Main entry point for the MenuDown application.
/// Uses NSApplicationMain approach for a traditional AppKit menubar-only app.

let app = NSApplication.shared

// Activate as accessory (no dock icon)
app.setActivationPolicy(.accessory)

let delegate = AppDelegate()
app.delegate = delegate

app.run()

