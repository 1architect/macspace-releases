import Darwin
import Foundation
import XCTest
@testable import MacSpaceDiskMap

final class DiskMapPerformanceTests: XCTestCase {
    private final class MemorySampler: @unchecked Sendable {
        private let lock = NSLock()
        private var maximum: UInt64 = 0
        private let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        static func footprint() -> UInt64 {
            var info = rusage_info_v6()
            _ = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V6, $0) }
            }
            return info.ri_phys_footprint
        }
        init() {
            maximum = Self.footprint()
            timer.setEventHandler { [weak self] in self?.sample() }
            timer.schedule(deadline: .now(), repeating: .milliseconds(10)); timer.resume()
        }
        private func sample() { let current = Self.footprint(); lock.withLock { maximum = max(maximum, current) } }
        func stop() -> UInt64 { timer.cancel(); sample(); return lock.withLock { maximum } }
    }

    func testHundredThousandDirectoryCacheDoesNotBuildASecondWholeIndexObjectGraph() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("disk-cache-memory-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var index = DiskIndex(root: "/fixture")
        let paths = (0..<100_000).map { "/fixture/folder\($0)" }
        index.directories[index.root] = DiskDirectory(path: index.root, folders: paths)
        for path in paths { index.directories[path] = DiskDirectory(path: path, directBytes: 4096, bytes: 4096) }
        let baseline = MemorySampler.footprint(), sampler = MemorySampler()
        let cache = folder.appendingPathComponent("index.scan")
        let started = Date()
        try DiskCache.write(index, to: cache)
        let restored = try DiskCache.read(from: cache, root: index.root)
        XCTAssertEqual(restored.directories.count, index.directories.count)
        XCTAssertEqual(restored.directories[paths.last!]?.bytes, 4096)
        let peak = sampler.stop(), extra = peak > baseline ? peak - baseline : 0
        print("DISK_CACHE_BENCHMARK directories=\(restored.directories.count) extraPeakMiB=\(Double(extra) / 1_048_576) seconds=\(Date().timeIntervalSince(started))")
        XCTAssertLessThan(extra, 160 * 1_048_576, "Cache serialization must be bounded to records, not a full JSON DOM")
        // Truncation must not silently turn an incomplete scan into an apparently complete index.
        let file = try FileHandle(forWritingTo: cache)
        try file.truncate(atOffset: 16); try file.close()
        XCTAssertThrowsError(try DiskCache.read(from: cache, root: index.root))
        withExtendedLifetime(index) {}
    }

    func testNewCloudPlaceholdersDoNotSweepTheExistingIndex() throws {
        var index = DiskIndex(root: "/fixture")
        index.directories[index.root] = DiskDirectory(path: index.root)
        for n in 0..<100_000 { let path = "/fixture/stable/\(n)"; index.directories[path] = DiskDirectory(path: path) }
        let clouds = Set((0..<1000).map { "/fixture/cloud\($0)" })
        var scanner = DiskScanner(index: index, metadata: { path in
            var info = stat(); info.st_mode = S_IFDIR; info.st_dev = 1
            if path.hasPrefix("/fixture/cloud") { info.st_flags = UInt32(SF_DATALESS) }
            return info
        })
        let started = Date()
        let result = try scanner.scan(changed: clouds)
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertTrue(scanner.enumerated.isEmpty)
        XCTAssertEqual(result.directories.count, 101_001)
        XCTAssertLessThan(elapsed, 5, "A new cloud folder must not search the entire cached disk")
        print("DISK_CLOUD_BENCHMARK cachedDirectories=100000 newCloudDirectories=1000 seconds=\(elapsed)")
    }
}
