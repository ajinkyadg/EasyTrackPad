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
Sources/CMultitouchSupport/    C declarations for the private MultitouchSupport.framework
Sources/InputCustomizer/
  App.swift                 Menu bar app entry point, permission gating
  Managers/
    KeyboardManager.swift        CGEventTap-based key interception/remap
    MouseManager.swift           CGEventTap-based mouse button interception
    TrackpadManager.swift        Owns pinch/rotate (NSEvent) + swipe/tap (multitouch)
    MultitouchGestureEngine.swift Raw per-finger touch frames from CMultitouchSupport
    GestureRecognizer.swift      Pure logic: touch frames → swipe/tap gesture events
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

Swipes and taps are finger-count-aware (2/3/4-finger swipes in all four
directions, 2-5-finger taps) via the private, undocumented
`MultitouchSupport.framework` — the same approach BetterTouchTool and
similar tools use, since AppKit's public gesture API has no concept of
finger count and can't detect taps at all. The C declarations live in
`Sources/CMultitouchSupport` (see the file for the struct-layout caveat);
`MultitouchGestureEngine` wraps the raw callback, and `GestureRecognizer`
turns a stream of touch frames into gesture events — the latter is pure
logic with no framework dependency, so it's covered by
`GestureRecognizerTests` using synthetic frames (finger-count gestures
can't be exercised any other way without a real trackpad and a real
finger).

Pinch and rotate stay on AppKit's public `NSEvent` `.magnify`/`.rotate`
monitors — they're inherently two-finger gestures already, so computing
scale/angle from raw touches ourselves wouldn't add anything.

Real touch data is noisy in two ways `GestureRecognizer` specifically
accounts for: fingers don't all land in the same callback frame (landing
staggered by a few ms), so it rebases its movement baseline every time
the finger count changes rather than measuring "travel" across a
count change; and a gesture can transiently report zero touching
fingers for a frame even mid-swipe, bridged over by a short
noise-tolerance grace period rather than treated as lift-off.

**Gesture Sensitivity**: the slider in Preferences → Trackpad scales how
much travel a swipe needs and how much wobble a tap tolerates
(`GestureRecognizer.sensitivity`, 0...1, applied live via
`SettingsStore.gestureSensitivity`). Defaults to the middle, which is
also what `GestureRecognizerTests` assumes.

**Troubleshooting**: flip `GestureRecognizer.debugLoggingEnabled` to
`true` to get an NSLog line for every gesture start/recognize/end,
including *why* a gesture didn't match (finger count, duration,
movement) — useful for tuning thresholds or diagnosing "sometimes
works" reports. Note that `log show`/`log stream` don't reliably surface
this app's own NSLog output when it's launched normally (via Finder/
`open`) even though the code runs — run the binary directly from a
terminal (`dist/InputCustomizer.app/Contents/MacOS/InputCustomizer`) for
NSLog output you can actually see.

**Accepted trade-off:** MultitouchSupport.framework has no official
headers and can change or disappear on any macOS update without notice.
If trackpad rules stop firing after an OS update, check Console.app for
an `NSLog` from `MultitouchGestureEngine` about `MTDeviceCreateDefault`
failing — that's the framework having moved out from under us. Swipe/tap
directions were implemented from the documented touch-state semantics
and verified on this developer's Mac; if a direction feels inverted on
yours, it's a one-line fix in `GestureRecognizer.swipeKind`.

## Known gaps / TODO

- **Code signing / notarization**: `export-app.sh` signs with, in order,
  a Developer ID Application identity, a free "Apple Development"
  identity, or a local self-signed identity it creates once and reuses
  (`InputCustomizer Local Dev`) — any of these keeps Accessibility/Input
  Monitoring grants stable across rebuilds, unlike ad-hoc signing, which
  invalidates them on every single build. None of this is sufficient for
  distributing the `.app` to someone else — that needs a real Developer
  ID identity and notarization, which isn't set up.
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
