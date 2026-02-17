import SwiftUI

/// A one-time welcome window shown on first launch, explaining how to
/// access MenuDown and reposition the menubar icon.
struct WelcomeView: View {
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.blue)

            Text("Welcome to MenuDown!")
                .font(.title2)
                .fontWeight(.bold)

            VStack(alignment: .leading, spacing: 12) {
                tipRow(
                    icon: "keyboard",
                    title: "Open with \u{2325}M (Option + M)",
                    description: "Press this shortcut anytime to toggle the MenuDown panel."
                )

                tipRow(
                    icon: "arrow.left.arrow.right",
                    title: "Reposition the icon",
                    description: "Hold \u{2318} Command and drag the MenuDown icon in your menubar to move it away from the notch."
                )

                tipRow(
                    icon: "arrow.up.arrow.down",
                    title: "Drag to reorder",
                    description: "Use the grip handle on each item to rearrange your menubar items in the panel."
                )

                tipRow(
                    icon: "shield.checkered",
                    title: "Grant Accessibility access",
                    description: "MenuDown needs Accessibility permission to discover your menubar items. You'll be prompted automatically."
                )
            }
            .padding(.horizontal, 8)

            Spacer()

            Button("Get Started") {
                onDismiss()
            }
            .keyboardShortcut(.defaultAction)
            .controlSize(.large)
        }
        .padding(28)
        .frame(width: 440, height: 460)
    }

    private func tipRow(icon: String, title: String, description: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 24, alignment: .center)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
