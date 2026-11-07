import Darwin
import Foundation
import XCTest
import MacSpaceSdk
import MacSpacePlatform
@testable import MacSpaceDiskMap

final class DiskNavigationRegressionTests: DiskSecurityFixtureCase {
    private final class Reads: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func read() { lock.withLock { value += 1 } }
        var count: Int { lock.withLock { value } }
    }
    private func context() -> ModuleContext {
        ModuleContext(manifest: ModuleManifest(id: "com.macspace.disk-map", name: "Disk", summary: "", version: "0.1", sdkVersion: SdkVersion.current, symbol: "internaldrive"), options: MemoryOptions(), permissions: AllowedPermissions())
    }
    private struct MemoryOptions: OptionStore {
        func bool(_ id: String) -> Bool { false }
        func string(_ id: String) -> String { "" }
        func isBackgroundTaskEnabled(_ id: String) -> Bool { false }
    }
    private struct AllowedPermissions: PermissionChecker {
        func status(of permission: Permission) -> PermissionStatus { .granted }
    }
    func testGraphDeleteRejectsMissingAndChangedReviewBeforeRemovingAnyFile() async throws {
        let base = URL(fileURLWithPath: "/private/tmp/graph-removal-" + UUID().uuidString)
        let downloads = base.appendingPathComponent("Downloads")
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let target = downloads.appendingPathComponent("target.txt"), other = downloads.appendingPathComponent("other.txt")
        try Data([1]).write(to: target); try Data([2]).write(to: other)
        let original = try XCTUnwrap(FileReviewIdentity(target.path))
        let store = DiskStore(root: downloads.path, cache: base.appendingPathComponent("cache/index"), home: base.path)
        let module = DiskMapModule(store: store, inventory: DiskInventory(loader: { _, _ in DiskApplications() }))
        let trash = FileRemovalSettings.movesToTrash() ? "1" : "0"
        let missing = await module.perform(.init(actionID: "deleteGraphFile", parameters: ["trash": trash]), context: context(), progress: { _ in })
        XCTAssertEqual(missing.outcome, .failed)
        try Data([3, 4]).write(to: target)
        let changed = await module.perform(.init(actionID: "deleteGraphFile", parameters: ["trash": trash,
            "id": DiskFileRemoval.id(target.path), "reviewed": String(decoding: try JSONEncoder().encode(original), as: UTF8.self)]),
            context: context(), progress: { _ in })
        XCTAssertEqual(changed.outcome, .failed)
        XCTAssertEqual(try Data(contentsOf: target), Data([3, 4]))
        XCTAssertEqual(try Data(contentsOf: other), Data([2]))
        await store.setActive(false)
    }

    func testFolderAndNestedNavigationNeverStartDuplicateOrAppDiscovery() async throws {
        let base = URL(fileURLWithPath: "/private/tmp/navigation-regression-" + UUID().uuidString)
        let home = base.appendingPathComponent("User"), downloads = home.appendingPathComponent("Downloads"), nested = downloads.appendingPathComponent("Nested")
        let source = base.appendingPathComponent("cache/index.sqlite")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let db = try DiskDatabase(url: source, root: home.path, home: home.path)
        try trustFixtureCache(source)
        try db.put(DiskDirectory(path: home.path))
        try db.put(DiskDirectory(path: downloads.path))
        try db.put(DiskDirectory(path: nested.path))
        try db.put(DiskDirectory(path: home.path + "/Library"))
        // Cached managed subtrees must not be enumerated by a direct folder request.
        try db.transaction {
            for n in 0..<20_000 { try db.put(DiskDirectory(path: home.path + "/Library/folder-\(n)")) }
        }
        for name in ["one.zip", "two.zip"] {
            let url = nested.appendingPathComponent(name)
            try Data([1]).write(to: url)
            let handle = try FileHandle(forWritingTo: url); try handle.truncate(atOffset: 100_000_000); try handle.close()
            try db.put(DiskFile(path: url.path, bytes: 4096, logicalBytes: 100_000_000, ownerUID: getuid()))
        }
        var state = DiskIndex(root: home.path); state.storageRevision = 4; state.summaryVersion = DiskIndex.summarySchemaVersion; state.revision = 1
        try db.saveState(state); try db.seal()
        let reads = Reads(), store = DiskStore(root: home.path, cache: source.deletingPathExtension(), home: home.path)
        let module = DiskMapModule(store: store, inventory: DiskInventory(loader: { _, _ in reads.read(); return DiskApplications() }))
        let started = Date()
        for path in [home.path, downloads.path, nested.path, home.path + "/Library"] {
            let page = await module.page(id: "folder:" + path, context: context())
            XCTAssertNotNil(page)
            if let hero = page?.hero { XCTAssertEqual(hero.id, DiskMapScreenBuilder.folderID(path)) }
            else { XCTAssertEqual(page?.layout, .singleColumn, "Empty folder pages keep their list at the top") }
            if path.hasSuffix("/Library") { XCTAssertNil(page?.loadingFraction, "Managed folders do not launch hidden metadata work") }
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5)
        XCTAssertEqual(reads.count, 0, "A folder click cannot reread the app catalog")
        XCTAssertEqual(try db.query("SELECT 1 FROM sqlite_master WHERE name='duplicate_fingerprints'"), 0, "Navigation cannot start fingerprinting or hashing")
        let direct = DiskBrowseRequest(folder: nested.path, kind: .direct)
        XCTAssertEqual(try db.reviewFolders(direct, after: "", limit: 128), [nested.path])
        XCTAssertTrue(try db.reviewFolders(direct, after: nested.path, limit: 128).isEmpty)
        var category = DiskBrowseRequest(folder: home.path, kind: .category, category: .largeFiles); category.includeSmaller = true
        let scoped = try db.reviewFolders(category, after: "", limit: 128)
        XCTAssertFalse(scoped.contains { $0.contains("/Library") })
        await store.setActive(false)
        print("DISK_NAVIGATION_REGRESSION cachedManagedFolders=20000 pages=4 seconds=\(Date().timeIntervalSince(started)) appReads=\(reads.count) contentHashing=false")
    }
}

