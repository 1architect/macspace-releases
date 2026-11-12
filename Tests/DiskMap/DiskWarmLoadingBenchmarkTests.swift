import Foundation
import MacSpaceSdk
import XCTest
@testable import MacSpaceDiskMap

final class DiskWarmLoadingBenchmarkTests: DiskSecurityFixtureCase {
    private struct Options: OptionStore {
        func bool(_ id: String) -> Bool { false }
        func string(_ id: String) -> String { "" }
        func isBackgroundTaskEnabled(_ id: String) -> Bool { false }
    }
    private struct Permissions: PermissionChecker {
        func status(of permission: Permission) -> PermissionStatus { .granted }
    }
    func testColdWarmAndReopenedInventory() async throws {
        guard ProcessInfo.processInfo.environment["MACSPACE_RESPONSIVENESS_BENCHMARK"] == "1" else { throw XCTSkip("Opt-in responsiveness benchmark") }
        let home = "/private/tmp/disk-warm-benchmark-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: home) }
        let root = home + "/Downloads"
        for n in 0..<300 {
            let directory = root + "/folder-\(n)"
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            for file in 0..<4 { try Data(repeating: 1, count: 4096).write(to: URL(fileURLWithPath: directory + "/\(file).bin")) }
        }
        let context = ModuleContext(manifest: ModuleManifest(id: "com.macspace.disk-map", name: "Disk", summary: "", version: "test", symbol: "internaldrive"), options: Options(), permissions: Permissions())
        let store = DiskStore(root: root, cache: URL(fileURLWithPath: home + "/cache/index"), home: home)
        let inventory = DiskInventory(loader: { _, previous in
            Thread.sleep(forTimeInterval: 0.025)
            var apps = previous ?? DiskApplications(); apps.catalogReadAt = Date()
            return apps
        })
        let module = DiskMapModule(store: store, inventory: inventory)
        let start = Date()
        _ = await module.tile(context: context)
        let warmup = Date().timeIntervalSince(start), firstVisit = Date()
        _ = await module.screen(context: context)
        let firstPage = Date().timeIntervalSince(firstVisit), revisits = Date()
        for _ in 0..<20 { _ = await module.screen(context: context) }
        let repeated = Date().timeIntervalSince(revisits)
        await module.setActive(false); await module.setActive(true)
        let resumed = Date()
        _ = await module.screen(context: context)
        let resume = Date().timeIntervalSince(resumed)
        await module.setActive(false)
        print("DISK_WARM_BENCH folders=300 files=1200 tileWarmupSeconds=\(warmup) firstPageAfterWarmupSeconds=\(firstPage) revisits20Seconds=\(repeated) resumeSeconds=\(resume)")
    }
}
