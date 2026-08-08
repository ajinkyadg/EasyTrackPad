import SwiftUI

/// Small monochrome "trackpad" glyph — a rounded rectangle frame holding
/// a row of dots (one per finger), where the finger that determines
/// direction is drawn as a fading motion trail (a gradient line, dark
/// near the other fingers and fading out toward a solid dot at the
/// landing position) instead of a plain dot, and a finger that's
/// deliberately anchored (see `.splitSwipe`) is drawn as a hollow
/// (unfilled) dot rather than solid. Styled after the icon language
/// common to trackpad-utility rule lists — flat, minimal, one color that
/// adapts with the system appearance — rather than SF Symbols, which
/// can't represent "which specific finger moves" the way this needs to.
/// Distinct from `GesturePreviewGraphic`, the larger colorful "doodle"
/// used in the Live Preview box.
struct GestureIconView: View {
    let kind: Trigger.GestureKind
    var height: CGFloat = 34

    /// A bit wider than tall reads better for the frame+dots glyph than
    /// a perfect square, but not by much — too wide is what made 4-5
    /// finger rows (already the widest content) look stretched.
    private static let aspectRatio: CGFloat = 1.3
    private var width: CGFloat { height * Self.aspectRatio }

    static let size = CGSize(width: 34 * aspectRatio, height: 34)

    private enum Slot {
        case dot(filled: Bool)
        case trail(degrees: Double)
    }

    var body: some View {
        Canvas { context, canvasSize in
            Self.drawFrame(&context, size: canvasSize)

            switch kind.category {
            case .pinchIn, .pinchOut, .rotateClockwise, .rotateCounterClockwise:
                Self.drawSymbolFallback(&context, kind: kind, size: canvasSize)
            default:
                Self.drawSlots(&context, slots: Self.slots(for: kind), size: canvasSize)
                if kind.isDoubleTap {
                    Self.drawDoubleMark(&context, size: canvasSize)
                }
            }
        }
        .frame(width: width, height: height)
    }

    // MARK: - Slot layout

    /// Which dot/trail symbols to lay out left-to-right for a kind.
    private static func slots(for kind: Trigger.GestureKind) -> [Slot] {
        let count = kind.fingerCount ?? 2

        // Split swipe: exactly one hollow (anchored) dot and one trail,
        // ordered to match which side actually moves.
        if let movingIsLeft = kind.splitSwipeMovingFingerIsLeft, let angle = kind.swipeAngleDegrees {
            return movingIsLeft
                ? [.trail(degrees: angle), .dot(filled: false)]
                : [.dot(filled: false), .trail(degrees: angle)]
        }

        guard let angle = kind.swipeAngleDegrees else {
            // Tap / double-tap: every finger touches, none "moves" — all
            // filled dots, no trail.
            return Array(repeating: .dot(filled: true), count: count)
        }

        // Ordinary swipe: (N-1) filled dots plus one motion trail
        // standing in for the direction. It sits at whichever end
        // matches a horizontal direction (left trail at the left end,
        // right trail at the right end); anything else defaults to the
        // trailing end.
        var slots: [Slot] = Array(repeating: .dot(filled: true), count: max(count - 1, 1))
        if angle == 180 {
            slots.insert(.trail(degrees: angle), at: 0)
        } else {
            slots.append(.trail(degrees: angle))
        }
        return slots
    }

    // MARK: - Drawing

    /// How far in from each edge all *content* (dots, trail) must stay —
    /// separate from, and smaller than, the frame's own border inset, so
    /// nothing ever touches or crosses the drawn rounded-rect outline.
    private static let contentInsetFraction: CGFloat = 0.17

    private static func drawFrame(_ context: inout GraphicsContext, size: CGSize) {
        let rect = CGRect(origin: .zero, size: size).insetBy(dx: size.width * 0.07, dy: size.height * 0.07)
        let path = Path(roundedRect: rect, cornerRadius: size.width * 0.2)
        context.fill(path, with: .color(.primary.opacity(0.06)))
        context.stroke(path, with: .color(.primary.opacity(0.55)), style: StrokeStyle(lineWidth: size.width * 0.05))
    }

    /// Every point placed here — dot centers, and both ends of a trail —
    /// is clamped into `safeRect` accounting for its own radius, which is
    /// what actually *guarantees* nothing crosses the frame, rather than
    /// hoping the spacing math works out for every finger count and
    /// direction. Spacing itself still compresses as slot count grows
    /// (matches `GesturePreviewGraphic.fingerPositions`'s approach) so
    /// dots don't overlap each other for 4-5 finger rows.
    private static func drawSlots(_ context: inout GraphicsContext, slots: [Slot], size: CGSize) {
        guard !slots.isEmpty else { return }
        let dotRadius = size.height * 0.15
        let insetX = size.width * contentInsetFraction
        let insetY = size.height * contentInsetFraction
        let safeRect = CGRect(x: insetX, y: insetY, width: size.width - insetX * 2, height: size.height - insetY * 2)

        let spacing = slots.count > 1 ? min(safeRect.width / CGFloat(slots.count - 1), size.width * 0.28) : 0
        let totalWidth = CGFloat(slots.count - 1) * spacing
        let startX = size.width / 2 - totalWidth / 2
        let y = size.height / 2

        for (index, slot) in slots.enumerated() {
            let x = slots.count > 1 ? startX + CGFloat(index) * spacing : size.width / 2
            let point = clamp(CGPoint(x: x, y: y), radius: dotRadius, in: safeRect)
            switch slot {
            case .dot(let filled):
                drawDot(&context, at: point, radius: dotRadius, filled: filled)
            case .trail(let degrees):
                drawTrail(&context, at: point, degrees: degrees, size: size, dotRadius: dotRadius, safeRect: safeRect)
            }
        }
    }