extension DiskNavigationRegressionTests {
    func testProductionCachedNavigationWithoutAppOrContentReads() throws {
        guard let path = ProcessInfo.processInfo.environment["MACSPACE_NAVIGATION_CACHE"] else {
            throw XCTSkip("Set MACSPACE_NAVIGATION_CACHE to an isolated copy of the completed index")
        }
        func footprint() -> UInt64 {
            var info = rusage_info_v6()
            _ = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V6, $0) }
            }
            return info.ri_phys_footprint
        }
        let db = try DiskDatabase(url: URL(fileURLWithPath: path), root: "/")
        try trustFixtureCache(URL(fileURLWithPath: path))
        var count: UInt64 = 0
        try db.query("SELECT COUNT(*) FROM dirs") { count = DiskDatabase.number($0, 0) }
        _ = try db.snapshot()
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let targets = ["/Users", home, home + "/Documents", home + "/Desktop", "/System", "/Library", home + "/Library"]
        let before = footprint(), began = Date()
        var peak = before
        for cycle in 0..<20 {
          for folder in targets {
            try autoreleasepool {
                guard try db.directory(folder) != nil else { return }
                let started = Date(), snapshot = try db.snapshot(folder: folder, inventory: false)
                let request = DiskBrowseRequest(folder: folder, kind: .direct)
                let page = db.canReview(request) ? try db.browse(request) : DiskBrowsePage(request: request, files: [], ownership: [:])
                XCTAssertNotNil(snapshot.index.directories[folder])
                XCTAssertLessThanOrEqual(page?.files.count ?? 0, 200)
                XCTAssertLessThan(Date().timeIntervalSince(started), 0.5, "Cached \(folder) must not wait on descendants or hashing")
                if cycle == 0 { print("DISK_CACHED_NAVIGATION folder=\(folder) seconds=\(Date().timeIntervalSince(started)) directFiles=\(page?.files.count ?? 0)") }
            }
            peak = max(peak, footprint())
          }
        }
        XCTAssertLessThan(Date().timeIntervalSince(began), 8)
        XCTAssertLessThan(peak > before ? peak - before : 0, 32 * 1024 * 1024)
        print("DISK_CACHED_NAVIGATION_TOTAL cachedFolders=\(count) pages=\(targets.count * 20) seconds=\(Date().timeIntervalSince(began)) extraPeakMiB=\(Double(peak > before ? peak - before : 0) / 1_048_576)")
    }
}

