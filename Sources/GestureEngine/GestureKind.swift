import Foundation

/// The vocabulary of trackpad/Magic-Mouse gestures `GestureRecognizer` can
/// produce. Lives in `GestureEngine` (not `InputModels`, where the rest of
/// the rule-configuration types live) because the recognizer is the one
/// authority that actually constructs these values (via `rawValue`) — the
/// higher-level `Trigger` type re-exposes this as `Trigger.GestureKind`
/// via a typealias, so existing call sites don't need to change.
public enum GestureKind: String, Codable, CaseIterable {
    case twoFingerSwipeLeft, twoFingerSwipeRight, twoFingerSwipeUp, twoFingerSwipeDown
    case twoFingerSwipeUpLeft, twoFingerSwipeUpRight, twoFingerSwipeDownLeft, twoFingerSwipeDownRight
    case threeFingerSwipeLeft, threeFingerSwipeRight, threeFingerSwipeUp, threeFingerSwipeDown
    case threeFingerSwipeUpLeft, threeFingerSwipeUpRight, threeFingerSwipeDownLeft, threeFingerSwipeDownRight
    case fourFingerSwipeLeft, fourFingerSwipeRight, fourFingerSwipeUp, fourFingerSwipeDown
    case fourFingerSwipeUpLeft, fourFingerSwipeUpRight, fourFingerSwipeDownLeft, fourFingerSwipeDownRight
    case fiveFingerSwipeLeft, fiveFingerSwipeRight, fiveFingerSwipeUp, fiveFingerSwipeDown
    case fiveFingerSwipeUpLeft, fiveFingerSwipeUpRight, fiveFingerSwipeDownLeft, fiveFingerSwipeDownRight
    case twoFingerTap, threeFingerTap, fourFingerTap, fiveFingerTap
    case twoFingerDoubleTap, threeFingerDoubleTap, fourFingerDoubleTap, fiveFingerDoubleTap
    case pinchIn, pinchOut
    case rotateClockwise, rotateCounterClockwise
    /// Two fingers down, only one of them actually swipes up/down
    /// while the other stays put as an anchor — distinct from
    /// `twoFingerSwipeUp`/`Down`, where both fingers travel together.
    /// "Left"/"Right" is whichever finger is on that side (by x
    /// position) at touch-down, not a specific physical finger.
    case twoFingerLeftSwipeUp, twoFingerLeftSwipeDown
    case twoFingerRightSwipeUp, twoFingerRightSwipeDown
    /// Two fingers down, one stays put as an anchor while the other
    /// lifts and taps again — the tap counterpart to
    /// `twoFingerLeftSwipeUp`/`Down` above. "Left"/"Right" is
    /// whichever finger is on that side at touch-down, same
    /// convention as the split-swipe cases.
    case twoFingerLeftTap, twoFingerRightTap
    /// Not a discrete gesture like the rest of this enum — fires *during*
    /// an ordinary 2-finger scroll (which `GestureRecognizer` otherwise
    /// leaves entirely to macOS's own native scroll handling) when the
    /// fingers are moving quickly and have reached near the bottom edge
    /// of the surface, i.e. "trying to keep scrolling down but running
    /// out of physical trackpad to do it on." Meant to be bound to a
    /// "jump to end" action (e.g. Cmd+Down) so a fast scroll can carry
    /// through past the trackpad's physical edge instead of needing a
    /// lift-and-reposition to keep going.
    case twoFingerFastScrollToBottomEdge

    /// camelCase raw value split on uppercase boundaries, e.g.
    /// "threeFingerSwipeUpLeft" -> ["three","Finger","Swipe","Up","Left"].
    private var rawValueWords: [String] {
        var words: [String] = []
        var current = ""
        for char in rawValue {
            if char.isUppercase, !current.isEmpty {
                words.append(current)
                current = String(char)
            } else {
                current.append(char)
            }
        }
        if !current.isEmpty { words.append(current) }
        return words
    }

    private static let fingerCountNumbers: [String: Int] = ["two": 2, "three": 3, "four": 4, "five": 5]
    private static let directionDegrees: [String: Double] = [
        "Right": 0, "UpRight": 45, "Up": 90, "UpLeft": 135,
        "Left": 180, "DownLeft": 225, "Down": 270, "DownRight": 315
    ]

    /// Coarse gesture family — what `GestureIconView` needs to decide
    /// *how* to draw the icon (dots + arrow vs. dots only vs. a pinch/
    /// rotate symbol), independent of finger count or direction.
    public enum Category {
        case swipe, splitSwipe, splitTap, tap, doubleTap, pinchIn, pinchOut, rotateClockwise, rotateCounterClockwise, fastScrollToEdge
    }

    private static let splitSwipeCases: Set<GestureKind> = [
        .twoFingerLeftSwipeUp, .twoFingerLeftSwipeDown, .twoFingerRightSwipeUp, .twoFingerRightSwipeDown
    ]
    private static let splitTapCases: Set<GestureKind> = [.twoFingerLeftTap, .twoFingerRightTap]

