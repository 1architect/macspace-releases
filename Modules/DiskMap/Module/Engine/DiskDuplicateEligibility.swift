import Foundation
import MacSpacePlatform

/// Identical project resources are often required copies. This only narrows duplicate cleanup, not ordinary file review.
final class DiskDuplicateEligibility: @unchecked Sendable {
    private let home: String
    private let lock = NSLock()
    private var ancestors: [String: Bool] = [:]
    private static let manifests = [".git", "CMakeLists.txt", "Package.swift", "Cargo.toml", "package.json", "pyproject.toml", "go.mod", "pom.xml", "build.gradle", "build.gradle.kts"]
    init(home: String = FileManager.default.homeDirectoryForCurrentUser.path) { self.home = home }
    func reset() { lock.withLock { ancestors.removeAll(keepingCapacity: true) } }
    func allows(_ original: String) -> Bool {
        let path = FileReviewPolicy.livePath(original)
        let components = path.split(separator: "/")
        if components.contains(where: { ["xcassets", "appiconset", "imageset"].contains(($0 as NSString).pathExtension.lowercased()) }) { return false }
        guard let base = FileReviewPolicy.personalFolders.map({ home + "/" + $0 }).first(where: { path.hasPrefix($0 + "/") }) else { return true }
        var folder = (path as NSString).deletingLastPathComponent
        while folder.hasPrefix(base + "/") {
            let project: Bool
            if let cached = lock.withLock({ ancestors[folder] }) { project = cached }
            else {
                if Self.manifests.contains(where: { FileManager.default.fileExists(atPath: folder + "/" + $0) }) { project = true }
                else {
                    var xcodeProject = false
                    _ = autoreleasepool { DirectoryWalk.entries(at: folder) { name, entry in
                        if entry.isDirectory, ["xcodeproj", "xcworkspace"].contains((name as NSString).pathExtension.lowercased()) { xcodeProject = true }
                    } }
                    project = xcodeProject
                }
                lock.withLock {
                    if ancestors.count >= 1024 { ancestors.removeAll(keepingCapacity: true) }
                    ancestors[folder] = project
                }
            }
            if project { return false }
            if folder == base { break }
            folder = (folder as NSString).deletingLastPathComponent
        }
        return true
    }
}
