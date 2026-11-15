import Darwin
import Foundation
import XCTest
@testable import MacSpacePlatform

private final class ArchiveKeys: MetadataKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    func read(_ account: String) throws -> Data? { lock.withLock { values[account] } }
    func create(_ account: String, value: Data) throws { lock.withLock { values[account] = value } }
    func replace(_ account: String, value: Data) throws { lock.withLock { values[account] = value } }
    func delete(_ account: String) throws { _ = lock.withLock { values.removeValue(forKey: account) } }
}

final class DirectoryListingArchiveTests: XCTestCase {
    private var folder: URL!
    private var location: URL { folder.appendingPathComponent("cache/facts.sqlite") }
    private var identity: DirectoryListingArchive.Identity {
        var value = stat(); XCTAssertEqual(lstat(folder.path, &value), 0)
        return .init(value)
    }
    override func setUpWithError() throws {
        MetadataKeys.useStore(ArchiveKeys())
        folder = URL(fileURLWithPath: "/private/tmp/listing-archive-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
        MetadataKeys.useStore(SilentMetadataKeyStore())
    }
    private func seed(_ paths: [String]) throws {
        let archive = try DirectoryListingArchive(url: location, validateHistory: false)
        for path in paths { archive.record(Data("protected-directory-facts-fixture".utf8), path: path, request: "extended", identity: identity) }
        archive.finish()
    }

    func testCompletedFactsAreEncryptedAndBoundToTheirDirectoryAndRequest() throws {
        let path = folder.appendingPathComponent("data").path
        try seed([path])
        let archive = try DirectoryListingArchive(url: location, validateHistory: false)
        XCTAssertEqual(archive.read(path, request: "extended", identity: identity), Data("protected-directory-facts-fixture".utf8))
        XCTAssertNil(archive.read(path, request: "basic", identity: identity))
        var altered = stat(); XCTAssertEqual(lstat(folder.path, &altered), 0); altered.st_ino += 1
        XCTAssertNil(archive.read(path, request: "extended", identity: .init(altered)))
        archive.finish()
        let bytes = try Data(contentsOf: location)
        XCTAssertNil(bytes.range(of: Data("protected-directory-facts-fixture".utf8)))
        XCTAssertNil(bytes.range(of: Data(path.utf8)))
    }

    func testExplicitChangesInvalidateOnlyTheirScopesAndLostHistoryInvalidatesEverything() throws {
        let root = folder.appendingPathComponent("data").path
        let paths = [root, root + "/child", root + "-sibling"]
        try seed(paths)
        do {
            let archive = try DirectoryListingArchive(url: location, validateHistory: false, changes: .init(shallow: [root]))
            XCTAssertNil(archive.read(root, request: "extended", identity: identity))
            XCTAssertNotNil(archive.read(root + "/child", request: "extended", identity: identity))
            archive.finish()
        }
        do {
            let archive = try DirectoryListingArchive(url: location, validateHistory: false, changes: .init(recursive: [root]))
            XCTAssertNil(archive.read(root + "/child", request: "extended", identity: identity))
            XCTAssertNotNil(archive.read(root + "-sibling", request: "extended", identity: identity))
            archive.finish()
        }
        let archive = try DirectoryListingArchive(url: location, validateHistory: false, changes: .init(lost: true))
        XCTAssertNil(archive.read(root + "-sibling", request: "extended", identity: identity))
        archive.finish()
    }

    func testInterruptedEpochCannotMakeNewOrOldFactsLookCurrent() throws {
        let path = folder.appendingPathComponent("data").path
        try seed([path])
        do {
            let archive = try DirectoryListingArchive(url: location, validateHistory: false)
            for index in 0..<1024 {
                archive.record(Data([1]), path: path + "/\(index)", request: "extended", identity: identity)
            }
            // Do not finish: bounded batches may exist but their generation remains incomplete.
        }
        let archive = try DirectoryListingArchive(url: location, validateHistory: false)
        XCTAssertNil(archive.read(path, request: "extended", identity: identity))
        XCTAssertNil(archive.read(path + "/0", request: "extended", identity: identity))
        archive.finish()
    }

    func testAnotherReaderCannotShareAnUnfinishedGenerationAndLinksAreRefused() throws {
        let archive = try DirectoryListingArchive(url: location, validateHistory: false)
        XCTAssertThrowsError(try DirectoryListingArchive(url: location, validateHistory: false))
        archive.finish()
        let redirected = folder.appendingPathComponent("redirected")
        XCTAssertEqual(symlink(location.deletingLastPathComponent().path, redirected.path), 0)
        XCTAssertThrowsError(try DirectoryListingArchive(url: redirected.appendingPathComponent("facts.sqlite"), validateHistory: false))
    }

    func testNativeBatchesReplayAcrossReadersAndReopenWithoutChangingEntries() throws {
        let root = folder.appendingPathComponent("data")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("nested/empty"), withIntermediateDirectories: true)
        try Data(repeating: 7, count: 8192).write(to: root.appendingPathComponent("nested/文档.txt"))
        func walk(_ archive: DirectoryListingArchive?) -> (rows: [String], cached: Int) {
            struct Records { var rows: [String] = []; var cached = 0 }
            let result = DirectoryWalk.walk(root.path, extended: true, archive: archive, makeState: { Records() }) { records, path, entry in
                records.rows.append("\(path()):\(entry.type):\(entry.device):\(entry.ownerUID):\(entry.flags):\(entry.linkCount):\(entry.logicalBytes):\(entry.allocatedBytes):\(entry.cloneFamily):\(entry.privateBytes):\(entry.extendedFlags)")
                if entry.fromArchive { records.cached += 1 }
                return entry.isDirectory && !entry.isDataless ? .descend : .skip
            }
            return (result.states.flatMap(\.rows).sorted(), result.states.reduce(0) { $0 + $1.cached })
        }
        let expected = walk(nil)
        XCTAssertFalse(expected.rows.isEmpty)
        do {
            let archive = try DirectoryListingArchive(url: location, validateHistory: false)
            XCTAssertEqual(walk(archive).rows, expected.rows)
            let repeated = walk(archive)
            XCTAssertEqual(repeated.rows, expected.rows)
            XCTAssertEqual(repeated.cached, expected.rows.count)
            archive.finish()
        }
        let archive = try DirectoryListingArchive(url: location, validateHistory: false)
        let restored = walk(archive)
        XCTAssertEqual(restored.rows, expected.rows)
        XCTAssertEqual(restored.cached, expected.rows.count)
        archive.finish()
    }

