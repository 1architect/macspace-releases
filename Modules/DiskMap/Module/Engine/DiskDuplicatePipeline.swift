import CryptoKit
import Darwin
import Foundation
import MacSpacePlatform

/// Only metadata crosses the writer boundary. Every content read happens on one utility worker.
protocol DiskDuplicateStorage: Sendable {
    func beginDuplicatePass(folder: String, minimumSize: UInt64) async throws
    func duplicateMetadata(after: String) async throws -> [DiskFile]
    func stageDuplicate(_ file: DiskFile, identity: FileReviewIdentity) async throws
    func duplicateWork(sample: Bool, after: String) async throws -> [DiskDuplicateWork]
    func saveDuplicate(_ work: DiskDuplicateWork, sample: Data, digest: Data?) async throws
    func failDuplicate(_ path: String) async throws
    func finishDuplicatePass() async throws
}

struct DiskDuplicateWork: Sendable {
    var file: DiskFile
    var identity: FileReviewIdentity
    var sample: Data?
    var digest: Data?
}

struct DiskDuplicateReport: Sendable {
    var sampled = 0
    var verified = 0
    var reused = 0
    /// Inaccessible or changed content is unknown, never evidence of uniqueness or unused data.
    var unknown = 0
}

enum DiskDuplicatePipeline {
    static func run(storage: any DiskDuplicateStorage, folder: String, minimumSize: UInt64 = 100_000_000,
                    scoped: Bool = false, eligible: @escaping @Sendable (String) -> Bool = { FileReviewPolicy.includes($0) }, published: @escaping @Sendable () async -> Void = {}) async throws -> DiskDuplicateReport {
        let worker = Task.detached(priority: .utility) {
            try await process(storage: storage, folder: folder, minimumSize: minimumSize, scoped: scoped, eligible: eligible, published: published)
        }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }

    private static func process(storage: any DiskDuplicateStorage, folder: String, minimumSize: UInt64,
                                scoped: Bool, eligible: @Sendable (String) -> Bool, published: @Sendable () async -> Void) async throws -> DiskDuplicateReport {
        try Task.checkCancellation()
        var report = DiskDuplicateReport(), enumerationFailures = 0
        try await storage.beginDuplicatePass(folder: folder, minimumSize: scoped ? 1 : minimumSize)
        if scoped {
            // Expanded scopes discover small files on demand; no whole-disk small-file index.
            guard eligible(folder + "/candidate") else { return .init() }
            let enumerator = FileManager.default.enumerator(at: URL(fileURLWithPath: folder), includingPropertiesForKeys: nil,
                                                          options: [.skipsHiddenFiles, .skipsPackageDescendants],
                                                          errorHandler: { _, _ in enumerationFailures += 1; return true })
            if enumerator == nil { enumerationFailures += 1 }
            while let url = autoreleasepool(invoking: { enumerator?.nextObject() as? URL }) {
                try Task.checkCancellation()
                guard eligible(url.path) else { enumerator?.skipDescendants(); continue }
                var info = stat()
                guard lstat(url.path, &info) == 0 else { report.unknown += 1; continue }
                guard info.st_mode & S_IFMT == S_IFREG else { continue }
                guard let identity = FileReviewIdentity(url.path) else { report.unknown += 1; continue }
                guard identity.uid == getuid(), identity.size > 0, FileReviewIdentity(info) == identity else { continue }
                let file = DiskFile(path: url.path, bytes: UInt64(max(0, info.st_blocks)) * 512, logicalBytes: UInt64(identity.size), ownerUID: identity.uid)
                try await storage.stageDuplicate(file, identity: identity)
            }
        } else {
            var after = ""
            while true {
                try Task.checkCancellation()
                let batch = try await storage.duplicateMetadata(after: after)
                guard let last = batch.last else { break }
                for file in batch {
                    try Task.checkCancellation()
                    guard eligible(file.path) else { continue }
                    guard let identity = FileReviewIdentity(file.path), UInt64(max(0, identity.size)) == file.logicalBytes else { report.unknown += 1; continue }
                    guard identity.uid == getuid(), identity.size > 0 else { continue }
                    try await storage.stageDuplicate(file, identity: identity)
                }
                after = last.path
            }
        }
        let reader = DiskDuplicateReader()
        report.unknown += enumerationFailures
        for sampling in [true, false] {
            var after = ""
            while true {
                try Task.checkCancellation()
                let batch = try await storage.duplicateWork(sample: sampling, after: after)
                guard let last = batch.last else { break }
                for work in batch {
                    try Task.checkCancellation()
                    let sample: Data, digest: Data?
                    do {
                        sample = try work.sample ?? reader.hash(work.file.path, expected: work.identity, sample: true)
                        if sampling { digest = work.digest }
                        else { digest = try work.digest ?? reader.hash(work.file.path, expected: work.identity, sample: false) }
                        // The cached identity is checked even when no file contents had to be read.
                        guard FileReviewIdentity(work.file.path) == work.identity else { throw POSIXError(.EBUSY) }
                    } catch is CancellationError { throw CancellationError() }
                    catch { report.unknown += 1; try await storage.failDuplicate(work.file.path); continue }
                    try await storage.saveDuplicate(work, sample: sample, digest: digest)
                    if sampling { if work.sample == nil { report.sampled += 1 } }
                    else if work.digest == nil { report.verified += 1 }
                    else { report.reused += 1 }
                }
                after = last.file.path
                await published()
            }
        }
        // An incomplete walk cannot establish that cached paths vanished.
        if enumerationFailures == 0 { try await storage.finishDuplicatePass() }
        await published()
        return report
    }
}

