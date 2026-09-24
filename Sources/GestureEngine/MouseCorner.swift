import CoreGraphics

/// One of the four corners of the trackpad a click can be gated to (see
/// `Trigger.mouseCornerClick` in `InputModels`). Only the top two are
/// allowed today — deciding whether a click counts is `resolveCornerClick`
/// in CornerClick.swift. All four stay in the enum so rules saved by older
/// versions still decode.
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
}
