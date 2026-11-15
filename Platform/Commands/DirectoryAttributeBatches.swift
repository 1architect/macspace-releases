import Compression
import Darwin
import Foundation

/// Native attribute references are relative offsets, not process pointers. Validate every cached record before replaying any
/// callback. Corrupt, incomplete, oversized or unsupported records fall back to the live reader without partial double counting.
enum DirectoryAttributeBatches {
    struct Batch { var count: Int32; var bytes: Data }
    private static let magic: UInt32 = 0x3146444d
    private static let compressedMagic: UInt32 = 0x3246444d
    private static let algorithm = COMPRESSION_LZ4_RAW
    static var compressionScratchSize: Int { compression_encode_scratch_buffer_size(algorithm) }

    /// Reuse the worker's native buffer after enumeration. Store only the smaller payload in the pending queue.
    static func compact(_ data: Data, into buffer: UnsafeMutableRawPointer, capacity: Int, scratch: UnsafeMutableRawPointer) -> Data {
        let headerSize = 8
        guard data.count >= 512, capacity > headerSize else { return data }
        let limit = min(capacity - headerSize, data.count - headerSize - 128)
        let length = data.withUnsafeBytes { source in
            compression_encode_buffer((buffer + headerSize).assumingMemoryBound(to: UInt8.self), limit,
                source.baseAddress!.assumingMemoryBound(to: UInt8.self), source.count, scratch, algorithm)
        }
        guard length > 0 else { return data }
        buffer.storeBytes(of: compressedMagic.littleEndian, as: UInt32.self)
        buffer.storeBytes(of: UInt32(data.count).littleEndian, toByteOffset: 4, as: UInt32.self)
        return Data(bytes: buffer, count: headerSize + length)
    }

