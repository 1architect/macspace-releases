import MacSpaceSdk
import SwiftUI

/// The window ids, and which one MacSpace uses: the glass window (`MainView`) or a standard macOS window with a sidebar
/// (`StandardWindowView`), chosen with the Standard Window switch in Settings > Design.
public enum MacSpaceWindow {
    public static let glass = "main"
    public static let standard = "standard"

    @MainActor public static var current: String { DesignSettings.shared.standardWindow ? standard : glass }
}

/// Keeps the window that is open the one the Standard Window switch asks for: when it changes, or when the other window was the
/// one opened (at launch, or from the menu bar), the right one opens and this one closes.
struct WindowKindSwitch: ViewModifier {
    let id: String
    @ObservedObject private var settings = DesignSettings.shared
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    func body(content: Content) -> some View {
        content
            .onAppear(perform: follow)
            .onChange(of: settings.standardWindow) { _, _ in follow() }
    }

    private func follow() {
        let wanted = MacSpaceWindow.current
        guard wanted != id else { return }
        // The other window first: closing the last window could quit the app.
        openWindow(id: wanted)
        dismissWindow(id: id)
    }
}

/// The dashboard and the pages in a standard macOS window: a sidebar with the overview, the modules and Settings, and the selected
/// one beside it. The tiles are the dashboard's own; a tile opens its page in the sidebar's selection instead of zooming.
public struct StandardWindowView: View {
    @ObservedObject var host: ModuleHost
    @ObservedObject var updates: UpdateController
    @StateObject private var storage = StorageOverview()
    @ObservedObject private var designSettings = DesignSettings.shared
    @ObservedObject private var remote = DebugRemote.shared
    @State private var selection: Destination? = .home

    public init(host: ModuleHost, updates: UpdateController) {
        self.host = host
        self.updates = updates
    }

    public var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Label("Overview", systemImage: "square.grid.2x2").tag(Destination.home)
                Section("Modules") {
                    ForEach(host.dashboardHandles) { handle in
                        Label(handle.manifest.name, systemImage: handle.manifest.symbol).tag(Destination.module(handle.id))
                    }
                }
                Label("Settings", systemImage: "gearshape").tag(Destination.settings)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } detail: {
            detail
        }
        .environment(\.design, designSettings.design)
        // The window takes the palette's appearance (dark grounds, dark chrome), so its toolbar and sidebar match the pages.
        .preferredColorScheme(designSettings.design.colorScheme)
        .frame(minWidth: Theme.minimumSize.width + 200, minHeight: Theme.minimumSize.height)
        .task { await host.start() }
        .task { await storage.refresh() }
        .modifier(WindowKindSwitch(id: MacSpaceWindow.standard))
        .onChange(of: remote.command?.id) { _, _ in
            guard let text = remote.command?.text else { return }
            if text == "open:settings" { open(.settings) }
            else if text == "back" || text == "close" { selection = .home }
            else if text.hasPrefix("open:"), text != "open:colorLab" { open(.module(String(text.dropFirst(5)))) }
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch selection ?? .home {
        case .home, .storage:
            HomeView(host: host, storage: storage, open: open)
                .padding(Theme.frame)
                .coordinateSpace(name: ZoomSpace.name)
                .navigationTitle("MacSpace")
        case let .module(id):
            if let handle = host.handle(for: id) {
                let tint = HomeView.tiles(for: host.dashboardHandles).first { $0.destination == .module(id) }?.tint ?? .slate
                ScreenView(handle: handle, tint: tint)
                    .environment(\.pageScrollTop, 8)
                    .background { TileBackdrop(tint: tint, cornerRadius: 0).ignoresSafeArea() }
                    .id(id)
                    .navigationTitle(handle.manifest.name)
                    .toolbar {
                        ToolbarItem {
                            Button { Task { await handle.refresh(reload: true) } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                                .disabled(handle.isBusy)
                        }
                    }
            }
        case .settings:
            // On its tile's ground, as in the glass window, where the page is drawn on the tile it grew from.
            SettingsPages(host: host, updates: updates)
                .environment(\.pageScrollTop, 8)
                .background { TileBackdrop(tint: .slate, cornerRadius: 0).ignoresSafeArea() }
                .navigationTitle(host.settingsPage == .cleanupHistory ? "Recent cleanups" : "Settings")
        }
    }

    /// A tile clicked on the overview selects its page.
    private func open(_ destination: Destination) {
        guard destination != .home, destination != .storage else { return }
        if destination == .settings { host.settingsPage = nil }
        selection = destination
    }
}
