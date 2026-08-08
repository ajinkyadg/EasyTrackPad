# InputCustomizer

A simple, hackable macOS app for customizing trackpad gestures, mouse
buttons, and keyboard keys — a lightweight, open-source alternative to
BetterTouchTool / MultitouchTool, built as a native Swift/SwiftUI app.

**Smoogler** is this app's signature gesture, built in as a preset: a
3-finger trackpad swipe that keeps switching browser tabs for as long as
you keep sliding, firing again per increment of travel rather than on a
fixed timer — it feels like physically gliding through your tabs instead
of tapping a key repeatedly. See [Repeat while held](#trackpad-gestures)
below for how it works under the hood.

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
    TouchVisualizerModel.swift   Shared live-touch state for the preview UI (see below)
    ActionRunner.swift      Shared "run this action" execution (shell, launch app, media key)
    ActiveApp.swift          NSWorkspace frontmost-app query, for per-app rule scoping
    ActivityLog.swift        Live activity feed shown in ConsoleView (see below)
    FrontmostAppObserver.swift Notifies SettingsStore on frontmost-app changes, for profile auto-activation
    PermissionsHelper.swift Accessibility permission check/prompt
  Models/
    CustomizationRule.swift Trigger → Action rule model (Codable)
    Profile.swift            Named set of rules; PersistedState/ProfileExportFile shapes
    KeyCodeMap.swift        keyCode/modifiers <-> human-readable shortcut labels
    GesturePresets.swift    Curated one-click rule templates
  Storage/
    SettingsStore.swift     JSON persistence in ~/Library/Application Support (see Profiles below)
  Views/
    SettingsView.swift      Sidebar-navigated rule list (Trackpad / Mouse / Keyboard) + live console + profile switcher
    ManageProfilesView.swift Create/rename/duplicate/delete/export/import profiles
    AppReferenceListEditor.swift Shared app-picker rows, used by RuleFormView and ManageProfilesView
    ConsoleView.swift        Live, color-coded activity feed fed by ActivityLog
    RuleFormView.swift      Form to add, edit, or preset-prefill a rule
    GestureIconView.swift   Icon + finger-count badge for a GestureKind
    TouchVisualizerView.swift Live touch dots + recognized-gesture preview
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
on your own Mac, export and install a local `.app` bundle:

```bash
./Scripts/export-app.sh
```

The script builds the release executable, wraps it in
`dist/InputCustomizer.app`, signs it with a stable identity (see
"Code signing" below), and **installs a copy to `/Applications`** —
quitting any running instance there first — so however you normally
launch the app (Spotlight, Launchpad, double-clicking) always picks up
the build you just made. `dist/` and `/Applications` silently diverging
is exactly the kind of thing that produces a confusing "I changed the
code but the app looks the same" report; the script closes that gap for
you rather than leaving it as a manual step. Set
`INPUTCUSTOMIZER_SKIP_INSTALL=1` to skip the install and only touch
`dist/`.

On first launch, macOS will prompt for **Accessibility** access
(System Settings → Privacy & Security → Accessibility). You may also need
to grant **Input Monitoring** so the keyboard and mouse event taps receive
events. After launch, look for the hand-tap icon in the menu bar →
**Preferences…** to add rules per device. For a keyboard rule or a
"Remap to Key" action, click **Record** and press the key combo you
want. Click an existing rule to edit it in place, or use **Add from
Preset** for a curated starting point (see `GesturePresets.swift`) you
can tweak before saving. Use the menu bar's **Pause All Rules** item (or
the toggle in Preferences) as a kill switch if a rule misbehaves.

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

Swipes and taps are finger-count-aware (2-5-finger swipes in all 8
compass directions — cardinal and diagonal — plus 2-5-finger taps and
double-taps) via the private, undocumented `MultitouchSupport.framework`
— the same approach BetterTouchTool and similar tools use, since
AppKit's public gesture API has no concept of finger count and can't
detect taps at all. The C declarations live in `Sources/CMultitouchSupport`
(see the file for the struct-layout caveat); `MultitouchGestureEngine`
wraps the raw callback, and `GestureRecognizer` turns a stream of touch
frames into gesture events — the latter is pure logic with no framework
dependency, so it's covered by `GestureRecognizerTests` using synthetic
frames (finger-count gestures can't be exercised any other way without a
real trackpad and a real finger).

