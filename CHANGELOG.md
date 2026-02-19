# Changelog

All notable changes to MenuDown are documented here. Releases are available on the [GitHub Releases](https://github.com/Jmartinns/MenuDown/releases) page.

## [0.6.0] — 2026-02-19

### Added

- **Click-to-Reveal** for notch-blocked menu bar items — detects items hidden behind the notch and provides reachability checking
- Boundary-blocked notice popover alerts when items can't be moved past the notch boundary
- `cancelActiveForwarding()` for cleaner interaction transitions before reorder

### Changed

- Removed SpacerManager entirely — original menubar items are always visible
- Refactored MenuBarReorderer with Finder activation for better notch handling and greedy direct-placement algorithm
- Enhanced ClickForwarder with `bestReachableClickPoint()` for notch-blocked item detection

## [0.5.0] — 2026-02-18

### Changed

- Global hotkey changed to **⌃⌥⌘M** (Control + Option + Command + M) using Carbon API for reliable registration
- Removed spacer toggle — original menubar items now always visible
- Welcome window uses the app icon instead of a generic SF Symbol

### Fixed

- Simplified icon capture to avoid reveal/re-hide flashes

## [0.4.2] — 2026-02-18

### Fixed

- Menus no longer collapse after ~1 second when clicking status items through MenuDown
- Rewrote click forwarding to use synthetic clicks with proper cursor warping for reliable menu tracking
- Added generation-based invalidation to prevent stale dismissal monitors from interfering with new clicks

## [0.4.1] — 2026-02-17

### Fixed

- Click forwarding now works when app menus overlap status items
- Removed Finder flash on click fallback

## [0.4.0] — 2026-02-17

### Improved

- Drag-to-reorder grip reliability on trackpads
- Menubar reorder algorithm — icons now move directly to the target position instead of one step at a time (waypoint-aware dragging)

## [0.3.2] — 2026-02-17

### Fixed

- Welcome window now fits all content properly

### Added

- "Getting Started…" settings menu item to re-open the welcome guide anytime
- Drag-to-reorder tip in the welcome guide

## [0.3.1] — 2026-02-17

### Improved

- DMG now includes Applications folder symlink for easy drag-to-install
- Added favicon to the GitHub Pages site

## [0.3.0] — 2026-02-17

### Added

- **Automatic updates via Sparkle** — checks for updates automatically and notifies when a new version is available
- "Check for Updates…" menu item in the Settings gear menu
- EdDSA-signed appcast hosted on GitHub Pages

## [0.2.1] — 2026-02-17

### Fixed

- Click forwarding — clicking items in the panel now properly activates their menus again
- Option+M hotkey not working after fresh accessibility permission grant
- Drag-to-reorder now uses the grip handle only, so it no longer conflicts with clicks

## [0.2.0] — 2026-02-17

### Added

- Custom app icon
- Custom menubar template icon (adapts to light/dark mode)
- Drag-to-reorder menubar items with physical rearrangement
- Drag grip handles for visual reorder cue
- MenuDown appears in its own item list

### Improved

- Icon caching — no more disappearing icons
- Reorder algorithm with single direct drags

## [1.0.0] — 2026-02-17

Initial release.

### Features

- Vertical menubar layout — all third-party status items in a clean dropdown
- Auto-discovery via the Accessibility API
- Click forwarding to open original menus
- Custom renaming — right-click to rename items with cryptic titles
- Native Swift, no dependencies, scans in under 0.5 seconds

[0.5.0]: https://github.com/Jmartinns/MenuDown/releases/tag/v0.5.0
[0.4.2]: https://github.com/Jmartinns/MenuDown/releases/tag/v0.4.2
[0.4.1]: https://github.com/Jmartinns/MenuDown/releases/tag/v0.4.1
[0.4.0]: https://github.com/Jmartinns/MenuDown/releases/tag/v0.4.0
[0.3.2]: https://github.com/Jmartinns/MenuDown/releases/tag/v0.3.2
[0.3.1]: https://github.com/Jmartinns/MenuDown/releases/tag/v0.3.1
[0.3.0]: https://github.com/Jmartinns/MenuDown/releases/tag/v0.3.0
[0.2.1]: https://github.com/Jmartinns/MenuDown/releases/tag/v0.2.1
[0.2.0]: https://github.com/Jmartinns/MenuDown/releases/tag/v0.2.0
[1.0.0]: https://github.com/Jmartinns/MenuDown/releases/tag/v1.0.0
