# InputCustomizer

A simple, hackable macOS app for customizing trackpad gestures, mouse
buttons, and keyboard keys — a lightweight, open-source alternative to
BetterTouchTool / MultitouchTool, built as a native Swift/SwiftUI app.

## Status

Usable for personal, day-to-day use via `Scripts/export-app.sh`. Core
engines (keyboard remap, mouse button remap, trackpad gestures) work
end to end, rules can be created for all three devices — including
capturing a keyboard combo and remapping any trigger to a synthetic
keypress — and there's a menu-bar "Pause All Rules" kill switch and a
"Launch at Login" toggle. What's still missing is packaging for
distribution off your own machine; see [Known gaps](#known-gaps--todo).

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
    KeyCodeMap.swift        keyCode/modifiers <-> human-readable shortcut labels
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
**Preferences…** to add rules per device. For a keyboard rule or a
"Remap to Key" action, click **Record** and press the key combo you
want. Use the menu bar's **Pause All Rules** item (or the toggle in
Preferences) as a kill switch if a rule misbehaves.

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

- **Code signing / notarization**: `export-app.sh` will sign with a
  Developer ID Application identity if one is installed, otherwise
  it falls back to ad-hoc signing (fine for running on your own Mac,
  not for distributing the `.app` to someone else). Notarization for
  distribution outside your own machine isn't set up.
- **Mouse rule modifiers**: mouse button rules don't yet have a modifier
  picker in `AddRuleView` (always `modifiers: 0`) — the model and
  matching logic already support them, just no UI control for it.
- **Launch at Login reliability**: `SMAppService` registration is most
  reliable once the exported `.app` lives in `/Applications` — running
  it from `dist/` or Xcode's DerivedData may not survive a reboot
  consistently.

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
