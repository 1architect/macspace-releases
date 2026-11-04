import MacSpaceSdk
import SwiftUI

/// The owning module supplies refresh and action execution to every graph, including dashboard graphs and lazy pages.
@MainActor
struct GraphInteraction {
    let handle: ModuleHandle

    var busy: Bool { handle.isReloading || handle.isCleaning }

    func refresh() async { await handle.refresh(reload: true) }

    func delete(_ action: Action) async {
        guard ConfirmationAlert.ask(action) else { return }
        _ = await handle.perform(action)
    }
}

extension EnvironmentValues {
    @Entry var graphInteraction: GraphInteraction?
    @Entry var graphContextMenusEnabled = true
}

/// Modules may omit confirmation metadata, but can never omit confirmation for a graph's Delete command.
enum GraphMenuPolicy {
    static func deletion(_ action: Action?, label: String) -> Action? {
        guard var action else { return nil }
        action.title = String(localized: "Delete")
        action.role = .destructive
        if action.confirmation == nil {
            action.confirmation = Confirmation(title: String(localized: "Delete \(label)?"),
                message: String(localized: "Confirm deletion of this item."), confirmTitle: String(localized: "Delete"))
        }
        return action
    }
}

private struct GraphContextMenu: ViewModifier {
    let label: String
    let actions: GraphContextActions?
    var enabled = true
    @Environment(\.graphContextMenusEnabled) private var graphMenusEnabled
    @Environment(\.graphInteraction) private var interaction

    func body(content: Content) -> some View {
        if enabled && graphMenusEnabled, let interaction {
            content.contextMenu {
                let paths = (actions?.paths ?? []).filter { $0.hasPrefix("/") && FileManager.default.fileExists(atPath: $0) }
                if !paths.isEmpty {
                    Button {
                        let existing = paths.filter { FileManager.default.fileExists(atPath: $0) }
                        RevealTarget.show(existing.map { URL(fileURLWithPath: $0) })
                    } label: { Label(String(localized: "Open in Finder"), systemImage: "folder") }
                }
                if let action = GraphMenuPolicy.deletion(actions?.delete, label: label) {
                    Button(role: .destructive) {
                        Task { await interaction.delete(action) }
                    } label: { Label(String(localized: "Delete"), systemImage: "trash") }
                    .disabled(interaction.busy)
                }
                Button {
                    Task { await interaction.refresh() }
                } label: { Label(String(localized: "Refresh"), systemImage: "arrow.clockwise") }
                .disabled(interaction.busy)
            }
        } else { content }
    }
}

extension View {
    func graphContextMenu(label: String, actions: GraphContextActions? = nil, enabled: Bool = true) -> some View {
        modifier(GraphContextMenu(label: label, actions: actions, enabled: enabled))
    }
}
