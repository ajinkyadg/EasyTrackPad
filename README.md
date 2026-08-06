# InputCustomizer

A simple, hackable macOS app for customizing trackpad gestures, mouse
buttons, and keyboard keys — a lightweight, open-source alternative to
BetterTouchTool / MultitouchTool, built as a native Swift/SwiftUI app.

## Status

Early scaffold. Core engines (keyboard remap, mouse button remap, trackpad
gestures) and a basic rules UI are in place; see [Roadmap](#roadmap) for
what's stubbed out vs. working.

## Architecture

```
Sources/InputCustomizer/
  App.swift                 Menu bar app entry point, permission gating
  Managers/
    KeyboardManager.swift   CGEventTap-based key interception/remap
    MouseManager.swift      CGEventTap-based mouse button interception
    TrackpadManager.swift   NSEvent gesture monitors (swipe/magnify/rotate)
    ActionRunner.swift      Shared "run this action" execution (shell, launch app, media key)
    PermissionsHelper.swift Accessibility permission check/prompt
  Models/
    CustomizationRule.swift Trigger → Action rule model (Codable)
  Storage/
    SettingsStore.swift     JSON persistence in ~/Library/Application Support
  Views/
    SettingsView.swift      Tabbed rule list (Trackpad / Mouse / Keyboard)
    AddRuleView.swift       Form to create a new rule
```

Each device gets its own manager so you can reason about (and debug) one
input source at a time. All managers read from the same `SettingsStore`,
so adding a rule in the UI takes effect immediately without restarting.

## Requirements

- macOS 13+
- Xcode 15+ (for building/running/signing; Swift Package Manager alone
  can compile the code but you'll want Xcode for entitlements, signing,
  and a proper .app bundle)

## Getting started

This repo is a Swift Package, which is enough to build and iterate on
logic (`swift build`, `swift test`). To use it like a normal menu-bar app
on your own Mac, export a local `.app` bundle:

```bash
./Scripts/export-app.sh
open dist/InputCustomizer.app
```

The script builds the release executable, wraps it in
`dist/InputCustomizer.app`, copies the bundle metadata from
`Sources/InputCustomizer/Resources/Info.plist`, and ad-hoc signs the app
for local use.

On first launch, macOS will prompt for **Accessibility** access
(System Settings → Privacy & Security → Accessibility). You may also need
to grant **Input Monitoring** so the keyboard and mouse event taps receive
events. After launch, look for the hand-tap icon in the menu bar →
**Preferences…** to add rules per device.

For development in Xcode:

1. Open the folder in Xcode: `File → Open…` → select this folder.
2. Xcode will read `Package.swift` and let you run the `InputCustomizer`
   scheme directly.

For pure logic development:
```bash
swift build
swift test
```

## Trackpad gestures

The current implementation uses AppKit's public `NSEvent` gesture
monitors (`.swipe`, `.magnify`, `.rotate`). This is deliberately
conservative — it won't break across macOS point releases and needs no
private frameworks — but it can't do things like raw finger-count taps
(e.g. "3-finger tap" is only partially covered). If you need that level
of control later, the private `MultitouchSupport.framework` (used by
BetterTouchTool and others) exposes raw multitouch frames, at the cost
of being unsupported/undocumented and liable to break on macOS updates.

## Known gaps / TODO

- **Keyboard combo capture UI**: `AddRuleView` has a placeholder for
  keyboard rules — needs a small "press a key to record it" capture
  view (listen for one `NSEvent.addLocalMonitorForEvents(.keyDown)`,
  store the keyCode + modifiers).
- **Mouse → key remap**: `MouseManager.apply(action:)` doesn't yet
  handle `.remapToKey` — needs a synthetic `CGEvent` keyDown/keyUp post.
- **Launch at login**: not implemented; use `SMAppService` (macOS 13+)
  when ready.
- **Code signing / notarization**: needed for distribution outside the
  App Store; not set up yet.
- **Menu bar icon toggle for "pause all rules"**: quick win, not done.

## Fixing bugs / extending

Because this is a small, dependency-free SPM package, the fastest
debug loop is:
1. Reproduce the logic in `Tests/InputCustomizerTests` if possible
   (fast, no permissions needed) — see `CustomizationRuleTests.swift`
   for the pattern.
2. For anything touching real system events (taps, gesture monitors),
   run the app from Xcode with breakpoints in the relevant `Manager`'s
   `handle(...)` method — that's where every rule match happens.

## License

MIT — see [LICENSE](LICENSE).
