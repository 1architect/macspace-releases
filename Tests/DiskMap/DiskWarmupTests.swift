import Foundation
import MacSpaceSdk
import XCTest
@testable import MacSpaceDiskMap

final class DiskWarmupTests: DiskSecurityFixtureCase {
    private final class Reads: @unchecked Sendable {
        private let lock = NSLock()
        private var reads = 0
        var count: Int { lock.withLock { reads } }
        func record() { lock.withLock { reads += 1 } }
    }
    private struct Options: OptionStore {
        func bool(_ id: String) -> Bool { false }
        func string(_ id: String) -> String { "" }
        func isBackgroundTaskEnabled(_ id: String) -> Bool { false }
    }
    private struct Permissions: PermissionChecker {
        func status(of permission: Permission) -> PermissionStatus { .granted }
    }
    private var context: ModuleContext {
        ModuleContext(manifest: ModuleManifest(id: "com.macspace.disk-map", name: "Disk", summary: "", version: "test", symbol: "internaldrive"), options: Options(), permissions: Permissions())
    }
    func testTileWarmsAppInventoryAndFirstPageReusesIt() async throws {
        let home = "/private/tmp/disk-warmup-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: home) }
        try FileManager.default.createDirectory(atPath: home + "/Downloads", withIntermediateDirectories: true)
        let reads = Reads(), store = DiskStore(root: home + "/Downloads", cache: URL(fileURLWithPath: home + "/cache/index"), home: home)
        let module = DiskMapModule(store: store, inventory: DiskInventory(loader: { index, _ in
            reads.record()
            var apps = DiskApplications(); apps.catalogRevision = index.catalogRevision; apps.catalogReadAt = Date()
            return apps
        }))
        _ = await module.tile(context: context)
        XCTAssertEqual(reads.count, 1, "Warm the page's data without constructing a page")
        _ = await module.screen(context: context)
        _ = await module.screen(context: context)
        XCTAssertEqual(reads.count, 1)
        await module.setActive(false)
    }

    func testConcurrentWarmupAndPageShareOneAppDiscovery() async throws {
        let home = "/private/tmp/disk-warmup-shared-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: home) }
        try FileManager.default.createDirectory(atPath: home + "/Downloads", withIntermediateDirectories: true)
        let reads = Reads(), started = expectation(description: "App discovery"), gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let store = DiskStore(root: home + "/Downloads", cache: URL(fileURLWithPath: home + "/cache/index"), home: home)
        let module = DiskMapModule(store: store, inventory: DiskInventory(loader: { index, _ in
            reads.record(); started.fulfill()
            _ = gate.wait(timeout: .now() + 5)
            var apps = DiskApplications(); apps.catalogRevision = index.catalogRevision; apps.catalogReadAt = Date()
            return apps
        }))
        let context = context
        let tile = Task { await module.tile(context: context) }
        await fulfillment(of: [started], timeout: 5)
        let page = Task { await module.screen(context: context) }
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(reads.count, 1)
        gate.signal()
        _ = await (tile.value, page.value)
        XCTAssertEqual(reads.count, 1)
        await module.setActive(false)
    }
}
