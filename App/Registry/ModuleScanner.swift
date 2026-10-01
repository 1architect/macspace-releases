import Foundation
import MacSpaceSdk

public struct ModuleDescriptor: Equatable, Sendable, Identifiable {
    public enum Compatibility: Equatable, Sendable {
        case compatible
        case incompatible(reason: String)
    }

    public var manifest: ModuleManifest
    public var bundleURL: URL
    public var compatibility: Compatibility

    public var id: String { manifest.id }
}

/// A bundle in the modules folder that could not be used at all (no readable manifest, or a duplicate id).
public struct ModuleProblem: Equatable, Sendable, Identifiable {
    public var bundleName: String
    public var reason: String

    public var id: String { bundleName }
}

/// Finds module bundles (`*.macspacemodule`) and reads their manifests without running any module code.
public enum ModuleScanner {
    public static let bundleExtension = "macspacemodule"
    public static let manifestPath = "Contents/Resources/Manifest.json"

    public static func scan(directory: URL, systemVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion,
                            fileManager: FileManager = .default) -> (modules: [ModuleDescriptor], problems: [ModuleProblem]) {
        let entries = ((try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == bundleExtension }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var modules: [ModuleDescriptor] = []
        var problems: [ModuleProblem] = []
        let decoder = JSONDecoder()
        for url in entries {
            let name = url.lastPathComponent
            guard let data = try? Data(contentsOf: url.appendingPathComponent(manifestPath)) else {
                problems.append(ModuleProblem(bundleName: name, reason: "Manifest.json is missing."))
                continue
            }
            let manifest: ModuleManifest
            do { manifest = try decoder.decode(ModuleManifest.self, from: data) } catch {
                problems.append(ModuleProblem(bundleName: name, reason: "Manifest.json is not valid: \(error.localizedDescription)"))
                continue
            }
            if modules.contains(where: { $0.id == manifest.id }) {
                problems.append(ModuleProblem(bundleName: name, reason: "Another module already uses the id \(manifest.id)."))
                continue
            }
            modules.append(ModuleDescriptor(manifest: manifest, bundleURL: url,
                                            compatibility: compatibility(of: manifest, systemVersion: systemVersion)))
        }
        modules.sort { ($0.manifest.order, $0.manifest.name) < ($1.manifest.order, $1.manifest.name) }
        return (modules, problems)
    }

    static func compatibility(of manifest: ModuleManifest, systemVersion: OperatingSystemVersion) -> ModuleDescriptor.Compatibility {
        if manifest.sdkVersion != SdkVersion.current {
            return .incompatible(reason: "Built for module contract \(manifest.sdkVersion); this app uses \(SdkVersion.current).")
        }
        if let minimum = manifest.minimumMacOS, let required = parse(minimum), isOlder(systemVersion, than: required) {
            return .incompatible(reason: "Needs macOS \(minimum) or later.")
        }
        return .compatible
    }

    static func parse(_ version: String) -> OperatingSystemVersion? {
        let parts = version.split(separator: ".").compactMap { Int($0) }
        guard let major = parts.first else { return nil }
        return OperatingSystemVersion(majorVersion: major, minorVersion: parts.count > 1 ? parts[1] : 0, patchVersion: parts.count > 2 ? parts[2] : 0)
    }

    static func isOlder(_ lhs: OperatingSystemVersion, than rhs: OperatingSystemVersion) -> Bool {
        (lhs.majorVersion, lhs.minorVersion, lhs.patchVersion) < (rhs.majorVersion, rhs.minorVersion, rhs.patchVersion)
    }
}

/// Loads a module's code. The bundle must be signed by the same team as the app (hardened runtime library validation).
public enum ModuleLoader {
    public enum LoadError: Error, LocalizedError {
        case cannotLoad(String)
        case noPrincipalClass

        public var errorDescription: String? {
            switch self {
            case let .cannotLoad(path): return "The module bundle could not be loaded (\(path))."
            case .noPrincipalClass: return "The module bundle does not provide a MacSpaceModuleEntry principal class."
            }
        }
    }

    public static func load(_ descriptor: ModuleDescriptor) throws -> any MacSpaceModule {
        guard let bundle = Bundle(url: descriptor.bundleURL), bundle.load() else {
            throw LoadError.cannotLoad(descriptor.bundleURL.lastPathComponent)
        }
        guard let entry = bundle.principalClass as? MacSpaceModuleEntry.Type else { throw LoadError.noPrincipalClass }
        return entry.init().makeModule()
    }
}