/// One fixed allocation, reused across samples and full reads. No autoreleased Data per chunk.
final class DiskDuplicateReader {
    static let bufferSize = 256 * 1024
    private let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 64)
    deinit { buffer.deallocate() }

    func hash(_ path: String, expected: FileReviewIdentity? = nil, sample: Bool = false) throws -> Data {
        try Task.checkCancellation()
        let descriptor = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW_ANY | O_NONBLOCK)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_flags & UInt32(SF_DATALESS) == 0, info.st_size >= 0 else { throw POSIXError(.EINVAL) }
        let identity = FileReviewIdentity(info)
        guard expected == nil || expected == identity else { throw POSIXError(.EBUSY) }
        var hash = SHA256()
        if sample {
            let length = min(Int64(64 * 1024), identity.size)
            for offset in Set([Int64(0), max(0, (identity.size - length) / 2), max(0, identity.size - length)]).sorted() {
                try read(descriptor, offset: offset, length: length, into: &hash)
            }
        } else {
            try read(descriptor, offset: 0, length: identity.size, into: &hash)
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0, FileReviewIdentity(after) == identity,
              FileReviewIdentity(path) == identity else { throw POSIXError(.EBUSY) }
        return Data(hash.finalize())
    }

    private func read(_ descriptor: Int32, offset: Int64, length: Int64, into hash: inout SHA256) throws {
        var done: Int64 = 0
        while done < length {
            try Task.checkCancellation()
            let count = pread(descriptor, buffer, min(Self.bufferSize, Int(length - done)), off_t(offset + done))
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw POSIXError(.EIO) }
            hash.update(bufferPointer: UnsafeRawBufferPointer(start: buffer, count: count))
            done += Int64(count)
        }
    }
}

/// Capture on the writer, verify outside it immediately before removal. Keep the chosen survivor unselected.
struct DiskDuplicateVerification: Codable, Equatable, Sendable {
    var path: String
    var identity: FileReviewIdentity
    var keeper: String
    var keeperIdentity: FileReviewIdentity
    var digest: Data

    func verify(eligible: (String) -> Bool = { FileReviewPolicy.includes($0) }) throws -> Bool {
        guard eligible(path), eligible(keeper),
              identity.uid == getuid(), keeperIdentity.uid == getuid(),
              identity.size > 0, identity.size == keeperIdentity.size, digest.count == 32,
              identity.device != keeperIdentity.device || identity.inode != keeperIdentity.inode,
              FileReviewIdentity(path) == identity, FileReviewIdentity(keeper) == keeperIdentity else { return false }
        let reader = DiskDuplicateReader()
        guard try reader.hash(path, expected: identity) == digest,
              try reader.hash(keeper, expected: keeperIdentity) == digest else { return false }
        // Both identities, including ctime, must still match after both reads.
        return FileReviewIdentity(path) == identity && FileReviewIdentity(keeper) == keeperIdentity
    }
}
