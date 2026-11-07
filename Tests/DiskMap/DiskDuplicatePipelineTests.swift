import CryptoKit
import Darwin
import Foundation
import XCTest
import MacSpacePlatform
@testable import MacSpaceDiskMap

final class DiskDuplicatePipelineTests: DiskSecurityFixtureCase {
    private actor Storage: DiskDuplicateStorage {
        let database: DiskDatabase
        var removeBeforeSample: String?
        init(root: URL) throws {
            database = try DiskDatabase(url: root.appendingPathComponent("index.sqlite"), root: root.path)
            database.inventoryIncludes = { _ in true }
            try database.put(DiskDirectory(path: root.path))
        }
        func index(_ urls: [URL]) throws {
            for url in urls {
                var info = stat()
                guard lstat(url.path, &info) == 0 else { throw POSIXError(.ENOENT) }
                try database.putDetail(.init(path: url.path, bytes: UInt64(info.st_blocks) * 512,
                                             logicalBytes: UInt64(info.st_size), ownerUID: getuid()), link: "")
            }
        }
        func beginDuplicatePass(folder: String, minimumSize: UInt64) throws { try database.beginDuplicatePass(folder: folder, minimumSize: minimumSize) }
        func duplicateMetadata(after: String) throws -> [DiskFile] { try database.duplicateMetadata(after: after) }
        func stageDuplicate(_ file: DiskFile, identity: FileReviewIdentity) throws { try database.stageDuplicate(file, identity: identity) }
        func duplicateWork(sample: Bool, after: String) throws -> [DiskDuplicateWork] {
            let work = try database.duplicateWork(sample: sample, after: after)
            if sample, let path = removeBeforeSample { removeBeforeSample = nil; try FileManager.default.removeItem(atPath: path) }
            return work
        }
        func saveDuplicate(_ work: DiskDuplicateWork, sample: Data, digest: Data?) throws { try database.saveDuplicate(work, sample: sample, digest: digest) }
        func failDuplicate(_ path: String) throws { try database.failDuplicate(path) }
        func finishDuplicatePass() throws { try database.finishDuplicatePass() }
        func page(_ root: URL) throws -> DiskBrowsePage { try database.duplicatePage(.init(folder: root.path, kind: .duplicates)) }
        func cacheCount() throws -> Int { try database.query("SELECT path FROM duplicate_fingerprints") }
        func removeWhenSampled(_ path: String) { removeBeforeSample = path }
    }

    private func temporary() throws -> URL {
        let root = URL(fileURLWithPath: "/private/tmp/duplicate-pipeline-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// Materialize all bytes with one reused chunk; logical length and actual contents agree.
    @discardableResult
    private func payload(_ url: URL, mebibytes: Int) throws -> Data {
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        defer { close(descriptor) }
        let chunk = Data(repeating: 0x31, count: 1_048_576)
        var digest = SHA256()
        for _ in 0..<mebibytes {
            try chunk.withUnsafeBytes { bytes in
                var written = 0
                while written < bytes.count {
                    let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: written), bytes.count - written)
                    if count < 0, errno == EINTR { continue }
                    guard count > 0 else { throw POSIXError(.EIO) }
                    written += count
                }
            }
            digest.update(data: chunk)
        }
        return Data(digest.finalize())
    }

