import Foundation
import Darwin
import MacSpaceSdk
import MacSpacePlatform

/// Resolve the complete request before touching any file. Progress uses the same opaque choice IDs as app-cache selection.
enum DiskFileRemoval {
    static func id(_ path: String) -> String { "file:" + Data(path.utf8).base64EncodedString() }
    static func userFile(_ path: String) -> Bool { FileReviewPolicy.includes(path) }
    static func canDelete(_ path: String) -> Bool {
        guard userFile(path), let identity = FileReviewIdentity(path), identity.uid == getuid() else { return false }
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().path == path
    }
    static func selectable(_ file: DiskFile) -> Bool {
        file.ownerUID == getuid() && userFile(file.path)
    }

    struct Result {
        var targets: [String]
        var failures: [String]
        var removedBytes: UInt64 = 0
    }
    static func execute(ids: Set<String>, folder: String, index: DiskIndex,
                        files: [DiskFile]? = nil,
                        eligible: (String) -> Bool = DiskFileRemoval.canDelete,
                        remove: ((String) throws -> Void)? = nil,
                        confirmedMoveToTrash: Bool? = nil,
                        progress: ProgressSink = { _ in }) -> Result? {
        guard index.contains(folder, below: index.root), index.directories[folder] != nil, !ids.isEmpty else { return nil }
        let candidates = (files ?? index.largeFiles).filter { index.contains($0.path, below: folder) && ids.contains(Self.id($0.path)) }
        guard Set(candidates.map { Self.id($0.path) }) == ids else { return nil }
        let selectedPaths = Set(candidates.map(\.path))
        let inUse = OpenFileUse.inspect(selectedPaths)
        let moveToTrash = confirmedMoveToTrash ?? false
        let identities = Dictionary(uniqueKeysWithValues: candidates.compactMap { file in FileReviewIdentity(file.path).map { (file.path, $0) } })
        var result = Result(targets: candidates.map(\.path), failures: []), finished: [String] = []
        for (n, file) in candidates.enumerated() {
            if let readers = inUse[file.path], !readers.isEmpty {
                result.failures.append(file.path + ": " + readers.map(\.process).joined(separator: ", "))
            }
            else if (file.identity != nil && file.identity != identities[file.path]) || (remove == nil && file.identity == nil) {
                result.failures.append(file.path + ": " + loc("File changed since selection. Review it again."))
            }
            else if !eligible(file.path) { result.failures.append(file.path + ": " + loc("This file cannot be deleted here.")) }
            else {
                do {
                    if let proof = file.duplicateVerification {
                        guard !selectedPaths.contains(proof.keeper),
                              FileReviewIdentity(proof.keeper) == proof.keeperIdentity else {
                            throw CocoaError(.fileReadUnknown)
                        }
                    }
                    if let remove { try remove(file.path) }
                    else {
                        guard confirmedMoveToTrash != nil, let identity = identities[file.path] else { throw CocoaError(.fileReadNoSuchFile) }
                        try ReviewedFileRemoval.remove(file.path, expected: identity, moveToTrash: moveToTrash)
                    }
                    result.removedBytes += file.bytes
                    finished.append(Self.id(file.path))
                }
                catch { result.failures.append(file.path + ": " + error.localizedDescription) }
            }
            progress(ActionProgress(fraction: Double(n + 1) / Double(candidates.count), message: loc("Freeing space"), finished: finished))
        }
        return result
    }
}
