import SwiftUI
import GestureEngine
import InputModels

/// Small blue-tinted "trackpad" glyph — a rounded rectangle frame holding
/// a staggered row of dots (one per finger, alternating slightly up/down
/// rather than a flat line, closer to a relaxed hand than a ruler), where
/// a finger that's deliberately anchored (see `.splitSwipe`) is hollow
/// rather than solid. Each moving finger also gets a very faint short
/// trace trailing behind its dot (fading out away from the dot) to hint
/// at motion, and direction — when the gesture has one — additionally
/// gets a tiny arrow tucked at whichever edge/corner of the frame
/// matches that direction, rather than either of those replacing a
/// finger's dot outright.
struct GestureIconView: View {
    let kind: Trigger.GestureKind
    var height: CGFloat = 34

    /// A bit wider than tall reads better for the frame+dots glyph than
    /// a perfect square, but not by much — too wide is what made 4-5
    /// finger rows (already the widest content) look stretched.
    private static let aspectRatio: CGFloat = 1.3
    private var width: CGFloat { height * Self.aspectRatio }

    static let size = CGSize(width: 34 * aspectRatio, height: 34)

    /// A single accent for the whole glyph — vibrant enough to read at
    /// small sizes in both light and dark appearances, rather than
    /// deriving from `.primary`/`.accentColor` which would tie this to
    /// whatever the system/app accent happens to be.
    static let iconColor = Color(red: 0.2, green: 0.5, blue: 1.0)

    private enum Slot {
        case dot(filled: Bool, tracing: Bool)
    }

    var body: some View {
        Canvas { context, canvasSize in
            Self.drawFrame(&context, size: canvasSize)

            switch kind.category {
            case .pinchIn, .pinchOut, .rotateClockwise, .rotateCounterClockwise:
                Self.drawSymbolFallback(&context, kind: kind, size: canvasSize)
            default:
                Self.drawDots(&context, slots: Self.slots(for: kind), angleDegrees: kind.swipeAngleDegrees, size: canvasSize)
                if let angle = kind.swipeAngleDegrees {
                    Self.drawEdgeArrow(&context, degrees: angle, size: canvasSize)
                }
                if kind.isDoubleTap {
                    Self.drawDoubleMark(&context, size: canvasSize)
                }
            }
        }
        .frame(width: width, height: height)
    }

    // MARK: - Dot layout

    /// One entry per finger, left to right. `filled` = solid (touching/
    /// moving/tapping) vs. hollow (anchored — the split-swipe and
    /// split-tap cases, where order also encodes which side is which).
    /// `tracing` = whether that finger actually travels, so only moving
    /// fingers get a motion trace behind their dot — an anchored (or
    /// tapping-in-place) finger stays put.
    private static func slots(for kind: Trigger.GestureKind) -> [Slot] {
        let hasDirection = kind.swipeAngleDegrees != nil
        if let movingIsLeft = kind.splitActiveFingerIsLeft {
            return movingIsLeft
                ? [.dot(filled: true, tracing: hasDirection), .dot(filled: false, tracing: false)]
                : [.dot(filled: false, tracing: false), .dot(filled: true, tracing: hasDirection)]
        }
        let count = kind.fingerCount ?? 2
        return Array(repeating: .dot(filled: true, tracing: hasDirection), count: count)
    }

    // MARK: - Drawing

    /// How far in from each edge all *content* (dots, arrow, trace) must
    /// stay — separate from, and smaller than, the frame's own border
    /// inset, so nothing ever touches or crosses the drawn rounded-rect
    /// outline.
    private static let contentInsetFraction: CGFloat = 0.17

    static func drawFrame(_ context: inout GraphicsContext, size: CGSize) {
        let rect = CGRect(origin: .zero, size: size).insetBy(dx: size.width * 0.07, dy: size.height * 0.07)
        let path = Path(roundedRect: rect, cornerRadius: size.width * 0.2)
        context.fill(path, with: .color(iconColor.opacity(0.05)))
        context.stroke(path, with: .color(iconColor.opacity(0.45)), style: StrokeStyle(lineWidth: size.width * 0.05))
    }

    static func safeRect(for size: CGSize) -> CGRect {
        let insetX = size.width * contentInsetFraction
        let insetY = size.height * contentInsetFraction
        return CGRect(x: insetX, y: insetY, width: size.width - insetX * 2, height: size.height - insetY * 2)
    }

