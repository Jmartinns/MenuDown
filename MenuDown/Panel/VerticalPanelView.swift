import SwiftUI
import UniformTypeIdentifiers

/// The SwiftUI view rendered inside the vertical panel, showing a list of
/// third-party menubar items arranged vertically.
struct VerticalPanelView: View {

    @ObservedObject var scanner: MenuBarScanner
    let onItemClicked: (MenuBarItem) -> Void
    let onSettingsClicked: () -> Void
    let onReorderApplied: (([MenuBarItem]) -> Void)?

    /// The locally-ordered list. Starts from scanner.items but can be
    /// rearranged by the user via drag-and-drop.
    @State private var orderedItems: [MenuBarItem] = []

    /// Whether the local order differs from the scanner's natural order.
    @State private var orderDirty = false

    /// The item currently being dragged, if any.
    @State private var draggingItem: MenuBarItem?

    var body: some View {
        VStack(spacing: 0) {
            if scanner.isScanning && scanner.items.isEmpty {
                loadingState
            } else if scanner.items.isEmpty {
                emptyState
            } else {
                itemList
            }
            applyOrderBar
                .opacity(orderDirty ? 1 : 0)
                .allowsHitTesting(orderDirty)
            Divider()
            footerBar
        }
        .frame(width: 220)
        .onChange(of: scanner.items.map(\.id)) { _ in
            syncOrder()
        }
        .onAppear {
            syncOrder()
        }
    }

    // MARK: - Order syncing

    /// Show items in their actual menubar order (sorted by X position).
    /// This ensures the panel always reflects reality, so when the user
    /// drags to reorder, only their explicit changes are applied — no
    /// phantom corrections from stale saved preferences.
    private func syncOrder() {
        orderedItems = scanner.items.sorted { $0.position.x < $1.position.x }
        orderDirty = false
    }

    // MARK: - Subviews

    private var itemList: some View {
        ScrollView {
            VStack(spacing: 1) {
                ForEach(orderedItems) { item in
                    ItemRow(item: item) {
                        onItemClicked(item)
                    }
                    .onDrag {
                        self.draggingItem = item
                        return NSItemProvider(object: item.id as NSString)
                    }
                    .onDrop(
                        of: [UTType.text],
                        delegate: ItemReorderDropDelegate(
                            item: item,
                            items: $orderedItems,
                            draggingItem: $draggingItem,
                            orderDirty: $orderDirty
                        )
                    )
                    .opacity(draggingItem?.id == item.id ? 0.4 : 1.0)
                }
            }
            .padding(.vertical, 4)
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxHeight: 400)
    }