    static func encode(_ batches: [Batch], request: attrlist) -> Data? {
        var result = Data()
        func append(_ number: UInt32) { var number = number.littleEndian; withUnsafeBytes(of: &number) { result.append(contentsOf: $0) } }
        append(magic); append(UInt32(batches.count))
        for batch in batches {
            guard valid(batch, request: request) else { return nil }
            append(UInt32(batch.count)); append(UInt32(batch.bytes.count)); result.append(batch.bytes)
            guard result.count <= DirectoryListingArchive.maximumPayload else { return nil }
        }
        return result
    }
    static func decode(_ data: Data, request: attrlist) -> [Batch]? {
        guard data.count >= 8 && data.count <= DirectoryListingArchive.maximumPayload else { return nil }
        let header = data.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian }
        if header == compressedMagic {
            guard let expanded = expand(data) else { return nil }
            return decodeNative(expanded, request: request)
        }
        return decodeNative(data, request: request)
    }

    private static func expand(_ data: Data) -> Data? {
        guard data.count > 8 else { return nil }
        return data.withUnsafeBytes { source in
            let length = Int(source.loadUnaligned(fromByteOffset: 4, as: UInt32.self).littleEndian)
            guard length >= 512, length <= DirectoryListingArchive.maximumPayload, length > data.count else { return nil }
            // A spare byte distinguishes an exact decode from an output that exhausted its destination.
            var expanded = Data(count: length + 1)
            let decoded = expanded.withUnsafeMutableBytes { destination in
                compression_decode_buffer(destination.baseAddress!.assumingMemoryBound(to: UInt8.self), destination.count,
                    (source.baseAddress! + 8).assumingMemoryBound(to: UInt8.self), source.count - 8, nil, algorithm)
            }
            guard decoded == length else { return nil }
            expanded.removeLast()
            return expanded
        }
    }

    private static func decodeNative(_ data: Data, request: attrlist) -> [Batch]? {
        return data.withUnsafeBytes { raw in
            guard raw.loadUnaligned(as: UInt32.self).littleEndian == magic else { return nil }
            let number = raw.loadUnaligned(fromByteOffset: 4, as: UInt32.self).littleEndian
            guard number <= 65536 else { return nil }
            var offset = 8, result: [Batch] = []
            for _ in 0..<number {
                guard offset <= raw.count - 8 else { return nil }
                let count = raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self).littleEndian
                let length = Int(raw.loadUnaligned(fromByteOffset: offset + 4, as: UInt32.self).littleEndian)
                offset += 8
                guard count > 0 && count <= 65536, length > 0 && length <= raw.count - offset else { return nil }
                let batch = Batch(count: Int32(count), bytes: data.subdata(in: offset..<offset + length))
                guard valid(batch, request: request) else { return nil }
                result.append(batch); offset += length
            }
            return offset == raw.count ? result : nil
        }
    }

    private static func valid(_ batch: Batch, request: attrlist) -> Bool {
        guard batch.count > 0 else { return false }
        return batch.bytes.withUnsafeBytes { raw in
            var offset = 0
            for _ in 0..<batch.count {
                guard offset <= raw.count - 24 else { return false }
                let length = Int(raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
                guard length >= 24 && length <= raw.count - offset else { return false }
                let returned = raw.loadUnaligned(fromByteOffset: offset + 4, as: attribute_set_t.self)
                guard returned.commonattr & ~request.commonattr == 0, returned.fileattr & ~request.fileattr == 0,
                      returned.forkattr & ~request.forkattr == 0, returned.dirattr == 0, returned.volattr == 0,
                      returned.commonattr & attrgroup_t(ATTR_CMN_NAME | ATTR_CMN_DEVID) == attrgroup_t(ATTR_CMN_NAME | ATTR_CMN_DEVID) else { return false }
                var field = offset + 24
                if returned.commonattr & attrgroup_t(ATTR_CMN_ERROR) != 0 {
                    guard field <= offset + length - 4, raw.loadUnaligned(fromByteOffset: field, as: UInt32.self) == 0 else { return false }
                    field += 4
                }
                guard field <= offset + length - MemoryLayout<attrreference_t>.size else { return false }
                let reference = raw.loadUnaligned(fromByteOffset: field, as: attrreference_t.self)
                let name = field + Int(reference.attr_dataoffset), nameBytes = Int(reference.attr_length)
                guard nameBytes > 0, name >= offset, name <= offset + length - nameBytes,
                      raw[name + nameBytes - 1] == 0 else { return false }
                field += MemoryLayout<attrreference_t>.size
                var type: UInt32 = 0, fileID: UInt64 = 0
                let common: [(Int32, Int)] = [(ATTR_CMN_DEVID, 4), (ATTR_CMN_OBJTYPE, 4), (ATTR_CMN_MODTIME, 16),
                    (ATTR_CMN_OWNERID, 4), (ATTR_CMN_FLAGS, 4), (ATTR_CMN_FILEID, 8)]
                for (bit, size) in common where returned.commonattr & attrgroup_t(bit) != 0 {
                    guard field <= offset + length - size else { return false }
                    if bit == ATTR_CMN_OBJTYPE { type = raw.loadUnaligned(fromByteOffset: field, as: UInt32.self) }
                    if bit == ATTR_CMN_FILEID { fileID = raw.loadUnaligned(fromByteOffset: field, as: UInt64.self) }
                    field += size
                }
                for (bit, size) in [(ATTR_FILE_LINKCOUNT, 4), (ATTR_FILE_TOTALSIZE, 8), (ATTR_FILE_ALLOCSIZE, 8)] where returned.fileattr & attrgroup_t(bit) != 0 { field += size }
                for bit in [ATTR_CMNEXT_PRIVATESIZE, ATTR_CMNEXT_CLONEID, ATTR_CMNEXT_EXT_FLAGS] where returned.forkattr & attrgroup_t(bit) != 0 { field += 8 }
                guard field <= offset + length, name >= field, type != UInt32(VREG.rawValue) || fileID != 0 else { return false }
                offset += length
            }
            return offset == raw.count
        }
    }
}