    /// Every dot center is clamped into the safe rect accounting for its
    /// own radius, which is what actually *guarantees* nothing crosses
    /// the frame, rather than hoping the spacing math works out for
    /// every finger count. Spacing compresses as count grows; the
    /// vertical stagger — alternating up/down per dot — is what turns a
    /// flat row into something that reads as a loose hand rather than a
    /// ruler.
    private static func drawDots(_ context: inout GraphicsContext, slots: [Slot], angleDegrees: Double?, size: CGSize) {
        guard !slots.isEmpty else { return }
        let rect = safeRect(for: size)
        let dotRadius = size.height * 0.1
        let spacing = slots.count > 1 ? min(rect.width / CGFloat(slots.count - 1), size.width * 0.28) : 0
        let totalWidth = CGFloat(slots.count - 1) * spacing
        let startX = size.width / 2 - totalWidth / 2
        let staggerY = size.height * 0.13

        for (index, slot) in slots.enumerated() {
            let x = slots.count > 1 ? startX + CGFloat(index) * spacing : size.width / 2
            let y = size.height / 2 + (index.isMultiple(of: 2) ? -staggerY : staggerY)
            let point = clamp(CGPoint(x: x, y: y), radius: dotRadius, in: rect)
            switch slot {
            case .dot(let filled, let tracing):
                if tracing, let angle = angleDegrees {
                    drawTrailingTrace(&context, at: point, degrees: angle, dotRadius: dotRadius, size: size, safeRect: rect)
                }
                drawDot(&context, at: point, radius: dotRadius, filled: filled)
            }
        }
    }

    static func clamp(_ point: CGPoint, radius: CGFloat, in rect: CGRect) -> CGPoint {
        CGPoint(
            x: min(max(point.x, rect.minX + radius), rect.maxX - radius),
            y: min(max(point.y, rect.minY + radius), rect.maxY - radius)
        )
    }

    static func drawDot(_ context: inout GraphicsContext, at point: CGPoint, radius: CGFloat, filled: Bool) {
        let rect = CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
        if filled {
            context.fill(Path(ellipseIn: rect), with: .color(iconColor))
        } else {
            context.stroke(Path(ellipseIn: rect), with: .color(iconColor), style: StrokeStyle(lineWidth: radius * 0.45))
        }
    }

    /// A short, faint gradient line trailing *behind* a moving dot —
    /// opposite its direction of travel, fading to nothing away from the
    /// dot — as a subtle motion hint. Deliberately much smaller/fainter
    /// than the old single big trail-in-a-slot design: this is a texture
    /// on top of a normal dot, not a replacement for one.
    private static func drawTrailingTrace(_ context: inout GraphicsContext, at point: CGPoint, degrees: Double, dotRadius: CGFloat, size: CGSize, safeRect: CGRect) {
        let radians = degrees * .pi / 180
        let dir = CGVector(dx: cos(radians), dy: -sin(radians))
        let length = size.width * 0.22
        let start = clamp(CGPoint(x: point.x - dir.dx * length, y: point.y - dir.dy * length), radius: dotRadius * 0.4, in: safeRect)
        var path = Path()
        path.move(to: start)
        path.addLine(to: point)
        context.stroke(
            path,
            with: .linearGradient(Gradient(colors: [iconColor.opacity(0), iconColor.opacity(0.45)]), startPoint: start, endPoint: point),
            style: StrokeStyle(lineWidth: dotRadius * 0.9, lineCap: .round)
        )
    }

