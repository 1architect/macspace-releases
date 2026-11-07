import Foundation
import XCTest
import MacSpaceSdk
import MacSpaceDiskMapPrivileged
@testable import MacSpaceDiskMap

final class DiskReviewLatencyTests: DiskSecurityFixtureCase {
    private struct Options: OptionStore {
        func bool(_ id: String) -> Bool { false }
        func string(_ id: String) -> String { "" }
        func isBackgroundTaskEnabled(_ id: String) -> Bool { false }
    }
    private struct Permissions: PermissionChecker {
        func status(of permission: Permission) -> PermissionStatus { .granted }
    }
    private final class Reads: @unchecked Sendable {
        private let lock = NSLock(); private var value = 0
        func record() { lock.withLock { value += 1 } }
        var count: Int { lock.withLock { value } }
    }
    private func context() -> ModuleContext {
        ModuleContext(manifest: ModuleManifest(id: "com.macspace.disk-map", name: "Disk", summary: "", version: "test", symbol: "internaldrive"), options: Options(), permissions: Permissions())
    }
    private func reviewID(_ selection: Selection, paths: [String]) throws -> String {
        let parameters = ["ids": Selection.parameter(paths), "reviewed": String(decoding: try JSONEncoder().encode(selection.reviewed.filter { paths.contains($0.key) }), as: UTF8.self)]
        return ActionPageRequest(destination: DiskUninstallBatch.reviewDestination, parameters: parameters).pageID
    }
    func testReviewNeverRepeatsDiscoveryEvenWhenTheDiskRevisionAdvances() async throws {
        let home = "/private/tmp/review-latency-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: home) }
        let path = home + "/Applications/Example.app"
        try FileManager.default.createDirectory(atPath: path + "/Contents", withIntermediateDirectories: true)
        try (["CFBundleIdentifier": "org.fixture.review", "CFBundleName": "Example"] as NSDictionary).write(to: URL(fileURLWithPath: path + "/Contents/Info.plist"))
        let owner = try XCTUnwrap(AppOwner(path: path)), catalog = AppCatalog(owners: [])
        let resolver = OwnershipResolver(catalog: catalog)
        var prepared = DiskApplications(); prepared.catalog = catalog; prepared.catalogReadAt = Date()
        prepared.apps = [DiskApplication(owner: owner, bytes: 8192, dataPaths: [], removable: true, classification: .installedUser,
            plan: resolver.plan(for: owner, home: home, systemLibrary: home + "/SystemLibrary"))]
        let frozen = prepared, reads = Reads()
        let inventory = DiskInventory(loader: { _, _ in reads.record(); return frozen })
        let store = DiskStore(root: home, cache: URL(fileURLWithPath: home + "/cache/index"), home: home)
        let module = DiskMapModule(store: store, inventory: inventory)
        let loaded = await module.page(id: "apps", context: context())
        let picker = try XCTUnwrap(loaded)
        let selection = try XCTUnwrap(picker.selection)
        XCTAssertEqual(reads.count, 1)
        _ = await store.view()
        await store.mark([home], recursive: true)
        _ = await store.view()
        let start = Date()
        let page = await module.page(id: try reviewID(selection, paths: [path]), context: context())
        XCTAssertEqual(page?.selection?.action.id, "uninstallSelected")
        XCTAssertEqual(reads.count, 1, "Opening review cannot redo receipts, signatures, service discovery or unrelated app ownership")
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5)
        // A removed app is rejected even though review uses the prepared catalog.
        try FileManager.default.removeItem(atPath: path)
        let stale = await module.page(id: try reviewID(selection, paths: [path]), context: context())
        XCTAssertNil(stale?.primary)
        await module.setActive(false)
    }
    func testNativePreparedReviewLatency() async throws {
        guard let source = ProcessInfo.processInfo.environment["MACSPACE_REVIEW_LATENCY_CACHE"] else {
            throw XCTSkip("Set MACSPACE_REVIEW_LATENCY_CACHE to an isolated index backup")
        }
        let directory = URL(fileURLWithPath: "/private/tmp/native-review-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = directory.appendingPathComponent("index")
        try FileManager.default.copyItem(atPath: source, toPath: cache.appendingPathExtension("sqlite").path)
        let module = DiskMapModule(store: DiskStore(root: "/", cache: cache))
        let picker = await module.page(id: "apps", context: context())
        let selection = try XCTUnwrap(picker?.selection), paths = selection.choices.keys.sorted()
        XCTAssertFalse(paths.isEmpty)
        for (name, chosen) in [("single", Array(paths.prefix(1))), ("all", paths)] {
            let id = try reviewID(selection, paths: chosen), start = Date()
            let page = await module.page(id: id, context: context())
            let elapsed = Date().timeIntervalSince(start)
            XCTAssertNotNil(page?.selection?.action)
            print("UNINSTALL_REVIEW_LATENCY mode=\(name) apps=\(chosen.count) seconds=\(elapsed)")
            if let limit = ProcessInfo.processInfo.environment["MACSPACE_REVIEW_MAX_SECONDS"].flatMap(Double.init) { XCTAssertLessThan(elapsed, limit) }
        }
        await module.setActive(false)
    }
}
