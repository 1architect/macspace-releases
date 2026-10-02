import Foundation
import MacSpacePlatform

/// Removes the files of a macOS update that is already installed (`/System/Volumes/Data/macOS Install Data`). macOS leaves them
/// behind in some cases (measured on 26B5091g: 1.27 GB from August on a system installed in September).
///
/// The helper decides for itself whether they are a leftover: the staged folder must be older than the installed system's
/// `SystemVersion.plist`. If it is not, an update may be waiting and nothing is deleted. The `Locked Files` folder carries the SIP
/// `restricted` flag and is left alone.
public struct StagedUpdateResult: Codable, Equatable, Sendable {
    public let executed: Bool
    public let bytesBefore: UInt64?
    public let bytesAfter: UInt64?
    public let removedEntries: Int
    public let error: String?

    public init(executed: Bool, bytesBefore: UInt64?, bytesAfter: UInt64?, removedEntries: Int, error: String?) {
        self.executed = executed
        self.bytesBefore = bytesBefore
        self.bytesAfter = bytesAfter
        self.removedEntries = removedEntries
        self.error = error
    }
}

public struct StagedUpdateCleaner {
    public static let storePath = "/System/Volumes/Data/macOS Install Data"
    public static let systemVersionPath = "/System/Library/CoreServices/SystemVersion.plist"
    static let protectedNames: Set<String> = ["Locked Files"]

    let storePath: String
    let systemVersionPath: String
    let fileManager: FileManager

    public init(storePath: String = StagedUpdateCleaner.storePath, systemVersionPath: String = StagedUpdateCleaner.systemVersionPath,
                fileManager: FileManager = .default) {
        self.storePath = storePath
        self.systemVersionPath = systemVersionPath
        self.fileManager = fileManager
    }

    private func modified(_ path: String) -> Date? { try? fileManager.attributesOfItem(atPath: path)[.modificationDate] as? Date }

    private func size() -> UInt64? {
        FileTreeSizer().size(at: URL(fileURLWithPath: storePath)).map { $0.allocatedBytesEstimate ?? $0.logicalBytes }
    }

    public func execute() -> StagedUpdateResult {
        guard fileManager.fileExists(atPath: storePath), let names = try? fileManager.contentsOfDirectory(atPath: storePath) else {
            return StagedUpdateResult(executed: false, bytesBefore: nil, bytesAfter: nil, removedEntries: 0, error: "There are no staged update files to remove.")
        }
        guard let staged = modified(storePath), let installed = modified(systemVersionPath), staged < installed else {
            return StagedUpdateResult(executed: false, bytesBefore: nil, bytesAfter: nil, removedEntries: 0,
                                      error: "These files are not older than the installed system, so an update may be waiting. Nothing was deleted.")
        }
        let before = size()
        var removed = 0
        var failures: [String] = []
        for name in names where !Self.protectedNames.contains(name) {
            do { try fileManager.removeItem(atPath: (storePath as NSString).appendingPathComponent(name)); removed += 1 }
            catch { failures.append("\(name): \(error.localizedDescription)") }
        }
        return StagedUpdateResult(executed: true, bytesBefore: before, bytesAfter: size(), removedEntries: removed,
                                  error: failures.isEmpty ? nil : failures.joined(separator: " "))
    }
}