**Double-tap**: both the single tap and the double-tap fire — tap 1
fires immediately as a normal tap (no added latency to every tap just to
check whether a second one is coming), and if tap 2 follows within 0.35s
at a similar position, it fires the single tap again *and* the
double-tap. If you configure both `.threeFingerTap` and
`.threeFingerDoubleTap` with different actions, expect both to run on
the second tap of a real double-tap — there's no attempt to suppress the
single-tap action after the fact.

**Diagonal swipes**: harder to perform consistently with multiple
fingers than cardinal swipes — this is a real ergonomic property of the
gesture, not just a threshold-tuning problem. If a diagonal direction
feels unreliable, that may be the ceiling for that finger count rather
than a bug.

Pinch and rotate stay on AppKit's public `NSEvent` `.magnify`/`.rotate`
monitors — they're inherently two-finger gestures already, so computing
scale/angle from raw touches ourselves wouldn't add anything.

**Split swipe** (2 fingers down, only one moves): `twoFingerLeftSwipeUp`/
`Down` and `twoFingerRightSwipeUp`/`Down` fire when one finger stays
essentially still (an anchor) while the *other* one swipes up or down —
distinct from `twoFingerSwipeUp`/`Down`, which need both fingers
travelling together. "Left"/"Right" is whichever finger is on that side
by x-position when the two fingers first land, not a specific physical
finger. `GestureRecognizer` tracks each finger's own displacement from
its own touch-down position for this (`splitReferences`), separately
from the shared centroid ordinary swipes use, and checks for this
anchor+mover pattern before falling back to the ordinary centroid-based
swipe check — so two fingers genuinely moving together are unaffected
and still fire the ordinary two-finger swipe.

**Live touch preview**: the trackpad gesture picker in the rule form
shows live touch dots and the recognized gesture name as you perform it
on the trackpad, with a "Use This Gesture" button to select it directly
— useful for seeing exactly what a diagonal or 5-finger gesture looks
like before committing to it. It's fed by `TouchVisualizerModel`, which
`TrackpadManager` publishes into (main thread) only while the preview is
actually visible (`isActive`) — the same raw touch frames are always
flowing at up to ~120Hz on a background thread regardless, but hopping
*every* one to main whether or not anyone's watching was the exact
mistake that made the app feel laggy earlier in development, so this
stays strictly opt-in. One consequence worth knowing: the preview
observes the app's one real, always-on gesture engine, not a sandboxed
copy — performing a gesture while previewing also triggers any rule
you've already configured for it. Toggle "Pause all rules" first if you
don't want that while testing.

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

**Repeat while held**: a per-rule toggle (only shown for swipe triggers)
that keeps re-applying the rule's action for as long as the swiping
fingers stay down, instead of firing once — useful for e.g.
"swipe-and-hold to keep switching tabs". Two ways to repeat, both
per-rule:
- **Timer-based** (default): fires on a fixed cadence, tuned by two
  Preferences → Trackpad sliders — **Repeat While Held Speed**
  (`SettingsStore.repeatWhileHeldInterval`, seconds between repeats) and
  **Repeat Delay** (`repeatWhileHeldDelay`, how long to wait after the
  first fire before repeating actually begins — mirrors macOS's own
  "Delay Until Repeat" keyboard setting).
- **Distance-based** ("Repeat by distance instead of time", shown once
  "Repeat while held" is on, ordinary swipes only — not the split-swipe
  gestures above): fires again each time the swiping fingers travel a
  further increment, like a scroll wheel, tuned by the **Repeat by
  Distance Sensitivity** slider. `GestureRecognizer` tracks this via a
  baseline that advances by exactly one increment per tick (not jumping
  to the current position), so a fast/noisy frame covering several
  increments at once defers the extra ticks to the next frame or two
  instead of dropping or firing them all at once unbounded.

