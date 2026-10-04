import Foundation
#if canImport(MachO)
import MachO
#endif

/// The Darwin notification posted after a preference is written, so the processes that cache the setting read it again: what System
/// Settings posts after it changes the same setting.
public enum DarwinNotificationName: Codable, Equatable, Sendable, CustomStringConvertible {
    /// A name known as text, such as `AFLanguageCodeDidChangeDarwinNotification` (CP112).
    case literal(String)
    /// A string constant the framework owning the setting exports, read at run time: its value is the name, whatever this build
    /// makes it.
    case exported(framework: String, symbol: String)

    public var description: String {
        switch self {
        case .literal(let name): return name
        case let .exported(framework, symbol): return "\(symbol) (\((framework as NSString).lastPathComponent))"
        }
    }

    /// The name to post; nil when the framework or its constant is missing on this build.
    public func resolve() -> String? {
        switch self {
        case .literal(let name): return name
        case let .exported(framework, symbol): return ExportedString.value(framework: framework, symbol: symbol)
        }
    }

    /// Posts it on the Darwin center, as `notifyutil -p` does. Returns the name posted, nil if it could not be resolved.
    @discardableResult
    public func post() -> String? {
        guard let name = resolve() else { return nil }
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName(name as CFString), nil, nil, true)
        return name
    }
}

/// Reads a string constant a framework exports (`const char *`, or a constant `CFString`/`NSString`). The pointer
/// is followed only into the sections that hold such strings, so a constant of another type gives nil instead of a crash.
public enum ExportedString {
    public static func value(framework: String, symbol: String) -> String? {
        #if canImport(MachO)
        guard let handle = dlopen(framework, RTLD_LAZY | RTLD_NOLOAD) ?? dlopen(framework, RTLD_LAZY),
              let address = dlsym(handle, symbol) else { return nil }
        var info = Dl_info()
        guard dladdr(address, &info) != 0, let base = info.dli_fbase else { return nil }
        let header = UnsafePointer(base.assumingMemoryBound(to: mach_header_64.self))
        // `const char name[]`: the symbol is the text.
        if contains(UnsafeRawPointer(address), header, "__TEXT", ["__cstring"]) {
            return String(cString: address.assumingMemoryBound(to: CChar.self))
        }
        // A pointer: kept in a data segment, to text or to a constant CFString.
        guard contains(UnsafeRawPointer(address), header, nil, ["__const", "__data", "__auth_ptr"]),
              let target = UnsafeRawPointer(address).load(as: UnsafeRawPointer?.self) else { return nil }
        if contains(target, header, "__TEXT", ["__cstring"]) { return String(cString: target.assumingMemoryBound(to: CChar.self)) }
        if contains(target, header, nil, ["__cfstring"]) {
            return Unmanaged<CFString>.fromOpaque(target).takeUnretainedValue() as String
        }
        return nil
        #else
        return nil
        #endif
    }

    #if canImport(MachO)
    private static let dataSegments = ["__DATA_CONST", "__DATA", "__AUTH_CONST", "__AUTH", "__DATA_DIRTY"]

    /// Whether `pointer` lies in one of the named sections of the image (in any data segment when `segment` is nil).
    private static func contains(_ pointer: UnsafeRawPointer, _ header: UnsafePointer<mach_header_64>, _ segment: String?,
                                 _ sections: [String]) -> Bool {
        for name in segment.map({ [$0] }) ?? dataSegments {
            for section in sections {
                var size: UInt = 0
                guard let start = getsectiondata(header, name, section, &size), size > 0 else { continue }
                let lower = UnsafeRawPointer(start)
                if pointer >= lower && pointer < lower + Int(size) { return true }
            }
        }
        return false
    }
    #endif
}
