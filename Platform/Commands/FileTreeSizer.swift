import Foundation

public struct FileTreeSize: Sendable, Equatable {
    public let logicalBytes: UInt64
    public let allocatedBytesEstimate: UInt64?

    public init(logicalBytes: UInt64, allocatedBytesEstimate: UInt64?) {
        self.logicalBytes = logicalBytes
        self.allocatedBytesEstimate = allocatedBytesEstimate
    }
}

public struct FileTreeSizer: Sendable {
    public init() {}

    private var sizingKeys: Set<URLResourceKey> {
        [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
            .fileAllocatedSizeKey,
            .totalFileSizeKey,
            .totalFileAllocatedSizeKey,
            .volumeIdentifierKey
        ]
    }

    /// Descriptive filesystem sizing only. This deliberately does not claim unique APFS block ownership.
    /// Descendants mounted from another filesystem are skipped to avoid obvious double counting.
    public func size(at url: URL) -> FileTreeSize? {
        do {
            let rootValues = try url.resourceValues(forKeys: sizingKeys)
            if rootValues.isSymbolicLink == true {
                return nil
            }

            if rootValues.isRegularFile == true {
                return FileTreeSize(
                    logicalBytes: logicalSize(from: rootValues) ?? 0,
                    allocatedBytesEstimate: allocatedSize(from: rootValues)
                )
            }

            guard rootValues.isDirectory == true else {
                return FileTreeSize(
                    logicalBytes: logicalSize(from: rootValues) ?? 0,
                    allocatedBytesEstimate: allocatedSize(from: rootValues)
                )
            }

            let rootVolumeID = rootValues.volumeIdentifier.map { String(describing: $0) }
            guard let enumerator = FileManager.default.enumerator(
                at: url,
                includingPropertiesForKeys: Array(sizingKeys),
                options: [],
                errorHandler: { _, _ in true }
            ) else { return nil }

            var logical: UInt64 = 0
            var allocated: UInt64 = 0
            var sawAllocated = false

            for case let item as URL in enumerator {
                guard let resource = try? item.resourceValues(forKeys: sizingKeys) else { continue }
                if resource.isSymbolicLink == true { continue }

                if let rootVolumeID,
                   let itemVolumeID = resource.volumeIdentifier.map({ String(describing: $0) }),
                   itemVolumeID != rootVolumeID {
                    enumerator.skipDescendants()
                    continue
                }

                guard resource.isRegularFile == true else { continue }
                logical += logicalSize(from: resource) ?? 0
                if let value = allocatedSize(from: resource) {
                    allocated += value
                    sawAllocated = true
                }
            }

            return FileTreeSize(
                logicalBytes: logical,
                allocatedBytesEstimate: sawAllocated ? allocated : nil
            )
        } catch {
            return nil
        }
    }

    private func logicalSize(from values: URLResourceValues) -> UInt64? {
        let value = values.totalFileSize ?? values.fileSize
        return value.map { UInt64(max(0, $0)) }
    }

    private func allocatedSize(from values: URLResourceValues) -> UInt64? {
        let value = values.totalFileAllocatedSize ?? values.fileAllocatedSize
        return value.map { UInt64(max(0, $0)) }
    }
}
