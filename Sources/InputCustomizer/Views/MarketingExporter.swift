#if DEBUG
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import GestureEngine
import InputModels

/// Renders the Gumroad marketing GIFs and hero from the real glyph drawing
/// code: `swift run InputCustomizer --export-marketing <dir>`. Needs ffmpeg.
@MainActor
enum MarketingExporter {
    static let brandIndigo = NSColor(srgbRed: 0x4A / 255, green: 0x3F / 255, blue: 0xE0 / 255, alpha: 1)
    static let fps = 20
    static let gestureSeconds = 3.0
    static let gestureCanvas = CGSize(width: 640, height: 516)
    static let heroCanvas = CGSize(width: 1280, height: 640)
    static let background = Color(white: 1)

    static let gestures: [(name: String, kind: Trigger.GestureKind, surface: GlyphSurface)] = [
        ("smoogler-next-tab", .threeFingerSwipeRight, .trackpad),
        ("smoogler-previous-tab", .threeFingerSwipeLeft, .trackpad),
        ("three-finger-swipe-up", .threeFingerSwipeUp, .trackpad),
        ("four-finger-swipe-up", .fourFingerSwipeUp, .trackpad),
        ("three-finger-tap", .threeFingerTap, .trackpad),
        ("three-finger-double-tap", .threeFingerDoubleTap, .trackpad),
        ("pinch-in", .pinchIn, .trackpad),
        ("pinch-out", .pinchOut, .trackpad),
        ("rotate-clockwise", .rotateClockwise, .trackpad),
        ("fast-scroll-to-bottom", .twoFingerFastScrollToBottomEdge, .trackpad),
        ("split-swipe-left-finger-up", .twoFingerLeftSwipeUp, .trackpad),
        ("split-swipe-left-finger-down", .twoFingerLeftSwipeDown, .trackpad),
        ("split-tap-right-finger", .twoFingerRightTap, .trackpad),
        ("magic-mouse-swipe-right", .twoFingerSwipeRight, .mouse),
        ("magic-mouse-split-swipe-up", .twoFingerLeftSwipeUp, .mouse),
    ]

    /// Returns true when the export flag was passed (the caller then quits).
    static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard let flag = args.firstIndex(of: "--export-marketing") else { return false }
        let dir = URL(fileURLWithPath: args.count > flag + 1 ? args[flag + 1] : "Assets/Marketing", isDirectory: true)
        GestureIconView.colorOverride = brandIndigo
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let frames = Int(gestureSeconds * Double(fps))
            for g in gestures {
                try writeGIF(dir.appendingPathComponent("\(g.name).gif"), size: gestureCanvas, frames: frames) { progress in
                    AnyView(gestureFrame(g.kind, surface: g.surface, progress: progress))
                }
            }
            let heroFrames = frames * 2
            try writeGIF(dir.appendingPathComponent("smoogler-hero.gif"), size: heroCanvas, frames: heroFrames) { progress in
                AnyView(HeroFrame(progress: progress))
            }
            // A still for the Gumroad cover, caught mid-travel.
            try writePNG(render(AnyView(HeroFrame(progress: 0.3)), size: heroCanvas), to: dir.appendingPathComponent("smoogler-hero.png"))
            print("Exported marketing assets to \(dir.path)")
        } catch {
            fputs("Marketing export failed: \(error)\n", stderr)
            exit(1)
        }
        return true
    }

    static func gestureFrame(_ kind: Trigger.GestureKind, surface: GlyphSurface, progress: Double) -> some View {
        let glyphHeight = gestureCanvas.height * 0.9
        return ZStack {
            background
            Canvas { context, size in
                GestureIconView.draw(kind, surface: surface, in: &context, size: size, progress: progress)
            }
            .frame(width: glyphHeight * GestureIconView.aspectRatio, height: glyphHeight)
        }
        .frame(width: gestureCanvas.width, height: gestureCanvas.height)
    }

    static func render(_ view: AnyView, size: CGSize) -> CGImage? {
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height))
        renderer.scale = 1
        return renderer.cgImage
    }

    static func writePNG(_ image: CGImage?, to url: URL) throws {
        guard let image, let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
    }

    static func writeGIF(_ url: URL, size: CGSize, frames: Int, frame: (Double) -> AnyView) throws {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        for i in 0..<frames {
            try writePNG(render(frame(Double(i) / Double(frames)), size: size),
                         to: work.appendingPathComponent(String(format: "f%04d.png", i)))
        }
        let ffmpeg = Process()
        ffmpeg.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        ffmpeg.arguments = [
            "ffmpeg", "-v", "error", "-y", "-framerate", "\(fps)",
            "-i", work.appendingPathComponent("f%04d.png").path,
            "-filter_complex", "split[a][b];[a]palettegen=stats_mode=full:reserve_transparent=0[p];[b][p]paletteuse=dither=sierra2_4a",
            "-loop", "0", url.path,
        ]
        try ffmpeg.run()
        ffmpeg.waitUntilExit()
        guard ffmpeg.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
        print("  \(url.lastPathComponent)")
    }
}

