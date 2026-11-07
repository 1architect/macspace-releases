import CryptoKit
import Darwin
import Foundation

/// The authoritative review manifest has no pathname and its key never leaves this process.
/// Both records and their ordinal positions are authenticated. The disk index retains only offsets;
/// Swift decodes one bounded page, rather than retaining an entire selection in memory.
final class DiskSelectionSnapshot {
    private let records: UnsafeMutablePointer<FILE>
    private let offsets: UnsafeMutablePointer<FILE>
    private let key = SymmetricKey(size: .bits256)
    private(set) var count: UInt64 = 0
    private(set) var bytes: UInt64 = 0
    private var lastPath: String?
    private static let maximumRecordBytes = 1_048_576
    private static let maximumManifestBytes = 2_147_483_648

    private static func failure() -> DiskDatabase.Failure {
        .init(message: "Selected files changed. Review them again.")
    }

    init() throws {
        func allocate() throws -> UnsafeMutablePointer<FILE> {
            guard let file = tmpfile() else { throw Self.failure() }
            guard fchmod(fileno(file), 0o600) == 0, fcntl(fileno(file), F_SETFD, FD_CLOEXEC) == 0 else {
                fclose(file); throw Self.failure()
            }
            return file
        }
        records = try allocate()
        do { offsets = try allocate() }
        catch { fclose(records); throw error }
    }

    deinit { fclose(records); fclose(offsets) }

    private func ordinal(_ value: UInt64) -> Data {
        var value = value.bigEndian
        return withUnsafeBytes(of: &value) { Data($0) }
    }

    func append(_ file: DiskFile) throws {
        guard lastPath.map({ $0.utf8.lexicographicallyPrecedes(file.path.utf8) }) != false,
              fseek(records, 0, SEEK_END) == 0, fseek(offsets, 0, SEEK_END) == 0 else { throw Self.failure() }
        let encoder = JSONEncoder()
        let data = try encoder.encode(file)
        guard data.count <= Self.maximumRecordBytes else { throw Self.failure() }
        let encrypted = try AES.GCM.seal(data, using: key, authenticating: ordinal(count))
        guard let combined = encrypted.combined, combined.count <= Self.maximumRecordBytes else { throw Self.failure() }
        let position = ftell(records)
        guard position >= 0, position <= Self.maximumManifestBytes - combined.count - MemoryLayout<UInt32>.size else { throw Self.failure() }
        var offset = UInt64(position), length = UInt32(combined.count)
        guard fwrite(&offset, MemoryLayout<UInt64>.size, 1, offsets) == 1,
              fwrite(&length, MemoryLayout<UInt32>.size, 1, records) == 1,
              combined.withUnsafeBytes({ fwrite($0.baseAddress, 1, combined.count, records) }) == combined.count else { throw Self.failure() }
        let total = bytes.addingReportingOverflow(file.bytes)
        guard !total.overflow else { throw Self.failure() }
        count += 1; bytes = total.partialValue; lastPath = file.path
    }

    private func read(_ index: UInt64) throws -> DiskFile {
        guard index < count, index <= UInt64(Int.max / MemoryLayout<UInt64>.size),
              fflush(offsets) == 0, fflush(records) == 0,
              fseek(offsets, Int(index) * MemoryLayout<UInt64>.size, SEEK_SET) == 0 else { throw Self.failure() }
        var offset: UInt64 = 0, length: UInt32 = 0
        guard fread(&offset, MemoryLayout<UInt64>.size, 1, offsets) == 1,
              offset < Self.maximumManifestBytes,
              fseek(records, Int(offset), SEEK_SET) == 0,
              fread(&length, MemoryLayout<UInt32>.size, 1, records) == 1,
              length > 0, length <= Self.maximumRecordBytes else { throw Self.failure() }
        var data = Data(count: Int(length))
        let received = data.withUnsafeMutableBytes { fread($0.baseAddress, 1, Int(length), records) }
        guard received == Int(length) else { throw Self.failure() }
        let plaintext = try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: key, authenticating: ordinal(index))
        return try JSONDecoder().decode(DiskFile.self, from: plaintext)
    }

    private func lowerBound(_ path: String, exclusive: Bool) throws -> UInt64 {
        var lower: UInt64 = 0, upper = count
        while lower < upper {
            let middle = lower + (upper - lower) / 2, candidate = try read(middle).path
            if candidate.utf8.lexicographicallyPrecedes(path.utf8) || (exclusive && candidate.utf8.elementsEqual(path.utf8)) {
                lower = middle + 1
            } else { upper = middle }
        }
        return lower
    }

    func file(at path: String) throws -> DiskFile? {
        let index = try lowerBound(path, exclusive: false)
        guard index < count else { return nil }
        let file = try read(index)
        return file.path.utf8.elementsEqual(path.utf8) ? file : nil
    }

    func page(after path: String, limit: Int) throws -> [DiskFile] {
        let start = try lowerBound(path, exclusive: true)
        let end = min(count, start + UInt64(max(1, min(limit, 200))))
        return try (start..<end).map { try read($0) }
    }
}
