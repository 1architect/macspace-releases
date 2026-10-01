import MacSpaceSdk
import SwiftUI

/// The menu bar item: one line per active module, taken from the summary each module already provides.
public struct MenuBarContent: View {
    @ObservedObject var host: ModuleHost
    @Environment(\.openWindow) private var openWindow

    public init(host: ModuleHost) {
        self.host = host
    }

    static func headline(_ widget: ScreenWidget?) -> String? {
        switch widget {
        case let .banner(banner)?: return banner.title
        case let .usage(usage)?: return [usage.title, usage.footnote].compactMap { $0 }.joined(separator: ": ")
        case let .text(text)?: return text.text
        default: return nil
        }
    }

    public var body: some View {
        ForEach(host.activeHandles) { handle in
            Label(Self.headline(handle.summary).map { "\(handle.manifest.name): \($0)" } ?? handle.manifest.name, systemImage: handle.manifest.symbol)
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
