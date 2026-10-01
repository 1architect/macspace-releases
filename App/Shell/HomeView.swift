import MacSpaceSdk
import SwiftUI

/// The dashboard: one tile per active module, each showing the summary widget the module provides.
struct HomeView: View {
    @ObservedObject var host: ModuleHost
    let open: (String) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("MACSPACE").font(.largeTitle.weight(.bold))
                if host.activeHandles.isEmpty {
                    ContentUnavailableView {
                        Label("No modules are on", systemImage: "puzzlepiece.extension")
                    } description: {
                        Text("Turn modules on in Settings.")
                    }
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 380), alignment: .top)], alignment: .leading, spacing: 16) {
                        ForEach(host.activeHandles) { handle in ModuleTile(handle: handle) { open(handle.id) } }
                    }
                }
            }
            .padding(20)
        }
    }
}

struct ModuleTile: View {
    @ObservedObject var handle: ModuleHandle
    let open: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(action: open) {
                HStack {
                    Label(handle.manifest.name, systemImage: handle.manifest.symbol).font(.title3.weight(.semibold))
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            if let summary = handle.summary {
                WidgetView(widget: summary) { action, extra in Task { await handle.perform(action, extraParameters: extra) } }
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
    }
}
