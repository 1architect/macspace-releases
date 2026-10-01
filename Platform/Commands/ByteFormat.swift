import Foundation

public enum ByteFormat {
    /// "12,04 GB" in the user's locale, with decimal units to match what Finder and System Settings show.
    public static func string(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
    }
}
