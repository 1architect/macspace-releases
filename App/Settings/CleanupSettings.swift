import MacSpacePlatform
import SwiftUI

/// Automatic cleanup: on or off, how often, which modules take part, and when it last ran.
struct AutoCleanSection: View {
    @ObservedObject var cleaner: AutoCleaner
    @ObservedObject var host: ModuleHost

    private var takingPart: [String] {
        host.activeHandles.filter { $0.manifest.autoClean == true }.map(\.manifest.name)
    }

    var body: some View {
        Section("Automatic cleanup") {
            Toggle("Clean automatically", isOn: $cleaner.isEnabled)
                .help("While MacSpace runs (its window or the menu bar), it frees what is safe to free without asking: caches, old reports, purgeable app files and released system assets. Never version history or anything that cannot be undone.")
            if cleaner.isEnabled {
                Picker("How often", selection: $cleaner.frequency) {
                    ForEach(AutoCleaner.Frequency.allCases) { Text($0.title).tag($0) }
                }
            }
            LabeledContent("Modules") {
                Text(takingPart.isEmpty ? "None is on" : takingPart.joined(separator: ", ")).foregroundStyle(.secondary).lineLimit(1)
            }
            HStack {
                TitleLine(title: "Last run", note: lastRunText)
                Spacer()
                if cleaner.isRunning { ProgressView().controlSize(.small) }
                Button("Clean Now") { Task { await cleaner.runNow() } }.disabled(cleaner.isRunning || takingPart.isEmpty)
            }
        }
    }

    private var lastRunText: String {
        guard let lastRun = cleaner.lastRun else { return "never" }
        let when = lastRun.formatted(.relative(presentation: .named))
        return cleaner.lastFreed.map { "\(when), freed \(ByteFormat.string($0))" } ?? when
    }
}

/// Every cleanup MacSpace made, with the lifetime total on top.
struct CleanupHistorySection: View {
    @State private var entries = CleanupHistory.shared.entries
    @State private var lifetime = CleanupHistory.shared.lifetimeBytes
    @State private var expanded = false

    var body: some View {
        Section("Cleanup history") {
            LabeledContent("Freed in total") {
                Text(ByteFormat.string(lifetime)).monospacedDigit().contentTransition(.numericText())
            }
            .help("Everything MacSpace has freed on this Mac, measured on the volume each time.")
            if entries.isEmpty {
                Text("Nothing cleaned yet.").foregroundStyle(.secondary)
            } else {
                DisclosureGroup(isExpanded: $expanded) {
                    ForEach(entries.prefix(50)) { entry in
                        HStack {
                            TitleLine(title: entry.moduleName, note: "\(entry.date.formatted(date: .abbreviated, time: .shortened)) · \(Self.trigger(entry.trigger))")
                            Spacer(minLength: 8)
                            Text(ByteFormat.string(entry.freedBytes)).monospacedDigit().foregroundStyle(.secondary)
                        }
                        .help(entry.summary)
                    }
                } label: {
                    TitleLine(title: "Recent cleanups", note: entries.count == 1 ? "1 cleanup" : "\(entries.count) cleanups")
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: CleanupHistory.didChange)) { _ in
            withAnimation(Theme.value) {
                entries = CleanupHistory.shared.entries
                lifetime = CleanupHistory.shared.lifetimeBytes
            }
        }
    }

    static func trigger(_ trigger: CleanupHistory.Trigger) -> String {
        switch trigger {
        case .manual: return "by you"
        case .automatic: return "automatic"
        case .background: return "finished by MacSpace"
        }
    }
}
