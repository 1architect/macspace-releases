import MacSpacePlatform
import SwiftUI

/// Cleanup in one section: automatic cleanup (on or off, how often, which modules take part), then what has been freed so far and a
/// row that opens the page of every cleanup (`CleanupHistoryPage`).
struct CleanupSection: View {
    @ObservedObject var cleaner: AutoCleaner
    @ObservedObject var host: ModuleHost
    @State private var count = CleanupHistory.shared.entries.count
    @State private var lifetime = CleanupHistory.shared.lifetimeBytes

    private var takingPart: [String] {
        host.activeHandles.filter { $0.manifest.autoClean == true }.map(\.manifest.name)
    }

    var body: some View {
        Section("Cleanup") {
            Toggle("Clean automatically", isOn: $cleaner.isEnabled)
                .help("While MacSpace runs (its window or the menu bar), it frees what is safe to free without asking: caches, old reports, purgeable app files and released system assets. Never version history or anything that cannot be undone. Modules taking part: \(takingPart.isEmpty ? "none" : takingPart.joined(separator: ", ")).")
            if cleaner.isEnabled {
                Picker("How often", selection: $cleaner.frequency) {
                    ForEach(AutoCleaner.Frequency.allCases) { Text($0.title).tag($0) }
                }
            }
            LabeledContent("Freed in total") {
                Text(ByteFormat.string(lifetime)).monospacedDigit().contentTransition(.numericText())
            }
            .help("Everything MacSpace has freed on this Mac, measured on the volume each time.")
            SettingsLinkRow(title: "Recent cleanups", note: count == 1 ? "1 cleanup" : "\(count) cleanups") { host.settingsPage = .cleanupHistory }
        }
        .onReceive(NotificationCenter.default.publisher(for: CleanupHistory.didChange)) { _ in
            withAnimation(Theme.value) {
                count = CleanupHistory.shared.entries.count
                lifetime = CleanupHistory.shared.lifetimeBytes
            }
        }
    }
}

/// A row that opens a page over Settings, with a chevron.
struct SettingsLinkRow: View {
    let title: String
    let note: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                TitleLine(title: title, note: note)
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Every cleanup, newest first: the module, when and how it started beside it, and the space freed.
struct CleanupHistoryPage: View {
    @State private var entries = CleanupHistory.shared.entries
    @State private var lifetime = CleanupHistory.shared.lifetimeBytes
    @Environment(\.design) private var design

    var body: some View {
        Form {
            Section {
                if entries.isEmpty {
                    Text("Nothing cleaned yet.").foregroundStyle(.secondary)
                }
                ForEach(entries) { entry in
                    HStack {
                        TitleLine(title: entry.moduleName, note: "\(entry.date.formatted(date: .abbreviated, time: .shortened)) · \(Self.trigger(entry.trigger))")
                        Spacer(minLength: 8)
                        Text(ByteFormat.string(entry.freedBytes)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .help(entry.summary)
                }
            } header: {
                TitleLine(title: "Recent cleanups", note: "\(ByteFormat.string(lifetime)) freed in total")
            }
            PageBottomRoom()
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .modifier(PageScrollArea(hasFooter: false))
        .environment(\.colorScheme, design.colorScheme)
        // Settings is drawn on the slate tile's color.
        .environment(\.pageGround, design.palette(.slate).base)
        .onReceive(NotificationCenter.default.publisher(for: CleanupHistory.didChange)) { _ in
            withAnimation(Theme.layout) {
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