extension DiskNavigationRegressionTests {
    func testInstallersUseCompletedInventoryWithoutSmallFileWorkers() async throws {
        let home = URL(fileURLWithPath: "/private/tmp/installer-page-" + UUID().uuidString)
        let root = home.appendingPathComponent("Downloads"), cache = home.appendingPathComponent("cache/index.sqlite")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let url = root.appendingPathComponent("small.pkg"); try Data(repeating: 3, count: 4096).write(to: url)
        let db = try DiskDatabase(url: cache, root: root.path, home: home.path)
        try trustFixtureCache(cache)
        var scanner = DiskDatabaseScanner(db: db, excluded: [])
        try scanner.scan(.init(), cursor: 1, progress: nil)
        let store = DiskStore(root: root.path, cache: cache.deletingPathExtension(), home: home.path)
        var request = DiskBrowseRequest(folder: root.path, kind: .category, category: .installers); request.includeSmaller = true
        let value = await store.browse(request), page = try XCTUnwrap(value)
        XCTAssertEqual(page.files.map(\.path), [url.path]); XCTAssertNil(page.loadingFraction)
        XCTAssertFalse(request.usesMetadataInventory)
        XCTAssertEqual(page.eligibleCount, 1)
        var selected: [DiskFile] = []; try db.streamScope(request) { selected.append($0) }
        XCTAssertEqual(selected.map(\.path), [url.path])
        let screen = DiskMapScreenBuilder.browsePage(page)
        let lists = screen.widgets.compactMap { if case let .list(list) = $0 { return list }; return nil }
        XCTAssertTrue(lists.contains { $0.title == "PKG files" && $0.rows.map(\.id) == [DiskFileRemoval.id(url.path)] })
        XCTAssertTrue(lists.flatMap(\.rows).allSatisfy { $0.sectionID == nil })
        await store.setActive(false)
    }
    func testSmallDescendantImagesAreVisibleDespiteDirectIniAndPhotoLibrariesStayReadOnly() async throws {
        let home = URL(fileURLWithPath: "/private/tmp/folder-scope-" + UUID().uuidString)
        let root = home.appendingPathComponent("Pictures"), cache = home.appendingPathComponent("cache/index.sqlite")
        let nested = root.appendingPathComponent("Fototeca/Pictures"), library = root.appendingPathComponent("Library.photoslibrary/originals")
        for folder in [root, nested, library] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        defer { try? FileManager.default.removeItem(at: home) }
        let ini = root.appendingPathComponent("desktop.ini"), image = nested.appendingPathComponent("photo.jpg"), managed = library.appendingPathComponent("managed.jpg")
        for url in [ini, image, managed] { try Data(repeating: 7, count: 4096).write(to: url) }
        let db = try DiskDatabase(url: cache, root: root.path, home: home.path)
        try trustFixtureCache(cache)
        var scanner = DiskDatabaseScanner(db: db, excluded: [])
        try scanner.scan(.init(), cursor: 1, progress: nil)
        let store = DiskStore(root: root.path, cache: cache.deletingPathExtension(), home: home.path)
        var complete: DiskBrowsePage?
        for _ in 0..<100 {
            let page = await store.folderFiles(root.path)
            if page?.loadingFraction == nil { complete = page; break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let files = try XCTUnwrap(complete)
        XCTAssertEqual(Set(files.files.map(\.path)), [ini.path, image.path])
        XCTAssertTrue(files.request.inFolder); XCTAssertTrue(files.request.includeSmaller)
        XCTAssertFalse(files.files.contains { $0.path == managed.path })
        var managedPage: DiskBrowsePage?
        for _ in 0..<100 {
            let page = await store.folderFiles(library.path)
            if page?.loadingFraction == nil { managedPage = page; break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let inspected = try XCTUnwrap(managedPage)
        XCTAssertEqual(inspected.files.map(\.path), [managed.path]); XCTAssertEqual(inspected.request.kind, .managed)
        let screen = DiskMapScreenBuilder.browsePage(inspected)
        XCTAssertNil(screen.selection)
        XCTAssertThrowsError(try db.streamScope(inspected.request) { _ in XCTFail("Photo-library internals must never enter cleanup selection") })
        await store.setActive(false)
    }
}

extension DiskNavigationRegressionTests {
    func testFolderCountIncludesSmallFilesAndSubfoldersAndPersistsAcrossReopen() throws {
        let home = URL(fileURLWithPath: "/private/tmp/folder-count-" + UUID().uuidString), root = home.appendingPathComponent("Downloads")
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Nested"), withIntermediateDirectories: true)
        for name in ["small.txt", "photo.jpg"] { try Data([1]).write(to: root.appendingPathComponent(name)) }
        let cache = home.appendingPathComponent("cache/index.sqlite")
        let db = try DiskDatabase(url: cache, root: root.path, home: home.path)
        try trustFixtureCache(cache)
        var scanner = DiskDatabaseScanner(db: db, excluded: [])
        try scanner.scan(.init(), cursor: 1, progress: nil)
        XCTAssertEqual(try db.directory(root.path)?.itemCount, 3)
        let reopened = try DiskDatabase(url: cache, root: root.path, home: home.path)
        XCTAssertEqual(try reopened.countedDirectory(root.path)?.itemCount, 3)
        try db.query("UPDATE dirs SET items=NULL WHERE path=?", [.text(root.path)])
        XCTAssertEqual(try db.countedDirectory(root.path)?.itemCount, 3, "Old cache counts must be measured truthfully, never fabricated from only indexed large files")
        var index = DiskIndex(root: "/")
        index.directories["/"] = .init(path: "/")
        index.personalFolders = [try XCTUnwrap(db.countedDirectory(root.path))]
        let screen = DiskMapScreenBuilder.screen(index, apps: DiskApplications())
        let row = try XCTUnwrap(screen.widgets.compactMap { if case let .list(list) = $0, list.id == "personal-folders" { return list.rows.first }; return nil }.first)
        XCTAssertEqual(row.subtitle, "3 items"); XCTAssertEqual(row.paths, [root.path])
    }
}

extension DiskNavigationRegressionTests {
    func testShowSmallerFilesOpensAListOnlyPageWithOnlySmallerFiles() async throws {
        let home = URL(fileURLWithPath: "/private/tmp/smaller-expansion-" + UUID().uuidString)
        let root = home.appendingPathComponent("Downloads"), cache = home.appendingPathComponent("cache/index.sqlite")
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let large = root.appendingPathComponent("large.zip"), small = root.appendingPathComponent("small.zip")
        for file in [large, small] { try Data([1]).write(to: file) }
        let writer = try FileHandle(forWritingTo: large); try writer.truncate(atOffset: 100_000_000); try writer.close()
        let db = try DiskDatabase(url: cache, root: home.path, home: home.path)
        try trustFixtureCache(cache)
        var scanner = DiskDatabaseScanner(db: db, excluded: [home.path + "/cache"])
        try scanner.scan(.init(), cursor: 1, progress: nil)
        let module = DiskMapModule(store: DiskStore(root: home.path, cache: cache.deletingPathExtension(), home: home.path))
        let initialValue = await module.page(id: DiskMapScreenBuilder.folderID(root.path), context: context())
        let initial = try XCTUnwrap(initialValue)
        let expansion = try XCTUnwrap(initial.widgets.compactMap { widget -> Row? in
            guard case let .list(list) = widget else { return nil }
            return list.rows.first { $0.title == "Show files smaller than 100 MB" }
        }.first)
        XCTAssertFalse(expansion.replacesPage)
        let id = try XCTUnwrap(expansion.pageID)
        var expanded: Screen?
        for _ in 0..<100 {
            let page = await module.page(id: id, context: context())
            if page?.loadingFraction == nil { expanded = page; break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let result = try XCTUnwrap(expanded)
        XCTAssertNil(result.hero)
        XCTAssertEqual(result.layout, .singleColumn)
        let rows = result.widgets.flatMap { if case let .list(list) = $0 { return list.rows }; return [] }
        XCTAssertTrue(rows.contains { $0.id == DiskFileRemoval.id(small.path) })
        XCTAssertFalse(rows.contains { $0.id == DiskFileRemoval.id(large.path) })
        XCTAssertFalse(result.widgets.contains { if case let .list(list) = $0 { return list.rows.contains { $0.title == "Show files smaller than 100 MB" } }; return false })
        await module.setActive(false)
    }
}

extension DiskNavigationRegressionTests {
    func testShowAllReadsReadySmallFileInventoryWithoutLoadingOrTemporaryWalk() async throws {
        let home = URL(fileURLWithPath: "/private/tmp/ready-small-index-" + UUID().uuidString)
        let root = home.appendingPathComponent("Downloads"), cache = home.appendingPathComponent("cache/index.sqlite")
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for n in 0..<451 { try Data([1]).write(to: root.appendingPathComponent("file-\(n).txt")) }
        let db = try DiskDatabase(url: cache, root: root.path, home: home.path)
        try trustFixtureCache(cache)
        var scanner = DiskDatabaseScanner(db: db, excluded: [])
        try scanner.scan(.init(), cursor: 1, progress: nil)
        XCTAssertEqual(try db.state()?.personalInventoryVersion, DiskIndex.personalInventorySchemaVersion)
        var request = DiskBrowseRequest(folder: root.path, kind: .category, category: .documents); request.includeSmaller = true
        let page = try XCTUnwrap(db.browse(request))
        XCTAssertNil(page.loadingFraction); XCTAssertEqual(page.eligibleCount, 451); XCTAssertEqual(page.files.count, 200)
        XCTAssertEqual(try db.query("SELECT 1 FROM sqlite_temp_master WHERE name='smaller'"), 0)
        let store = DiskStore(root: root.path, cache: cache.deletingPathExtension(), home: home.path)
        let module = DiskMapModule(store: store)
        let screenValue = await module.page(id: request.pageID, context: context()), screen = try XCTUnwrap(screenValue)
        XCTAssertNil(screen.loadingFraction); XCTAssertNil(screen.hero); XCTAssertEqual(screen.layout, .singleColumn)
        XCTAssertFalse(screen.widgets.contains { if case let .list(list) = $0 { return list.emptyMessage == "Reading files…" }; return false })
        await module.setActive(false)
    }
    func testOldCachePreparesPersonalMetadataOnceBeforeAllFilesNavigation() throws {
        let home = URL(fileURLWithPath: "/private/tmp/upgrade-small-index-" + UUID().uuidString)
        let root = home.appendingPathComponent("Downloads"), managed = home.appendingPathComponent("Library")
        defer { try? FileManager.default.removeItem(at: home) }
        for folder in [root, managed] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        try Data([1]).write(to: root.appendingPathComponent("small.txt"))
        try Data([1]).write(to: managed.appendingPathComponent("managed.txt"))
        let db = try DiskDatabase(url: home.appendingPathComponent("cache/index.sqlite"), root: home.path, home: home.path)
        try trustFixtureCache(home.appendingPathComponent("cache/index.sqlite"))
        try db.put(DiskDirectory(path: home.path)); try db.put(DiskDirectory(path: root.path)); try db.put(DiskDirectory(path: managed.path))
        var old = DiskIndex(root: home.path); old.storageRevision = 4; old.summaryVersion = DiskIndex.summarySchemaVersion
        try db.saveState(old)
        try db.preparePersonalInventory()
        XCTAssertEqual(try db.state()?.personalInventoryVersion, DiskIndex.personalInventorySchemaVersion)
        XCTAssertEqual(try db.query("SELECT path FROM file_details"), 1, "Only approved personal metadata belongs in the persistent file inventory")
        try Data([1]).write(to: root.appendingPathComponent("later.txt"))
        try db.preparePersonalInventory()
        XCTAssertEqual(try db.query("SELECT path FROM file_details"), 1, "Completed preparation must not run again during page navigation")
        var scanner = DiskDatabaseScanner(db: db, excluded: [])
        try scanner.scan(.init(shallow: [root.path]), cursor: 2, progress: nil)
        XCTAssertEqual(try db.query("SELECT path FROM file_details"), 2, "Changed-branch reconciliation updates small metadata incrementally")
    }
}
