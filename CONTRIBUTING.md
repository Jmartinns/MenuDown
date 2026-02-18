# Contributing to MenuDown

Thanks for your interest in contributing to MenuDown! This document covers the basics to get you started.

## Getting Started

1. **Fork** the repository and clone your fork
2. Install [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`
3. Generate the project: `xcodegen generate`
4. Resolve dependencies: `xcodebuild -resolvePackageDependencies`
5. Open `MenuDown.xcodeproj` in Xcode

## Development Notes

- **Swift 5.9**, targeting **macOS 13 Ventura** and later
- The `.xcodeproj` is gitignored — always regenerate it from `project.yml`
- MenuDown runs as an **LSUIElement** (no Dock icon, no main menu)
- The app requires **Accessibility** permission to discover menubar items
- Debug logs are written to `/tmp/menudown_debug.log`

## Making Changes

1. Create a feature branch from `main`
2. Make your changes with clear, focused commits
3. Ensure the project builds without warnings: `xcodebuild -scheme MenuDown -configuration Debug build`
4. Test on a Mac with a notch if possible (the core use case)
5. Update `CHANGELOG.md` if the change is user-facing
6. Open a pull request against `main`

## Code Style

- Follow existing conventions in the codebase
- Use `///` doc comments for public API
- Keep files focused — one primary type per file
- Prefer descriptive names over abbreviations

## Architecture Overview

| Directory | Purpose |
|-----------|---------|
| `App/` | App delegate, lifecycle, settings menu |
| `MenuBar/` | Scanner, spacer, icon capture |
| `Panel/` | SwiftUI panel view and NSPanel controller |
| `Interaction/` | Click forwarding, reordering, change detection |
| `Utilities/` | Preferences, accessibility helpers |

## Reporting Issues

- Use the **Bug Report** or **Feature Request** issue templates
- Include your MenuDown version, macOS version, and Mac model
- For bugs, paste the debug log from `/tmp/menudown_debug.log` if relevant

## License

By contributing, you agree that your contributions will be licensed under the [MIT License](LICENSE).
