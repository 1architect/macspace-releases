import AppKit
import Darwin
import MacSpacePlatform
import MacSpaceSdk
import SwiftUI
import XCTest
@testable import MacSpaceApp

/// The memory the dashboard costs, with the real modules (read-only: nothing is cleaned, no background task runs) and no helper
/// (Issue 11). Opt-in, in a release build:
///
///     MACSPACE_MEMORY_BENCHMARK=Build/MacSpace.app/Contents/PlugIns swift test -c release -Xswiftc -enable-testing \
///         --filter MemoryBenchmarkTests
///
/// `MACSPACE_MEMORY_BENCHMARK_UI=none` reads the modules with no window, for the share the window adds. `..._HOLD=60` keeps the
/// window up that many seconds at the end, for `heap` or `sample`. Prints `BENCHMARK` lines; asserts nothing.
private struct ReadOnlyModule: MacSpaceModule {
    let base: any MacSpaceModule
    init() { fatalError("Only made around a loaded module") }
    init(base: any MacSpaceModule) { self.base = base }
    func tile(context: ModuleContext) async -> Tile { await base.tile(context: context) }
    func tile(context: ModuleContext, progress: @escaping LoadProgressSink) async -> Tile { await base.tile(context: context, progress: progress) }
    func status(context: ModuleContext) async -> (tile: Tile, screen: Screen)? { await base.status(context: context) }
    func screen(context: ModuleContext) async -> Screen { await base.screen(context: context) }
    func screen(context: ModuleContext, progress: @escaping LoadProgressSink) async -> Screen { await base.screen(context: context, progress: progress) }
    func perform(_ request: ActionRequest, context: ModuleContext, progress: @escaping ProgressSink) async -> ActionResult {
        .failed("Read-only benchmark")
    }
}

@MainActor
final class MemoryBenchmarkTests: XCTestCase {
    private static func report(_ label: String) {
        var info = rusage_info_v6()
        _ = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V6, $0) }
        }
        var stats = malloc_statistics_t()
        malloc_zone_statistics(nil, &stats)
        let mb = { (bytes: UInt64) in String(format: "%.1f MB", Double(bytes) / 1_048_576) }
        print("BENCHMARK \(label): footprint \(mb(info.ri_phys_footprint)), peak \(mb(info.ri_lifetime_max_phys_footprint)), "
              + "heap in use \(mb(UInt64(stats.size_in_use))), heap held \(mb(UInt64(stats.size_allocated)))")
    }

    func testDashboardMemory() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let plugins = environment["MACSPACE_MEMORY_BENCHMARK"] else { throw XCTSkip("Opt-in: MACSPACE_MEMORY_BENCHMARK") }
        let window = environment["MACSPACE_MEMORY_BENCHMARK_UI"] != "none"
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.regular)
        UserDefaults.standard.set(true, forKey: Onboarding.completedKey)
        // As MacSpace does at launch.
        GlyphCache.apply()
        Self.report("start")
        let host = ModuleHost(modulesDirectory: URL(fileURLWithPath: plugins, isDirectory: true),
                              settings: SettingsStore(defaults: Fixtures.defaults()), privileged: nil,
                              loader: { ReadOnlyModule(base: try ModuleLoader.load($0)) })
        var shown: NSWindow?
        if window {
            let canvas = NSWindow(contentRect: NSRect(x: 200, y: 150, width: 716, height: 540), styleMask: [.borderless], backing: .buffered, defer: false)
            canvas.isOpaque = false
            canvas.backgroundColor = .clear
            canvas.identifier = NSUserInterfaceItemIdentifier(MacSpaceWindow.glass)
            canvas.contentView = NSHostingView(rootView: ReleasableContent { MainView(host: host, updates: UpdateController()) })
            canvas.makeKeyAndOrderFront(nil)
            NSApp.activate()
            shown = canvas
        } else {
            await host.start()
        }
        for second in [5, 15, 30] {
            try await Task.sleep(for: .seconds(second == 5 ? 5 : second == 15 ? 10 : 15))
            Self.report("\(window ? "dashboard" : "no window") at \(second) s")
        }
        if window {
            // What dropping the closed window's content frees (`ClosedWindowRelease`).
            ClosedWindowRelease.shared.release()
            try await Task.sleep(for: .seconds(5))
            Self.report("content released")
        }
        if let hold = environment["MACSPACE_MEMORY_BENCHMARK_HOLD"].flatMap(Double.init) {
            print("BENCHMARK holding")
            try await Task.sleep(for: .seconds(hold))
        }
        host.scheduler.stopAll()
        _ = shown // Left open: closing a window outside a scene trips MacSpace's window customization (KVO), and the process ends anyway.
    }
}
