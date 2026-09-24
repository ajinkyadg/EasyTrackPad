import SwiftUI
import AppKit
import GestureEngine
import InputModels

/// Which physical surface a gesture glyph is drawn on: the trackpad's
/// pebble tile, or a Magic Mouse's egg-shaped shell — so a Magic Mouse
/// rule is recognisable as one before its label is read.
enum GlyphSurface: Hashable {
    case trackpad, mouse

    init(device: InputDevice) {
        self = device == .magicMouse ? .mouse : .trackpad
    }
}

/// Accent-tinted gesture glyph in an "organic minimal" language: a soft
/// pebble surface holding one fingertip pad per finger. Tuned to stay
/// readable at the 20–28pt sizes rule rows and pickers use:
///
/// - **Fingertips are pads, not dots** — slightly egg-shaped ovals (narrower
///   toward the nail), splayed a few degrees outward like a relaxed hand,
///   sitting on a soft contact shadow.
/// - **Motion is a tapered smear** — a comet-like stroke, full pad width at
///   the finger and thinning to nothing where the motion began, with a very
///   slight bow so it reads as a hand's path rather than a ruler line.
///   Direction is still carried three ways: cluster lean, smears, and a
///   soft seed-shaped arrowhead on the leading edge, cut free of
///   the pads by a thin knocked-out moat.
/// - **Anchored fingers are hollow pads**, moving/tapping pads are solid.
/// - **Modifiers live on the frame**: the double-tap badge sits on the
///   tile's corner, knocked out of the outline.
/// - One colour (`iconColor`) at a few opacities, so the whole glyph
///   follows the user's accent colour. Every shape is deterministic —
///   the "irregular" edges come from fixed harmonics, not randomness.
struct GestureIconView: View {
    let kind: Trigger.GestureKind
    var height: CGFloat = 34
    var surface: GlyphSurface = .trackpad
    /// Loops the gesture being performed — fingers touch down, travel,
    /// hold, lift. Used where one glyph has the stage (the live preview,
    /// the featured-preset card, a hovered rule row), never for a whole
    /// list at once. Ignored under Reduce Motion.
    var animated = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// A bit wider than tall reads better for the frame+pads glyph than a
    /// perfect square, but not by much. Rows align on this box for every surface.
    static let aspectRatio: CGFloat = 1.3
    private var width: CGFloat { height * Self.aspectRatio }

    static let size = CGSize(width: 34 * aspectRatio, height: 34)

    /// The system accent color, shared with the live touch dots and every
    /// other tinted glyph in the app so the whole UI reads as one palette.
    static let iconColor = Color.accentColor

    /// One loop of the animation, in seconds.
    static let animationPeriod: Double = 2.0