    private func change(_ url: URL, at offset: UInt64) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        try handle.write(contentsOf: Data([0x7f]))
    }

    func testRealLargeCandidatesCollapseHardlinksSampleThenVerifyAndReuseCache() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("a"), alias = root.appendingPathComponent("a-alias")
        let b = root.appendingPathComponent("b"), c = root.appendingPathComponent("c"), d = root.appendingPathComponent("d")
        try payload(a, mebibytes: 128)
        for url in [b, c, d] { try FileManager.default.copyItem(at: a, to: url) }
        try change(c, at: 256 * 1024) // Outside all sample windows: only full verification can reject it.
        try change(d, at: 0) // Sampling rejects this file before any full read.
        try FileManager.default.linkItem(at: a, to: alias)
        let storage = try Storage(root: root)
        try await storage.index([a, alias, b, c, d])
        let first = try await DiskDuplicatePipeline.run(storage: storage, folder: root.path, eligible: { _ in true })
        XCTAssertEqual(first.sampled, 4)
        XCTAssertEqual(first.verified, 3)
        XCTAssertEqual(first.unknown, 0)
        let page = try await storage.page(root)
        XCTAssertEqual(page.files.map(\.path), [a.path, b.path])
        XCTAssertEqual(page.duplicateGroups.first?.keeper.path, a.path)
        XCTAssertNotNil(page.duplicateGroups.first?.keeper.duplicateVerification)
        XCTAssertEqual(page.files.first?.logicalBytes, 128 * 1_048_576)
        let cacheCount = try await storage.cacheCount()
        XCTAssertEqual(cacheCount, 4)
        let second = try await DiskDuplicatePipeline.run(storage: storage, folder: root.path, eligible: { _ in true })
        XCTAssertEqual(second.sampled, 0)
        XCTAssertEqual(second.verified, 0)
        XCTAssertEqual(second.reused, 3)
        XCTAssertEqual(second.unknown, 0)
    }

    func testExpandedScopeIncludesSmallCopiesAndOriginalKeeperProofFailsAfterChange() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("personal")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let a = folder.appendingPathComponent("a"), b = folder.appendingPathComponent("b")
        try payload(a, mebibytes: 1); try FileManager.default.copyItem(at: a, to: b)
        let storage = try Storage(root: root)
        let report = try await DiskDuplicatePipeline.run(storage: storage, folder: folder.path, scoped: true, eligible: { _ in true })
        XCTAssertEqual(report.verified, 2)
        let page = try await storage.page(folder)
        let proof = try XCTUnwrap(page.files.first?.duplicateVerification)
        XCTAssertTrue(try proof.verify(eligible: { _ in true }))
        // Restore mtime after a same-size edit: ctime still invalidates the reviewed keeper.
        let modified = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: a.path)[.modificationDate] as? Date)
        try change(a, at: 256 * 1024)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: a.path)
        XCTAssertFalse(try proof.verify(eligible: { _ in true }))
        let stale = try await storage.page(folder)
        XCTAssertTrue(stale.files.isEmpty)
        let rerun = try await DiskDuplicatePipeline.run(storage: storage, folder: folder.path, scoped: true, eligible: { _ in true })
        XCTAssertEqual(rerun.sampled, 1)
        XCTAssertEqual(rerun.verified, 1)
        let after = try await storage.page(folder)
        XCTAssertTrue(after.files.isEmpty)
    }

    func testMissingCandidateIsUnknownAndOtherScopeCacheSurvives() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let storage = try Storage(root: root)
        for name in ["first", "second"] {
            let folder = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let a = folder.appendingPathComponent("a"), b = folder.appendingPathComponent("b")
            try payload(a, mebibytes: 1); try FileManager.default.copyItem(at: a, to: b)
            if name == "second" { await storage.removeWhenSampled(b.path) }
            let result = try await DiskDuplicatePipeline.run(storage: storage, folder: folder.path, scoped: true, eligible: { _ in true })
            if name == "second" { XCTAssertEqual(result.unknown, 1) }
        }
        let first = try await storage.page(root.appendingPathComponent("first"))
        XCTAssertEqual(first.files.count, 2)
        let second = try await storage.page(root.appendingPathComponent("second"))
        XCTAssertTrue(second.files.isEmpty)
    }

    private static func footprint() -> UInt64 {
        var info = rusage_info_v6()
        _ = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V6, $0) } }
        return info.ri_phys_footprint
    }

    private final class Sampler: @unchecked Sendable {
        let lock = NSLock()
        var peak = DiskDuplicatePipelineTests.footprint()
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        init() {
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                let value = DiskDuplicatePipelineTests.footprint()
                lock.withLock { peak = max(peak, value) }
            }
            timer.schedule(deadline: .now(), repeating: .milliseconds(5)); timer.resume()
        }
        func stop() -> UInt64 { timer.cancel(); return lock.withLock { max(peak, DiskDuplicatePipelineTests.footprint()) } }
    }

    func testRepeatedReal512MiBReadsHaveConstantMemoryAndHonorCancellation() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("payload")
        let expected = try payload(file, mebibytes: 512)
        let baseline = Self.footprint(), sampler = Sampler()
        let reader = DiskDuplicateReader()
        // Deliberately no autoreleasepool around the loop: per-chunk Foundation buffers would accumulate here.
        for _ in 0..<3 { XCTAssertEqual(try reader.hash(file.path), expected) }
        let peak = sampler.stop(), growth = peak > baseline ? peak - baseline : 0
        XCTAssertLessThan(growth, 24 * 1_048_576, "Streaming 1.5 GiB must use a fixed buffer, not retain chunks")
        let cancelled = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try DiskDuplicateReader().hash(file.path)
        }
        do { _ = try await cancelled.value; XCTFail("A cancelled reader must stop before reading") }
        catch is CancellationError { }
    }
}
