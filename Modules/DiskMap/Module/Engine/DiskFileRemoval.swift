import Foundation
import MacSpaceSdk

/// Resolve the complete request before touching any file. Progress uses the same opaque choice IDs as app-cache selection.
enum DiskFileRemoval {
    struct Result {
        var targets: [String]
        var failures: [String]
    }
    static func execute(ids: Set<String>, folder: String, index: DiskIndex,
                        eligible: (String) -> Bool = DiskMapScreenBuilder.canDelete,
                        remove: (String) throws -> Void = { try FileManager.default.removeItem(atPath: $0) },
                        progress: ProgressSink = { _ in }) -> Result? {
        guard index.contains(folder, below: index.root), index.directories[folder] != nil, !ids.isEmpty else { return nil }
        let candidates = DiskMapScreenBuilder.largeFiles(index, folder: folder).filter { ids.contains(DiskMapScreenBuilder.fileID($0.path)) }
        guard Set(candidates.map { DiskMapScreenBuilder.fileID($0.path) }) == ids else { return nil }
        var result = Result(targets: candidates.map(\.path), failures: []), finished: [String] = []
        for (n, file) in candidates.enumerated() {
            if !eligible(file.path) { result.failures.append(file.path + ": " + loc("This file cannot be deleted here.")) }
            else {
                do { try remove(file.path); finished.append(DiskMapScreenBuilder.fileID(file.path)) }
                catch { result.failures.append(file.path + ": " + error.localizedDescription) }
            }
            progress(ActionProgress(fraction: Double(n + 1) / Double(candidates.count), message: loc("Freeing space"), finished: finished))
        }
        return result
    }
}
