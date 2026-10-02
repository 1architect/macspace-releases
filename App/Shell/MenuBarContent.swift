import MacSpaceSdk
import SwiftUI

/// The menu bar item: one line per active module, taken from its dashboard tile.
public struct MenuBarContent: View {
    @ObservedObject var host: ModuleHost
    @Environment(\.openWindow) private var openWindow

    public init(host: ModuleHost) {
        self.host = host
    }

    public var body: some View {
        ForEach(host.activeHandles) { handle in
            Label(handle.tile.map { "\(handle.manifest.name): \($0.status)" } ?? handle.manifest.name, systemImage: handle.manifest.symbol)
        }
        if host.activeHandles.isEmpty { Text("No modules are on") }
        Divider()
        Button("Open MacSpace") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("Quit MacSpace") { NSApp.terminate(nil) }
    }
}
