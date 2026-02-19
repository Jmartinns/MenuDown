<p align="center">
  <img src="docs/MenuDownIcon.png" alt="MenuDown" width="128" height="128" style="border-radius: 22%;" />
</p>

<h1 align="center">MenuDown</h1>

<p align="center">
  <strong>Reclaim your menubar from the MacBook notch.</strong><br>
  A lightweight macOS utility that reveals hidden menubar items — automatically dragging them out from behind the notch so you can see and click them.
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

MacBook models with a notch cut into the menubar. When you run enough apps, their menubar items get pushed behind the notch — invisible, unreachable, and impossible to click. macOS silently swallows click events in the notch zone, so even if you know an item is there, you can't interact with it.

## The Solution

MenuDown adds a single icon to your menubar. Click it (or press **⌃⌥⌘M**) to open a vertical panel showing every third-party menubar item — including the ones hidden behind the notch.

When you click a hidden item, MenuDown doesn't just try to click through the notch (that would fail). Instead, it **physically drags the item out** from behind the notch into visible space, then clicks it. The menu opens exactly as if you'd clicked the real icon. This all happens automatically in a fraction of a second.

<!-- TODO: Add screenshot -->
<!-- <p align="center">
  <img src="docs/screenshot.png" alt="MenuDown panel showing menubar items vertically" width="600">
</p> -->

## Features

- **Click-to-Reveal** — Click any item in the panel, even one hidden behind the notch. MenuDown automatically drags it into view, clicks it, and opens its menu
- **Smart reordering** — Drag items to rearrange your menubar. MenuDown physically moves the real icons to match, intelligently exposing notch-blocked items first so every icon reaches its target
- **Auto-discovery** — Finds all third-party menubar items automatically via the macOS Accessibility API
- **App menu clearance** — When a foreground app's text menus (File, Edit, View…) overlap your status icons, MenuDown temporarily clears them so clicks and drags land on the right target
- **Vertical layout** — All your menubar items in a clean dropdown panel — no more guessing what's hiding behind the notch
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

### Discovery

MenuDown uses the macOS **Accessibility API** (`AXUIElement`) to discover third-party menubar extras across all running applications. It queries each app's `kAXExtrasMenuBarAttribute` concurrently to build the item list in under 0.5 seconds — including items hidden behind the notch that you can't see.

### Notch Bypass (Click-to-Reveal)

Clicking a visible item is straightforward: MenuDown warps the cursor to the real icon position and synthesizes a click.

Clicking a **hidden** item is harder. macOS silently discards click events that land in the notch exclusion zone. MenuDown works around this by synthesizing a **⌘-drag** that physically pulls the icon out from behind the notch into visible space, then clicking it there. If a foreground app's text menus (File, Edit, View…) are overlapping the status-item area, MenuDown temporarily switches to Finder to clear them, performs the operation, then restores the original app.

### Smart Reordering

When you rearrange items in the panel and apply changes, MenuDown physically moves the real menubar icons via synthetic ⌘-drag events. The reorder algorithm:

1. **Pre-expose** — Sweeps all notch-blocked items into visible space so every icon is reachable
2. **Greedy placement** — Each iteration picks the most-displaced reachable item and drags it directly to its target in one move
3. **On-demand expose** — If an item can't be reached (still behind the notch), it's dragged out individually before the next pass
4. **Loop detection** — Tracks previous states to prevent infinite cycling if items shift unpredictably

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
│   ├── ClickForwarder.swift       # Click forwarding with notch-bypass drag-to-expose
│   ├── MenuBarReorderer.swift     # Greedy reorder with pre-expose & loop detection
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
