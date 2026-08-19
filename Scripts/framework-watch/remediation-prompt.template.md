You are diagnosing and, if possible, fixing a break in InputCustomizer (a
macOS trackpad/mouse/keyboard customization app) caused by a change to
Apple's private `MultitouchSupport.framework` or to how macOS exposes
multitouch devices in the IORegistry, detected by an automated watcher.

You are running in an **isolated git worktree** at the current directory,
on a dedicated branch (`__BRANCH__`) created from `main` — this is NOT the
user's main checkout. You have full tool access. Your job:

1. Read the diagnostic report below. It shows what changed since the last
   known-good baseline.
2. Investigate: the app's whole dependency on this framework lives in
   `Sources/CMultitouchSupport/shim.h` (the private C declarations) and
   `Sources/GestureEngine/MultitouchGestureEngine.swift` (the Swift
   wrapper, including `findService`/`start(preferring:)`, which target a
   specific IOKit `AppleMultitouchDevice` service via
   `MTDeviceCreateFromService`). Use the same reverse-engineering
   technique the report's symbol dump came from if you need to look
   deeper — `lldb --batch -o "target create <helper-that-dlopens-the-
   framework>" -o "run" -o "target modules dump symtab
   MultitouchSupport" -o "quit"` (see `Scripts/framework-watch/lib.sh`'s
   `fw_dump_multitouch_symbols` for the exact pattern), and `ioreg -c
   AppleMultitouchDevice -l -w0` for the IORegistry shape.
3. If you can identify and fix the break (e.g. a renamed symbol, a moved
   property key, a changed function signature) — do so. Update
   `Sources/CMultitouchSupport/shim.h` and/or
   `Sources/GestureEngine/MultitouchGestureEngine.swift` as needed.
4. Run `swift build && swift test` and confirm both pass. Note that some
   things here are only verifiable on real hardware (actual multitouch
   frame delivery) — you cannot test that yourself; say so plainly in
   your summary rather than claiming full verification.
5. **Commit your changes to this branch with a clear message. Do NOT
   push. Do NOT open a PR. Do NOT touch `main`. Do NOT run anything
   outside this worktree directory.** The user reviews and merges this
   manually.
6. If you cannot identify a fix, or the break requires hardware
   verification you can't do, still commit whatever diagnostic notes/
   partial investigation are useful, and clearly state in your final
   summary that this needs human follow-up and why.

Keep your final summary under 300 words — it gets written to a log file
the user reads later, not a live conversation.

---

## Diagnostic report

__REPORT__
