import Darwin
import Foundation
import XCTest
@testable import MacSpacePlatform

final class DirectoryAttributeBatchTests: XCTestCase {
    func testNativeEncodingRejectsEveryTruncatedFrameAndInvalidLengths() throws {
        let root = URL(fileURLWithPath: "/private/tmp/attribute-batch-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data([1]).write(to: root.appendingPathComponent("é_文档.txt"))
        let fd = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(fd, 0); defer { close(fd) }
        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS)
        for flag in [ATTR_CMN_ERROR, ATTR_CMN_NAME, ATTR_CMN_DEVID, ATTR_CMN_OBJTYPE, ATTR_CMN_OWNERID, ATTR_CMN_FLAGS, ATTR_CMN_FILEID] {
            request.commonattr |= attrgroup_t(flag)
        }
        request.fileattr = attrgroup_t(ATTR_FILE_LINKCOUNT | ATTR_FILE_TOTALSIZE | ATTR_FILE_ALLOCSIZE)
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: 256 * 1024, alignment: 8)
        defer { buffer.deallocate() }
        let count = getattrlistbulk(fd, &request, buffer, 256 * 1024, 0)
        XCTAssertEqual(count, 1)
        let length = Int(buffer.loadUnaligned(as: UInt32.self))
        let encoded = try XCTUnwrap(DirectoryAttributeBatches.encode([.init(count: count, bytes: Data(bytes: buffer, count: length))], request: request))
        XCTAssertEqual(DirectoryAttributeBatches.decode(encoded, request: request)?.count, 1)
        for length in 0..<encoded.count { XCTAssertNil(DirectoryAttributeBatches.decode(Data(encoded.prefix(length)), request: request), "prefix \(length)") }
        var malformed = encoded
        malformed.replaceSubrange(16..<20, with: [UInt8](repeating: 0xff, count: 4))
        XCTAssertNil(DirectoryAttributeBatches.decode(malformed, request: request))
        let empty = try XCTUnwrap(DirectoryAttributeBatches.encode([], request: request))
        XCTAssertEqual(DirectoryAttributeBatches.decode(empty, request: request)?.count, 0)

        let native = Data(bytes: buffer, count: length)
        let batch = DirectoryAttributeBatches.Batch(count: 64, bytes: Data((0..<64).flatMap { _ in native }))
        let raw = try XCTUnwrap(DirectoryAttributeBatches.encode([batch], request: request))
        let scratch = UnsafeMutableRawPointer.allocate(byteCount: max(1, DirectoryAttributeBatches.compressionScratchSize), alignment: 16)
        defer { scratch.deallocate() }
        let compact = DirectoryAttributeBatches.compact(raw, into: buffer, capacity: 256 * 1024, scratch: scratch)
        XCTAssertLessThan(compact.count, raw.count)
        let replay = try XCTUnwrap(DirectoryAttributeBatches.decode(compact, request: request)?.first)
        XCTAssertEqual(replay.count, batch.count)
        XCTAssertEqual(replay.bytes, batch.bytes)
        XCTAssertNil(DirectoryAttributeBatches.decode(Data(compact.dropLast()), request: request))
        var oversized = compact
        oversized.replaceSubrange(4..<8, with: [UInt8](repeating: 0xff, count: 4))
        XCTAssertNil(DirectoryAttributeBatches.decode(oversized, request: request))
        let invalidRaw = Data(repeating: 0, count: 2048)
        XCTAssertNil(DirectoryAttributeBatches.decode(
            DirectoryAttributeBatches.compact(invalidRaw, into: buffer, capacity: 256 * 1024, scratch: scratch), request: request))
    }
}
