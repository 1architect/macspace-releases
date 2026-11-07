import AppKit
import MacSpaceSdk
import SwiftUI
import XCTest
@testable import MacSpaceApp

/// Safe visual fixtures: the handlers cannot clean files or change settings.
@MainActor
final class ModuleOverviewRenderTests: XCTestCase {
    func testOverviewAtFullHalfAndQuarterSizes() async throws {
        guard let directory = ProcessInfo.processInfo.environment["MACSPACE_SNAPSHOT_DIR"] else { throw XCTSkip("Opt-in snapshots") }
        let appRows = ["Daemon containers", "Replicatord", "Wallpaper", "Notes", "chronod", "Mediaanalysisd"].enumerated().map {
            Row(id: "app:\($0.offset)", title: $0.element, trailing: "\(386 - $0.offset * 40) MB", badges: [Badge("App data", .info)])
        }
        let otherRows = ["Managed by macOS", "/usr/local", "Shared app files", "Other caches", "OneDrive"].enumerated().map {
            Row(id: "other:\($0.offset)", title: $0.element, trailing: "\(6 - $0.offset).1 GB")
        }
        let caches = ["clang", "Firefox", "ChatGPT", "OneDrive", "WhatsApp", "codex-runtimes", "uv", "Swift packages", "Xcode builds", "Bun"].enumerated().map {
            Row(id: "cache:\($0.offset)", title: $0.element, trailing: "\(200 - $0.offset * 12) MB", badges: [Badge($0.offset == 0 ? "System cache" : "Open now", .info)])
        }
        var cacheGroup = Row.group(id: "caches", title: "Caches you can free", totalBytes: 2_000_000_000, rows: caches)
        cacheGroup.selection = Selection(action: Action(id: "free", title: "Free selected"), choices: Dictionary(uniqueKeysWithValues: caches.map { ($0.id, 100) }),
                                         checked: [caches[0].id], sections: [
                                            SelectionSection(id: "recommended", title: "Recommended 1 item 200 MB", rows: [caches[0].id]),
                                            SelectionSection(id: "apps", title: "Come back with use 4 items 1 GB", rows: Array(caches[1...4]).map(\.id)),
                                            SelectionSection(id: "developer", title: "Developer 5 items 800 MB", rows: Array(caches[5...]).map(\.id))],
                                         save: Action(id: "save", title: "Save"))
        let handle = ModuleHandle(confirm: { _ in true }, descriptor: ModuleDescriptor(manifest: Fixtures.manifest(), bundleURL: URL(fileURLWithPath: "/tmp"), compatibility: .compatible),
                                  settings: SettingsStore(defaults: Fixtures.defaults()), permissions: FakePermissions(), loader: { _ in FakeModule() })
        let widgets: [ScreenWidget] = [.list(ListWidget(id: "groups", rows: [
            .group(id: "appdata", title: "App data", totalBytes: 1_420_000_000, rows: appRows),
            .group(id: "other", title: "Everything else", totalBytes: 10_320_000_000, rows: otherRows)])),
            .section(SectionWidget(id: "free", title: "Free now", widgets: [.list(ListWidget(id: "free-list", rows: [cacheGroup]))], priority: .actionable))]
        let hero = UsageBar(id: "usage", title: "", segments: [
            UsageSegment(id: "managed", label: "Managed by macOS", bytes: 10_010_000_000, tone: .series(0)),
            UsageSegment(id: "free", label: "Can be freed", bytes: 1_530_000_000, tone: .accent),
            UsageSegment(id: "packages", label: "Homebrew and packages", bytes: 2_050_000_000, tone: .series(1)),
            UsageSegment(id: "caches", label: "Other caches", bytes: 864_000_000, tone: .series(2)),
            UsageSegment(id: "support", label: "Support files", bytes: 432_000_000, tone: .series(3)),
            UsageSegment(id: "apps", label: "App data", bytes: 2_070_000_000, tone: .series(4))])
        for (name, width, height) in [("initial", 678.0, 468.0), ("small-floating", 780.0, 550.0), ("breakpoint-below", 943.0, 650.0), ("breakpoint-above", 944.0, 650.0), ("reference-full", 1448.0, 930.0), ("fullscreen", 2090.0, 1140.0), ("half", 1045.0, 1140.0), ("quarter", 1045.0, 570.0)] {
            let view = ZStack(alignment: .topLeading) {
                TileBackdrop(tint: .blue, cornerRadius: 16)
                WidgetForm(widgets: widgets, handler: { _, _, _, _ in nil }, allowsGraphBesideList: true, expandsGroups: true, handle: handle) {
                    HeroBlocks(usage: hero, tint: .blue)
                }
                .modifier(PageScrollArea(hasFooter: true))
                Text("System Data").font(.system(size: 16, weight: .semibold)).padding(30)
            }
            .frame(width: width, height: height)
            .environment(\.colorScheme, .dark)
            try await write(view, to: directory, name: name)
        }
        let switches = ["Siri", "Apple Intelligence", "Dictation"].enumerated().map {
            ToggleRow(id: "switch:\($0.offset)", title: $0.element, isOn: true,
                      detail: "Turn this feature off to stop its background activity and free its downloaded files.",
                      trailing: "2.1 GB", action: Action(id: "toggle", title: "Change"))
        }
        let single = WidgetForm(widgets: [.toggles(ToggleList(id: "features", title: "Features", rows: switches))],
                                handler: { _, _, _, _ in nil }, showsTop: false, maximumColumns: 1) { EmptyView() }
            .modifier(PageScrollArea(hasFooter: false))
            .frame(width: 1470, height: 900)
            .background(TileBackdrop(tint: .graphite))
            .environment(\.colorScheme, .dark)
        try await write(single, to: directory, name: "single-column")
        let settings = PageForm {
            PageSection("Settings") {
                Toggle("Show MacSpace in the menu bar", isOn: .constant(true))
                Toggle("Check for updates", isOn: .constant(true))
            }
        }
        .modifier(PageScrollArea(hasFooter: false))
        .frame(width: 1470, height: 900)
        .background(TileBackdrop(tint: .graphite))
        .environment(\.colorScheme, .dark)
        try await write(settings, to: directory, name: "settings")
    }

    private func write(_ view: some View, to directory: String, name: String) async throws {
        _ = NSApplication.shared
        let hosting = NSHostingView(rootView: view)
        let size = hosting.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: CGPoint(x: -5000, y: 0), size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderBack(nil)
        defer { window.orderOut(nil); window.close() }
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .seconds(1))
        hosting.displayIfNeeded()
        let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        XCTAssertGreaterThan(bitmap.pixelsWide, 1000)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("overview-\(name).png"))
    }
}