    /// A very small arrow, separate from the finger dots entirely,
    /// anchored at whichever point on the frame's edge/corner the
    /// direction actually points toward (the ray from center in that
    /// direction, clipped to the safe rect boundary) — so a rightward
    /// swipe's arrow sits at the right edge, a diagonal one sits in that
    /// corner, etc. Screen y grows downward while gesture angles follow
    /// `GestureRecognizer`'s atan2(dy, dx) convention (dy > 0 = up) —
    /// flip the y component here, same as the app's other gesture graphics.
    static func drawEdgeArrow(_ context: inout GraphicsContext, degrees: Double, size: CGSize) {
        let rect = safeRect(for: size)
        let radians = degrees * .pi / 180
        let dir = CGVector(dx: cos(radians), dy: -sin(radians))
        let perp = CGVector(dx: -dir.dy, dy: dir.dx)

        let center = CGPoint(x: rect.midX, y: rect.midY)
        let tx: CGFloat = dir.dx != 0 ? (rect.width / 2) / abs(dir.dx) : .greatestFiniteMagnitude
        let ty: CGFloat = dir.dy != 0 ? (rect.height / 2) / abs(dir.dy) : .greatestFiniteMagnitude
        let t = min(tx, ty)
        let anchor = CGPoint(x: center.x + dir.dx * t, y: center.y + dir.dy * t)

        // Thinner than before, with a rounded tail: a small filled circle
        // centered on the tail (radius matching the base half-width, so
        // it passes exactly through both back corners) fills them in
        // smoothly, so the silhouette reads as a soft dart rather than a
        // sharp-cornered triangle — cheaper than constructing an explicit
        // arc path, and the two shapes union correctly under the default
        // nonzero fill rule since neither crosses the other's winding.
        let arrowLength = size.width * 0.1
        let arrowWidth = size.width * 0.06
        let tip = CGPoint(x: anchor.x + dir.dx * arrowLength / 2, y: anchor.y + dir.dy * arrowLength / 2)
        let tailCenter = CGPoint(x: anchor.x - dir.dx * arrowLength / 2, y: anchor.y - dir.dy * arrowLength / 2)
        let baseLeft = CGPoint(x: tailCenter.x + perp.dx * arrowWidth / 2, y: tailCenter.y + perp.dy * arrowWidth / 2)
        let baseRight = CGPoint(x: tailCenter.x - perp.dx * arrowWidth / 2, y: tailCenter.y - perp.dy * arrowWidth / 2)

        var path = Path()
        path.move(to: tip)
        path.addLine(to: baseLeft)
        path.addLine(to: baseRight)
        path.closeSubpath()
        let tailRadius = arrowWidth / 2
        path.addEllipse(in: CGRect(x: tailCenter.x - tailRadius, y: tailCenter.y - tailRadius, width: tailRadius * 2, height: tailRadius * 2))
        context.fill(path, with: .color(iconColor.opacity(0.85)))
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
                .foregroundColor(iconColor)
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
        MouseCornerGlyphRenderer.prewarm()
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

/// Same "trackpad frame + dot" glyph language as `GestureIconView`, for
/// the 4 corner-click options — a single solid dot placed toward the
/// actual corner (not the evenly-spaced finger row `GestureIconView`
/// draws) plus the same small edge arrow pointing into it. Reuses that
/// view's drawing primitives directly (`drawFrame`/`drawDot`/
/// `drawEdgeArrow`/etc., all `internal` rather than `private` for exactly
/// this reuse) rather than duplicating them, so the two glyph families
/// can never visually drift apart.
struct MouseCornerIconView: View {
    let corner: MouseCorner
    var height: CGFloat = 34

    private static let aspectRatio: CGFloat = 1.3
    private var width: CGFloat { height * Self.aspectRatio }
    static let size = CGSize(width: 34 * aspectRatio, height: 34)

    /// Matches `GestureKind.swipeAngleDegrees`' convention (0 = right, 90
    /// = up, counterclockwise) and exactly the angles `MouseCorner
    /// .iconSymbolName`'s SF Symbol fallback already implied, so a corner
    /// click's arrow points the same way its old plain-symbol icon did.
    private var angleDegrees: Double {
        switch corner {
        case .topLeft: return 135
        case .topRight: return 45
        case .bottomLeft: return 225
        case .bottomRight: return 315
        }
    }

    var body: some View {
        Canvas { context, canvasSize in
            GestureIconView.drawFrame(&context, size: canvasSize)
            let rect = GestureIconView.safeRect(for: canvasSize)
            let dotRadius = canvasSize.height * 0.1
            let radians = angleDegrees * .pi / 180
            // Same y-flip as GestureIconView.drawEdgeArrow: screen y grows
            // downward, gesture angles follow atan2(dy, dx) with dy>0=up.
            let direction = CGVector(dx: cos(radians), dy: -sin(radians))
            let target = CGPoint(x: rect.midX + direction.dx * rect.width / 2, y: rect.midY + direction.dy * rect.height / 2)
            let point = GestureIconView.clamp(target, radius: dotRadius, in: rect)
            GestureIconView.drawDot(&context, at: point, radius: dotRadius, filled: true)
            GestureIconView.drawEdgeArrow(&context, degrees: angleDegrees, size: canvasSize)
        }
        .frame(width: width, height: height)
    }
}

/// Same rasterize-and-cache pattern as `GestureGlyphRenderer`, for the 4
/// `MouseCornerIconView`s — see that type's doc comment for why a Picker
/// row needs a pre-rendered `Image` rather than a live SwiftUI view.
enum MouseCornerGlyphRenderer {
    private static var cache: [MouseCorner: Image] = [:]

    @MainActor
    static func prewarm() {
        for corner in MouseCorner.allCases {
            _ = image(for: corner)
        }
    }

    @MainActor
    static func image(for corner: MouseCorner) -> Image {
        if let cached = cache[corner] { return cached }
        let renderer = ImageRenderer(content: MouseCornerIconView(corner: corner).frame(width: MouseCornerIconView.size.width, height: MouseCornerIconView.size.height))
        renderer.scale = 3
        let image: Image
        if let nsImage = renderer.nsImage {
            image = Image(nsImage: nsImage)
        } else {
            image = Image(systemName: corner.iconSymbolName)
        }
        cache[corner] = image
        return image
    }
}
