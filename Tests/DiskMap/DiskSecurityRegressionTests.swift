import Darwin
import XCTest
import MacSpacePlatform
import MacSpaceSdk
@testable import MacSpaceDiskMap

private struct UnavailableMetadataStore: MetadataKeyStore {
    func read(_ account: String) throws -> Data? { throw MetadataUnavailable() }
    func create(_ account: String, value: Data) throws { throw MetadataUnavailable() }
    func replace(_ account: String, value: Data) throws { throw MetadataUnavailable() }
    func delete(_ account: String) throws { throw MetadataUnavailable() }
}
private struct SecurityOptions: OptionStore {
    func bool(_ id: String) -> Bool { false }
    func string(_ id: String) -> String { "" }
    func isBackgroundTaskEnabled(_ id: String) -> Bool { false }
}
private struct SecurityPermissions: PermissionChecker { func status(of permission: Permission) -> PermissionStatus { .granted } }

final class DiskSecurityRegressionTests: DiskSecurityFixtureCase {
    private func restoreFixtureKeys() { super.setUp() }
    private func context() -> ModuleContext {
        ModuleContext(manifest: ModuleManifest(id: "com.macspace.disk-map", name: "Disk", summary: "", version: "1", symbol: "internaldrive"), options: SecurityOptions(), permissions: SecurityPermissions())
    }
    func testBusyIndexIsNotDeletedByFallback() async throws {
        let folder = URL(fileURLWithPath: "/private/tmp/disk-busy-" + UUID().uuidString)
        let root = folder.appendingPathComponent("Downloads"), url = folder.appendingPathComponent("cache/index.sqlite")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        do {
            let db = try DiskDatabase(url: url, root: root.path, home: folder.path)
            var state = DiskIndex(root: root.path); state.storageRevision = 4
            try db.saveState(state); try db.seal()
        }
        try trustFixtureCache(url)
        let fd = open(url.path, O_RDWR | O_CLOEXEC)
        guard fd >= 0 else { throw PrivateFile.Refusal() }; defer { close(fd) }
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
        var original = stat(); XCTAssertEqual(fstat(fd, &original), 0)
        let store = DiskStore(root: root.path, cache: url.deletingPathExtension(), home: folder.path)
        let failed = await store.snapshot(); XCTAssertEqual(failed.loadError, true)
        var after = stat(), named = stat()
        XCTAssertEqual(fstat(fd, &after), 0); XCTAssertEqual(lstat(url.path, &named), 0)
        XCTAssertEqual(after.st_nlink, 1)
        XCTAssertEqual(named.st_ino, original.st_ino)
        await store.suspendProtectedStorage()
    }
    func testConfirmedCorruptInventoryStillRebuilds() async throws {
        let folder = URL(fileURLWithPath: "/private/tmp/disk-corrupt-" + UUID().uuidString)
        let root = folder.appendingPathComponent("Downloads"), url = folder.appendingPathComponent("cache/index.sqlite")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        do { _ = try DiskDatabase(url: url, root: root.path, home: folder.path) }
        try trustFixtureCache(url)
        try PrivateFile(url).write(Data("corrupt inventory".utf8))
        let unrelated = folder.appendingPathComponent("cache/keep.txt")
        try Data("preserved".utf8).write(to: unrelated)
        let store = DiskStore(root: root.path, cache: url.deletingPathExtension(), home: folder.path)
        let rebuilt = await store.snapshot()
        XCTAssertNotEqual(rebuilt.loadError, true)
        XCTAssertNotEqual(try Data(contentsOf: url), Data("corrupt inventory".utf8))
        XCTAssertEqual(try Data(contentsOf: unrelated), Data("preserved".utf8))
        await store.suspendProtectedStorage()
    }
    func testTransientKeyFailureRecoversWithoutActivityToggle() async throws {
        let folder = URL(fileURLWithPath: "/private/tmp/disk-key-resume-" + UUID().uuidString)
        let root = folder.appendingPathComponent("Downloads")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder); restoreFixtureKeys() }
        let store = DiskStore(root: root.path, cache: folder.appendingPathComponent("cache/index"), home: folder.path)
        let module = DiskMapModule(store: store, inventory: DiskInventory(loader: { _, _ in DiskApplications() }))
        await module.setActive(true)
        let before = await store.snapshot(); XCTAssertNotEqual(before.loadError, true)
        MetadataKeys.useStore(UnavailableMetadataStore())
        let refused = await module.perform(ActionRequest(actionID: "inert"), context: context(), progress: { _ in })
        XCTAssertEqual(refused.outcome, .failed)
        restoreFixtureKeys()
        await module.invalidate(); _ = await module.tile(context: context())
        let after = await store.snapshot(); XCTAssertNotEqual(after.loadError, true)
        await store.suspendProtectedStorage()
    }
    func testProtectedResumeRespectsHostInactivity() async throws {
        let folder = URL(fileURLWithPath: "/private/tmp/disk-inactive-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = DiskStore(root: folder.path, cache: folder.appendingPathComponent("cache/index"), home: folder.path)
        _ = await store.snapshot()
        await store.setActive(false); await store.suspendProtectedStorage()
        let inactive = await store.snapshot(); XCTAssertEqual(inactive.loadError, true)
        await store.setActive(true)
        let resumed = await store.snapshot(); XCTAssertNotEqual(resumed.loadError, true)
        await store.setActive(false); await store.suspendProtectedStorage()
    }
    func testEveryMainDatabaseDescriptorClosesOnExec() throws {
        let folder = URL(fileURLWithPath: "/private/tmp/disk-fds-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("cache/index.sqlite")
        let db = try DiskDatabase(url: url, root: folder.path)
        try withExtendedLifetime(db) {
            let descriptors = try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").compactMap(Int32.init)
            var matched = 0
            for fd in descriptors {
                var path = [CChar](repeating: 0, count: Int(PATH_MAX))
                let result = path.withUnsafeMutableBufferPointer { fcntl(fd, F_GETPATH, $0.baseAddress!) }
                guard result == 0, String(cString: path) == url.path else { continue }
                matched += 1
                XCTAssertNotEqual(fcntl(fd, F_GETFD) & FD_CLOEXEC, 0, "A database descriptor must not survive exec")
            }
            XCTAssertGreaterThanOrEqual(matched, 2, "Inspect both the boundary descriptor and SQLite's duplicated descriptor")
        }
    }
}
