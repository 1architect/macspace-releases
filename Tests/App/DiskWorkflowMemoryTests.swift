import AppKit
import Darwin
import SwiftUI
import XCTest
import MacSpacePlatform
import MacSpaceSdk
@testable import MacSpaceApp

@MainActor
final class DiskWorkflowMemoryTests: XCTestCase {
    private func footprint(_ label: String) -> UInt64 {
        var info = rusage_info_v6()
        _ = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V6, $0) } }
        var heap = malloc_statistics_t(); malloc_zone_statistics(nil, &heap)
        print("FULL_APP_MEMORY stage=\(label) footprintMiB=\(Double(info.ri_phys_footprint)/1_048_576) lifetimePeakMiB=\(Double(info.ri_lifetime_max_phys_footprint)/1_048_576) heapUsedMiB=\(Double(heap.size_in_use)/1_048_576) heapHeldMiB=\(Double(heap.size_allocated)/1_048_576)")
        return info.ri_phys_footprint
    }
    func testFullAppDiskBrowsingStaysWithin150MB() async throws {
        guard let path = ProcessInfo.processInfo.environment["MACSPACE_DISK_WORKFLOW_MEMORY"] else { throw XCTSkip("Opt-in read-only full-app memory workflow") }
        await runWorkflow(path)
    }
    @inline(never) private func runWorkflow(_ path: String) async {
        UserDefaults.standard.set(true, forKey: Onboarding.completedKey)
        _ = NSApplication.shared; GlyphCache.apply()
        let host = ModuleHost(modulesDirectory: URL(fileURLWithPath: path), settings: SettingsStore(defaults: Fixtures.defaults()), privileged: nil,
            loader: { ReadOnlyModule(base: try ModuleLoader.load($0)) })
        let canvas = NSWindow(contentRect: CGRect(x: -5000, y: 0, width: 716, height: 540), styleMask: [.borderless], backing: .buffered, defer: false)
        canvas.isReleasedWhenClosed = false
        canvas.identifier = NSUserInterfaceItemIdentifier(MacSpaceWindow.glass)
        canvas.contentView = NSHostingView(rootView: MainView(host: host, updates: UpdateController()))
        canvas.orderBack(nil)
        _ = footprint("start")
        await host.start()
        try? await Task.sleep(for: .seconds(5))
        XCTAssertLessThan(footprint("dashboard"), 150 * 1_048_576)
        guard let disk = host.handle(for: "com.macspace.disk-map") else { XCTFail("Disk module missing"); return }
        FileHandle.standardError.write(Data("WORKFLOW disk found: \(disk.state)\n".utf8))
        canvas.setFrame(CGRect(x: -5000, y: 0, width: 1448, height: 900), display: true)
        AppRouter.shared.open(.storage)
        try? await Task.sleep(for: .seconds(4))
        XCTAssertNotNil(disk.screen?.hero)
        XCTAssertTrue(disk.screenIsVisible)
        XCTAssertLessThan(footprint("disk-root-wide"), 150 * 1_048_576)
        if let hold = ProcessInfo.processInfo.environment["MACSPACE_MEMORY_HOLD_WIDE"].flatMap(Double.init) { try? await Task.sleep(for: .seconds(hold)) }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for (n, id) in ["folder:/Users", "folder:" + home, "folder:" + home + "/Library", "folder:" + home + "/Library/Caches"].enumerated() {
            disk.pushGroup(id)
            for _ in 0..<500 where disk.pages[id] == nil { try? await Task.sleep(for: .milliseconds(10)) }
            XCTAssertNotNil(disk.pages[id]?.hero)
            try? await Task.sleep(for: .seconds(2))
            XCTAssertLessThan(footprint("folder-depth-\(n)"), 150 * 1_048_576)
        }
        while !disk.groupPath.isEmpty { disk.popGroup() }
        try? await Task.sleep(for: .seconds(1))
        for id in ["apps", "large:/"] {
            disk.pushGroup(id)
            for _ in 0..<500 where disk.pages[id] == nil { try? await Task.sleep(for: .milliseconds(10)) }
            XCTAssertNotNil(disk.pages[id])
            try? await Task.sleep(for: .seconds(2))
            XCTAssertLessThan(footprint("page-\(id)"), 150 * 1_048_576)
            disk.popGroup()
            try? await Task.sleep(for: .milliseconds(700))
        }
        canvas.setFrame(CGRect(x: -5000, y: 0, width: 700, height: 490), display: true)
        try? await Task.sleep(for: .seconds(2))
        XCTAssertLessThan(footprint("disk-root-compact"), 150 * 1_048_576)
        canvas.orderOut(nil)
        ClosedWindowRelease.shared.release()
        for handle in host.handles { handle.deactivate() }
        host.scheduler.stopAll()
        try? await Task.sleep(for: .seconds(2))
        _ = footprint("closed")
        if let hold = ProcessInfo.processInfo.environment["MACSPACE_MEMORY_BENCHMARK_HOLD"].flatMap(Double.init) {
            try? await Task.sleep(for: .seconds(hold))
        }
        // The process releases the native test window; avoid scene-less close customization.
    }
}