    var body: some View {
        Group {
            if animated && !reduceMotion {
                TimelineView(.animation) { timeline in
                    let progress = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: Self.animationPeriod) / Self.animationPeriod
                    Canvas { context, canvasSize in
                        Self.draw(kind, surface: surface, in: &context, size: canvasSize, progress: progress)
                    }
                }
            } else {
                Canvas { context, canvasSize in
                    Self.draw(kind, surface: surface, in: &context, size: canvasSize)
                }
            }
        }
        .frame(width: width, height: height)
        .accessibilityElement()
        .accessibilityLabel(kind.displayName)
        .accessibilityAddTraits(.isImage)
    }

    // MARK: - Geometry

    /// The surface outline plus the rect all content (pads, smears,
    /// arrows) must stay inside, so nothing ever crosses the outline.
    struct Layout {
        let content: CGRect
        let dotRadius: CGFloat
        /// Vertical offset alternating per finger — a relaxed hand, not a ruler.
        let stagger: CGFloat
        let surface: GlyphSurface
    }

    static func layout(for surface: GlyphSurface, fingers: Int, size: CGSize) -> Layout {
        switch surface {
        case .trackpad:
            let inset = CGSize(width: size.width * 0.17, height: size.height * 0.18)
            return Layout(
                content: CGRect(origin: .zero, size: size).insetBy(dx: inset.width, dy: inset.height),
                dotRadius: size.height * 0.1,
                stagger: size.height * 0.1,
                surface: surface
            )
        case .mouse:
            let capsule = mouseCapsule(in: size)
            return Layout(
                content: capsule.insetBy(dx: capsule.width * 0.16, dy: capsule.height * 0.12),
                // Three fingers side by side on a mouse's narrow shell
                // need smaller pads or they merge into one blob.
                dotRadius: size.height * (fingers >= 3 ? 0.06 : 0.075),
                stagger: 0,
                surface: surface
            )
        }
    }

    static func mouseCapsule(in size: CGSize) -> CGRect {
        let h = size.height * 0.9, w = size.height * 0.75
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }

    static func strokeWidth(for size: CGSize) -> CGFloat { size.height * 0.055 }

    static func clamp(_ point: CGPoint, radius: CGFloat, in rect: CGRect) -> CGPoint {
        CGPoint(
            x: min(max(point.x, rect.minX + radius), rect.maxX - radius),
            y: min(max(point.y, rect.minY + radius), rect.maxY - radius)
        )
    }

    /// Screen y grows downward while gesture angles follow the recognizer's
    /// atan2(dy, dx) convention (dy > 0 = up) — flipped here, once.
    static func direction(degrees: Double) -> CGVector {
        let radians = degrees * .pi / 180
        return CGVector(dx: cos(radians), dy: -sin(radians))
    }

    // MARK: - Organic shape builders

    /// A closed Catmull-Rom spline through `points` — the smoothing that
    /// turns sampled outlines into soft, continuous curves.
    static func smoothClosedPath(_ points: [CGPoint]) -> Path {
        var path = Path()
        let n = points.count
        guard n > 2 else { return path }
        path.move(to: points[0])
        for i in 0..<n {
            let p0 = points[(i - 1 + n) % n], p1 = points[i], p2 = points[(i + 1) % n], p3 = points[(i + 2) % n]
            let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
            let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
            path.addCurve(to: p2, control1: c1, control2: c2)
        }
        path.closeSubpath()
        return path
    }

    /// Superellipse sample with a fixed low-frequency wobble — soft corners
    /// and faintly bowed sides, like a river pebble or a bar of soap.
    /// `taper` narrows the top relative to the bottom (egg shapes).
    static func blobPath(center: CGPoint, rx: CGFloat, ry: CGFloat, exponent: CGFloat,
                         taper: CGFloat = 0, wobble: [(amp: CGFloat, freq: CGFloat, phase: CGFloat)] = [],
                         rotation: Double = 0, samples: Int = 48) -> Path {
        let cr = cos(rotation), sr = sin(rotation)
        let points: [CGPoint] = (0..<samples).map { i in
            let t = CGFloat(i) / CGFloat(samples) * 2 * .pi
            let c = cos(t), s = sin(t)
            var x = rx * (c < 0 ? -1 : 1) * pow(abs(c), 2 / exponent)
            let y = ry * (s < 0 ? -1 : 1) * pow(abs(s), 2 / exponent)
            // s < 0 is the top half on screen: narrow it by `taper`.
            x *= 1 + taper * s
            var scale: CGFloat = 1
            for w in wobble { scale += w.amp * sin(w.freq * t + w.phase) }
            let px = x * scale, py = y * scale
            return CGPoint(x: center.x + px * cr - py * sr, y: center.y + px * sr + py * cr)
        }
        return smoothClosedPath(points)
    }

    /// The fingertip pad: an oval a little taller than wide, narrower
    /// toward the nail. `radius` is the equivalent dot radius.
    static func padPath(at point: CGPoint, radius: CGFloat, tilt: Double = 0) -> Path {
        blobPath(center: point, rx: radius * 0.93, ry: radius * 1.05, exponent: 2.15, taper: 0.07,
                 rotation: tilt * .pi / 180, samples: 28)
    }

    /// A comet-like smear along `centerline` (tail → head): zero width at
    /// the tail, `headWidth` at the head, with a round head cap.
    static func taperedPath(_ centerline: [CGPoint], headWidth: CGFloat, tailWidth: CGFloat = 0) -> Path {
        let n = centerline.count
        guard n > 1 else { return Path() }
        var left: [CGPoint] = [], right: [CGPoint] = []
        for i in 0..<n {
            let a = centerline[max(i - 1, 0)], b = centerline[min(i + 1, n - 1)]
            var tx = b.x - a.x, ty = b.y - a.y
            let len = max(hypot(tx, ty), 0.0001); tx /= len; ty /= len
            let t = CGFloat(i) / CGFloat(n - 1)
            // Ease-out swell: thin for the first third, full body near the finger.
            let w = (tailWidth + (headWidth - tailWidth) * pow(t, 0.55)) / 2
            let p = centerline[i]
            left.append(CGPoint(x: p.x - ty * w, y: p.y + tx * w))
            right.append(CGPoint(x: p.x + ty * w, y: p.y - tx * w))
        }
        var path = Path()
        path.move(to: left[0])
        for p in left.dropFirst() { path.addLine(to: p) }
        let head = centerline[n - 1], prev = centerline[n - 2]
        let heading = atan2(head.y - prev.y, head.x - prev.x)
        path.addArc(center: head, radius: headWidth / 2, startAngle: .radians(Double(heading) - .pi / 2),
                    endAngle: .radians(Double(heading) + .pi / 2), clockwise: true)
        for p in right.reversed() { path.addLine(to: p) }
        path.closeSubpath()
        return path
    }

    /// Centerline from `start` to `end` with a gentle perpendicular bow.
    static func bowedLine(from start: CGPoint, to end: CGPoint, bow: CGFloat, samples: Int = 18) -> [CGPoint] {
        let dx = end.x - start.x, dy = end.y - start.y
        let len = max(hypot(dx, dy), 0.0001)
        let px = -dy / len, py = dx / len
        return (0...samples).map { i in
            let t = CGFloat(i) / CGFloat(samples)
            let b = bow * len * sin(.pi * t)
            return CGPoint(x: start.x + dx * t + px * b, y: start.y + dy * t + py * b)
        }
    }

    static func surfacePath(size: CGSize, surface: GlyphSurface) -> Path {
        switch surface {
        case .trackpad:
            let rect = CGRect(origin: .zero, size: size).insetBy(dx: size.width * 0.075, dy: size.height * 0.075)
            return blobPath(center: CGPoint(x: rect.midX, y: rect.midY), rx: rect.width / 2, ry: rect.height / 2,
                            exponent: 4.2, wobble: [(0.010, 2, 0.6), (0.006, 3, 2.1)], samples: 96)
        case .mouse:
            let c = mouseCapsule(in: size)
            return blobPath(center: CGPoint(x: c.midX, y: c.midY), rx: c.width / 2, ry: c.height / 2,
                            exponent: 2.4, taper: 0.03, wobble: [(0.008, 3, 0.4)], samples: 72)
        }
    }

    static func drawFrame(_ context: inout GraphicsContext, size: CGSize, surface: GlyphSurface = .trackpad) {
        let path = surfacePath(size: size, surface: surface)
        let bounds = path.boundingRect
        // Soft top-lit body: a touch denser toward the bottom, like a
        // pebble catching light from above.
        context.fill(path, with: .linearGradient(
            Gradient(colors: [iconColor.opacity(0.07), iconColor.opacity(0.15)]),
            startPoint: CGPoint(x: bounds.midX, y: bounds.minY), endPoint: CGPoint(x: bounds.midX, y: bounds.maxY)))
        context.stroke(path, with: .color(iconColor.opacity(0.46)), style: StrokeStyle(lineWidth: strokeWidth(for: size)))
        // The button seam is what makes the shell read as a mouse — a
        // tapered groove, only where there's room for it.
        if surface == .mouse, size.height >= 24 {
            let c = mouseCapsule(in: size)
            var seam = Path()
            seam.move(to: CGPoint(x: c.midX, y: c.minY + c.height * 0.07))
            seam.addLine(to: CGPoint(x: c.midX, y: c.minY + c.height * 0.24))
            context.stroke(seam, with: .linearGradient(Gradient(colors: [iconColor.opacity(0.4), iconColor.opacity(0)]),
                                                       startPoint: CGPoint(x: c.midX, y: c.minY + c.height * 0.07), endPoint: CGPoint(x: c.midX, y: c.minY + c.height * 0.26)),
                           style: StrokeStyle(lineWidth: strokeWidth(for: size) * 0.55, lineCap: .round))
        }
    }

    // MARK: - Primitives

    /// A fingertip pad. Solid pads sit on a soft contact shadow and, when
    /// there's room, carry a faint specular sheen; hollow pads are anchored.
    static func drawDot(_ context: inout GraphicsContext, at point: CGPoint, radius: CGFloat, filled: Bool, tilt: Double = 0) {
        if filled {
            let pad = padPath(at: point, radius: radius, tilt: tilt)
            var shadowed = context
            shadowed.addFilter(.shadow(color: iconColor.opacity(0.45), radius: max(radius * 0.35, 0.6), x: 0, y: max(radius * 0.2, 0.5)))
            shadowed.fill(pad, with: .color(iconColor))
            if radius >= 3.5 {
                // Sheen: a small, soft highlight up-and-left on the pad.
                let hl = CGPoint(x: point.x - radius * 0.28, y: point.y - radius * 0.38)
                var sheen = context
                sheen.clip(to: pad)
                sheen.fill(Path(ellipseIn: CGRect(x: hl.x - radius * 0.7, y: hl.y - radius * 0.6, width: radius * 1.4, height: radius * 1.2)),
                           with: .radialGradient(Gradient(colors: [.white.opacity(0.38), .white.opacity(0)]), center: hl, startRadius: 0, endRadius: radius * 0.7))
            }
        } else {
            // Inset so a hollow pad's *outer* edge matches a solid pad's size.
            let width = max(radius * 0.28, 1.1)
            let inner = radius - width / 2
            let ring = padPath(at: point, radius: inner, tilt: tilt)
            context.fill(ring, with: .color(iconColor.opacity(0.3)))
            context.stroke(ring, with: .color(iconColor), style: StrokeStyle(lineWidth: width))
        }
    }

    /// A tapered smear from `start` (transparent, pointed) to `end` (the pad).
    static func drawTrail(_ context: inout GraphicsContext, from start: CGPoint, to end: CGPoint, width: CGFloat, bow: CGFloat = 0) {
        let path = taperedPath(bowedLine(from: start, to: end, bow: bow), headWidth: width)
        context.fill(path, with: .linearGradient(
            Gradient(stops: [.init(color: iconColor.opacity(0), location: 0), .init(color: iconColor.opacity(0.34), location: 0.4), .init(color: iconColor.opacity(0.7), location: 1)]),
            startPoint: start, endPoint: end))
    }

    /// A soft seed-shaped arrowhead — gently convex flanks, rounded tip and barbs —
    /// with its tip at `tip`, pointing along `dir`.
    static func drawArrowhead(_ context: inout GraphicsContext, tip: CGPoint, dir: CGVector, length: CGFloat, width: CGFloat, knockout gap: CGFloat = 0) {
        let perp = CGVector(dx: -dir.dy, dy: dir.dx)
        // A round-joined outline adds `soften / 2` all round, so the
        // geometry is pulled in by that much to keep the tip on `tip`.
        let soften = length * 0.22
        let l = length - soften, w = width / 2 - soften / 2
        func q(_ along: CGFloat, _ across: CGFloat) -> CGPoint {
            CGPoint(x: tip.x - dir.dx * (along + soften / 2) + perp.dx * across, y: tip.y - dir.dy * (along + soften / 2) + perp.dy * across)
        }
        var path = Path()
        path.move(to: q(0, 0))
        // Very slightly convex flanks — a seed or a leaf tip, not a thorn.
        path.addQuadCurve(to: q(l, w), control: q(l * 0.5, w * 0.6))
        path.addQuadCurve(to: q(l * 0.58, 0), control: q(l * 0.8, w * 0.2))
        path.addQuadCurve(to: q(l, -w), control: q(l * 0.8, -w * 0.2))
        path.addQuadCurve(to: q(0, 0), control: q(l * 0.5, -w * 0.6))
        path.closeSubpath()
        if gap > 0 {
            // Clear a thin moat around the arrow so it never fuses with a
            // pad or smear it overlaps — it reads as a separate mark.
            var moat = context
            moat.blendMode = .destinationOut
            moat.stroke(path, with: .color(.black), style: StrokeStyle(lineWidth: soften + gap * 2, lineCap: .round, lineJoin: .round))
        }
        context.fill(path, with: .color(iconColor))
        context.stroke(path, with: .color(iconColor), style: StrokeStyle(lineWidth: soften, lineCap: .round, lineJoin: .round))
    }

    /// The arrowhead at whichever edge/corner of `rect` the direction
    /// points to — right edge for a rightward swipe, a corner for a
    /// diagonal — with its tip on the boundary.
    static func drawEdgeArrow(_ context: inout GraphicsContext, degrees: Double, in rect: CGRect, size: CGSize, scale: CGFloat = 1) {
        let dir = direction(degrees: degrees)
        let tx: CGFloat = dir.dx != 0 ? (rect.width / 2) / abs(dir.dx) : .greatestFiniteMagnitude
        let ty: CGFloat = dir.dy != 0 ? (rect.height / 2) / abs(dir.dy) : .greatestFiniteMagnitude
        let t = min(tx, ty)
        let tip = CGPoint(x: rect.midX + dir.dx * t, y: rect.midY + dir.dy * t)
        drawArrowhead(&context, tip: tip, dir: dir, length: size.height * 0.24 * scale, width: size.height * 0.23 * scale,
                      knockout: max(size.height * 0.035, 0.9))
    }

    /// Double-tap badge, sitting on the tile's top-right corner and knocked
    /// out of the outline (not over a pad), sized so the "2" stays
    /// legible at row size without dwarfing the glyph at large sizes.
    static func drawDoubleTapBadge(_ context: inout GraphicsContext, size: CGSize) {
        let radius = max(size.height * 0.2, 5)
        let center = CGPoint(x: size.width - radius - size.width * 0.01, y: radius + size.height * 0.01)
        let gap = max(size.height * 0.05, 1.5)
        var knockout = context
        knockout.blendMode = .destinationOut
        knockout.fill(blobPath(center: center, rx: radius + gap, ry: radius + gap, exponent: 2), with: .color(.black))
        context.fill(blobPath(center: center, rx: radius, ry: radius, exponent: 2), with: .color(iconColor))
        let text = context.resolve(Text("2").font(.system(size: radius * 1.45, weight: .heavy, design: .rounded)).foregroundColor(.white))
        context.draw(text, at: center)
    }

    // MARK: - Motion

    /// Where one frame of the loop is. `progress == nil` is the still
    /// glyph, identical to the end-of-travel "hold" frame.
    struct Motion {
        /// 0 at touch-down position, 1 at the end of travel.
        var travel: CGFloat = 1
        /// Pads fade in on touch-down and out on lift.
        var opacity: Double = 1
        /// Pad size multiplier — presses dip, lifts swell slightly.
        var scale: CGFloat = 1
        /// Tap ripple: 0...1 expanding ring, `nil` when none is showing.
        var ripple: CGFloat?
        var isStatic = true

        static let still = Motion()

        private static func ease(_ x: Double) -> CGFloat {
            let t = min(max(x, 0), 1)
            return CGFloat(t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2)
        }

        /// Swipes, pinches, rotations: touch down 0–12%, travel 12–62%,
        /// hold 62–85%, lift 85–100%.
        static func moving(_ progress: Double?) -> Motion {
            guard let p = progress else { return .still }
            var m = Motion(isStatic: false)
            m.travel = ease((p - 0.12) / 0.5)
            if p < 0.12 { m.opacity = p / 0.12; m.scale = 0.8 + 0.2 * CGFloat(p / 0.12) }
            if p > 0.85 { let q = (p - 0.85) / 0.15; m.opacity = 1 - q; m.scale = 1 + 0.12 * CGFloat(q) }
            return m
        }

        /// Taps: one press (two for a double tap), each a quick dip in pad
        /// size with a ripple spreading from it.
        static func tapping(_ progress: Double?, presses: Int) -> Motion {
            guard let p = progress else { return .still }
            var m = Motion(isStatic: false)
            if p < 0.1 { m.opacity = p / 0.1 }
            if p > 0.85 { m.opacity = 1 - (p - 0.85) / 0.15 }
            let starts = presses == 2 ? [0.18, 0.42] : [0.25]
            for start in starts where p >= start && p < start + 0.3 {
                let q = (p - start) / 0.3
                m.ripple = CGFloat(q)
                if q < 0.35 { m.scale = 1 - 0.2 * CGFloat(sin(q / 0.35 * .pi)) }
            }
            return m
        }
    }

    static func lerp(_ a: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint {
        CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
    }

    /// An expanding, fading ring around a pad — the "tap" beat.
    static func drawRipple(_ context: inout GraphicsContext, at point: CGPoint, radius: CGFloat, phase: CGFloat) {
        let r = radius * (1.1 + 1.3 * phase)
        context.stroke(Path(ellipseIn: CGRect(x: point.x - r, y: point.y - r, width: r * 2, height: r * 2)),
                       with: .color(iconColor.opacity(Double(0.55 * (1 - phase)))),
                       style: StrokeStyle(lineWidth: max(radius * 0.22, 0.8)))
    }

    // MARK: - Glyphs

    static func draw(_ kind: Trigger.GestureKind, surface: GlyphSurface, in context: inout GraphicsContext, size: CGSize, progress: Double? = nil) {
        // Everything draws into one layer so the badge knockout cuts the
        // outline rather than the view behind it.
        context.drawLayer { layer in
            drawFrame(&layer, size: size, surface: surface)
            switch kind.category {
            case .pinchIn, .pinchOut:
                drawPinch(&layer, inward: kind.category == .pinchIn, surface: surface, size: size, motion: .moving(progress))
            case .rotateClockwise, .rotateCounterClockwise:
                drawRotate(&layer, clockwise: kind.category == .rotateClockwise, surface: surface, size: size, motion: .moving(progress))
            default:
                if kind == .twoFingerFastScrollToBottomEdge {
                    drawFastScroll(&layer, surface: surface, size: size, motion: .moving(progress))
                } else if let movingIsLeft = kind.splitActiveFingerIsLeft {
                    drawSplit(&layer, movingIsLeft: movingIsLeft, angle: kind.swipeAngleDegrees, surface: surface, size: size,
                              motion: kind.swipeAngleDegrees == nil ? .tapping(progress, presses: 1) : .moving(progress))
                } else {
                    drawFingers(&layer, count: kind.fingerCount ?? 2, angle: kind.swipeAngleDegrees, doubleTap: kind.isDoubleTap, surface: surface, size: size,
                                motion: kind.swipeAngleDegrees == nil ? .tapping(progress, presses: kind.isDoubleTap ? 2 : 1) : .moving(progress))
                }
                if kind.isDoubleTap { drawDoubleTapBadge(&layer, size: size) }
            }
        }
    }

    /// Outward splay for finger `index` of `count`: outer fingers lean away
    /// from the middle, like a relaxed hand.
    static func splay(_ index: Int, of count: Int) -> Double {
        (Double(index) - Double(count - 1) / 2) * 8
    }

    /// Base finger positions: evenly spread, spacing capped so 2 fingers
    /// don't sit at the far walls, staggered for trackpads.
    private static func basePoints(count: Int, layout: Layout, size: CGSize) -> [CGPoint] {
        let rect = layout.content
        let usable = rect.width - layout.dotRadius * 2
        let spacing = count > 1 ? min(usable / CGFloat(count - 1), size.width * 0.26) : 0
        let startX = rect.midX - CGFloat(count - 1) * spacing / 2
        return (0..<count).map { index in
            let y = rect.midY + (index.isMultiple(of: 2) ? -layout.stagger : layout.stagger)
            return CGPoint(x: startX + CGFloat(index) * spacing, y: y)
        }
    }

    private static func drawFingers(_ context: inout GraphicsContext, count: Int, angle: Double?, doubleTap: Bool, surface: GlyphSurface, size: CGSize, motion: Motion = .still) {
        let layout = layout(for: surface, fingers: count, size: size)
        var points = basePoints(count: count, layout: layout, size: size)
        // Keep the double-tap badge's corner clear.
        if doubleTap { points = points.map { CGPoint(x: $0.x, y: $0.y + size.height * 0.05) } }

        guard let angle else {
            var pads = context
            pads.opacity = motion.opacity
            for (i, point) in points.enumerated() {
                let pad = clamp(point, radius: layout.dotRadius, in: layout.content)
                if let phase = motion.ripple { drawRipple(&pads, at: pad, radius: layout.dotRadius, phase: phase) }
                drawDot(&pads, at: pad, radius: layout.dotRadius * motion.scale, filled: true, tilt: splay(i, of: count))
            }
            return
        }

        let dir = direction(degrees: angle)
        // Lean the whole cluster toward the direction of travel.
        let lean = CGVector(dx: dir.dx * layout.content.width * 0.08, dy: dir.dy * layout.content.height * 0.16)
        let trailLength = surface == .trackpad ? size.width * 0.32
            : (abs(dir.dx) > abs(dir.dy) ? layout.content.width * 0.75 : layout.content.height * 0.42)
        if surface == .mouse, abs(dir.dx) > abs(dir.dy) {
            // Side-by-side pads would hide each other's horizontal smears:
            // stagger them like a relaxed hand so both smears stay visible.
            let offset = layout.content.height * 0.13
            points = points.enumerated().map { CGPoint(x: $1.x, y: $1.y + ($0.isMultiple(of: 2) ? -offset : offset)) }
        }
        let dots = points.map { clamp(CGPoint(x: $0.x + lean.dx, y: $0.y + lean.dy), radius: layout.dotRadius, in: layout.content) }
        let starts = dots.map { clamp(CGPoint(x: $0.x - dir.dx * trailLength, y: $0.y - dir.dy * trailLength), radius: layout.dotRadius * 0.3, in: layout.content) }
        // Animated: each pad starts where its smear begins and travels to
        // its resting spot, the smear growing behind it.
        let current = zip(starts, dots).map { lerp($0, $1, motion.travel) }
        var pads = context
        pads.opacity = motion.opacity
        // All smears first, then all pads, so no smear crosses a pad.
        for (i, dot) in current.enumerated() where motion.travel > 0.08 {
            drawTrail(&pads, from: starts[i], to: dot, width: layout.dotRadius * 1.4, bow: count >= 4 ? 0 : (i.isMultiple(of: 2) ? 0.035 : -0.035))
        }
        for (i, dot) in current.enumerated() {
            drawDot(&pads, at: dot, radius: layout.dotRadius * motion.scale, filled: true, tilt: splay(i, of: count))
        }
        if surface == .trackpad {
            var arrow = context
            arrow.opacity = motion.isStatic ? 1 : Double(motion.travel) * motion.opacity
            drawEdgeArrow(&arrow, degrees: angle, in: layout.content, size: size)
        }
        // The mouse shell is too narrow for an edge arrow without it landing
        // on a pad; lean + smears carry direction there.
    }

    /// One finger anchored (hollow pad), the other travelling. A swipe
    /// shows the mover at the end of its travel with a full-height smear;
    /// a tap just shows it solid.
    private static func drawSplit(_ context: inout GraphicsContext, movingIsLeft: Bool, angle: Double?, surface: GlyphSurface, size: CGSize, motion: Motion = .still) {
        let layout = layout(for: surface, fingers: 2, size: size)
        let points = basePoints(count: 2, layout: layout, size: size)
        let r = layout.dotRadius
        for (index, point) in points.enumerated() {
            let isMover = (index == 0) == movingIsLeft
            let tilt = splay(index, of: 2)
            let resting = clamp(CGPoint(x: point.x, y: layout.content.midY), radius: r, in: layout.content)
            guard isMover, let angle else {
                // The anchor stays put the whole loop; only the mover animates.
                var pad = context
                if isMover { pad.opacity = motion.opacity }
                if isMover, let phase = motion.ripple { drawRipple(&pad, at: resting, radius: r, phase: phase) }
                drawDot(&pad, at: resting, radius: isMover ? r * motion.scale : r, filled: isMover, tilt: tilt)
                continue
            }
            let up = angle == 90
            let end = CGPoint(x: point.x, y: up ? layout.content.minY + r : layout.content.maxY - r)
            let start = CGPoint(x: point.x, y: up ? layout.content.maxY - r * 0.3 : layout.content.minY + r * 0.3)
            // Animated, the mover starts beside the anchor and slides away.
            let from = motion.isStatic ? start : CGPoint(x: point.x, y: resting.y)
            let now = lerp(from, end, motion.travel)
            var pad = context
            pad.opacity = motion.opacity
            if motion.travel > 0.08 { drawTrail(&pad, from: motion.isStatic ? start : from, to: now, width: r * 1.4, bow: index == 0 ? 0.04 : -0.04) }
            drawDot(&pad, at: now, radius: r * motion.scale, filled: true, tilt: tilt)
        }
    }

    /// Two-finger swipe down plus a shoreline at the bottom edge — "to the end".
    private static func drawFastScroll(_ context: inout GraphicsContext, surface: GlyphSurface, size: CGSize, motion: Motion = .still) {
        let layout = layout(for: surface, fingers: 2, size: size)
        let r = layout.dotRadius
        let barY = layout.content.maxY
        let points = basePoints(count: 2, layout: layout, size: size).map { CGPoint(x: $0.x, y: layout.content.midY - r * 0.2) }
        var pads = context
        pads.opacity = motion.opacity
        for (i, dot) in points.enumerated() {
            let start = CGPoint(x: dot.x, y: layout.content.minY + r * 0.3)
            let now = lerp(start, dot, motion.travel)
            if motion.travel > 0.08 { drawTrail(&pads, from: start, to: now, width: r * 1.4) }
            drawDot(&pads, at: now, radius: r * motion.scale, filled: true, tilt: splay(i, of: 2))
        }
        // Double chevron under the fingers, then the edge "shoreline":
        // a lens that swells in the middle and tapers to both ends.
        let midX = layout.content.midX
        for step in 0..<2 {
            let tip = CGPoint(x: midX, y: barY - r * 0.9 + CGFloat(step) * r * 0.7 - r * 0.7)
            drawArrowhead(&context, tip: tip, dir: CGVector(dx: 0, dy: 1), length: r * 0.9, width: r * 1.9)
        }
        let thick = max(r * 0.6, 1.3)
        let x0 = layout.content.minX + r * 0.1, x1 = layout.content.maxX - r * 0.1
        var bar = Path()
        bar.move(to: CGPoint(x: x0, y: barY))
        bar.addQuadCurve(to: CGPoint(x: x1, y: barY), control: CGPoint(x: midX, y: barY - thick))
        bar.addQuadCurve(to: CGPoint(x: x0, y: barY), control: CGPoint(x: midX, y: barY + thick))
        bar.closeSubpath()
        context.fill(bar, with: .color(iconColor))
        context.stroke(bar, with: .color(iconColor), style: StrokeStyle(lineWidth: max(thick * 0.35, 0.6), lineJoin: .round))
    }

    /// Two pads on a diagonal: pinch in shows them close together with
    /// smears from the corners; pinch out shows them at the corners with
    /// smears from the middle. Pads tilt along the pinch axis.
    private static func drawPinch(_ context: inout GraphicsContext, inward: Bool, surface: GlyphSurface, size: CGSize, motion: Motion = .still) {
        let layout = layout(for: surface, fingers: 2, size: size)
        let r = layout.dotRadius
        let rect = layout.content
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let outer = [CGPoint(x: rect.minX + r, y: rect.minY + r), CGPoint(x: rect.maxX - r, y: rect.maxY - r)]
        let axisTilt = -Double(atan2(outer[1].x - outer[0].x, outer[1].y - outer[0].y)) * 180 / .pi + 180
        var ends: [CGPoint] = []
        for (i, corner) in outer.enumerated() {
            let towardCenter = CGVector(dx: center.x - corner.x, dy: center.y - corner.y)
            let near = CGPoint(x: center.x - towardCenter.dx * 0.38, y: center.y - towardCenter.dy * 0.38)
            let (start, end) = inward ? (corner, near) : (CGPoint(x: center.x - towardCenter.dx * 0.1, y: center.y - towardCenter.dy * 0.1), corner)
            let now = lerp(start, end, motion.travel)
            var trail = context
            trail.opacity = motion.opacity
            if motion.travel > 0.08 { drawTrail(&trail, from: start, to: now, width: r * 1.4, bow: i == 0 ? 0.05 : 0.05) }
            ends.append(now)
        }
        var pads = context
        pads.opacity = motion.opacity
        for end in ends { drawDot(&pads, at: end, radius: r * motion.scale, filled: true, tilt: axisTilt) }
    }

    /// Two pads on opposite sides of a circle, each with a tapered arc
    /// smear behind it in the direction of turn.
    private static func drawRotate(_ context: inout GraphicsContext, clockwise: Bool, surface: GlyphSurface, size: CGSize, motion: Motion = .still) {
        let layout = layout(for: surface, fingers: 2, size: size)
        let r = layout.dotRadius
        let center = CGPoint(x: layout.content.midX, y: layout.content.midY)
        let radius = min(layout.content.width, layout.content.height) / 2 - r * 0.5
        // Screen angles (y down): clockwise on screen = increasing angle.
        let sweep: Double = clockwise ? 1 : -1
        var ends: [(CGPoint, Double)] = []
        for base in [-150.0, 30.0] {
            let steps = 24
            // Animated, the arc is swept out as the pads turn.
            let span = 110 * Double(max(motion.travel, 0.001))
            // Slightly elliptical orbit — wider than tall, like the tile.
            let line: [CGPoint] = (0...steps).map { i in
                let a = (base + sweep * span * Double(i) / Double(steps)) * .pi / 180
                return CGPoint(x: center.x + cos(a) * radius * 1.12, y: center.y + sin(a) * radius)
            }
            let from = line[0], to = line[steps]
            var trail = context
            trail.opacity = motion.opacity
            if motion.travel > 0.08 {
                trail.fill(taperedPath(line, headWidth: r * 1.4), with: .linearGradient(
                    Gradient(stops: [.init(color: iconColor.opacity(0), location: 0), .init(color: iconColor.opacity(0.34), location: 0.4), .init(color: iconColor.opacity(0.7), location: 1)]),
                    startPoint: from, endPoint: to))
            }
            let endAngle = base + sweep * span
            ends.append((to, endAngle + 90))
        }
        var pads = context
        pads.opacity = motion.opacity
        for (p, tilt) in ends { drawDot(&pads, at: p, radius: r * motion.scale, filled: true, tilt: tilt) }
    }
}

