import Foundation
import MacSpacePlatform

/// Groups the downloads in `/System/Library/AssetsV2` by what they are for, and says which setting releases each group.
/// macOS keeps an asset while something subscribes to it and deletes it only after the subscription goes, so the only safe lever
/// is the setting behind the subscription; MacSpace does not edit Apple's subscription database for a live account.
/// Measured on 26B5091g: `results/assetsv2-inventory-2026-10-01/`.
public struct AssetFamily: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    /// Asset names in the family, e.g. `siri.asr.assistant.pt_BR`.
    public let assets: [String]
    public let bytes: UInt64
    /// What keeps the family installed.
    public let heldBy: String
    /// Where the user releases it; empty when no setting is known.
    public let steps: [String]
    /// Whether the steps were checked on a real macOS build.
    public let verified: Bool
}

public struct AssetFamilyScanner {
    public static let defaultRoot = "/System/Library/AssetsV2"
    /// Families smaller than this are folded into "Other".
    public static let minimumBytes: UInt64 = 20_000_000

    struct Rule {
        let id: String
        let title: String
        let tokens: [String]
        let heldBy: String
        let steps: [String]
        let verified: Bool
    }

    static let rules: [Rule] = [
        // No setting releases them: the Siri speech service, speech recognition and phone call features keep the model for the Siri
        // language and the system language whatever Siri's settings, so they are not listed among the downloads to turn off.
        Rule(id: "siri-speech", title: "Siri speech models", tokens: ["siri.asr.assistant", "siri.asr.hammer"],
             heldBy: "The Siri speech service, speech recognition and phone call features, for the Siri language and the system language. No setting removes them.",
             steps: [], verified: true),
        Rule(id: "siri-voices", title: "Siri voices", tokens: ["siri.tts"],
             heldBy: "The Siri text-to-speech service, for the selected Siri voice and language.",
             steps: ["Open System Settings → Apple Intelligence & Siri → Siri Voice and choose a voice that is not a downloaded premium one.",
                     "After a restart, free them under Free now → Unused system assets."], verified: false),
        Rule(id: "speech-recognition", title: "Speech recognition (dictation and calls)", tokens: ["speech.asr", "transcription"],
             heldBy: "Siri's speech service and phone call features, for the languages they transcribe.",
             steps: ["Open System Settings → Keyboard → Dictation and remove languages you do not dictate in.",
                     "After a restart, free them under Free now → Unused system assets."], verified: false),
        Rule(id: "language-data", title: "Language data (spelling, text analysis)", tokens: ["linguisticdata"],
             heldBy: "Requested by the system for each language it has seen text in, and refreshed daily. It is not a Settings choice: the Spelling language can be set to a single language and the list stays the same (checked on 26B5091g).",
             steps: [], verified: true),
        Rule(id: "developer-docs", title: "Apple developer documentation", tokens: ["documentationasset"],
             heldBy: "Downloaded for Xcode; macOS marks it precious and nothing subscribes to it.",
             steps: ["Open Xcode → Settings and look under Components or Documentation for the downloaded documentation.",
                     "Remove it there; Xcode downloads it again when you open the documentation viewer."], verified: false),
        Rule(id: "photos-models", title: "Photos models (Spatial Photos)", tokens: ["spatialphotos"],
             heldBy: "macOS's model catalog, for the Photos spatial effect.",
             steps: [], verified: false),
        Rule(id: "dictionaries", title: "Dictionaries", tokens: ["dictionary", "portuguese", "oxford", "thesaurus"],
             heldBy: "The Dictionary app and Look Up.",
             steps: ["Open Dictionary → Settings and turn off the dictionaries you do not use."], verified: false),
    ]

    let root: String
    private let fileManager: FileManager

    public init(root: String = AssetFamilyScanner.defaultRoot, fileManager: FileManager = .default) {
        self.root = root
        self.fileManager = fileManager
    }

    func assets() -> [(name: String, bytes: UInt64)] {
        let sizer = FileTreeSizer()
        var found: [(String, UInt64)] = []
        func visit(_ directory: String, depth: Int) {
            guard let children = try? fileManager.contentsOfDirectory(atPath: directory) else { return }
            for child in children where !child.hasPrefix(".") {
                let path = (directory as NSString).appendingPathComponent(child)
                if child.hasSuffix(".asset") {
                    let bytes = sizer.size(at: URL(fileURLWithPath: path)).map { $0.allocatedBytesEstimate ?? $0.logicalBytes } ?? 0
                    found.append((Self.name(of: path, folder: directory), bytes))
                } else if depth < 2 {
                    var isDirectory: ObjCBool = false
                    if fileManager.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue { visit(path, depth: depth + 1) }
                }
            }
        }
        visit(root, depth: 0)
        return found
    }

    /// The asset's own name from its Info.plist, falling back to the folder it sits in.
    static func name(of assetPath: String, folder: String) -> String {
        let plist = (assetPath as NSString).appendingPathComponent("Info.plist")
        if let data = FileManager.default.contents(atPath: plist),
           let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            if let properties = info["MobileAssetProperties"] as? [String: Any], let specifier = properties["AssetSpecifier"] as? String { return specifier }
            if let name = info["CFBundleName"] as? String { return name }
        }
        let parent = (folder as NSString).lastPathComponent
        return parent == "purpose_auto" ? ((folder as NSString).deletingLastPathComponent as NSString).lastPathComponent : parent
    }

    public func scan() -> [AssetFamily] {
        var groups: [String: (rule: Rule?, assets: [String], bytes: UInt64)] = [:]
        for asset in assets() {
            let lowered = asset.name.lowercased()
            let rule = Self.rules.first { rule in rule.tokens.contains { lowered.contains($0) } }
            let key = rule?.id ?? "other"
            var group = groups[key] ?? (rule, [], 0)
            group.assets.append(asset.name)
            group.bytes += asset.bytes
            groups[key] = group
        }
        var families: [AssetFamily] = []
        var otherBytes: UInt64 = 0
        var otherAssets: [String] = []
        for (id, group) in groups {
            guard let rule = group.rule else { otherBytes += group.bytes; otherAssets += group.assets; continue }
            families.append(AssetFamily(id: id, title: rule.title, assets: group.assets.sorted(), bytes: group.bytes, heldBy: rule.heldBy,
                                        steps: rule.steps, verified: rule.verified))
        }
        if otherBytes > 0 {
            families.append(AssetFamily(id: "other", title: "Other system downloads", assets: otherAssets.sorted(), bytes: otherBytes,
                                        heldBy: "Assorted macOS features and the OS itself.", steps: [], verified: false))
        }
        return families.filter { $0.bytes >= Self.minimumBytes }.sorted { $0.bytes > $1.bytes }
    }
}
