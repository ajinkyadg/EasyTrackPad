import SwiftUI

/// Live activity feed — the in-app replacement for having to run the
/// binary from a terminal to see `NSLog` output. Fed by `ActivityLog`,
/// which every manager writes to on an actual gesture/key/button match
/// (never on every raw event — see each manager's `handle` for why that
/// matters, especially for keyboard). Hidden by default; shown as a
/// trailing pane from the settings window's "Activity" toolbar toggle.
struct ConsoleView: View {
    @EnvironmentObject var activityLog: ActivityLog

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Activity").font(.headline)
                Spacer()
                Button {
                    activityLog.clear()
                } label: {
                    Label("Clear", systemImage: "trash")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .disabled(activityLog.entries.isEmpty)
                .help("Clear activity")
                .accessibilityLabel("Clear activity")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            if activityLog.entries.isEmpty {
                emptyState
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(activityLog.entries) { entry in
                                entryRow(entry).id(entry.id)
                            }
                        }
                        .padding(12)
                    }
                    .onChange(of: activityLog.entries.last?.id) { lastID in
                        guard let lastID else { return }
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo(lastID, anchor: .bottom)
                        }
                    }
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "waveform.path.ecg")
                .font(.title)
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Text("No activity yet")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Perform a gesture, key combo, or mouse click to see it here.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func entryRow(_ entry: ActivityLog.Entry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol(for: entry.kind))
                .foregroundStyle(tint(for: entry.kind))
                .frame(width: 16)
                .help(entry.kind.rawValue)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.message)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(entry.kind.rawValue) · \(Self.timeFormatter.string(from: entry.timestamp))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
        .accessibilityElement(children: .combine)
    }

    /// The symbol shape — not just its color — distinguishes each kind,
    /// so the feed still reads correctly for color-blind users.
    private func symbol(for kind: ActivityLog.Kind) -> String {
        switch kind {
        case .detected: return "hand.point.up.left"
        case .fired: return "bolt"
        case .executing: return "play.circle"
        case .info: return "info.circle"
        }
    }

    private func tint(for kind: ActivityLog.Kind) -> Color {
        switch kind {
        case .detected: return .accentColor
        case .fired: return .orange
        case .executing: return .green
        case .info: return .secondary
        }
    }
}
