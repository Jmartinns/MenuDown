import Cocoa
import Combine

/// Monitors for changes in the menubar: apps launching/quitting, status items
/// appearing/disappearing. Triggers re-scans when changes are detected.
final class ChangeMonitor {

    private var cancellables = Set<AnyCancellable>()
    private let onChangeDetected: () -> Void

    init(onChangeDetected: @escaping () -> Void) {
        self.onChangeDetected = onChangeDetected
    }

    /// Start monitoring for workspace notifications that indicate menubar changes.
    func startMonitoring() {
        let workspace = NSWorkspace.shared
        let nc = workspace.notificationCenter

        // App launched — may add a status item
        nc.publisher(for: NSWorkspace.didLaunchApplicationNotification)
            .debounce(for: .seconds(1), scheduler: RunLoop.main)
            .sink { [weak self] notification in
                let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                print("[ChangeMonitor] App launched: \(app?.localizedName ?? "unknown")")
                self?.onChangeDetected()
            }
            .store(in: &cancellables)

        // App terminated — should remove its status item
        nc.publisher(for: NSWorkspace.didTerminateApplicationNotification)
            .debounce(for: .seconds(0.5), scheduler: RunLoop.main)
            .sink { [weak self] notification in
                let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                print("[ChangeMonitor] App terminated: \(app?.localizedName ?? "unknown")")
                self?.onChangeDetected()
            }
            .store(in: &cancellables)

        // Wake from sleep — items may have changed
        nc.publisher(for: NSWorkspace.didWakeNotification)
            .debounce(for: .seconds(2), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                print("[ChangeMonitor] System woke from sleep.")
                self?.onChangeDetected()
            }
            .store(in: &cancellables)
    }

    /// Stop monitoring.
    func stopMonitoring() {
        cancellables.removeAll()
    }
}