    private static func clamp(_ point: CGPoint, radius: CGFloat, in rect: CGRect) -> CGPoint {
        CGPoint(
            x: min(max(point.x, rect.minX + radius), rect.maxX - radius),
            y: min(max(point.y, rect.minY + radius), rect.maxY - radius)
        )
    }

    private static func drawDot(_ context: inout GraphicsContext, at point: CGPoint, radius: CGFloat, filled: Bool) {
        let rect = CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
        if filled {
            context.fill(Path(ellipseIn: rect), with: .color(.primary))
        } else {
            context.stroke(Path(ellipseIn: rect), with: .color(.primary), style: StrokeStyle(lineWidth: radius * 0.45))
        }
    }

    /// A fading motion trail instead of an arrowhead — a gradient line
    /// the same thickness as the other fingers' dots, dark near the rest
    /// of the hand and fading out along the direction of travel, capped
    /// with a solid dot (matching `drawDot`'s size) at the landing point
    /// so it still reads clearly at a glance which way this finger moves.
    /// Both ends are clamped into `safeRect`, so an edge slot pointing
    /// further toward that same edge shortens gracefully instead of
    /// spilling past the frame. Screen y grows downward while gesture
    /// angles follow `GestureRecognizer`'s atan2(dy, dx) convention
    /// (dy > 0 = up) — flip the y component here, same as the app's
    /// other gesture graphics.
    private static func drawTrail(_ context: inout GraphicsContext, at point: CGPoint, degrees: Double, size: CGSize, dotRadius: CGFloat, safeRect: CGRect) {
        let radians = degrees * .pi / 180
        let dir = CGVector(dx: cos(radians), dy: -sin(radians))
        let length = size.width * 0.26

        let start = clamp(CGPoint(x: point.x - dir.dx * length / 2, y: point.y - dir.dy * length / 2), radius: dotRadius * 0.6, in: safeRect)
        let end = clamp(CGPoint(x: point.x + dir.dx * length / 2, y: point.y + dir.dy * length / 2), radius: dotRadius, in: safeRect)

        var path = Path()
        path.move(to: start)
        path.addLine(to: end)
        context.stroke(
            path,
            with: .linearGradient(
                Gradient(colors: [Color.primary.opacity(0.04), Color.primary.opacity(0.85)]),
                startPoint: start,
                endPoint: end
            ),
            style: StrokeStyle(lineWidth: dotRadius * 1.2, lineCap: .round)
        )

        drawDot(&context, at: end, radius: dotRadius, filled: true)
    }

    private static func drawDoubleMark(_ context: inout GraphicsContext, size: CGSize) {
        let text = context.resolve(Text("2").font(.system(size: size.width * 0.28, weight: .bold)).foregroundColor(.white))
        let textSize = text.measure(in: size)
        let badgeRadius = max(textSize.width, textSize.height) / 2 + 1.5
        let point = CGPoint(x: size.width - badgeRadius - 1, y: size.height - badgeRadius - 1)
        let badgeRect = CGRect(x: point.x - badgeRadius, y: point.y - badgeRadius, width: badgeRadius * 2, height: badgeRadius * 2)
        context.fill(Path(ellipseIn: badgeRect), with: .color(.orange))
        context.draw(text, at: point)
    }

    private static func drawSymbolFallback(_ context: inout GraphicsContext, kind: Trigger.GestureKind, size: CGSize) {
        let text = context.resolve(
            Text(Image(systemName: kind.iconSymbolName))
                .font(.system(size: size.width * 0.38, weight: .medium))
                .foregroundColor(.primary)
        )
        context.draw(text, at: CGPoint(x: size.width / 2, y: size.height / 2))
    }
}

/// Rasterizes `GestureIconView` into a real bitmap for use as a Picker
/// dropdown item's icon. macOS renders `Picker` menu rows as native
/// `NSMenuItem`s, which only support a flat image — a live composited
/// SwiftUI view doesn't reliably show up there, only a pre-rendered
/// `Image` does. Cached per kind since there are 44 of them and the
/// menu can reopen repeatedly.
enum GestureGlyphRenderer {
    private static var cache: [Trigger.GestureKind: Image] = [:]

    /// Renders and caches every gesture's icon up front. Called once at
    /// app launch so the first time a rule sheet's gesture Picker builds
    /// (all 44 rows need their icon to construct the menu), it's reading
    /// an already-warm cache instead of doing 44 `ImageRenderer` passes
    /// synchronously on the main thread — that first-render cost was
    /// visible as a stall when picking a gesture.
    @MainActor
    static func prewarm() {
        for kind in Trigger.GestureKind.allCases {
            _ = image(for: kind)
        }
    }

    @MainActor
    static func image(for kind: Trigger.GestureKind) -> Image {
        if let cached = cache[kind] { return cached }
        let renderer = ImageRenderer(content: GestureIconView(kind: kind).frame(width: GestureIconView.size.width, height: GestureIconView.size.height))
        renderer.scale = 3
        let image: Image
        if let nsImage = renderer.nsImage {
            image = Image(nsImage: nsImage)
        } else {
            image = Image(systemName: kind.iconSymbolName)
        }
        cache[kind] = image
        return image
    }
}
