import Foundation
import Darwin
import MacSpaceDiskMapPrivileged

/// A framed, streaming cache: encoding/decoding one directory never builds a second whole-disk JSON object graph.
enum DiskCache {
    private static let magic = Data("MSIDX002".utf8)
    private static let maximumRecord = 64 * 1024 * 1024
    private struct Header: Codable {
        var root: String
        var eventID: UInt64
        var catalogRevision: UInt64?
        var revision: UInt64
        var volumeUsed: UInt64?
        var directoryCount: Int
        var linkCount: Int
        var claimCount: Int?
    }
    private struct Claim: Codable { var id: UInt32; var claim: DiskOwnershipClaim }
    private struct Links: Codable { var id: String; var files: [DiskFile] }
    private enum Invalid: Error { case truncated, format }

    static func write(_ index: DiskIndex, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = url.deletingLastPathComponent().appendingPathComponent("." + UUID().uuidString + ".scan")
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw Invalid.format }
        defer { try? FileManager.default.removeItem(at: temporary) }
        let file = try FileHandle(forWritingTo: temporary)
        defer { try? file.close() }
        var buffer = magic
        let encoder = JSONEncoder()
        func record<T: Encodable>(_ kind: UInt8, _ value: T) throws {
            try autoreleasepool {
                let payload = try encoder.encode(value)
                guard payload.count <= maximumRecord else { throw Invalid.format }
                buffer.append(kind)
                var length = UInt32(payload.count).littleEndian
                withUnsafeBytes(of: &length) { buffer.append(contentsOf: $0) }
                buffer.append(payload)
                if buffer.count >= 64 * 1024 { try file.write(contentsOf: buffer); buffer.removeAll(keepingCapacity: true) }
            }
        }
        try record(0, Header(root: index.root, eventID: index.eventID, catalogRevision: index.catalogRevision, revision: index.revision, volumeUsed: index.volumeUsed,
                             directoryCount: index.directories.count, linkCount: index.hardlinks.count, claimCount: index.ownershipClaims?.count))
        for node in index.directories.values { try record(1, node) }
        for (id, files) in index.hardlinks { try record(2, Links(id: id, files: files)) }
        for (id, claim) in index.ownershipClaims ?? [:] { try record(3, Claim(id: id, claim: claim)) }
        if !buffer.isEmpty { try file.write(contentsOf: buffer) }
        try file.synchronize()
        guard rename(temporary.path, url.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    static func read(from url: URL, root: String) throws -> DiskIndex {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var buffer = Data(), offset = 0
        func read(_ count: Int, eofAllowed: Bool = false) throws -> Data? {
            var result = Data()
            while result.count < count {
                if offset == buffer.count {
                    buffer = try file.read(upToCount: 64 * 1024) ?? Data(); offset = 0
                    if buffer.isEmpty {
                        if eofAllowed && result.isEmpty { return nil }
                        throw Invalid.truncated
                    }
                }
                let take = min(count - result.count, buffer.count - offset)
                result.append(buffer[offset..<(offset + take)]); offset += take
            }
            return result
        }
        guard try read(magic.count) == magic else { throw Invalid.format }
        var header: Header?
        var index = DiskIndex(root: root)
        let decoder = JSONDecoder()
        while let framing = try read(5, eofAllowed: true) {
            try autoreleasepool {
                let length = framing.withUnsafeBytes { Int(UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 1, as: UInt32.self))) }
                guard length > 0, length <= maximumRecord, let payload = try read(length) else { throw Invalid.format }
                switch framing[0] {
                case 0:
                    guard header == nil else { throw Invalid.format }
                    let value = try decoder.decode(Header.self, from: payload)
                    guard value.root == root, value.directoryCount > 0 else { throw Invalid.format }
                    header = value; index.catalogRevision = value.catalogRevision; index.eventID = value.eventID; index.revision = value.revision; index.volumeUsed = value.volumeUsed
                case 1:
                    guard header != nil else { throw Invalid.format }
                    let node = try decoder.decode(DiskDirectory.self, from: payload)
                    guard index.contains(node.path, below: root) else { throw Invalid.format }
                    index.directories[node.path] = node
                case 2:
                    guard header != nil else { throw Invalid.format }
                    let links = try decoder.decode(Links.self, from: payload)
                    index.hardlinks[links.id] = links.files
                case 3:
                    guard header != nil else { throw Invalid.format }
                    let value = try decoder.decode(Claim.self, from: payload)
                    if index.ownershipClaims == nil { index.ownershipClaims = [:] }
                    index.ownershipClaims?[value.id] = value.claim
                default: throw Invalid.format
                }
            }
        }
        guard let header, index.directories[root] != nil, index.directories.count == header.directoryCount,
              index.hardlinks.count == header.linkCount,
              (index.ownershipClaims?.count ?? 0) == (header.claimCount ?? 0) else { throw Invalid.truncated }
        return index
    }
}
