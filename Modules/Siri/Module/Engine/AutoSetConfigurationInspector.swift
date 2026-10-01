import CryptoKit
import Foundation

public struct AutoSetConfigurationObservation: Codable, Sendable, Equatable {
    public let sourcePath: String
    public let sha256: String?
    public let byteCount: Int?
    public let selectorCount: Int?
    public let targetCount: Int?
    public let targetSelectors: [String]
    public let error: String?
}

/// Bounded reader for the live SUCorePersistedState AutoSetConfigurations keyed archive.
/// It follows only the known CP108 archive fields and never instantiates archived classes.
public struct AutoSetConfigurationInspector {
    public static let defaultPath = "/System/Library/AssetsV2/persisted/AutoSetConfigurations/AutoSetConfigurations_Entry_com.apple.UnifiedAssetFramework_com.apple.modelcatalog.state"
    public static let targetSpecifier = "com.apple.fm.language.instruct_3b.base.generic_sparse"
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) { self.fileManager = fileManager }

    public func inspect(path: String = Self.defaultPath, maximumBytes: Int = 16 * 1024 * 1024) -> AutoSetConfigurationObservation {
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else {
            return failure(path, "Could not open AutoSetConfigurations state file for read-only inspection.")
        }
        defer { try? handle.close() }
        guard let size = try? fileManager.attributesOfItem(atPath: path)[.size] as? NSNumber,
              size.intValue >= 0, size.intValue <= maximumBytes else {
            return failure(path, "AutoSetConfigurations file is unavailable or exceeds the \(maximumBytes)-byte parse limit.")
        }
        guard let data = try? handle.readToEnd(), data.count == size.intValue else {
            return failure(path, "Could not read the complete AutoSetConfigurations file.")
        }
        return analyze(data: data, sourcePath: path)
    }

    public func analyze(data: Data, sourcePath: String = Self.defaultPath, maximumBytes: Int = 16 * 1024 * 1024) -> AutoSetConfigurationObservation {
        guard data.count <= maximumBytes else { return failure(sourcePath, "AutoSetConfigurations data exceeds the \(maximumBytes)-byte parse limit.") }
        do {
            guard let outer = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
                  let fields = outer["SUCorePersistedStatePolicySecureCodedObjectsFields"] as? [String: Any],
                  let embedded = fields["setConfiguration"] as? Data else {
                return failure(sourcePath, "Expected CP108 SUCore persisted-state wrapper and setConfiguration data field.", data: data)
            }
            guard let archive = try PropertyListSerialization.propertyList(from: embedded, options: [], format: nil) as? [String: Any],
                  let objects = archive["$objects"] as? [Any], objects.count <= 100_000,
                  let top = archive["$top"] as? [String: Any],
                  let rootIndex = uidIndex(top["root"]), objects.indices.contains(rootIndex),
                  let root = objects[rootIndex] as? [String: Any],
                  let entriesIndex = uidIndex(root["autoAssetEntries"]), objects.indices.contains(entriesIndex),
                  let entriesObject = objects[entriesIndex] as? [String: Any],
                  let entries = entriesObject["NS.objects"] as? [Any], entries.count <= 10_000 else {
                return failure(sourcePath, "AutoSetConfigurations keyed archive is malformed or exceeds bounded object/entry limits.", data: data)
            }
            var selectors: [String] = []
            selectors.reserveCapacity(entries.count)
            for entryRef in entries {
                guard let entryIndex = uidIndex(entryRef), objects.indices.contains(entryIndex),
                      let entry = objects[entryIndex] as? [String: Any],
                      let selectorIndex = uidIndex(entry["assetSelector"]), objects.indices.contains(selectorIndex),
                      let selector = objects[selectorIndex] as? [String: Any],
                      let specifierIndex = uidIndex(selector["assetSpecifier"]), objects.indices.contains(specifierIndex),
                      let specifier = objects[specifierIndex] as? String else {
                    return failure(sourcePath, "One or more AutoSetConfigurations entries lack the expected assetSelector.assetSpecifier fields.", data: data)
                }
                selectors.append(specifier)
            }
            let hits = selectors.filter { $0 == Self.targetSpecifier }
            return AutoSetConfigurationObservation(
                sourcePath: sourcePath, sha256: digest(data), byteCount: data.count,
                selectorCount: selectors.count, targetCount: hits.count, targetSelectors: hits,
                error: nil
            )
        } catch {
            return failure(sourcePath, "Property-list decoding failed: \(error.localizedDescription)", data: data)
        }
    }

    private func failure(_ path: String, _ message: String, data: Data? = nil) -> AutoSetConfigurationObservation {
        AutoSetConfigurationObservation(sourcePath: path, sha256: data.map(digest), byteCount: data?.count,
                                        selectorCount: nil, targetCount: nil, targetSelectors: [], error: message)
    }

    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func uidIndex(_ value: Any?) -> Int? {
        guard let value else { return nil }
        if let dictionary = value as? [String: Any], let index = dictionary["CF$UID"] as? NSNumber { return index.intValue }
        let typeName = String(reflecting: type(of: value))
        let description = String(describing: value)
        guard typeName.localizedCaseInsensitiveContains("KeyedArchiverUID") ||
                description.localizedCaseInsensitiveContains("KeyedArchiverUID") else { return nil }
        if let child = Mirror(reflecting: value).children.first(where: {
            let label = ($0.label ?? "").lowercased()
            return label.contains("value") || label.contains("uid")
        }) {
            if let index = child.value as? Int { return index }
            if let index = child.value as? UInt { return Int(exactly: index) }
            if let index = child.value as? NSNumber { return index.intValue }
        }
        for pattern in [#"value\s*=\s*(\d+)"#, #"value\s*:\s*(\d+)"#, #"UID\(?([0-9]+)\)?"#] {
            guard let range = description.range(of: pattern, options: .regularExpression) else { continue }
            if let digits = description[range].split(whereSeparator: { !$0.isNumber }).last,
               let index = Int(digits) { return index }
        }
        return nil
    }
}