**Smoogler** is the built-in showcase for distance-based repeat: two
presets (`GesturePresets.all`, "Smoogler: Next Tab" / "Smoogler:
Previous Tab", featured first in the "Add from Preset" menu), each a
3-finger swipe remapped to Cmd+Shift+]/[ (the cross-browser next/
previous-tab shortcut) with `repeatsWhileHeld` and `repeatsByDistance`
both on out of the box — no configuration needed beyond adding the
preset.

Both mechanisms share the same safety nets in `TrackpadManager`: a fast
(0.1s) poll of whether any finger is still down, as a backstop in case
the primary lift-off signal (`GestureRecognizer.onTouchEnded`) is ever
missed, and a hard 20-second ceiling on any single repeat session
regardless of touch state, for the (harder to fully rule out without
varied hardware) case where multitouch frame delivery itself stalls.

**Troubleshooting — in-app console**: Preferences has a live "Console"
pane (`ConsoleView.swift`, fed by `ActivityLog`) showing exactly what the
app is doing in real time — every recognized gesture/key/button that
matched a rule (`Detected`/`Fired`, blue/orange), every action actually
executing (`Executing`, green), and repeat-while-held lifecycle events
(`Info`, gray). This exists specifically so you don't need Terminal for
day-to-day diagnosis anymore — check it first. It only ever logs on an
actual match, never on every raw keystroke/click (see
`KeyboardManager.handle`'s comment for why that matters — logging every
key-down system-wide would both flood the console and leak unrelated
keystrokes).

For the small residue of diagnostics that don't route through
`ActivityLog` — `GestureRecognizer.debugLoggingEnabled` (verbose per-frame
NSLog, useful for tuning thresholds) and startup/permission logging —
`log show`/`log stream` don't reliably surface this app's own NSLog
output when it's launched normally (via Finder/`open`) even though the
code runs, so you'd still need to run the binary directly from a terminal
(`dist/InputCustomizer.app/Contents/MacOS/InputCustomizer`) for those
specifically.

**"Repeat while held" not stopping**: the in-app console shows
`repeat-while-held started for N action(s)` / `repeat-by-distance armed
for N action(s)` and `repeat-while-held stopped (...)` directly (also
still mirrored to NSLog). The stop reason tells you which path fired:
`onTouchEnded` is the normal case (fingers actually lifted); `backstop
(onTouchEnded never
arrived)` means the fast touch-state poll had to self-stop it because the
lift-off notification was missed or delayed — if you see that reason
regularly, it's worth reporting, since it means the primary stop signal
isn't reliable on that hardware; `max duration reached (20s)` means even
the poll never saw fingers lift, which points at frame delivery itself
having stalled. If you see `started`/`armed` with no `stopped` line ever,
something is more seriously wrong and worth filing as a bug directly.

**Accepted trade-off:** MultitouchSupport.framework has no official
headers and can change or disappear on any macOS update without notice.
Swipe/tap directions were implemented from the documented touch-state
semantics and verified on this developer's Mac; if a direction feels
inverted on yours, it's a one-line fix in `GestureRecognizer.swipeKind`.

**Fallback if the framework breaks**: `MultitouchGestureEngine.start()`
returns whether a device was actually found, rather than assuming
success. `TrackpadManager` publishes that into
`TouchVisualizerModel.isMultitouchAvailable`, and Preferences → Trackpad
shows an orange warning banner when it's `false`, instead of finger-count
gestures just silently never firing. Nothing else is affected: pinch and
rotate use the public `NSEvent` `.magnify`/`.rotate` monitors, and
keyboard/mouse remapping use the public `CGEventTap` API — none of that
depends on `MultitouchGestureEngine` at all, so it keeps working even if
the private framework disappears entirely. If you see the banner, check
Console.app for the `MTDeviceCreateDefault` failure `NSLog` from
`MultitouchGestureEngine` to confirm, then file/track it as an OS-version
compatibility issue.

## Profiles

Rules live inside **profiles** — named, self-contained sets of rules
(`Profile` in `Models/Profile.swift`) — rather than one flat list.
`SettingsStore` tracks two different notions of "current profile,"
deliberately kept separate:

- **`selectedProfileID`** — your manual, durable choice, persisted, and
  what the rule list (`RuleListView`) and the profile switcher (top bar
  of Preferences) both edit/display.
- **`activeProfileID`** — the profile actually consulted by
  `rules(for:)` at match time. Equal to `selectedProfileID` unless some
  profile's `autoActivateApps` claims the current frontmost app, in
  which case that profile *temporarily* overrides the manual selection
  and reverts the instant you switch away. Never persisted, never
  overwrites your manual choice — see `Profile.resolveActiveProfile`
  (pure, unit-tested) for the exact precedence.

An app can only ever auto-activate **one** profile —
`SettingsStore.assignAutoActivateApp(_:toProfile:)` strips the claim
from any other profile first, so this is enforced by construction rather
than left as an undefined conflict. `FrontmostAppObserver` drives this
off `NSWorkspace.didActivateApplicationNotification` (not polling), so
resolving the active profile only happens on the rare event of switching
apps, not per keystroke/gesture.

**Quick-switching**: the menu bar item has a "Switch Profile" submenu
(checkmark on the current manual selection) for changing profiles
without opening Preferences. The Preferences top bar's profile switcher
shows the *effective* active profile, and flags it with a bolt icon
and "(auto)" when it currently diverges from your manual selection —
so an app-triggered override is never a silent surprise about why a
different set of gestures just started firing.

**Create/rename/duplicate/delete/export/import** all live in "Manage
Profiles…" (from the profile switcher menu, `ManageProfilesView.swift`).
Export/import is plain JSON (`ProfileExportFile`, matching this
project's stated "hackable, hand-editable" persistence philosophy — see
`SettingsStore.swift`'s own doc comment) — a profile's rules and
`autoActivateApps` both travel with it, but importing always mints fresh
ids for the profile and every rule (never trusts ids from an external
file, even a self-exported one) and auto-disambiguates a colliding name
(`"Work"` → `"Work 2"`).

**Migration**: a pre-profiles `rules.json` (a bare `[CustomizationRule]`
array — what every installation before this feature has) is
automatically wrapped into a single `"Default"` profile on first launch,
with the original file backed up to `rules.json.pre-profiles.bak` first.
This only ever runs once per file — `SettingsStore.load()`'s decode
cascade tries the current `PersistedState` shape first, and migrating
immediately re-saves in that shape, so the legacy-array branch can never
match again for the same file (see `testMigrationIsIdempotentOnASecondLaunch`).

## Per-app rule scoping

Any rule, on any device (trackpad/mouse/keyboard), can be scoped to only
fire while specific apps are frontmost — e.g. a browser-only tab-switch
gesture that doesn't also fire in Finder. In the rule form, "Add App…"
opens a file picker (`/Applications` by default); the picked `.app`'s
bundle identifier (`Bundle(url:)?.bundleIdentifier`) is what's actually
matched against, with the display name cached alongside it just for the
UI (`AppReference` in `CustomizationRule.swift`). Empty (the default) —
applies everywhere, so existing saved rules are unaffected.

The actual check, `CustomizationRule.applies(whileFrontmostAppIs:)`, is
deliberately pure — it takes the current frontmost bundle identifier as
a parameter rather than querying `NSWorkspace` itself, so it's directly
unit-testable without AppKit. The real query lives in `ActiveApp.swift`
and is called once per event in each of the three managers
(`TrackpadManager.fire`, `KeyboardManager.handle`, `MouseManager.handle`)
right alongside their existing trigger-match filtering. Fails open if the
frontmost app can't be determined (`nil`), so a transient `NSWorkspace`
hiccup can't silently disable every app-scoped rule.

**This vs. Profiles**: the two mechanisms answer different questions and
are both kept deliberately, not merged. This is a fine-grained exception
on *one rule* ("this one binding only fires in Chrome"). Profiles (above)
are a coarse, whole-workflow swap ("Work" vs. "Gaming" — an entirely
different set of bindings). A rule's `restrictedToApps` is only ever
consulted for rules belonging to whichever profile is currently *active*
— profile selection decides which rules are even in play; per-rule
scoping further narrows within that active set. The rule form's own
footer text points this out at exactly the point a user would otherwise
wonder which one to reach for.

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
  picker in `RuleFormView` (always `modifiers: 0`) — the model and
  matching logic already support them, just no UI control for it.
- **Presets vs. OS-level trackpad gestures**: a preset like "4-Finger
  Swipe Up → Mission Control" mimics a gesture macOS may already bind at
  the system level (System Settings → Trackpad). Since this app's raw
  multitouch tap runs independently of whatever AppKit/WindowServer does
  with the same physical touch, using both at once can double-fire (e.g.
  Mission Control opening then immediately closing). If that happens,
  disable the equivalent gesture in System Settings → Trackpad.
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
