<p align="center">
  <img src="docs/MenuDownIcon.png" alt="MenuDown" width="128" height="128" style="border-radius: 22%;" />
</p>

<h1 align="center">MenuDown</h1>

<p align="center">
  <strong>Reclaim your menubar from the MacBook notch.</strong><br>
  A lightweight macOS utility that displays third-party menubar items in a vertical panel — so nothing hides behind the notch ever again.
</p>

<p align="center">
  <a href="https://github.com/Jmartinns/MenuDown/releases/latest"><img src="https://img.shields.io/github/v/release/Jmartinns/MenuDown?style=flat-square&color=c840e9" alt="Latest Release"></a>
  <a href="https://github.com/Jmartinns/MenuDown/releases/latest"><img src="https://img.shields.io/github/downloads/Jmartinns/MenuDown/total?style=flat-square&color=4040ff" alt="Downloads"></a>
  <img src="https://img.shields.io/badge/macOS-13%2B-blue?style=flat-square" alt="macOS 13+">
  <img src="https://img.shields.io/badge/Swift-5.9-orange?style=flat-square" alt="Swift 5.9">
  <a href="LICENSE"><img src="https://img.shields.io/github/license/Jmartinns/MenuDown?style=flat-square" alt="License"></a>
</p>

<p align="center">
  <a href="https://github.com/Jmartinns/MenuDown/releases/latest/download/MenuDown.dmg">
    <strong>⬇ Download MenuDown.dmg</strong>
  </a>
  &nbsp;&nbsp;·&nbsp;&nbsp;
  <a href="https://jmartinns.github.io/MenuDown/">Website</a>
  &nbsp;&nbsp;·&nbsp;&nbsp;
  <a href="CHANGELOG.md">Changelog</a>
</p>

---

## The Problem

MacBook models with a notch cut into the menubar. When you run enough apps, their menubar items get hidden behind the notch — invisible and unreachable.

## The Solution

MenuDown adds a single icon to your menubar. Click it (or press **⌃⌥⌘M**) to open a vertical panel listing all your third-party menubar items. Click any item to open its original menu, exactly as if you'd clicked the real icon.

<!-- TODO: Add screenshot -->
<!-- <p align="center">
  <img src="docs/screenshot.png" alt="MenuDown panel showing menubar items vertically" width="600">
</p> -->

## Features

- **Vertical layout** — All third-party menubar items in a clean dropdown panel
- **Auto-discovery** — Finds items automatically via the macOS Accessibility API
- **Click forwarding** — Click an item to open its original menu with full tracking
- **Drag to reorder** — Rearrange the order; MenuDown physically moves the real menubar icons to match
- **Global hotkey** — Toggle the panel with **⌃⌥⌘M** (Control + Option + Command + M)
- **Auto-updates** — Built-in Sparkle updater checks for new versions automatically
- **Privacy first** — No network access, no analytics, no telemetry. Runs entirely on-device
- **Lightweight** — Native Swift, scans in under 0.5 seconds, minimal memory footprint

## Installation

1. Download **[MenuDown.dmg](https://github.com/Jmartinns/MenuDown/releases/latest/download/MenuDown.dmg)**
2. Open the DMG and drag MenuDown to **Applications**
3. Launch MenuDown — it appears as an arrow icon (↓) in your menubar
4. Grant **Accessibility** permission when prompted

> Signed and notarized by Apple. Requires macOS 13 Ventura or later.

## Building from Source

MenuDown uses [XcodeGen](https://github.com/yonaskolb/XcodeGen) to generate the Xcode project.

```bash
# Clone the repo
git clone https://github.com/Jmartinns/MenuDown.git
cd MenuDown

# Install XcodeGen if you don't have it
brew install xcodegen

# Generate the Xcode project and resolve dependencies
xcodegen generate
xcodebuild -resolvePackageDependencies

# Open in Xcode
open MenuDown.xcodeproj
```

### Requirements

- Xcode 15+
- macOS 13 Ventura SDK or later
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)

## How It Works

MenuDown uses the macOS **Accessibility API** (`AXUIElement`) to discover third-party menubar extras across all running applications. It queries each app's `kAXExtrasMenuBarAttribute` concurrently to build the item list in under 0.5 seconds.

When you click an item in the panel, MenuDown warps the cursor to the real status item position and synthesizes a click event, which makes macOS start proper menu tracking — the opened menu stays open and responds normally.

Drag-to-reorder uses synthetic **⌘-drag** events with a waypoint-aware algorithm that smoothly moves icons through intermediate positions.

## Architecture

```
MenuDown/
├── App/
│   └── AppDelegate.swift          # App lifecycle, hotkey, settings
├── MenuBar/
│   ├── MenuBarScanner.swift       # AX-based menubar item discovery
│   ├── SpacerManager.swift        # Hides/reveals original items
│   └── IconCapturer.swift         # Screenshots menubar for item icons
├── Panel/
│   ├── VerticalPanelController.swift  # NSPanel management
│   ├── VerticalPanelView.swift        # SwiftUI panel content
│   └── WelcomeView.swift              # First-launch welcome window
├── Interaction/
│   ├── ClickForwarder.swift       # Synthetic click forwarding
│   ├── MenuBarReorderer.swift     # Waypoint-aware ⌘-drag reordering
│   └── ChangeMonitor.swift        # App launch/quit detection
└── Utilities/
    ├── Preferences.swift          # UserDefaults wrapper
    └── AccessibilityHelper.swift  # Permission checking
```

## Roadmap

- [ ] Search / filter items by name
- [ ] Appearance customization (icon size, panel width, theme)
- [ ] Launch at login toggle in settings
- [ ] Exclude specific apps from the panel
- [ ] Hover previews for item tooltips
- [ ] Keyboard navigation within the panel
- [ ] Multi-display support

## Contributing

Contributions are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

## License

[MIT](LICENSE) — free for personal and commercial use.

---

<p align="center">
  Made by <a href="https://github.com/Jmartinns">Joey Martin</a>
</p>
