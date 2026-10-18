import Darwin
import Foundation

/// The override mechanism already used by Debloat, shared by feature controls. libfeatureflags reads these at boot; writing a
/// plist never proves a feature is off in the running system. Callers must read the effective flag after a restart.
public enum FeatureFlagOverrides {
    public static let directory = "/Library/Preferences/FeatureFlags/Domain"
    public static let declarations = ["/System/Library/FeatureFlags/Domain", "/System/Library/FeatureFlags/Unified/Domain"]

    public static func isDeclared(domain: String, feature: String, fileManager: FileManager = .default) -> Bool {
        declarations.contains { directory in
            guard let data = fileManager.contents(atPath: "\(directory)/\(domain).plist"),
                  let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return false }
            return root[feature] != nil
        }
    }

    /// nil means unreadable, never disabled. Reads the same boot-time state the owning framework reads.
    public static func effectiveValue(domain: String, feature: String) -> Bool? {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_os_feature_enabled_impl") else { return nil }
        typealias Read = @convention(c) (UnsafePointer<CChar>, UnsafePointer<CChar>) -> Bool
        let read = unsafeBitCast(symbol, to: Read.self)
        return domain.withCString { domain in feature.withCString { feature in read(domain, feature) } }
    }

    public enum Failure: Error, LocalizedError {
        case invalidPlist(String)
        public var errorDescription: String? {
            switch self { case .invalidPlist(let path): return "\(path) is not a dictionary property list." }
        }
    }

    /// Sets/removes only this feature's Enabled override, preserving unrelated features and metadata. An empty file is removed.
    /// The caller owns authorization, a write-ahead journal, the fixed allowlist and verification (as Debloat does).
    public static func update(feature: String, enabled: Bool?, path: String, fileManager: FileManager = .default) throws {
        var root = try read(path: path, fileManager: fileManager)
        var entry = root[feature] as? [String: Any] ?? [:]
        if let enabled {
            entry["Enabled"] = enabled
            entry.removeValue(forKey: "DevelopmentPhase") // libfeatureflags rejects both keys together
        } else { entry.removeValue(forKey: "Enabled") }
        root[feature] = entry.isEmpty ? nil : entry
        try write(root, path: path, fileManager: fileManager)
    }

    /// The whole feature entry, for a reversible control's journal. nil preserves absence rather than inventing an Enabled value.
    public static func entry(feature: String, path: String, fileManager: FileManager = .default) throws -> Data? {
        guard let entry = try read(path: path, fileManager: fileManager)[feature] else { return nil }
        return try PropertyListSerialization.data(fromPropertyList: entry, format: .binary, options: 0)
    }

    /// Restores a journaled entry without replacing the rest of its domain. This also restores DevelopmentPhase if disabling it
    /// removed that key. Callers must first check that the current entry still equals the one they wrote.
    public static func restore(feature: String, entry: Data?, path: String, fileManager: FileManager = .default) throws {
        var root = try read(path: path, fileManager: fileManager)
        root[feature] = try entry.map { try PropertyListSerialization.propertyList(from: $0, format: nil) }
        try write(root, path: path, fileManager: fileManager)
    }

    private static func read(path: String, fileManager: FileManager) throws -> [String: Any] {
        guard fileManager.fileExists(atPath: path) else { return [:] }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard let root = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw Failure.invalidPlist(path)
        }
        return root
    }

    private static func write(_ root: [String: Any], path: String, fileManager: FileManager) throws {
        let url = URL(fileURLWithPath: path)
        if root.isEmpty {
            if fileManager.fileExists(atPath: path) { try fileManager.removeItem(at: url) }
            return
        }
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o755])
        try PropertyListSerialization.data(fromPropertyList: root, format: .xml, options: 0).write(to: url, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path)
    }
}
