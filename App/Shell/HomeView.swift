import MacSpaceSdk
import SwiftUI

/// The dashboard: one tile per active module, each showing the summary widget the module provides.
struct HomeView: View {
    @ObservedObject var host: ModuleHost
    /// Where each tile's parts are, for the zoom into a module.
    var tiles = TileFrames()
    let open: (String) -> Void
    /// The tile that is being replaced by the zoom; it is not drawn so it does not show through.
    var hiddenTile: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if host.activeHandles.isEmpty {
                    ContentUnavailableView {
                        Label("No modules are on", systemImage: "puzzlepiece.extension")
                    } description: {
                        Text("Turn modules on in Settings.")
                    }
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 380), alignment: .top)], alignment: .leading, spacing: 16) {
                        ForEach(host.activeHandles) { handle in
                            ModuleTile(handle: handle, tiles: tiles) { open(handle.id) }
                                .opacity(hiddenTile == handle.id ? 0 : 1)
                        }
                    }
                }
            }
            .padding(20)
        }
        .scrollEdgeEffectHidden(true, for: .top)
    }
}

/// A module's title row and summary widget. The zoom draws the same two views while they travel, so they must not depend on
/// anything but the handle.
struct ModuleTileTitle: View {
    let manifest: ModuleManifest

    var body: some View {
        Label(manifest.name, systemImage: manifest.symbol).font(.title3.weight(.semibold))
    }
}

struct ModuleTile: View {
    @ObservedObject var handle: ModuleHandle
    let tiles: TileFrames
    let open: () -> Void

    private func update(_ change: (inout TileGeometry) -> Void) {
        var geometry = tiles.tiles[handle.id] ?? TileGeometry()
        change(&geometry)
        tiles.tiles[handle.id] = geometry
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(action: open) {
                HStack {
                    ModuleTileTitle(manifest: handle.manifest)
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(ZoomSpace.name)) } action: { frame in update { $0.header = frame } }
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            if let summary = handle.summary {
                WidgetView(widget: summary) { action, extra in Task { await handle.perform(action, extraParameters: extra) } }
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(ZoomSpace.name)) } action: { frame in update { $0.summary = frame } }
            } else {
                ProgressView().frame(maxWidth: .infinity)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(ZoomSpace.name)) } action: { frame in update { $0.summary = frame } }
            }
        }
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(ZoomSpace.name)) } action: { frame in update { $0.card = frame } }
    }
}
