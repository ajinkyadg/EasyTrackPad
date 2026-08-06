import Cocoa

/// Executes the non-remap actions a rule can trigger. Centralized here so
/// keyboard/mouse/trackpad managers stay focused on "what triggered" and
/// don't duplicate "how to run a shell command" logic.
enum ActionRunner {
    static func run(command: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/zsh")
        task.arguments = ["-c", command]
        try? task.run()
    }

    static func launch(bundleIdentifier: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            NSLog("InputCustomizer: couldn't find app with bundle id \(bundleIdentifier)")
            return
        }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    static func send(mediaKey: Action.MediaKey) {
        // Media keys require NX_KEYTYPE constants + posting an NSEvent with
        // subtype 8; kept as a stub with the mapping documented so it's
        // easy to fill in without hunting for the constants again.
        let keyMap: [Action.MediaKey: Int32] = [
            .playPause: 16,   // NX_KEYTYPE_PLAY
            .nextTrack: 17,   // NX_KEYTYPE_NEXT
            .previousTrack: 18, // NX_KEYTYPE_PREVIOUS
            .volumeUp: 0,     // NX_KEYTYPE_SOUND_UP
            .volumeDown: 1,   // NX_KEYTYPE_SOUND_DOWN
            .mute: 7          // NX_KEYTYPE_MUTE
        ]
        guard let code = keyMap[mediaKey] else { return }
        postMediaKeyEvent(keyCode: code)
    }

    private static func postMediaKeyEvent(keyCode: Int32) {
        for down in [true, false] {
            let flags: NSEvent.ModifierFlags = down ? .init(rawValue: 0xa00) : .init(rawValue: 0xb00)
            let data1 = (Int(keyCode) << 16) | (down ? 0xa00 : 0xb00)
            if let event = NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: flags,
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: 0,
                context: nil,
                subtype: 8,
                data1: data1,
                data2: -1
            ) {
                event.cgEvent?.post(tap: .cghidEventTap)
            }
        }
    }

    static func showMissionControl() {
        run(command: "open -a 'Mission Control'")
    }
}