    private var applyOrderBar: some View {
        HStack {
            Button("Reset") {
                syncOrder()
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(.secondary)

            Spacer()

            Button {
                // Save order to preferences
                Preferences.shared.itemOrder = orderedItems.map(\.bundleID)
                orderDirty = false
                // Trigger the physical reorder callback
                onReorderApplied?(orderedItems)
            } label: {
                Label("Apply Order", systemImage: "arrow.up.arrow.down")
                    .font(.caption)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "menubar.arrow.up.rectangle")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text("No third-party menu items found")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if !AccessibilityHelper.isAccessibilityEnabled {
                Button("Grant Accessibility Access") {
                    AccessibilityHelper.requestAccessibilityPermission()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Text("If you already granted access, try quitting\nand relaunching MenuDown.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 2)
            }
        }
        .padding(20)
    }

    private var loadingState: some View {
        VStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("Scanning menubar items...")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
    }

    private var footerBar: some View {
        HStack {
            if let lastScan = scanner.lastScanDate {
                Text("Scanned \(lastScan, style: .relative) ago")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Button {
                onSettingsClicked()
            } label: {
                Image(systemName: "gear")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}

// MARK: - Item Row

struct ItemRow: View {
    @ObservedObject var item: MenuBarItem
    let action: () -> Void
    @State private var isRenaming = false
    @State private var renameText = ""
    @State private var currentDisplayName = ""

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                DragGrip()

                iconView
                    .frame(width: 20, height: 20)

                VStack(alignment: .leading, spacing: 1) {
                    Text(currentDisplayName)
                        .font(.system(size: 13))
                        .lineLimit(1)
                    // Only show subtitle when it differs from display name
                    if item.appName != currentDisplayName {
                        Text(item.appName)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.quaternary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(Color.clear)
        .cornerRadius(4)
        .padding(.horizontal, 4)
        .contextMenu {
            Button("Rename…") {
                renameText = currentDisplayName
                isRenaming = true
            }
            if Preferences.shared.customName(for: item.bundleID) != nil {
                Button("Reset Name") {
                    Preferences.shared.setCustomName(nil, for: item.bundleID)
                    currentDisplayName = item.displayName
                }
            }
        }
        .sheet(isPresented: $isRenaming) {
            RenameSheet(
                currentName: currentDisplayName,
                onSave: { newName in
                    Preferences.shared.setCustomName(newName, for: item.bundleID)
                    currentDisplayName = newName
                    isRenaming = false
                },
                onCancel: { isRenaming = false }
            )
        }
        .onAppear {
            currentDisplayName = item.displayName
        }
    }

    @ViewBuilder
    private var iconView: some View {
        if let appIcon = item.appIcon {
            Image(nsImage: appIcon)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
        } else if let icon = item.capturedIcon {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
        } else if let wsIcon = Self.iconFromBundleID(item.bundleID) {
            Image(nsImage: wsIcon)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
        } else {
            Image(systemName: "app.fill")
                .foregroundStyle(.secondary)
        }
    }

    /// Look up an app icon via NSWorkspace as a last-resort fallback.
    private static func iconFromBundleID(_ bundleID: String) -> NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}

// MARK: - Rename Sheet

struct RenameSheet: View {
    let currentName: String
    let onSave: (String) -> Void
    let onCancel: () -> Void

    @State private var text: String = ""

    var body: some View {
        VStack(spacing: 16) {
            Text("Rename Menu Item")
                .font(.headline)

            TextField("Display name", text: $text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
                .onSubmit { save() }

            HStack(spacing: 12) {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .onAppear { text = currentName }
    }

    private func save() {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        onSave(trimmed)
    }
}

// MARK: - Drag-and-Drop Reorder Delegate

/// Handles the drop logic for reordering items within the VStack.
struct ItemReorderDropDelegate: DropDelegate {
    let item: MenuBarItem
    @Binding var items: [MenuBarItem]
    @Binding var draggingItem: MenuBarItem?
    @Binding var orderDirty: Bool

    func performDrop(info: DropInfo) -> Bool {
        draggingItem = nil
        return true
    }

    func dropEntered(info: DropInfo) {
        guard let dragging = draggingItem,
              dragging.id != item.id,
              let fromIndex = items.firstIndex(where: { $0.id == dragging.id }),
              let toIndex = items.firstIndex(where: { $0.id == item.id }) else {
            return
        }
        withAnimation(.easeInOut(duration: 0.2)) {
            items.move(fromOffsets: IndexSet(integer: fromIndex),
                       toOffset: toIndex > fromIndex ? toIndex + 1 : toIndex)
        }
        orderDirty = true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func validateDrop(info: DropInfo) -> Bool {
        true
    }
}

// MARK: - Drag Grip

/// A 2×3 dot grid drag handle, matching the standard grip pattern.
struct DragGrip: View {
    var body: some View {
        VStack(spacing: 3) {
            dotRow
            dotRow
            dotRow
        }
        .frame(width: 8)
    }

    private var dotRow: some View {
        HStack(spacing: 3) {
            Circle().frame(width: 3, height: 3)
            Circle().frame(width: 3, height: 3)
        }
        .foregroundStyle(.quaternary)
    }
}