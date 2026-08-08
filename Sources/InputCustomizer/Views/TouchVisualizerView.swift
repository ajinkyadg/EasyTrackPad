import SwiftUI

/// Live trackpad-touch + recognized-gesture preview, embedded in
/// `RuleFormView`'s gesture picker so you can see (and try) what you're
/// about to assign to a rule. Reads from the shared `TouchVisualizerModel`
/// that `TrackpadManager` already publishes into while this view is
/// visible — see that model's doc comment for why it's gated behind
/// `isActive` rather than always-on.
///
/// Note: this observes the app's one real, always-running gesture
/// engine — performing a gesture here also triggers any rule you've
/// already configured for it. Toggle "Pause all rules" first if that's
/// not what you want while previewing.
///
/// Layout is a fixed-size two-pane card (touch surface left, info text
/// right, divider between) rather than text stacked below a
/// variable-height box — the previous layout let every text-length
/// change and every appear/disappear of the "Use This Gesture" row
/// change the card's required height, which made the whole sheet visibly
/// resize on every gesture. Every row here reserves fixed space instead,
/// following the same grouped-card-with-dividers language as macOS
/// System Settings / Raycast preferences rather than a free-floating
/// stack of text.
struct TouchVisualizerView: View {
    @EnvironmentObject var visualizerModel: TouchVisualizerModel
    @Binding var selectedGesture: Trigger.GestureKind

    private static let touchingStates: Set<Int32> = [3, 4]
    private static let cardHeight: CGFloat = 200
    private static let surfaceWidth: CGFloat = 170
    private static let infoWidth: CGFloat = 176

    var body: some View {
        HStack(spacing: 0) {
            touchSurface
                .frame(width: Self.surfaceWidth, height: Self.cardHeight)

            Divider()

            infoPanel
                .frame(width: Self.infoWidth, height: Self.cardHeight)
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.secondary.opacity(0.25)))
        .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
        .onAppear { visualizerModel.activate() }
        .onDisappear { visualizerModel.deactivate() }
    }

    private var touchSurface: some View {
        GeometryReader { geometry in
            ZStack {
                // Static colorful preview of whatever the picker is
                // currently set to, filling the box while nothing is
                // actually touching — replaced by real touch dots the
                // instant a finger lands.
                if touchingTouches.isEmpty {
                    GesturePreviewGraphic(kind: selectedGesture)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                }

                ForEach(touchingTouches, id: \.id) { touch in
                    TouchDotView()
                        .position(
                            x: CGFloat(touch.position.x) * geometry.size.width,
                            // Normalized touch y grows upward (matches
                            // GestureRecognizer's "dy > 0 == up"
                            // convention); SwiftUI's y grows downward.
                            y: (1 - CGFloat(touch.position.y)) * geometry.size.height
                        )
                        .transition(.scale(scale: 0.3).combined(with: .opacity))
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .background(
                RadialGradient(
                    colors: [TouchDotView.neonGreen.opacity(0.07), .clear],
                    center: .center, startRadius: 0, endRadius: geometry.size.width * 0.75
                )
            )
            // Scoped to touch *identity* (fingers landing/lifting), never
            // to their per-frame position — animating position tracking
            // is what previously read as "shaky"; a dot popping in/out as
            // a finger actually lands/lifts is a one-time transition, not
            // continuous motion, so it's safe to animate.
            .animation(.spring(response: 0.22, dampingFraction: 0.7), value: touchingTouches.map(\.id))
        }
    }

    private var infoPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("DETECTED")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                // Always present (not conditionally inserted) so this row
                // never changes height — only visibility/enabled state
                // toggles. Explicit reset so trying a different gesture
                // doesn't require waiting out a timer or hoping the next
                // attempt happens to overwrite this one.
                Button {
                    visualizerModel.clearRecognized()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .opacity(visualizerModel.lastGesture == nil ? 0 : 1)
                .disabled(visualizerModel.lastGesture == nil)
                .help("Clear and try a new gesture")
            }
            .padding(.bottom, 4)

            // Fixed-height row regardless of whether a gesture is
            // currently shown, so this content switching doesn't reflow
            // anything below it.
            HStack(spacing: 6) {
                if let gesture = visualizerModel.lastGesture {
                    GestureIconView(kind: gesture, height: 22)
                    Text(gesture.displayName)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(2)
                } else {
                    Image(systemName: "hand.point.up.left")
                        .foregroundStyle(.tertiary)
                    Text("None yet")
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(height: 44, alignment: .top)

            Divider().padding(.vertical, 8)

            Text(statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .frame(height: 32, alignment: .top)

            Spacer(minLength: 8)

            // Always present (not conditionally inserted/removed) so its
            // row never changes the card's height — only its enabled
            // state changes with whether there's a gesture to use.
            Button("Use This Gesture") {
                if let gesture = visualizerModel.lastGesture {
                    selectedGesture = gesture
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(visualizerModel.lastGesture == nil)
            .frame(maxWidth: .infinity)
        }
        .padding(12)
    }

    private var touchingTouches: [MultitouchGestureEngine.Touch] {
        visualizerModel.touches.filter { Self.touchingStates.contains($0.state) }
    }

    private var statusText: String {
        let count = touchingTouches.count
        guard count > 0 else { return "Touch the trackpad to try a gesture." }
        return "\(count) finger\(count == 1 ? "" : "s") down — perform a gesture."
    }
}

/// A live finger-touch dot — neon-green halo (blurred fill + layered
/// glow shadows) and a faint ring around a solid core, rather than a
/// single flat circle. The two stacked `.shadow()` calls at different
/// radii/opacities (on top of the blurred halo circle) is what actually
/// sells the "neon glow" look — a single shadow reads as a flat drop
/// shadow, not a glow.
struct TouchDotView: View {
    static let neonGreen = Color(red: 57.0 / 255, green: 1.0, blue: 20.0 / 255)

    var body: some View {
        ZStack {
            Circle()
                .fill(Self.neonGreen.opacity(0.35))
                .frame(width: 50, height: 50)
                .blur(radius: 9)
            Circle()
                .strokeBorder(Self.neonGreen.opacity(0.55), lineWidth: 2)
                .frame(width: 34, height: 34)
            Circle()
                .fill(Self.neonGreen)
                .frame(width: 22, height: 22)
                .shadow(color: Self.neonGreen.opacity(0.85), radius: 8)
                .shadow(color: Self.neonGreen.opacity(0.5), radius: 16)
        }
        .allowsHitTesting(false)
    }
}
