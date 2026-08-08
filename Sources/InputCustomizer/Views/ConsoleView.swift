import SwiftUI

/// Live, color-coded activity feed — the in-app replacement for having to
/// run the binary from a terminal to see `NSLog` output. Fed by
/// `ActivityLog`, which every manager writes to on an actual gesture/key/
/// button match (never on every raw event — see each manager's `handle`
/// for why that matters, especially for keyboard).
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
                Text("Console").font(.headline)
                Spacer()
                Button("Clear") { activityLog.clear() }
                    .font(.caption)
                    .disabled(activityLog.entries.isEmpty)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        if activityLog.entries.isEmpty {
                            Text("Perform a gesture, key combo, or mouse button to see it here.")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .padding(12)
                        }
                        ForEach(activityLog.entries) { entry in
                            entryRow(entry).id(entry.id)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                }
                .onChange(of: activityLog.entries.last?.id) { lastID in
                    guard let lastID else { return }
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(lastID, anchor: .bottom)
                    }
                }
            }
        }
        .background(Color.black.opacity(0.03))
    }

    @ViewBuilder
    private func entryRow(_ entry: ActivityLog.Entry) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(Self.timeFormatter.string(from: entry.timestamp))
                .foregroundStyle(.tertiary)
            Text(entry.kind.rawValue + ":")
                .foregroundStyle(color(for: entry.kind))
                .fontWeight(.semibold)
            Text(entry.message)
                .foregroundStyle(.primary)
        }
        .font(.system(size: 11, design: .monospaced))
        .textSelection(.enabled)
    }

    private func color(for kind: ActivityLog.Kind) -> Color {
        switch kind {
        case .detected: return .blue
        case .fired: return .orange
        case .executing: return .green
        case .info: return .secondary
        }
    }
}
