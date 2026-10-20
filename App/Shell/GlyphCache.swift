import Darwin

/// Keeps Core Graphics' glyph cache small. Every text drawn on the CPU keeps a bitmap of each glyph at each size, place and scale it
/// was drawn at, and SwiftUI's numeric content transition draws its digits scaled and blurred on every frame of a roll: all those
/// bitmaps stayed. The cache's own limit (16 MB) was not kept to: thirteen numbers rolling eight times left 65 MB, and the numbers
/// changing while the modules read at launch 150 MB and more (Issue 11). At 1 MB the same rolls leave 7 MB, take the same CPU (a roll
/// never draws a digit at the same scale twice, so the cache never helped it) and look exactly the same: a glyph no longer kept is
/// drawn again, identically.
///
/// The functions are Core Graphics' own but not public: they are looked up when MacSpace starts, and without them nothing changes.
public enum GlyphCache {
    public static let limit = 1_048_576

    private typealias LocalCache = @convention(c) () -> OpaquePointer?
    private typealias SetMaxSize = @convention(c) (OpaquePointer?, Int) -> Void
    private typealias GetMaxSize = @convention(c) (OpaquePointer?) -> Int

    private static func function<T>(_ name: String, _ type: T.Type) -> T? {
        guard let handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_NOW | RTLD_NOLOAD),
              let address = dlsym(handle, name) else { return nil }
        return unsafeBitCast(address, to: type)
    }

    /// Applied once, before the first window draws. Returns the limit the cache now has, or nil when Core Graphics has no such cache.
    @discardableResult
    public static func apply() -> Int? {
        guard let local = function("CGFontCacheGetLocalCache", LocalCache.self), let setMaxSize = function("CGFontCacheSetMaxSize", SetMaxSize.self),
              let getMaxSize = function("CGFontCacheGetMaxSize", GetMaxSize.self), let cache = local() else { return nil }
        setMaxSize(cache, limit)
        return getMaxSize(cache)
    }
}