/// Rasterizes `GestureIconView` into a real bitmap for use as a Picker
/// dropdown item's icon. macOS renders `Picker` menu rows as native
/// `NSMenuItem`s, which only support a flat image — a live composited
/// SwiftUI view doesn't reliably show up there, only a pre-rendered
/// `Image` does. Cached per kind, surface, and accent colour (so a changed
/// accent colour in System Settings shows up without a relaunch).
enum GestureGlyphRenderer {
    private struct Key: Hashable {
        let kind: Trigger.GestureKind
        let surface: GlyphSurface
        let accent: String
    }
    private static var cache: [Key: Image] = [:]

    /// Renders and caches every trackpad gesture's icon up front, so the
    /// first time a rule sheet's gesture Picker builds it reads a warm
    /// cache instead of stalling on dozens of `ImageRenderer` passes.
    @MainActor
    static func prewarm() {
        for kind in Trigger.GestureKind.allCases {
            _ = image(for: kind)
        }
        MouseCornerGlyphRenderer.prewarm()
    }

    static var accentKey: String { NSColor.controlAccentColor.usingColorSpace(.sRGB)?.description ?? "" }

    @MainActor
    static func image(for kind: Trigger.GestureKind, surface: GlyphSurface = .trackpad) -> Image {
        let key = Key(kind: kind, surface: surface, accent: accentKey)
        if let cached = cache[key] { return cached }
        let renderer = ImageRenderer(content: GestureIconView(kind: kind, surface: surface).frame(width: GestureIconView.size.width, height: GestureIconView.size.height))
        renderer.scale = 3
        let image = renderer.nsImage.map { Image(nsImage: $0) } ?? Image(systemName: kind.iconSymbolName)
        cache[key] = image
        return image
    }
}

