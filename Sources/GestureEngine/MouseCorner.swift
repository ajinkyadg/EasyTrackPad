import CoreGraphics

/// One of the four corners of the touch surface a mouse click can be
/// gated to (see `Trigger.mouseCornerClick` in `InputModels`). A Magic
/// Mouse's shell has no pressure sensor, so this stands in for Force
/// Touch: "was a finger resting near this corner at the moment of an
/// ordinary click" — read from the same normalized multitouch position
/// `GestureRecognizer` already tracks for swipe/tap gestures, not a new
/// detection mechanism. Lives alongside `GestureRecognizer` (rather than
/// in `InputModels`) since resolving a position to a corner is the same
/// kind of pure signal-processing `GestureKind` matching is, just for
/// mouse clicks instead of swipes.
public enum MouseCorner: String, Codable, CaseIterable, Identifiable {
    case topLeft, topRight, bottomLeft, bottomRight
    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .topLeft: return "Top-Left Corner"
        case .topRight: return "Top-Right Corner"
        case .bottomLeft: return "Bottom-Left Corner"
        case .bottomRight: return "Bottom-Right Corner"
        }
    }

    /// SF Symbol pointing toward this corner — same "arrow.*" family
    /// `GestureKind.iconSymbolName` already uses for swipe directions, so
    /// a Corner Click option reads visually consistent with its sibling
    /// gesture options in the same picker/rule list rather than showing
    /// no icon at all.
    public var iconSymbolName: String {
        switch self {
        case .topLeft: return "arrow.up.left"
        case .topRight: return "arrow.up.right"
        case .bottomLeft: return "arrow.down.left"
        case .bottomRight: return "arrow.down.right"
        }
    }

    /// How much of the surface, measured in from each edge, counts as
    /// "the corner" — a fraction of the 0...1 normalized surface
    /// MultitouchSupport reports (x: left -> right, y: bottom -> top,
    /// same convention `TouchVisualizerView` uses). 0.3 is deliberately
    /// generous: a Magic Mouse's touch shell is small and curved, so a
    /// tight zone would make this hard to land reliably.
    private static let edgeFraction: CGFloat = 0.3

    /// `nil` if `position` isn't near any corner — most of the surface,
    /// by design, so an ordinary click in the middle never gets
    /// mis-gated into a corner rule.
    public static func resolve(from position: CGPoint) -> MouseCorner? {
        let left = position.x < edgeFraction
        let right = position.x > 1 - edgeFraction
        let top = position.y > 1 - edgeFraction
        let bottom = position.y < edgeFraction
        switch (left, right, top, bottom) {
        case (true, _, true, _): return .topLeft
        case (_, true, true, _): return .topRight
        case (true, _, _, true): return .bottomLeft
        case (_, true, _, true): return .bottomRight
        default: return nil
        }
    }
}
