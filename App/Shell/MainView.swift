import MacSpaceSdk
import SwiftUI

public enum Destination: Hashable {
    case home
    case module(String)
    case settings
}

/// The window: a sidebar of the active modules, the home dashboard, and Settings.
public struct MainView: View {
    @ObservedObject var host: ModuleHost
    @State private var selection: Destination? = .home

    public init(host: ModuleHost) {
        self.host = host
    }

    public var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Label("Home", systemImage: "square.grid.2x2").tag(Destination.home)
                Section("Modules") {
                    ForEach(host.activeHandles) { handle in
                        Label(handle.manifest.name, systemImage: handle.manifest.symbol).tag(Destination.module(handle.id))
                    }
                }
                Section {
                    Label("Settings", systemImage: "gearshape").tag(Destination.settings)
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
        } detail: {
            switch selection ?? .home {
            case .home: HomeView(host: host) { selection = .module($0) }
            case let .module(id):
                if let handle = host.handle(for: id) { ScreenView(handle: handle) } else { ContentUnavailableView("Module not found", systemImage: "questionmark.folder") }
            case .settings: SettingsView(host: host)
            }
        }
        .frame(minWidth: 860, minHeight: 560)
        .task { await host.reload() }
    }
}
