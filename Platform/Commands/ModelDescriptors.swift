import Foundation

/// How much the Apple Intelligence models take, from MobileAsset's own records.
///
/// The model folders cannot be read: System Settings' Storage page measures `com_apple_MobileAsset_UAF_FM_GenerativeModels` and
/// `…_FM_Visual` with a private entitlement (`com.apple.private.security.storage.MobileAssetGenerativeModels`), and without it even
/// root cannot list them. But MobileAsset keeps one world-readable record per asset in `/System/Library/AssetsV2/persisted/
/// AutoAssetDescriptors`: an archived `MADAutoAssetDescriptor` with `isOnFilesystem`, `downloadedFilesystemBytes` (on disk) and
/// `downloadedNetworkBytes` (a download's progress). Summed for the families Storage counts, they give the size (measured
/// 2026-10-04: 104 assets, 11.35 GB on disk, 6.2 GB of it the 3B base model).
public enum ModelDescriptors {
    public static let directory = "/System/Library/AssetsV2/persisted/AutoAssetDescriptors"
    /// One record per asset some client holds a lock on, named like its descriptor (`AutoAssetLocker_Entry_…` for
    /// `AutoAssetDescriptors_Entry_…`). A purge deletes only assets without a lock.
    public static let lockDirectory = "/System/Library/AssetsV2/persisted/AutoAssetLocker"
    /// The families System Settings counts as Apple Intelligence.
    public static let families = ["com.apple.MobileAsset.UAF.FM.GenerativeModels", "com.apple.MobileAsset.UAF.FM.Visual"]

    public struct Usage: Equatable, Sendable {
        /// On disk now.
        public var installedBytes: UInt64
        /// Downloaded so far for assets not complete yet.
        public var downloadingBytes: UInt64
        public var assets: Int
        /// The part of `installedBytes` some client still holds a lock on: macOS keeps it, a purge leaves it.
        public var lockedBytes: UInt64 = 0

        /// On disk and released: what a purge deletes now.
        public var releasedBytes: UInt64 { installedBytes > lockedBytes ? installedBytes - lockedBytes : 0 }
    }

    /// nil when the records cannot be read at all (an unknown macOS layout): the folder cannot be listed, or it has records of these
    /// families and none decodes. A Mac that never downloaded the models has none of them, and that is zero, not unknown (a CI
    /// runner showed it: other families' records only, 2026-10-07).
    public static func usage(directory: String = directory, lockDirectory: String = lockDirectory, families: [String] = families,
                             fileManager: FileManager = .default) -> Usage? {
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory) else { return nil }
        let locked = Set(((try? fileManager.contentsOfDirectory(atPath: lockDirectory)) ?? [])
            .map { $0.replacingOccurrences(of: "AutoAssetLocker_Entry_", with: "") })
        var usage = Usage(installedBytes: 0, downloadingBytes: 0, assets: 0)
        var readAny = false
        let records = names.filter { name in families.contains(where: { name.contains("_\($0)_") }) }
        for name in records {
            guard let data = fileManager.contents(atPath: "\(directory)/\(name)"), let descriptor = decode(data) else { continue }
            readAny = true
            guard families.contains(descriptor.assetType) else { continue }
            usage.assets += 1
            if descriptor.onDisk {
                let bytes = UInt64(max(descriptor.filesystemBytes, 0))
                usage.installedBytes += bytes
                if locked.contains(name.replacingOccurrences(of: "AutoAssetDescriptors_Entry_", with: "")) { usage.lockedBytes += bytes }
            }
            else { usage.downloadingBytes += UInt64(max(descriptor.networkBytes, 0)) }
        }
        return readAny || records.isEmpty ? usage : nil
    }

    /// Where MobileAsset records what it staged for the next macOS update (`AutoAssetStager_Entry_…`).
    public static let stagerDirectory = "/System/Library/AssetsV2/persisted/AutoAssetStager"

    /// What MobileAsset has staged for the next macOS update in these families: each entry's `assetContentBytes`. Staged models sit
    /// in the families' folders, which System Settings counts (216.6 MB of the 716.7 MB it showed for Apple Intelligence, 2026-10-06).
    public static func stagedBytes(directory: String = stagerDirectory, families: [String] = families, fileManager: FileManager = .default) -> UInt64 {
        let names = (try? fileManager.contentsOfDirectory(atPath: directory)) ?? []
        return names.filter { name in families.contains { name.contains("_\($0)_") } }.compactMap { name -> UInt64? in
            guard let data = fileManager.contents(atPath: "\(directory)/\(name)"),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let fields = plist["SUCorePersistedStatePolicyFields"] as? [String: Any],
                  let bytes = fields["assetContentBytes"] as? NSNumber else { return nil }
            return bytes.uint64Value
        }.reduce(0, +)
    }

    /// The descriptor archived inside one record (a SUCore persisted-state property list).
    static func decode(_ data: Data) -> Descriptor? {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let blob = (plist["SUCorePersistedStatePolicySecureCodedObjectsFields"] as? [String: Any])?["assetDescriptor"] as? Data,
              let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: blob) else { return nil }
        unarchiver.requiresSecureCoding = false
        unarchiver.setClass(Descriptor.self, forClassName: "MADAutoAssetDescriptor")
        defer { unarchiver.finishDecoding() }
        return unarchiver.decodeObject(forKey: NSKeyedArchiveRootObjectKey) as? Descriptor
    }

    /// The fields MacSpace reads from `MADAutoAssetDescriptor`; the rest of the archive is left undecoded.
    @objc(MacSpaceModelDescriptor)
    final class Descriptor: NSObject, NSCoding {
        let assetType: String
        let onDisk: Bool
        let filesystemBytes: Int64
        let networkBytes: Int64

        func encode(with coder: NSCoder) {}

        init?(coder: NSCoder) {
            assetType = coder.decodeObject(forKey: "assetType") as? String ?? ""
            onDisk = coder.decodeBool(forKey: "isOnFilesystem")
            filesystemBytes = coder.decodeInt64(forKey: "downloadedFilesystemBytes")
            networkBytes = coder.decodeInt64(forKey: "downloadedNetworkBytes")
        }
    }
}