    public var category: Category {
        switch self {
        case .pinchIn: return .pinchIn
        case .pinchOut: return .pinchOut
        case .rotateClockwise: return .rotateClockwise
        case .rotateCounterClockwise: return .rotateCounterClockwise
        case .twoFingerFastScrollToBottomEdge: return .fastScrollToEdge
        default:
            if Self.splitSwipeCases.contains(self) { return .splitSwipe }
            if Self.splitTapCases.contains(self) { return .splitTap }
            if isDoubleTap { return .doubleTap }
            let words = rawValueWords
            if words.count >= 3, words[2] == "Tap" { return .tap }
            return .swipe
        }
    }

    /// For `.splitSwipe`/`.splitTap` kinds only: which finger (by
    /// left/right position at touch-down) is the "active" one — the
    /// one that swipes, or the one that lifts and taps again — while
    /// the other stays down as an anchor. `nil` for every other
    /// category.
    public var splitActiveFingerIsLeft: Bool? {
        switch self {
        case .twoFingerLeftSwipeUp, .twoFingerLeftSwipeDown, .twoFingerLeftTap: return true
        case .twoFingerRightSwipeUp, .twoFingerRightSwipeDown, .twoFingerRightTap: return false
        default: return nil
        }
    }

    /// Direction of travel in degrees (0 = right, 90 = up, going
    /// counterclockwise) — matches `GestureRecognizer`'s `atan2(dy,
    /// dx)` convention exactly, so the drawn arrow points the same way
    /// the recognizer actually measures it. `nil` for non-swipe kinds.
    public var swipeAngleDegrees: Double? {
        switch self {
        case .twoFingerLeftSwipeUp, .twoFingerRightSwipeUp: return 90
        case .twoFingerLeftSwipeDown, .twoFingerRightSwipeDown: return 270
        case .twoFingerFastScrollToBottomEdge: return 270 // down, toward the edge it fires near
        default: break
        }
        guard category == .swipe else { return nil }
        let words = rawValueWords
        guard words.count >= 4 else { return nil }
        return Self.directionDegrees[words[3...].joined()]
    }

    /// 2...5 for swipe/tap/double-tap cases; nil for pinch/rotate, which
    /// are implicitly two-finger and don't need a UI badge for it.
    public var fingerCount: Int? {
        guard let first = rawValueWords.first else { return nil }
        return Self.fingerCountNumbers[first]
    }

    public var isDoubleTap: Bool {
        let words = rawValueWords
        return words.count >= 4 && words[2] == "Double" && words[3] == "Tap"
    }

    /// Human-readable label for pickers/rule lists, e.g. "3-Finger Swipe
    /// Up-Left" or "4-Finger Double Tap". Detects the gesture *kind*
    /// (Swipe/Tap/DoubleTap) explicitly rather than positionally —
    /// DoubleTap splits into two camelCase words ("Double","Tap"), not
    /// one, so a purely positional scheme misparses it.
    public var displayName: String {
        switch self {
        case .pinchIn: return "Pinch In"
        case .pinchOut: return "Pinch Out"
        case .rotateClockwise: return "Rotate Clockwise"
        case .rotateCounterClockwise: return "Rotate Counter-Clockwise"
        case .twoFingerLeftSwipeUp: return "2-Finger, Left Swipes Up"
        case .twoFingerLeftSwipeDown: return "2-Finger, Left Swipes Down"
        case .twoFingerRightSwipeUp: return "2-Finger, Right Swipes Up"
        case .twoFingerRightSwipeDown: return "2-Finger, Right Swipes Down"
        case .twoFingerLeftTap: return "2-Finger, Left Taps"
        case .twoFingerRightTap: return "2-Finger, Right Taps"
        case .twoFingerFastScrollToBottomEdge: return "Fast Scroll to Bottom Edge"
        default: break
        }
        let words = rawValueWords
        guard let count = fingerCount else { return rawValue }
        if isDoubleTap { return "\(count)-Finger Double Tap" }
        if words.count >= 3, words[2] == "Tap" { return "\(count)-Finger Tap" }
        if words.count >= 4, words[2] == "Swipe" {
            return "\(count)-Finger Swipe \(words[3...].joined(separator: "-"))"
        }
        return rawValue
    }

    /// SF Symbol name for `GestureIconView`. Swipe directions map to
    /// the matching `arrow.*` symbol (e.g. "UpLeft" -> "arrow.up.left");
    /// tap/double-tap share `hand.tap.fill` (already used for the
    /// paused menu-bar icon in App.swift, so it's proven to render).
    public var iconSymbolName: String {
        switch self {
        case .pinchIn: return "minus.magnifyingglass"
        case .pinchOut: return "plus.magnifyingglass"
        case .rotateClockwise: return "arrow.clockwise"
        case .rotateCounterClockwise: return "arrow.counterclockwise"
        case .twoFingerLeftSwipeUp, .twoFingerRightSwipeUp: return "arrow.up"
        case .twoFingerLeftSwipeDown, .twoFingerRightSwipeDown: return "arrow.down"
        case .twoFingerLeftTap, .twoFingerRightTap: return "hand.tap.fill"
        case .twoFingerFastScrollToBottomEdge: return "arrow.down.to.line"
        default: break
        }
        let words = rawValueWords
        if words.count >= 3, words[2] == "Tap" || isDoubleTap { return "hand.tap.fill" }
        if words.count >= 4, words[2] == "Swipe" {
            let direction = words[3...].joined(separator: ".").lowercased()
            return "arrow.\(direction)"
        }
        return "questionmark"
    }
}
