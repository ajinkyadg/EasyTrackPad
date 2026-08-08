import SwiftUI

/// Small static preview of the currently-selected gesture, drawn in a
/// bold "doodle" style — solid colorful dots for fingertips, a loose
/// rounded outline looping around them, and (for swipes) one big bold
/// arrow for direction. Fills the touch surface box whenever no real
/// touch is happening, replaced instantly by real touch dots the moment
/// a finger lands.
struct GesturePreviewGraphic: View {
    let kind: Trigger.GestureKind

    private static let dotPalette: [Color] = [.blue, .purple, .pink, .orange, .teal]
    private static let strokeColor = Color.accentColor

    var body: some View {
        Canvas { context, size in
            let dots = Self.fingerPositions(count: kind.fingerCount ?? 2, in: size)
            let clusterCenter = Self.center(of: dots, in: size)
            let dotRadius = size.width * 0.1
            // `fingerPositions` returns dots left-to-right, so index 0 is
            // always the left finger — matches `splitSwipeMovingFingerIsLeft`.
            let movingIsLeft = kind.splitSwipeMovingFingerIsLeft

            if let movingIsLeft, dots.count == 2 {
                // Anchor+mover gesture: a loose "both fingers move
                // together" outline would misrepresent it, so skip that
                // and instead ring the anchor finger to show it stays put.
                let anchorIndex = movingIsLeft ? 1 : 0
                Self.drawAnchorRing(&context, at: dots[anchorIndex], radius: dotRadius)
            } else {
                switch kind.category {
                case .pinchIn, .pinchOut:
                    Self.drawPinchArrows(&context, dots: dots, size: size, outward: kind.category == .pinchOut)
                case .rotateClockwise, .rotateCounterClockwise:
                    Self.drawRotateArc(&context, center: clusterCenter, radius: size.width * 0.26, clockwise: kind.category == .rotateClockwise)
                default:
                    break
                }
            }

            if let angle = kind.swipeAngleDegrees {
                if let movingIsLeft, dots.count == 2 {
                    // Trace comes from the finger that actually moves,
                    // not the cluster center, so it's clear which one.
                    Self.drawSwipeTrace(&context, from: dots[movingIsLeft ? 0 : 1], wrapHalfExtent: dotRadius * 1.6, angleDegrees: angle, size: size)
                } else {
                    let wrapHalfExtent = Self.drawWrapOutline(&context, dots: dots, dotRadius: dotRadius, size: size)
                    Self.drawSwipeTrace(&context, from: clusterCenter, wrapHalfExtent: wrapHalfExtent, angleDegrees: angle, size: size)
                }
            } else {
                Self.drawWrapOutline(&context, dots: dots, dotRadius: dotRadius, size: size)
            }

            for (index, point) in dots.enumerated() {
                Self.drawDot(&context, at: point, color: Self.dotPalette[index % Self.dotPalette.count], radius: dotRadius)
            }

            if kind.isDoubleTap, let first = dots.first {
                Self.drawDoubleMark(&context, near: CGPoint(x: first.x + size.width * 0.14, y: first.y - size.width * 0.14), size: size)
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: - Layout

    private static func fingerPositions(count: Int, in size: CGSize) -> [CGPoint] {
        let n = max(count, 1)
        let centerX = size.width * 0.5
        let centerY = size.height * 0.46
        let spacing = min(size.width * 0.16, size.width * 0.56 / CGFloat(max(n - 1, 1)))
        let startX = centerX - CGFloat(n - 1) * spacing / 2
        return (0..<n).map { i in
            let x = n > 1 ? startX + CGFloat(i) * spacing : centerX
            let t = n > 1 ? CGFloat(i) / CGFloat(n - 1) : 0.5
            let arc = sin(t * .pi) * size.height * 0.04 // fingers fan slightly, like a relaxed hand
            return CGPoint(x: x, y: centerY - arc)
        }
    }

    private static func center(of points: [CGPoint], in size: CGSize) -> CGPoint {
        guard !points.isEmpty else { return CGPoint(x: size.width / 2, y: size.height / 2) }
        let sum = points.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
        return CGPoint(x: sum.x / CGFloat(points.count), y: sum.y / CGFloat(points.count))
    }

    // MARK: - Drawing

    private static func drawDot(_ context: inout GraphicsContext, at point: CGPoint, color: Color, radius: CGFloat) {
        let rect = CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
        context.fill(Path(ellipseIn: rect), with: .color(color))
    }

    /// Dashed ring around a finger that stays down as an anchor while
    /// the other one swipes — the "held still" counterpart to the bold
    /// arrow on the moving finger.
    private static func drawAnchorRing(_ context: inout GraphicsContext, at point: CGPoint, radius: CGFloat) {
        let ringRadius = radius * 1.6
        let rect = CGRect(x: point.x - ringRadius, y: point.y - ringRadius, width: ringRadius * 2, height: ringRadius * 2)
        context.stroke(
            Path(ellipseIn: rect),
            with: .color(strokeColor.opacity(0.6)),
            style: StrokeStyle(lineWidth: radius * 0.25, dash: [radius * 0.45, radius * 0.4])
        )
    }

    /// A loose rounded "lasso" around the finger dots — the doodle-style
    /// stand-in for a hand/contact area. Returns half the outline's
    /// longer dimension, so the swipe arrow can start just outside it
    /// instead of overlapping the dots.
    @discardableResult
    private static func drawWrapOutline(_ context: inout GraphicsContext, dots: [CGPoint], dotRadius: CGFloat, size: CGSize) -> CGFloat {
        guard !dots.isEmpty else { return 0 }
        let padX = dotRadius * 1.5
        let padY = dotRadius * 1.9
        let minX = (dots.map(\.x).min() ?? 0) - padX
        let maxX = (dots.map(\.x).max() ?? 0) + padX
        let minY = (dots.map(\.y).min() ?? 0) - padY
        let maxY = (dots.map(\.y).max() ?? 0) + padY
        let rect = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        let path = Path(roundedRect: rect, cornerRadius: min(rect.width, rect.height) / 2)
        context.stroke(path, with: .color(strokeColor), style: StrokeStyle(lineWidth: dotRadius * 0.5, lineCap: .round, lineJoin: .round))
        return max(rect.width, rect.height) / 2
    }

    /// A fading motion trace instead of an arrowhead — a single gradient
    /// line running from just outside the finger cluster to the landing
    /// point, dark near the hand and fading out along the direction of
    /// travel, capped with a solid glowing dot at the tip (same idea as
    /// `GestureIconView`'s small trail, scaled up, with a soft halo
    /// behind it to match this graphic's bolder style). Screen y grows
    /// downward while `swipeAngleDegrees` follows `GestureRecognizer`'s
    /// atan2(dy, dx) convention (dy > 0 = up) — flip the y component
    /// here, same as `TouchVisualizerView`'s live dots.
    private static func drawSwipeTrace(_ context: inout GraphicsContext, from clusterCenter: CGPoint, wrapHalfExtent: CGFloat, angleDegrees: Double, size: CGSize) {
        let radians = angleDegrees * .pi / 180
        let dir = CGVector(dx: cos(radians), dy: -sin(radians))

        let start = CGPoint(x: clusterCenter.x + dir.dx * wrapHalfExtent, y: clusterCenter.y + dir.dy * wrapHalfExtent)
        let traceLength = size.width * 0.34
        let end = CGPoint(x: start.x + dir.dx * traceLength, y: start.y + dir.dy * traceLength)
        let lineWidth = size.width * 0.05
        let dotRadius = size.width * 0.075

        var trace = Path()
        trace.move(to: start)
        trace.addLine(to: end)
        let gradient = Gradient(colors: [strokeColor.opacity(0.04), strokeColor.opacity(0.95)])

        func haloRect(scale: CGFloat) -> CGRect {
            let r = dotRadius * scale
            return CGRect(x: end.x - r, y: end.y - r, width: r * 2, height: r * 2)
        }

        // Soft halo behind the trace + landing dot — same layered-glow
        // technique as TouchDotView's neon touch dots (stacking one blur
        // reads as a flat smear; two at different radii reads as an
        // actual glow falloff).
        context.drawLayer { ctx in
            ctx.addFilter(.blur(radius: size.width * 0.02))
            ctx.stroke(trace, with: .linearGradient(gradient, startPoint: start, endPoint: end), style: StrokeStyle(lineWidth: lineWidth * 1.6, lineCap: .round))
            ctx.fill(Path(ellipseIn: haloRect(scale: 1.6)), with: .color(strokeColor.opacity(0.5)))
        }
        context.drawLayer { ctx in
            ctx.addFilter(.blur(radius: size.width * 0.045))
            ctx.stroke(trace, with: .linearGradient(gradient, startPoint: start, endPoint: end), style: StrokeStyle(lineWidth: lineWidth * 2.1, lineCap: .round))
            ctx.fill(Path(ellipseIn: haloRect(scale: 2.1)), with: .color(strokeColor.opacity(0.3)))
        }

        context.stroke(trace, with: .linearGradient(gradient, startPoint: start, endPoint: end), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
        context.fill(Path(ellipseIn: haloRect(scale: 1)), with: .color(strokeColor))
    }

    private static func drawPinchArrows(_ context: inout GraphicsContext, dots: [CGPoint], size: CGSize, outward: Bool) {
        guard dots.count >= 2 else { return }
        let a = dots[0], b = dots[dots.count - 1]
        let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        for point in [a, b] {
            let towardMid = CGVector(dx: mid.x - point.x, dy: mid.y - point.y)
            let length = max(hypot(towardMid.dx, towardMid.dy), 1)
            let unit = CGVector(dx: towardMid.dx / length, dy: towardMid.dy / length)
            let reach = size.width * 0.14
            let from = outward ? CGPoint(x: point.x + unit.dx * reach, y: point.y + unit.dy * reach) : point
            let to = outward ? point : CGPoint(x: point.x + unit.dx * reach, y: point.y + unit.dy * reach)
            var path = Path()
            path.move(to: from)
            path.addLine(to: to)
            context.stroke(path, with: .color(strokeColor), style: StrokeStyle(lineWidth: size.width * 0.045, lineCap: .round))
        }
    }

    private static func drawRotateArc(_ context: inout GraphicsContext, center: CGPoint, radius: CGFloat, clockwise: Bool) {
        var path = Path()
        let startAngle = Angle.degrees(clockwise ? -40 : 220)
        let endAngle = Angle.degrees(clockwise ? 220 : -40)
        path.addArc(center: center, radius: radius, startAngle: startAngle, endAngle: endAngle, clockwise: !clockwise)
        context.stroke(path, with: .color(strokeColor), style: StrokeStyle(lineWidth: radius * 0.22, lineCap: .round))
    }

    private static func drawDoubleMark(_ context: inout GraphicsContext, near point: CGPoint, size: CGSize) {
        let text = context.resolve(Text("×2").font(.system(size: size.width * 0.11, weight: .bold)).foregroundColor(.white))
        let textSize = text.measure(in: CGSize(width: size.width, height: size.height))
        let badgeRect = CGRect(
            x: point.x - textSize.width / 2 - 4,
            y: point.y - textSize.height / 2 - 2,
            width: textSize.width + 8,
            height: textSize.height + 4
        )
        context.fill(Path(roundedRect: badgeRect, cornerRadius: badgeRect.height / 2), with: .color(.orange))
        context.draw(text, at: point)
    }
}
