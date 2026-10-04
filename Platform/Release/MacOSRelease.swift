import Foundation

/// The macOS release MacSpace runs on: version and build. Code is written for every release; where one release needs something of its
/// own, that difference is declared with `ReleaseSpecific`, never by comparing build strings inline.
public struct MacOSRelease: Equatable, Hashable, Sendable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int
    /// The build, e.g. 26B5091g; nil when unreadable.
    public let build: String?

    public init(major: Int, minor: Int = 0, patch: Int = 0, build: String? = nil) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.build = build
    }

    public static let current: MacOSRelease = {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return MacOSRelease(major: version.majorVersion, minor: version.minorVersion, patch: version.patchVersion, build: Self.readBuild())
    }()

    /// A beta (seed) build: a four-digit build number with a lowercase suffix (26B5091g). Rapid Security Responses also end in a
    /// lowercase letter but carry longer numbers (22E772610a).
    public var isPrerelease: Bool {
        guard let build else { return false }
        return build.range(of: #"^[0-9]+[A-Z][0-9]{4}[a-z]$"#, options: .regularExpression) != nil
    }

    /// "27.2", or "27.2.1".
    public var version: String { patch == 0 ? "\(major).\(minor)" : "\(major).\(minor).\(patch)" }

    /// "macOS 27.2 (26B5091g), beta", for diagnostics and the Settings page.
    public var description: String {
        var text = "macOS \(version)"
        if let build { text += " (\(build))" }
        if isPrerelease { text += ", beta" }
        return text
    }

    /// Ordered by version; the build does not take part.
    public static func < (lhs: MacOSRelease, rhs: MacOSRelease) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }

    static func readBuild() -> String? {
        var size = 0
        guard sysctlbyname("kern.osversion", nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.osversion", &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }
}

/// Which releases a release-specific value applies to.
public enum ReleaseMatch: Equatable, Hashable, Sendable {
    /// Every release of a major version (27 is every macOS 27).
    case major(Int)
    /// Versions from the first up to and including the second, by major.minor.patch.
    case versions(from: MacOSRelease, through: MacOSRelease)
    /// One build exactly (a beta that needs a fix of its own).
    case build(String)
    /// Beta builds only.
    case prerelease

    public func matches(_ release: MacOSRelease) -> Bool {
        switch self {
        case let .major(major): return release.major == major
        case let .versions(from, through): return !(release < from) && !(through < release)
        case let .build(build): return release.build == build
        case .prerelease: return release.isPrerelease
        }
    }
}

/// A value that is the same on every macOS release unless an override says otherwise for some of them. The first matching override
/// wins, so list the narrowest first (a build before its major version).
///
///     static let releaseWait = ReleaseSpecific(5.0, overrides: [(.build("26B5091g"), 8.0)])
///     Thread.sleep(forTimeInterval: releaseWait.value)
public struct ReleaseSpecific<Value: Sendable>: Sendable {
    public let standard: Value
    public let overrides: [(match: ReleaseMatch, value: Value)]

    public init(_ standard: Value, overrides: [(match: ReleaseMatch, value: Value)] = []) {
        self.standard = standard
        self.overrides = overrides
    }

    public func value(on release: MacOSRelease) -> Value {
        overrides.first { $0.match.matches(release) }?.value ?? standard
    }

    /// The value on the running Mac.
    public var value: Value { value(on: .current) }
}

/// The macOS releases MacSpace supports. A release outside them still runs: the app says it is untested there, it does not refuse.
public enum SupportedReleases {
    public static let majors: Set<Int> = [27]

    public static func isSupported(_ release: MacOSRelease = .current) -> Bool { majors.contains(release.major) }
}
