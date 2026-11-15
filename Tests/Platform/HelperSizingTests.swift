import XCTest
import Darwin
@testable import MacSpacePlatform

final class HelperSizingTests: XCTestCase {
    private struct Totals: Equatable {
        var logical: UInt64 = 0, allocated: UInt64 = 0, purgeable: UInt64 = 0, privateReads = 0
        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.logical == rhs.logical && lhs.allocated == rhs.allocated && lhs.purgeable == rhs.purgeable
        }
    }
    /// The previous eager accounting serves as an independent reference for the on-demand reader.
    private func measured(_ root: String, privateSizes: Bool) -> Totals {
        let links = CloneLedger(), clones = CloneLedger()
        let walk = DirectoryWalk.walk(root, extended: true, privateSizes: privateSizes, makeState: { Totals() }) { sums, path, entry in
            if entry.isDirectory { return entry.isDataless ? .skip : .descend }
            guard entry.isRegularFile else { return .skip }
            if entry.linkCount > 1, let inode = HardLinks.inode(path()), !links.claimLink(inode) { return .skip }
            sums.logical += entry.logicalBytes
            var bytes = entry.allocatedBytes
            if bytes > 0, entry.cloneFamily != 0, !clones.claim(entry.cloneFamily) {
                sums.privateReads += 1
                bytes = min(bytes, privateSizes ? entry.privateBytes : FileTreeSizer.livePrivateBytes(path()))
            }
            sums.allocated += bytes
            if entry.extendedFlags & UInt64(EF_IS_PURGEABLE) != 0 { sums.purgeable += bytes }
            return .skip
        }
        return walk.states.first ?? Totals()
    }

    func testDemandPrivateSizesMatchBatchedCloneAndHardLinkAccounting() throws {
        let root = URL(fileURLWithPath: "/private/tmp/demand-private-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("nested"), withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source"), clone = root.appendingPathComponent("nested/clone")
        try Data(repeating: 3, count: 65536).write(to: source)
        XCTAssertEqual(clonefile(source.path, clone.path, 0), 0)
        XCTAssertEqual(clonefile(source.path, root.appendingPathComponent("nested/unchanged-clone").path, 0), 0)
        let writer = try FileHandle(forWritingTo: clone)
        try writer.write(contentsOf: Data(repeating: 7, count: 8192)); try writer.close()
        XCTAssertEqual(link(source.path, root.appendingPathComponent("nested/alias").path), 0)
        for number in 0..<16 { try Data(repeating: UInt8(number), count: 8192).write(to: root.appendingPathComponent("ordinary-\(number)")) }
        let eager = measured(root.path, privateSizes: true)
        XCTAssertGreaterThan(eager.privateReads, 0, "The fixture must exercise private clone accounting")
        XCTAssertEqual(eager, measured(root.path, privateSizes: false))
        for pool in [nil, ScanPool(free: 2)] {
            for refuses in [false, true] {
                let actual = try XCTUnwrap(FileTreeSizer(countsPurgeable: true, clones: CloneLedger(), pool: pool, refusesLinks: refuses).size(at: root))
                XCTAssertEqual(actual.logicalBytes, eager.logical)
                XCTAssertEqual(actual.bytes, eager.allocated)
                XCTAssertEqual(actual.purgeableBytes, eager.purgeable)
            }
            XCTAssertEqual(AllocatedSize.allocatedBytes(root.path, excluding: [], clones: CloneLedger(), pool: pool), eager.allocated)
        }
    }

    func testNativePrivateSizeDemandComparison() throws {
        guard let root = ProcessInfo.processInfo.environment["MACSPACE_PRIVATE_SIZES_ROOT"] else { throw XCTSkip("Opt-in read-only attribute diagnostic") }
        for pair in 0..<3 {
            let order = pair % 2 == 0 ? [true, false] : [false, true]
            var expected: Totals?
            for eager in order {
                let start = Date(), result = measured(root, privateSizes: eager)
                print("PRIVATE_SIZE_DIAGNOSTIC pair=\(pair) eager=\(eager) seconds=\(Date().timeIntervalSince(start)) logical=\(result.logical) allocated=\(result.allocated) repeatedFamilies=\(result.privateReads)")
                if let expected { XCTAssertEqual(result, expected) }
                expected = result
            }
        }
    }
    /// The helper sizes root's folders with links refused anywhere in the path, purgeable files counted and helper threads: every
    /// combination must give the tree's size.
    func testEverySettingTheScanAndTheHelperUseGivesTheSameSize() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sizer-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("a/b"), withIntermediateDirectories: true)
        try Data(count: 2_000_000).write(to: root.appendingPathComponent("a/b/file"))
        try Data(count: 1_000_000).write(to: root.appendingPathComponent("top"))
        // The temporary folder is under /var, a link to /private/var: name it as the helper's callers do.
        let path = URL(fileURLWithPath: root.path.replacingOccurrences(of: "/var/", with: "/private/var/"))
        let plain = try XCTUnwrap(FileTreeSizer().size(at: path)?.bytes)
        XCTAssertGreaterThanOrEqual(plain, 3_000_000)
        for refuses in [false, true] {
            for pool in [nil, ScanPool(free: 2)] {
                let size = FileTreeSizer(countsPurgeable: true, pool: pool, refusesLinks: refuses).size(at: path)?.bytes
                XCTAssertEqual(size, plain, "refusesLinks \(refuses), pool \(pool != nil)")
            }
        }
    }
}
