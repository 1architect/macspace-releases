import Foundation

/// Ordinary file removal is permanent by default. Cleanup engines retain their own lifecycle rules.
public enum FileRemovalSettings {
    public static let moveToTrashKey = "files.moveToTrash"
    public static func movesToTrash(_ defaults: UserDefaults = .standard) -> Bool { defaults.bool(forKey: moveToTrashKey) }
    public static func remove(_ path: String, defaults: UserDefaults = .standard) throws {
        if movesToTrash(defaults) { try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil) }
        else { try FileManager.default.removeItem(atPath: path) }
    }
}