    func testNewCloneAndHardLinkAliasesDoNotReuseStaleAccounting() throws {
        for clone in [true, false] {
            let root = folder.appendingPathComponent(clone ? "clone-data" : "link-data")
            let source = root.appendingPathComponent("source/original")
            let destination = root.appendingPathComponent("destination/new")
            try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 1, count: 8192).write(to: source)
            let url = folder.appendingPathComponent(clone ? "clone-cache/facts.sqlite" : "link-cache/facts.sqlite")
            do {
                let archive = try DirectoryListingArchive(url: url, validateHistory: false)
                _ = FileTreeSizer(countsPurgeable: true, clones: CloneLedger(), pool: ScanPool(free: 0, archive: archive)).size(at: root)
                archive.finish()
            }
            if clone { XCTAssertEqual(clonefile(source.path, destination.path, 0), 0) }
            else { XCTAssertEqual(link(source.path, destination.path), 0) }
            let expected = FileTreeSizer(countsPurgeable: true, clones: CloneLedger()).size(at: root)
            let archive = try DirectoryListingArchive(url: url, validateHistory: false,
                changes: .init(shallow: [destination.deletingLastPathComponent().path]))
            let actual = FileTreeSizer(countsPurgeable: true, clones: CloneLedger(), pool: ScanPool(free: 0, archive: archive)).size(at: root)
            XCTAssertGreaterThan(archive.statistics.hits, 0)
            XCTAssertEqual(actual, expected, clone ? "clone-private bytes" : "a cached single-link file gained a second name")
            archive.finish()
        }
    }

    func testCachedClonePrivateBytesAreRefreshedAfterAnotherMemberIsWritten() throws {
        let root = folder.appendingPathComponent("partial-clones")
        let original = root.appendingPathComponent("source/original"), clone = root.appendingPathComponent("destination/clone")
        try FileManager.default.createDirectory(at: original.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: clone.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 8192).write(to: original)
        XCTAssertEqual(clonefile(original.path, clone.path, 0), 0)
        do {
            let archive = try DirectoryListingArchive(url: location, validateHistory: false)
            _ = FileTreeSizer(clones: CloneLedger(), pool: ScanPool(free: 0, archive: archive)).size(at: root)
            archive.finish()
        }
        let writer = try FileHandle(forWritingTo: clone)
        try writer.write(contentsOf: Data(repeating: 8, count: 4096)); try writer.close()
        XCTAssertGreaterThan(FileTreeSizer.livePrivateBytes(original.path), 0)
        let archive = try DirectoryListingArchive(url: location, validateHistory: false,
            changes: .init(shallow: [clone.deletingLastPathComponent().path]))
        let pool = ScanPool(free: 0, archive: archive)
        let expected = FileTreeSizer(clones: CloneLedger()).size(at: root)
        let actual = FileTreeSizer(clones: CloneLedger(), pool: pool).size(at: root)
        XCTAssertEqual(actual, expected)
        XCTAssertEqual(AllocatedSize.allocatedBytes(root.path, excluding: [], clones: CloneLedger(), pool: pool),
                       AllocatedSize.allocatedBytes(root.path, excluding: [], clones: CloneLedger()))
        XCTAssertGreaterThan(archive.statistics.hits, 0)
        archive.finish()
    }

    func testOverlappingOrdinaryRootsRetainTheirExistingCountingPolicy() throws {
        let root = folder.appendingPathComponent("ordinary")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 8192).write(to: root.appendingPathComponent("file"))
        let archive = try DirectoryListingArchive(url: location, validateHistory: false)
        let cachedLedger = CloneLedger(), liveLedger = CloneLedger()
        for _ in 0..<2 {
            let cached = FileTreeSizer(countsPurgeable: true, clones: cachedLedger, pool: ScanPool(free: 0, archive: archive)).size(at: root)
            let fresh = FileTreeSizer(countsPurgeable: true, clones: liveLedger).size(at: root)
            XCTAssertEqual(cached, fresh)
        }
        archive.finish()
    }

    func testLiveHistoryReusesUnchangedFactsAndDetectsChangesWhileClosed() throws {
        guard ProcessInfo.processInfo.environment["MACSPACE_DIRECTORY_HISTORY_TEST"] == "1" else { throw XCTSkip("Opt-in native FSEvents history fixture") }
        let root = folder.appendingPathComponent("history-data")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("file")
        try Data(repeating: 1, count: 8192).write(to: file)
        func measure(_ archive: DirectoryListingArchive) throws -> FileTreeSize {
            try XCTUnwrap(FileTreeSizer(countsPurgeable: true, clones: CloneLedger(), pool: ScanPool(free: 0, archive: archive)).size(at: root))
        }
        do {
            let archive = try DirectoryListingArchive(url: location)
            _ = try measure(archive); archive.finish()
        }
        do {
            let archive = try DirectoryListingArchive(url: location)
            _ = try measure(archive)
            XCTAssertGreaterThan(archive.statistics.hits, 0, "A native cache hit is required, not merely successful fallback")
            archive.finish()
        }
        // Content changes leave the containing directory's timestamps unchanged: history must retire the old payload.
        try Data(repeating: 2, count: 16384).write(to: file)
        let archive = try DirectoryListingArchive(url: location)
        XCTAssertEqual(try measure(archive), FileTreeSizer(countsPurgeable: true, clones: CloneLedger()).size(at: root))
        XCTAssertGreaterThan(archive.statistics.misses, 0)
        archive.finish()
    }

    func testLiveHistoryRetiresCachedBasicMetadataWhenAnAliasAppearsElsewhere() throws {
        guard ProcessInfo.processInfo.environment["MACSPACE_DIRECTORY_HISTORY_TEST"] == "1" else { throw XCTSkip("Opt-in native FSEvents history fixture") }
        let root = folder.appendingPathComponent("link-source"), aliases = folder.appendingPathComponent("link-aliases")
        for directory in [root, aliases] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        let source = root.appendingPathComponent("file")
        try Data(repeating: 1, count: 8192).write(to: source)
        do {
            let archive = try DirectoryListingArchive(url: location)
            _ = DirectoryWalk.walk(root.path, extended: true, archive: archive, makeState: { 0 }) { _, _, _ in .skip }
            archive.finish()
        }
        try FileManager.default.linkItem(at: source, to: aliases.appendingPathComponent("alias"))
        let archive = try DirectoryListingArchive(url: location)
        func links(_ cache: DirectoryListingArchive?) -> [UInt32] {
            DirectoryWalk.walk(root.path, extended: false, archive: cache, makeState: { [UInt32]() }) { counts, _, entry in
                counts.append(entry.linkCount); return .skip
            }.states.flatMap { $0 }
        }
        XCTAssertEqual(links(archive), [2])
        XCTAssertEqual(links(archive), links(nil))
        XCTAssertGreaterThan(archive.statistics.misses, 0)
        archive.finish()
    }

    func testSharedLeasesPublishOnlyAfterTheLastReaderAndDiscardOlderInFlightOutput() throws {
        let path = folder.appendingPathComponent("shared-data").path
        let first = try DirectoryListingArchive.borrow(location, validateHistory: false)
        let initial = first.archive.lookup(path, request: "fixture", identity: identity)
        let second = try DirectoryListingArchive.borrow(location, validateHistory: false)
        XCTAssertTrue(first.archive === second.archive)
        first.archive.record(Data([1]), path: path, request: "fixture", identity: identity, generation: initial.generation)
        XCTAssertNil(second.archive.read(path, request: "fixture", identity: identity))
        let current = second.archive.lookup(path, request: "fixture", identity: identity)
        second.archive.record(Data([2]), path: path, request: "fixture", identity: identity, generation: current.generation)
        first.finish(); first.finish()
        XCTAssertEqual(second.archive.read(path, request: "fixture", identity: identity), Data([2]))
        second.finish()
        XCTAssertNil(first.archive.read(path, request: "fixture", identity: identity))
        // Finished leases may remain referenced: their file lock must already be released.
        let next = try DirectoryListingArchive.borrow(location, validateHistory: false)
        XCTAssertEqual(next.archive.read(path, request: "fixture", identity: identity), Data([2]))
        next.finish()
    }

    func testConcurrentNegativeLookupsAndPopulationSurviveCheckpointsAndInvalidation() throws {
        let archive = try DirectoryListingArchive(url: location, validateHistory: false)
        let identity = identity, root = folder.appendingPathComponent("concurrent-data").path
        DispatchQueue.concurrentPerform(iterations: 8) { worker in
            for number in 0..<256 {
                let path = root + "/\(worker)-\(number)", payload = Data(path.utf8)
                let lookup = archive.lookup(path, request: "fixture", identity: identity)
                XCTAssertNil(lookup.data)
                archive.record(payload, path: path, request: "fixture", identity: identity, generation: lookup.generation)
                XCTAssertEqual(archive.read(path, request: "fixture", identity: identity), payload)
            }
        }
        archive.advanceReadBoundary(changes: .init(lost: true))
        let lookup = archive.lookup(root + "/0-0", request: "fixture", identity: identity)
        XCTAssertNil(lookup.data)
        archive.record(Data([7]), path: root + "/0-0", request: "fixture", identity: identity, generation: lookup.generation)
        XCTAssertEqual(archive.read(root + "/0-0", request: "fixture", identity: identity), Data([7]))
        archive.finish()
    }

    func testNegativeLookupDoesNotWaitForTheFenceAndCannotPublishBeforeItsBoundary() throws {
        let archive = try DirectoryListingArchive(url: location, validateHistory: false)
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), finished = DispatchGroup()
        finished.enter()
        DispatchQueue.global().async {
            archive.advanceReadBoundary(changes: {
                entered.signal()
                _ = release.wait(timeout: .now() + 5)
                return .init(lost: true)
            })
            finished.leave()
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        let path = folder.appendingPathComponent("during-fence").path, start = Date()
        let lookup = archive.lookup(path, request: "fixture", identity: identity)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1, "A negative lookup must not wait for history or a checkpoint")
        release.signal()
        XCTAssertEqual(finished.wait(timeout: .now() + 2), .success)
        archive.record(Data([1]), path: path, request: "fixture", identity: identity, generation: lookup.generation)
        XCTAssertNil(archive.read(path, request: "fixture", identity: identity), "Pre-fence native output must not become current")
        let current = archive.lookup(path, request: "fixture", identity: identity)
        archive.record(Data([2]), path: path, request: "fixture", identity: identity, generation: current.generation)
        XCTAssertEqual(archive.read(path, request: "fixture", identity: identity), Data([2]))
        archive.finish()
    }

    func testSharedSupersetPreservesBasicDatesAndExtendedAttributeVisibility() throws {
        let root = folder.appendingPathComponent("visible-data")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(repeating: 3, count: 8192).write(to: root.appendingPathComponent("file"))
        let archive = try DirectoryListingArchive(url: location, validateHistory: false)
        func records(_ cache: DirectoryListingArchive?, extended: Bool, dates: Bool) -> (rows: [String], cached: Int) {
            struct Records { var rows: [String] = []; var cached = 0 }
            let result = DirectoryWalk.walk(root.path, extended: extended, modificationDates: dates, archive: cache, makeState: { Records() }) { records, path, entry in
                records.rows.append("\(path()):\(entry.allocatedBytes):\(entry.modifiedAt?.timeIntervalSince1970 ?? -1):\(entry.cloneFamily):\(entry.privateBytes):\(entry.extendedFlags)")
                if entry.fromArchive { records.cached += 1 }; return .skip
            }
            return (result.states.flatMap(\.rows).sorted(), result.states.reduce(0) { $0 + $1.cached })
        }
        let basic = records(archive, extended: false, dates: true)
        XCTAssertEqual(basic.rows, records(nil, extended: false, dates: true).rows)
        XCTAssertEqual(archive.statistics.hits, 0)
        let extended = records(archive, extended: true, dates: false)
        XCTAssertEqual(extended.rows, records(nil, extended: true, dates: false).rows)
        XCTAssertEqual(extended.cached, 0, "A basic inventory miss must not populate extended facts")
        XCTAssertEqual(records(archive, extended: false, dates: true).rows, basic.rows)
        XCTAssertEqual(records(archive, extended: true, dates: false).cached, 1)
        XCTAssertEqual(records(archive, extended: false, dates: false).rows, records(nil, extended: false, dates: false).rows)
        archive.finish()
    }

    func testEventAliasesShareCanonicalKeys() {
        XCTAssertEqual(DirectoryChangeHistory.canonical("/var/folders/x"), "/private/var/folders/x")
        XCTAssertEqual(DirectoryChangeHistory.canonical("/System/Volumes/Data/Users/me/Library"), "/Users/me/Library")
    }
}
