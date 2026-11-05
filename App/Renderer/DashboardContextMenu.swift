import MacSpaceSdk
import SwiftUI

/// The dashboard has one module menu over the entire tile, including its graph, caption, switch and empty ground.
struct DashboardContextMenu: ViewModifier {
    let handle: ModuleHandle?
    var refreshStorage: (@MainActor () async -> Void)?

    func body(content: Content) -> some View {
        if let handle {
            content.contextMenu { DashboardMenu(handle: handle, refreshStorage: refreshStorage) }
        } else { content }
    }
}

private struct DashboardMenu: View {
    @ObservedObject var handle: ModuleHandle
    let refreshStorage: (@MainActor () async -> Void)?

    var body: some View {
        Button {
            Task {
                await handle.refresh(reload: true)
                await refreshStorage?()
            }
        } label: { Label(String(localized: "Refresh"), systemImage: "arrow.clockwise") }
        .disabled(handle.isReloading || handle.isCleaning)

    }
}