/// Same glyph language as `GestureIconView`, for the corner-click options:
/// one pad resting just inside the corner inside a soft press halo, and the
/// seed arrow pointing into that corner — the pad is pulled inward so it
/// never covers the arrow.
struct MouseCornerIconView: View {
    let corner: MouseCorner
    var height: CGFloat = 34
    /// Loops: the finger lands in the corner, presses (the halo ripples
    /// out), and lifts. Ignored under Reduce Motion.
    var animated = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var width: CGFloat { height * GestureIconView.aspectRatio }
    static let size = GestureIconView.size

    /// Matches `GestureKind.swipeAngleDegrees`' convention (0 = right, 90
    /// = up, counterclockwise).
    private var angleDegrees: Double {
        switch corner {
        case .topLeft: return 135
        case .topRight: return 45
        case .bottomLeft: return 225
        case .bottomRight: return 315
        }
    }

    var body: some View {
        Group {
            if animated && !reduceMotion {
                TimelineView(.animation) { timeline in
                    let progress = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: GestureIconView.animationPeriod) / GestureIconView.animationPeriod
                    Canvas { canvas, size in draw(&canvas, size: size, progress: progress) }
                }
            } else {
                Canvas { canvas, size in draw(&canvas, size: size, progress: nil) }
            }
        }
        .frame(width: width, height: height)
        .accessibilityElement()
        .accessibilityLabel("Click, \(corner.displayName.lowercased())")
        .accessibilityAddTraits(.isImage)
    }

    private func draw(_ canvas: inout GraphicsContext, size: CGSize, progress: Double?) {
        let motion = GestureIconView.Motion.tapping(progress, presses: 1)
          // One layer, so the arrow's knockout moat cuts only this glyph.
          canvas.drawLayer { context in
            GestureIconView.drawFrame(&context, size: size)
            let layout = GestureIconView.layout(for: .trackpad, fingers: 1, size: size)
            let rect = layout.content
            let dir = GestureIconView.direction(degrees: angleDegrees)
            let cornerPoint = CGPoint(x: rect.midX + dir.dx * rect.width / 2, y: rect.midY + dir.dy * rect.height / 2)
            let inward = size.width * 0.24
            let dot = GestureIconView.clamp(CGPoint(x: cornerPoint.x - dir.dx * inward, y: cornerPoint.y - dir.dy * inward * 0.6), radius: layout.dotRadius, in: rect)
            // A press halo around the pad: this is a click, not a swipe —
            // a soft filled bloom with a crisp rim, like a ripple in water.
            // Still: the halo sits at rest. Animated: it blooms with the press.
            let bloom: CGFloat = motion.isStatic ? 1 : (motion.ripple.map { 0.6 + 0.8 * $0 } ?? 0)
            var pad = context
            pad.opacity = motion.opacity
            if bloom > 0 {
                let ring = layout.dotRadius * 1.75 * bloom
                let fade = motion.isStatic ? 1 : Double(1 - (motion.ripple ?? 1))
                let halo = GestureIconView.blobPath(center: dot, rx: ring, ry: ring, exponent: 2)
                pad.fill(halo, with: .radialGradient(Gradient(colors: [GestureIconView.iconColor.opacity(0.28 * fade), GestureIconView.iconColor.opacity(0.06 * fade)]),
                                                     center: dot, startRadius: layout.dotRadius, endRadius: ring))
                pad.stroke(halo, with: .color(GestureIconView.iconColor.opacity(0.5 * fade)), style: StrokeStyle(lineWidth: max(layout.dotRadius * 0.3, 0.8)))
            }
            let tilt = dir.dx < 0 ? -10.0 : 10.0
            GestureIconView.drawDot(&pad, at: dot, radius: layout.dotRadius * motion.scale, filled: true, tilt: tilt)
            GestureIconView.drawEdgeArrow(&context, degrees: angleDegrees, in: rect, size: size, scale: 0.85)
          }
    }
}

/// Same rasterize-and-cache pattern as `GestureGlyphRenderer`, for the
/// `MouseCornerIconView`s.
enum MouseCornerGlyphRenderer {
    private struct Key: Hashable {
        let corner: MouseCorner
        let accent: String
    }
    private static var cache: [Key: Image] = [:]

    @MainActor
    static func prewarm() {
        for corner in MouseCorner.allCases {
            _ = image(for: corner)
        }
    }

    @MainActor
    static func image(for corner: MouseCorner) -> Image {
        let key = Key(corner: corner, accent: GestureGlyphRenderer.accentKey)
        if let cached = cache[key] { return cached }
        let renderer = ImageRenderer(content: MouseCornerIconView(corner: corner).frame(width: MouseCornerIconView.size.width, height: MouseCornerIconView.size.height))
        renderer.scale = 3
        let image = renderer.nsImage.map { Image(nsImage: $0) } ?? Image(systemName: corner.iconSymbolName)
        cache[key] = image
        return image
    }
}
