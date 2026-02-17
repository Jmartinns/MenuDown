import SwiftUI

/// The SwiftUI view rendered inside the vertical panel, showing a list of
/// third-party menubar items arranged vertically.
struct VerticalPanelView: View {

    @ObservedObject var scanner: MenuBarScanner
    let onItemClicked: (MenuBarItem) -> Void
    let onSettingsClicked: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if scanner.isScanning && scanner.items.isEmpty {
                loadingState
            } else if scanner.items.isEmpty {
                emptyState
            } else {
                itemList
            }
            Divider()
            footerBar
        }
        .frame(width: 220)
    }

    // MARK: - Subviews

    private var itemList: some View {
        ScrollView {
            VStack(spacing: 1) {
                ForEach(scanner.items) { item in
                    ItemRow(item: item) {
                        onItemClicked(item)
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxHeight: 400)
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
            HStack(spacing: 10) {
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
        if let icon = item.capturedIcon {
            Image(nsImage: icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else if let appIcon = item.appIcon {
            Image(nsImage: appIcon)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            Image(systemName: "app.fill")
                .foregroundStyle(.secondary)
        }
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