import SwiftUI
import AppKit
import UniformTypeIdentifiers
import InputModels

// Small building blocks shared across the settings window, the rule
// form, and the profiles sheet — kept in one place so banners, app rows,
// and rule summaries look and read identically everywhere they appear.

// MARK: - Notice banner

/// A full-width, inline notice strip (permission missing, rules paused,
/// device not detected). One component for all of them so every notice
/// in the app shares the same icon/title/message/button rhythm instead
/// of each call site hand-styling its own colored `Label`.
struct NoticeBanner<Actions: View>: View {
    enum Style {
        case warning, info

        var tint: Color {
            switch self {
            case .warning: return .orange
            case .info: return .accentColor
            }
        }
    }

    let style: Style
    let systemImage: String
    let title: String
    let message: String
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(style.tint)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            actions()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(style.tint.opacity(0.10))
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .contain)
    }
}

extension NoticeBanner where Actions == EmptyView {
    init(style: Style, systemImage: String, title: String, message: String) {
        self.init(style: style, systemImage: systemImage, title: title, message: message) { EmptyView() }
    }
}

// MARK: - App icons and picking

/// Resolves an installed app's icon and display name from its bundle
/// identifier for display only — nothing here is persisted, so a moved or
/// deleted app just falls back to a generic icon and the raw identifier.
enum InstalledApp {
    static func url(for bundleIdentifier: String) -> URL? {
        guard !bundleIdentifier.isEmpty else { return nil }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
    }

    static func icon(for bundleIdentifier: String) -> NSImage {
        if let url = url(for: bundleIdentifier) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSWorkspace.shared.icon(for: .application)
    }

    static func displayName(for bundleIdentifier: String) -> String {
        guard let url = url(for: bundleIdentifier) else { return bundleIdentifier }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    /// Runs the standard "choose an application" open panel rooted at
    /// /Applications. Returns nil on cancel.
    static func choose() -> AppReference? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        let bundleIdentifier = Bundle(url: url)?.bundleIdentifier ?? url.deletingPathExtension().lastPathComponent
        let displayName = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        return AppReference(bundleIdentifier: bundleIdentifier, displayName: displayName)
    }
}

/// A 16-pt app icon for list rows, decorative (the adjacent name is what
/// VoiceOver reads).
struct AppIconView: View {
    let bundleIdentifier: String
    var size: CGFloat = 16

    var body: some View {
        Image(nsImage: InstalledApp.icon(for: bundleIdentifier))
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

// MARK: - Human-readable rule summaries

extension Action.MediaKey {
    /// Sentence-case label for pickers and rule rows — the raw value
    /// (`playPause`) is a persisted identifier, not UI text.
    var displayName: String {
        switch self {
        case .playPause: return "Play/pause"
        case .nextTrack: return "Next track"
        case .previousTrack: return "Previous track"
        case .volumeUp: return "Volume up"
        case .volumeDown: return "Volume down"
        case .mute: return "Mute"
        }
    }
}

enum RuleSummary {
    static func mouseButtonName(_ number: Int) -> String {
        switch number {
        case 0: return "Primary click"
        case 1: return "Secondary click"
        case 2: return "Middle click"
        default: return "Button \(number)"
        }
    }

    static func trigger(_ trigger: Trigger) -> String {
        switch trigger {
        case let .keyCombo(keyCode, modifiers): return KeyCodeMap.describe(keyCode: keyCode, modifiers: modifiers)
        case let .mouseButton(number, _): return mouseButtonName(number)
        case let .mouseCornerClick(corner, number, _): return "\(mouseButtonName(number)), \(corner.displayName.lowercased())"
        case let .trackpadGesture(kind): return kind.displayName
        }
    }

    static func action(_ action: Action) -> String {
        switch action {
        case let .remapToKey(keyCode, modifiers): return KeyCodeMap.describe(keyCode: keyCode, modifiers: modifiers)
        case .runShellCommand: return "Run shell command"
        case let .launchApp(bundleIdentifier): return "Open \(InstalledApp.displayName(for: bundleIdentifier))"
        case let .sendMediaKey(key): return key.displayName
        case .missionControl: return "Mission Control"
        case .none: return "No action"
        }
    }

    /// "3-Finger Swipe Right → ⌃⇥" — the one-line answer to "what does
    /// this rule do", shown under every rule's name.
    static func line(for rule: CustomizationRule) -> String {
        "\(trigger(rule.trigger)) → \(action(rule.action))"
    }

    /// What an unnamed rule is called — "Press ⌘C", "Mission Control",
    /// "Open Safari" — so no row ever reads "Untitled rule".
    static func suggestedName(for action: Action) -> String {
        if case .remapToKey = action { return "Press \(self.action(action))" }
        return self.action(action)
    }

    /// The name shown in the rule list. Older rules saved the literal
    /// placeholder "Untitled rule"; preset-created ones carry a trailing
    /// "(3-Finger Double Tap)" that just repeats the trigger line under it.
    static func displayName(for rule: CustomizationRule) -> String {
        let trimmed = rule.name.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed == legacyPlaceholderName {
            return suggestedName(for: rule.action)
        }
        return RulePreset.strippingGestureNote(from: trimmed)
    }

    static let legacyPlaceholderName = "Untitled rule"
}

// MARK: - Device ordering

extension InputDevice {
    /// Sidebar order: the touch devices the app is built around first.
    static let sidebarOrder: [InputDevice] = [.trackpad, .magicMouse, .mouse, .keyboard]

    /// Outline SF Symbol for the sidebar and empty states — the model's
    /// `iconSymbolName` mixes filled and outline styles.
    var outlineSymbolName: String {
        switch self {
        case .keyboard: return "keyboard"
        case .mouse: return "computermouse"
        case .magicMouse: return "magicmouse"
        case .trackpad: return Self.trackpadSymbolName
        }
    }

    /// `trackpad` only exists from SF Symbols 5 (macOS 14); older systems
    /// fall back to the busier hand-on-rectangle glyph.
    private static let trackpadSymbolName: String =
        NSImage(systemSymbolName: "trackpad", accessibilityDescription: nil) != nil ? "trackpad" : "rectangle.and.hand.point.up.left"
}

// MARK: - Sliders

enum SliderBinding {
    /// For "repeat speed"-style sliders: left-to-right reading as "slower
    /// to faster" is natural, but a *smaller* interval is what's actually
    /// faster — so the slider shows `max + min - value` rather than the
    /// interval directly.
    static func inverted(_ value: Binding<Double>, in range: ClosedRange<Double>) -> Binding<Double> {
        Binding(
            get: { range.upperBound + range.lowerBound - value.wrappedValue },
            set: { value.wrappedValue = range.upperBound + range.lowerBound - $0 }
        )
    }
}

/// A form row slider with a leading title and min/max captions — the one
/// slider layout used by both the global Gesture Tuning popover and the
/// per-rule overrides in `RuleFormView`.
struct LabeledSlider: View {
    let title: String
    let value: Binding<Double>
    var range: ClosedRange<Double> = 0...1
    var minimumLabel = "Less"
    var maximumLabel = "More"

    var body: some View {
        Slider(value: value, in: range) {
            Text(title)
        } minimumValueLabel: {
            Text(minimumLabel).font(.caption).foregroundStyle(.secondary)
        } maximumValueLabel: {
            Text(maximumLabel).font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityLabel(title)
    }
}
