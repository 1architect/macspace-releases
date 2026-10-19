import Foundation

/// Whether MacSpace may ask macOS to delete its system assets (mobileassetd's purge) now. Not while Apple Intelligence is available:
/// its models download and update as system assets, and pieces not yet installed count as purgeable. On 2026-10-12, purges of
/// system assets at high urgency coincided with macOS deleting Apple Intelligence components mid-download (Messages and
/// summarization models, search understanding, translation, Shortcuts), on a disk with 87 GB free.
///
/// Every purge of the service goes through here, whoever asks: a module's button, Clean, automatic cleaning, `PurgeRetrier` and the
/// CLI (`CacheDeleteClient.purge`, `CacheDeleteClient.purgeInSubprocess`, `PurgeRun`). Once Apple Intelligence is switched off
/// (Siri & Apple Intelligence page), macOS reports it unavailable and the purge that releases its models goes ahead.
public enum SystemAssetGuard {
    /// Where macOS writes its eligibility answers (readable with Full Disk Access).
    public static let eligibilityPath = "/private/var/db/os_eligibility/eligibility.plist"
    static let siriModeDomain = "OS_ELIGIBILITY_DOMAIN_SIRI_MODE"
    /// `os_eligibility_answer_t` that means eligible (4 observed eligible, 2 not).
    static let eligibleAnswer = 4

    /// Whether Apple Intelligence is available on this Mac now; nil when macOS's answer cannot be read. Replaceable in tests.
    nonisolated(unsafe) public static var appleIntelligenceAvailable: @Sendable () -> Bool? = {
        (try? Data(contentsOf: URL(fileURLWithPath: eligibilityPath))).flatMap(available(inEligibility:))
    }

    /// Reads the Siri mode answer out of macOS's eligibility file; nil when it has none.
    public static func available(inEligibility data: Data) -> Bool? {
        guard let root = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let domain = root[siriModeDomain] as? [String: Any],
              let answer = (domain["os_eligibility_answer_t"] as? NSNumber)?.intValue else { return nil }
        return answer == eligibleAnswer
    }

    /// The system assets are kept now: Apple Intelligence is available. When its answer cannot be read, they are not held, as before.
    public static var holdsAssets: Bool { appleIntelligenceAvailable() == true }

    /// Owner withdrawal has a stricter gate than legacy purge-only callers: only the reviewed 2/4 answers are meaningful.
    public static func reviewedAvailability(inEligibility data: Data) -> Bool? {
        guard let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let domain = root[siriModeDomain] as? [String: Any], let answer = domain["os_eligibility_answer_t"] as? Int else { return nil }
        switch answer { case 2: return false; case 4: return true; default: return nil }
    }

    public static var reviewedAvailability: Bool? {
        (try? Data(contentsOf: URL(fileURLWithPath: eligibilityPath))).flatMap(reviewedAvailability(inEligibility:))
    }

    /// Why a purge of `services` is not made now, or nil when it may go ahead. A `featureCleanup` (the Siri, Spatial Photos and Phone
    /// switches, `AssetModelCleanup`) may go ahead while Apple Intelligence is on, as long as MobileAsset is downloading nothing
    /// (`downloadsIdle`): what went on 2026-10-12 were pieces caught mid-download, which count as purgeable until installed.
    public static func refusal(_ services: [String], featureCleanup: Bool = false) -> String? {
        guard services.contains(CacheDeleteService.mobileAsset), holdsAssets else { return nil }
        if featureCleanup, downloadsIdle() { return nil }
        return heldMessage
    }

    /// Where MobileAsset puts every download until it is complete, one folder each (`<family>.<hash>.auto.<uuid>`); the `.xml` files
    /// beside them are catalogs, not downloads.
    public static let stagingFolder = "/System/Library/AssetsV2/staging"

    /// MobileAsset is downloading nothing now: no folder in its staging folder, and no Apple Intelligence model record partly
    /// downloaded. Unreadable counts as busy. Replaceable in tests.
    nonisolated(unsafe) public static var downloadsIdle: @Sendable () -> Bool = {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: stagingFolder),
              !entries.contains(where: { !$0.hasSuffix(".xml") && !$0.hasPrefix(".") }),
              let usage = ModelDescriptors.usage() else { return false }
        return usage.downloadingBytes == 0
    }

    /// Said where a purge was not made, in English (results' details and the CLI).
    public static let heldMessage = "Apple Intelligence is on: MacSpace does not ask macOS to delete system assets, which hold its models and their downloads."
}