/// The hero: a 3-finger swipe on the left, a browser tab strip on the right
/// whose active tab follows the fingers — right through three tabs, then
/// back. Generic browser chrome, no real product's look.
private struct HeroFrame: View {
    let progress: Double

    private static let tabCount = 5
    private static let hops = 3
    private var indigo: Color { Color(nsColor: MarketingExporter.brandIndigo) }

    /// First half swipes right, second half swipes left.
    private var forward: Bool { progress < 0.5 }
    private var localProgress: Double { forward ? progress * 2 : (progress - 0.5) * 2 }

    /// Continuous active-tab position, stepping as the fingers travel —
    /// the same "one tab per stretch of travel" feel as repeatsByDistance.
    private var tabPosition: CGFloat {
        let travel = GestureIconView.Motion.moving(localProgress).travel
        let thresholds: [CGFloat] = [0.22, 0.52, 0.82]
        let stepped = thresholds.reduce(CGFloat(0)) { sum, t in
            let x = min(max((travel - t) / 0.08, 0), 1)
            return sum + x * x * (3 - 2 * x)
        }
        return forward ? stepped : CGFloat(Self.hops) - stepped
    }

    var body: some View {
        let size = MarketingExporter.heroCanvas
        HStack(spacing: 64) {
            Canvas { context, canvasSize in
                GestureIconView.draw(forward ? .threeFingerSwipeRight : .threeFingerSwipeLeft, surface: .trackpad,
                                     in: &context, size: canvasSize, progress: localProgress)
            }
            .frame(width: 300 * GestureIconView.aspectRatio, height: 300)
            browser
        }
        .frame(width: size.width, height: size.height)
        .background(Color(red: 0.965, green: 0.965, blue: 0.98))
    }

    private var browser: some View {
        let tabWidth: CGFloat = 112, stripHeight: CGFloat = 46
        let active = Int(tabPosition.rounded())
        return VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                Color(white: 0.925)
                HStack(spacing: 7) {
                    ForEach(0..<3) { _ in Circle().fill(Color(white: 0.78)).frame(width: 11, height: 11) }
                }
                .padding(.leading, 16).padding(.top, 17)
                // The active tab's sheet slides under the labels.
                // Overhangs into the (white) page so only its top corners show rounded.
                RoundedRectangle(cornerRadius: 9)
                    .fill(Color.white)
                    .frame(width: tabWidth, height: stripHeight)
                    .offset(x: 84 + tabPosition * tabWidth, y: 8)
                HStack(spacing: 0) {
                    ForEach(0..<Self.tabCount, id: \.self) { i in
                        let weight = max(0, 1 - abs(tabPosition - CGFloat(i)))
                        HStack(spacing: 8) {
                            Circle().fill(indigo.opacity(0.25 + 0.75 * weight)).frame(width: 12, height: 12)
                            Capsule().fill(Color(white: 0.55 - 0.25 * weight)).frame(width: 52 - CGFloat(i % 2) * 12, height: 7)
                        }
                        .frame(width: tabWidth, height: stripHeight - 8)
                    }
                }
                .offset(x: 84, y: 8)
            }
            .frame(height: stripHeight)
            page(for: active)
        }
        .frame(width: 680, height: 420)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.black.opacity(0.08)))
        .shadow(color: .black.opacity(0.12), radius: 24, y: 12)
    }

    /// Each tab gets a different page layout so a switch is visible at a glance.
    private func page(for tab: Int) -> some View {
        let widths: [[CGFloat]] = [[0.8, 0.6, 0.7], [0.5, 0.9, 0.4], [0.7, 0.45, 0.85], [0.6, 0.75, 0.5], [0.85, 0.5, 0.65]]
        let blockHeights: [CGFloat] = [120, 90, 150, 70, 110]
        return VStack(alignment: .leading, spacing: 16) {
            RoundedRectangle(cornerRadius: 10)
                .fill(indigo.opacity(0.08 + 0.04 * Double(tab % 3)))
                .frame(height: blockHeights[tab % 5])
            ForEach(0..<3, id: \.self) { row in
                Capsule().fill(Color(white: 0.88)).frame(width: 600 * widths[tab % 5][row], height: 12)
            }
            Spacer(minLength: 0)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.white)
    }
}
#endif
