import AppKit
import Darwin.membership
import Foundation
import ObjectiveC
import SQLite3

/// The model-owner requests reviewed in Issue 16, withdrawn and restored through Apple's own owner APIs. Runs only in the signed
/// CLI child (`asset-owners <scope> <mode>`), so an unexpected private-API failure ends that process, never the app. Every private
/// method's type encoding is checked before it is called; a mismatch refuses the whole operation.
/// Fixed scopes: siri, phone, released. Fixed modes: inspect, release, restore. No UAF database writes, payload deletion, lock
/// deletion, daemon suppression, profile or SIP change.
enum AssetOwners {
    struct Refusal: Error { var message: String; init(_ message: String) { self.message = message } }

    static func run(scope name: String, mode: String) -> Data {
        var result: [String: Any] = ["releasedOwners": 0, "pending": false]
        var details: [String] = []
        do {
            guard let scope = AssetModelCleanup.Scope(rawValue: name), scope != .spatialPhotos,
                  ["inspect", "release", "restore"].contains(mode) else { throw Refusal("Unknown owner scope or mode") }
            var console = stat()
            try require(getuid() != 0 && stat("/dev/console", &console) == 0 && console.st_uid == getuid(),
                        "Model controls require the logged-in user's session")
            try require(PhoneFeatureFlags.supported.value, "Model owner controls are not verified on this macOS build")
            for framework in ["PrivateFrameworks/UnifiedAssetFramework.framework/UnifiedAssetFramework", "Frameworks/Speech.framework/Speech",
                              "PrivateFrameworks/AssistantServices.framework/AssistantServices",
                              "PrivateFrameworks/DataDeliveryServices.framework/DataDeliveryServices"] {
                try load("/System/Library/" + framework)
            }
            if mode == "inspect" {
                try inspect(into: &result)
            } else {
                let folder = AssetModelCleanup.journal(scope).deletingLastPathComponent()
                try attempt("Cannot create owner journal folder") {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                }
                var info = stat()
                try require(lstat(folder.path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR && info.st_uid == getuid() && info.st_mode & 0o022 == 0,
                            "Unsafe owner journal folder")
                let lock = open(folder.appendingPathComponent("operation.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
                defer { if lock >= 0 { flock(lock, LOCK_UN); close(lock) } }
                try require(lock >= 0 && flock(lock, LOCK_EX | LOCK_NB) == 0, "Another model owner operation is running")
                let journal = try Journal(scope)
                let user = try userGUID()
                let owner = try manager()
                if mode == "restore" {
                    try restore(journal, owner: owner, user: user, details: &details)
                } else {
                    try reconcile(journal, owner: owner, user: user)
                    if scope == .released { try releaseLanguageData(journal, details: &details) } else {
                        try releaseSpeech(journal, owner: owner, user: user, details: &details)
                        if scope == .siri { try readoptLeftovers(owner: owner, user: user, details: &details) }
                        let active = try releaseVoices(journal, details: &details)
                        try releaseMappedOwners(journal, owner: owner, user: user, activeVoices: active, details: &details)
                    }
                }
                result["releasedOwners"] = journal.removed
            }
        } catch {
            result["error"] = (error as? Refusal)?.message ?? "Model owner operation failed"
            result["pending"] = true
        }
        result["details"] = details
        return (try? JSONSerialization.data(withJSONObject: result, options: .sortedKeys))
            ?? Data(#"{"error":"Could not encode model result","pending":true,"releasedOwners":0,"details":[]}"#.utf8)
    }

    /// Metadata and queries only: verifies the installed contracts before a mutation is offered on this build.
    static func inspect(into result: inout [String: Any]) throws {
        result["observedOwners"] = try rows().count
        _ = try manager()
        result["speechOff"] = try speechOff()
        let speech: AnyClass = try objcClass("SFSpeechAssetManager"), entitled: AnyClass = try objcClass("SFEntitledAssetManager")
        let center: AnyClass = try objcClass("DDSAssetCenter")
        try check(speech, "unsubscribeFromAssetsWithConfigs:clientIdentifier:completionHandler:", "v40@0:8@16@24@?32", classMethod: true)
        try check(entitled, "unsubscribeFromAssetsWithConfigs:subscriberId:completionHandler:", "v40@0:8@16@24@?32", classMethod: true)
        try check(entitled, "subscriptionNameForConfig:", "@24@0:8@16", classMethod: true)
        try check(entitled, "assetSetUsageForConfig:", "@24@0:8@16", classMethod: true)
        try check(entitled, "_assetSetSubscriptionWithConfig:expiration:", "@32@0:8@16@24", classMethod: true)
        try check(try objcClass("SFEntitledAssetConfig"), "initWithLanguage:assetType:", "@32@0:8@16Q24")
        try check(center, "removeAssertionWithIdentifier:assetType:", "v32@0:8@16@24")
        try check(center, "addAssertionsForAssetsWithQueries:policies:assertionIDs:clientID:", "v48@0:8@16@24@32@40")
        let voices = try VoiceConnection()
        defer { voices.close() }
        result["voiceOwners"] = try voices.requests().count
        let languageData = try languageDataOwners()
        result["languageDataOwners"] = languageData.count
        for item in languageData.values {
            try require(try sameLanguageData(item, try decode(try archive(item)) as? NSDictionary), "Language-data rollback preflight failed")
        }
        result["secureRollbackVerified"] = true
    }

    // MARK: Runtime contracts

    static func require(_ ok: Bool, _ message: String) throws { if !ok { throw Refusal(message) } }
    static func attempt<T>(_ message: String, _ body: () throws -> T) throws -> T {
        do { return try body() } catch let refusal as Refusal { throw refusal } catch { throw Refusal(message) }
    }
    static func load(_ path: String) throws {
        try require(dlopen(path, RTLD_LAZY) != nil, "Cannot load " + (path as NSString).lastPathComponent)
    }
    static func objcClass(_ name: String) throws -> AnyClass {
        guard let type = NSClassFromString(name) else { throw Refusal("Unreviewed owner method: \(name)") }
        return type
    }
    /// The installed method must have the reviewed type encoding before it is messaged.
    static func check(_ type: AnyClass, _ name: String, _ encoding: String, classMethod: Bool = false) throws {
        let selector = NSSelectorFromString(name)
        let method = classMethod ? class_getClassMethod(type, selector) : class_getInstanceMethod(type, selector)
        try require(method.flatMap(method_getTypeEncoding).map { String(cString: $0) } == encoding, "Unreviewed owner method: \(name)")
    }
    /// An object (or class object, for class methods) messaged through a protocol, as `(Class<P>)type` does in Objective-C.
    static func messaging<P>(_ object: AnyObject, as _: P.Type) -> P { unsafeBitCast(object, to: P.self) }
    /// A property read. A property the object lacks refuses, rather than raising inside the child as `valueForKey:` would.
    static func value(_ object: Any?, _ key: String) throws -> Any? {
        guard let object, !(object is NSNull) else { return nil }
        if let dictionary = object as? NSDictionary { return dictionary[key] }
        guard let object = object as? NSObject, object.responds(to: NSSelectorFromString(key)) else {
            throw Refusal("Unreviewed owner property: \(key)")
        }
        return object.value(forKey: key)
    }
    static func equal(_ lhs: Any?, _ rhs: Any?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case let (lhs as NSObject, rhs?): return lhs.isEqual(rhs)
        default: return false
        }
    }
    static func classes() -> [AnyClass] {
        [NSArray.self, NSMutableArray.self, NSDictionary.self, NSMutableDictionary.self, NSSet.self, NSMutableSet.self, NSString.self,
         NSNumber.self, NSDate.self, NSData.self, NSNull.self]
            + ["UAFAssetSetSubscription", "SFEntitledAssetConfig", "SiriTTSVoiceSubscription", "SiriTTSSynthesisVoice", "DDSAssertion",
               "DDSAssertDescriptor", "DDSAssetPolicy", "DDSLinguisticAssetQuery", "DDSAssetQuery", "DDSLinguisticAttributeFilter",
               "DDSAttributeFilter"].compactMap(NSClassFromString)
    }
    static func archive(_ object: Any) throws -> Data {
        try attempt("Owner rollback object could not be archived") {
            try NSKeyedArchiver.archivedData(withRootObject: object, requiringSecureCoding: true)
        }
    }
    static func decode(_ data: Data) throws -> Any {
        let object = try attempt("Owner rollback archive could not be securely decoded") {
            try NSKeyedUnarchiver.unarchivedObject(ofClasses: classes(), from: data)
        }
        guard let object else { throw Refusal("Owner rollback archive could not be securely decoded") }
        return object
    }
    /// Waits for one asynchronous reply; `fail` (an XPC error) or silence means no answer.
    final class Reply<Value>: @unchecked Sendable {
        private let semaphore = DispatchSemaphore(value: 0)
        private(set) var value: Value?
        private var answered = false
        func send(_ value: Value) { self.value = value; answered = true; semaphore.signal() }
        func fail() { semaphore.signal() }
        func wait(_ seconds: Double) -> Bool { semaphore.wait(timeout: .now() + seconds) == .success && answered }
    }
    static func retry(_ times: Int, every seconds: Double, until done: () throws -> Bool) rethrows -> Bool {
        for attempt in 0..<times {
            if try done() { return true }
            if attempt < times - 1 { Thread.sleep(forTimeInterval: seconds) }
        }
        return false
    }

    // MARK: Journal

    enum Phase: String, Codable { case prepared, submitted, removed, restoring, restored }
    struct Entry: Codable {
        var kind: String
        var client: String
        var name: String
        var archive: Data
        var phase: Phase
        var user: String?
        var expiry: Double?
    }
    /// The rollback record for one scope, saved and synced before each owner request.
    final class Journal {
        struct Stored: Codable { var version = 1; var scope: String; var uid: UInt32; var entries: [Entry]; var cycleRemoved: Int? }
        let scope: AssetModelCleanup.Scope
        var entries: [Entry] = []
        /// Owners removed in this run only, not every earlier journal entry.
        private(set) var removed = 0
        var url: URL { AssetModelCleanup.journal(scope) }

        init(_ scope: AssetModelCleanup.Scope) throws {
            self.scope = scope
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            var info = stat()
            try require(lstat(url.path, &info) == 0 && info.st_mode & S_IFMT == S_IFREG && info.st_uid == getuid() && info.st_mode & 0o077 == 0,
                        "Unsafe owner journal")
            entries = try Self.entries(try attempt("Invalid owner journal") { try Data(contentsOf: url) }, scope: scope)
        }
        /// Also reads the journals the earlier Objective-C bridge saved, which use the same keys.
        static func entries(_ data: Data, scope: AssetModelCleanup.Scope) throws -> [Entry] {
            let stored = try attempt("Invalid owner journal") { try PropertyListDecoder().decode(Stored.self, from: data) }
            try require(stored.version == 1 && stored.scope == scope.rawValue && stored.uid == getuid(), "Invalid owner journal")
            return stored.entries
        }
        func save() throws {
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            let stored = Stored(scope: scope.rawValue, uid: getuid(), entries: entries, cycleRemoved: removed)
            try attempt("Cannot save owner rollback journal") { try encoder.encode(stored).write(to: url, options: .atomic) }
            try require(chmod(url.path, 0o600) == 0, "Cannot protect owner journal")
            for (path, flags) in [(url.path, O_RDONLY | O_NOFOLLOW), (url.deletingLastPathComponent().path, O_RDONLY)] {
                let descriptor = open(path, flags)
                try require(descriptor >= 0, "Cannot open saved owner journal")
                let synced = fsync(descriptor) == 0
                close(descriptor)
                try require(synced, "Cannot sync owner journal")
            }
        }
        /// The first record keeps the original owner; a disable after a completed restore starts a fresh ownership cycle.
        func record(_ kind: String, client: String, name: String, archive: Data, user: String? = nil, expiry: Double? = nil) throws -> Int {
            if let index = entries.firstIndex(where: { $0.kind == kind && $0.client == client && $0.name == name }) {
                try require(![.submitted, .restoring].contains(entries[index].phase), "An earlier owner request needs read-only reconciliation")
                if entries[index].phase == .restored {
                    entries[index].archive = archive
                    if let user { entries[index].user = user }
                    if let expiry { entries[index].expiry = expiry }
                }
                entries[index].phase = .prepared
                return index
            }
            try require(entries.count < 512, "Too many owner rollback records")
            entries.append(Entry(kind: kind, client: client, name: name, archive: archive, phase: .prepared, user: user, expiry: expiry))
            return entries.count - 1
        }
        /// Saved as submitted before the request goes out, after the feature gates are checked once more.
        func submit(_ index: Int) throws {
            try safety(scope)
            entries[index].phase = .submitted
            try save()
        }
        func finish(_ index: Int) throws {
            entries[index].phase = .removed
            removed += 1
            try save()
        }
        func set(_ index: Int, _ phase: Phase) throws {
            entries[index].phase = phase
            try save()
        }
    }

    /// The features must still be off at every owner request, and Apple Intelligence's answer still readable: unavailable for the
    /// language data, which Apple Intelligence reads; either answer for a feature's own owners (`AssetModelCleanup.refusal`).
    static func safety(_ scope: AssetModelCleanup.Scope) throws {
        let eligibility = NSDictionary(contentsOfFile: "/private/var/db/os_eligibility/eligibility.plist")
        let answer = (eligibility?["OS_ELIGIBILITY_DOMAIN_SIRI_MODE"] as? NSDictionary)?["os_eligibility_answer_t"]
        let allowed = scope == .released ? [2] : [2, 4]
        try require(allowed.contains { equal(answer, NSNumber(value: $0)) }, "Apple Intelligence availability changed or became unreadable")
        func preference(_ key: String, _ domain: String) -> Any? {
            CFPreferencesAppSynchronize(domain as CFString)
            return CFPreferencesCopyAppValue(key as CFString, domain as CFString)
        }
        if scope == .siri {
            try require(equal(preference("Assistant Enabled", "com.apple.assistant.support"), NSNumber(value: false))
                        && preference("Output Voice", "com.apple.assistant.backedup") == nil && preferenceOff("assistantIsEnabled"),
                        "Siri settings changed; model cleanup stopped")
        }
        if scope == .phone {
            for feature in PhoneFeatureFlags.features {
                guard let enabled = FeatureFlagOverrides.effectiveValue(domain: PhoneFeatureFlags.domain, feature: feature) else {
                    throw Refusal("Phone feature gates became unreadable")
                }
                try require(!enabled, "Phone feature gates changed; cleanup stopped")
            }
            let expected = [("CallRecordingDisabled", "com.apple.TelephonyUtilities", true), ("CallScreeningDisabled", "com.apple.TelephonyUtilities", true),
                            ("FaceTimeCaptions", "com.apple.Accessibility", false), ("LiveTranscriptionInCallEnabled", "com.apple.Accessibility", false)]
            for (key, domain, value) in expected {
                try require(equal(preference(key, domain), NSNumber(value: value)), "Phone feature settings changed; cleanup stopped")
            }
        }
    }
    static func preferenceOff(_ name: String) throws -> Bool {
        let preferences: AnyClass = try objcClass("AFPreferences")
        try check(preferences, "sharedPreferences", "@16@0:8", classMethod: true)
        try check(preferences, name, "B16@0:8")
        let shared = messaging(preferences, as: SharedPreferences.self).sharedPreferences()
        typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
        let selector = NSSelectorFromString(name)
        return !unsafeBitCast(class_getMethodImplementation(object_getClass(shared), selector), to: Getter.self)(shared, selector)
    }
    static func speechOff() throws -> Bool { try preferenceOff("assistantIsEnabled") && preferenceOff("dictationIsEnabled") }
    static func userGUID() throws -> String {
        var uuid = uuid_t(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        try require(mbr_uid_to_uuid(getuid(), &uuid) == 0, "Cannot resolve the current account")
        return UUID(uuid: uuid).uuidString
    }

    // MARK: Unified asset subscriptions

    struct OwnerRow { var client: String; var name: String; var archive: Data; var expiry: Double; var user: String }
    /// The read-only, immutable view of the owner database; nothing is ever written to it.
    static func rows() throws -> [OwnerRow] {
        var database: OpaquePointer?
        defer { sqlite3_close(database) }
        try require(sqlite3_open_v2("file:/private/var/db/assetsubscriptiond/UAFAssetSubscriptions.db?mode=ro&immutable=1", &database,
                                    SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK, "Cannot read asset owners")
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        try require(sqlite3_prepare_v2(database, "SELECT k0,k1,k2,k3,k4 FROM Subscriptions", -1, &statement, nil) == SQLITE_OK,
                    "Unknown asset subscription schema")
        func text(_ column: Int32) throws -> String {
            guard let raw = sqlite3_column_text(statement, column) else { return "" }
            guard let text = String(validatingCString: UnsafeRawPointer(raw).assumingMemoryBound(to: CChar.self)) else {
                throw Refusal("Invalid owner identity text")
            }
            return text
        }
        var rows: [OwnerRow] = []
        var step = sqlite3_step(statement)
        while step == SQLITE_ROW {
            let blob = sqlite3_column_blob(statement, 2).map { Data(bytes: $0, count: Int(sqlite3_column_bytes(statement, 2))) } ?? Data()
            rows.append(OwnerRow(client: try text(0), name: try text(1), archive: blob, expiry: sqlite3_column_double(statement, 3), user: try text(4)))
            step = sqlite3_step(statement)
        }
        try require(step == SQLITE_DONE, "Incomplete owner inventory")
        return rows
    }
    static func row(_ rows: [OwnerRow], client: String, name: String, user: String) throws -> OwnerRow? {
        let found = rows.filter { $0.client == client && $0.name == name && $0.user.caseInsensitiveCompare(user) == .orderedSame }
        try require(found.count < 2, "Duplicate owner identity")
        return found.first
    }
    static func facts(_ subscription: Any?) throws -> NSDictionary {
        var facts: [String: Any] = [:]
        for key in ["name", "assetSets", "usageAliases", "expiration"] { facts[key] = try value(subscription, key) ?? NSNull() }
        return facts as NSDictionary
    }
    static func manager() throws -> UAFManager {
        let type: AnyClass = try objcClass("UAFAssetSetManager")
        try check(type, "sharedManager", "@16@0:8", classMethod: true)
        try check(type, "subscriptionsForSubscriber:", "@24@0:8@16")
        try check(type, "unsubscribe:subscriptionNames:user:userInitiated:queue:completion:", "v60@0:8@16@24@32B40@44@?52")
        try check(type, "subscribe:subscriptions:user:userInitiated:queue:completion:", "v60@0:8@16@24@32B40@44@?52")
        return messaging(messaging(type, as: SharedManager.self).sharedManager(), as: UAFManager.self)
    }
    static func subscription(_ owner: UAFManager, client: String, name: String) throws -> AnyObject? {
        let all = owner.subscriptions(forSubscriber: client)
        try require(all == nil || all is NSArray, "Owner API query failed")
        var found: AnyObject?
        for subscription in (all as? NSArray) ?? [] where equal(try value(subscription, "name"), name) {
            try require(found == nil, "Duplicate owner API identity")
            found = subscription as AnyObject
        }
        return found
    }
    static func absent(_ owner: UAFManager, _ entry: Entry, user: String) throws -> Bool {
        try row(rows(), client: entry.client, name: entry.name, user: user) == nil && subscription(owner, client: entry.client, name: entry.name) == nil
    }
    /// Unsubscribes one verified owner and waits until both the API and the database no longer list it.
    static func withdraw(_ journal: Journal, _ index: Int, owner: UAFManager, user: String) throws {
        try journal.submit(index)
        let reply = Reply<Void>()
        let entry = journal.entries[index]
        owner.unsubscribe(entry.client, subscriptionNames: [entry.name], user: user, userInitiated: true, queue: nil) { reply.send(()) }
        let answered = reply.wait(30)
        try require(answered && retry(5, every: 1) { try absent(owner, entry, user: user) }, "Owner removal has not been verified")
        try journal.finish(index)
    }

    /// A request submitted earlier but never confirmed is checked read-only; it is never sent again while ambiguous.
    static func reconcile(_ journal: Journal, owner: UAFManager, user: String) throws {
        for index in journal.entries.indices {
            let entry = journal.entries[index]
            try require(entry.phase != .restoring, "An interrupted restore needs verification before cleanup can resume")
            guard entry.phase == .submitted else { continue }
            let gone: Bool
            switch entry.kind {
            case "uaf": gone = try absent(owner, entry, user: user)
            case "dds": gone = try languageDataOwners()[entry.name] == nil
            case "tts":
                let voices = try VoiceConnection()
                defer { voices.close() }
                gone = try voices.requests().allSatisfy { !equal(try value($0, "clientId"), entry.client) }
            default: gone = false
            }
            try require(gone, "An interrupted owner operation is still ambiguous; no request was repeated")
            try journal.finish(index)
        }
    }

    // MARK: Speech

    /// Siri's type-3 `assistant.<locale>` and Phone's type-7 `transcription.<language>` owners, through exact configs that must
    /// reproduce the captured owner. Shared speech models stay while Siri or Dictation is on.
    static func releaseSpeech(_ journal: Journal, owner: UAFManager, user: String, details: inout [String]) throws {
        let phone = journal.scope == .phone
        let client = phone ? "com.apple.TelephonyUtilities" : "com.apple.siri.embeddedspeech"
        if !phone, try !speechOff() { details.append("Siri or Dictation is active; shared speech models were kept."); return }
        let speech: AnyClass = try objcClass("SFSpeechAssetManager"), entitled: AnyClass = try objcClass("SFEntitledAssetManager")
        let configType: AnyClass = try objcClass("SFEntitledAssetConfig")
        try check(entitled, "subscriptionNameForConfig:", "@24@0:8@16", classMethod: true)
        try check(entitled, "assetSetUsageForConfig:", "@24@0:8@16", classMethod: true)
        try check(entitled, "_assetSetSubscriptionWithConfig:expiration:", "@32@0:8@16@24", classMethod: true)
        try check(configType, "initWithLanguage:assetType:", "@32@0:8@16Q24")
        try check(phone ? speech : entitled, phone ? "unsubscribeFromAssetsWithConfigs:clientIdentifier:completionHandler:"
                                                   : "unsubscribeFromAssetsWithConfigs:subscriberId:completionHandler:", "v40@0:8@16@24@?32", classMethod: true)
        let assets = messaging(entitled, as: EntitledAssets.self)
        let prefix = phone ? "transcription." : "assistant."
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        let all = try rows()
        var configs: [AnyObject] = [], indices: [Int] = []
        for row in all where row.client == client && row.user.caseInsensitiveCompare(user) == .orderedSame && row.name.hasPrefix(prefix) {
            let language = String(row.name.dropFirst(prefix.count))
            try require(!language.isEmpty && language.count < 40 && language.unicodeScalars.allSatisfy(allowed.contains), "Unreviewed speech language")
            let config = try makeConfig(configType, language: language, assetType: phone ? 7 : 3)
            try require(equal(assets.subscriptionName(for: config), row.name)
                        && equal(assets.assetSetUsage(for: config), ["asr.language": language] as NSDictionary), "Speech config does not match its owner")
            let original = try decode(row.archive)
            let expected = assets.subscription(with: config, expiration: try value(original, "expiration") as AnyObject?)
            try require(expected != nil && facts(expected).isEqual(try facts(original)), "Speech owner does not match the reviewed config shape")
            let current = try subscription(owner, client: client, name: row.name)
            try require(current != nil && facts(original).isEqual(try facts(current)), "Speech owner changed during preflight")
            indices.append(try journal.record("uaf", client: client, name: row.name, archive: row.archive, user: user, expiry: row.expiry))
            configs.append(config)
            // Siri's paired Hammer request goes with the same unsubscribe and is verified with it.
            if !phone, let hammer = try self.row(all, client: client, name: "hammer." + language, user: user) {
                indices.append(try journal.record("uaf", client: client, name: hammer.name, archive: hammer.archive, user: user, expiry: hammer.expiry))
            }
        }
        guard !configs.isEmpty else { return }
        for index in indices { try journal.submit(index) }
        let reply = Reply<AnyObject?>()
        if phone {
            messaging(speech, as: SpeechAssets.self).unsubscribe(configs: configs, clientIdentifier: client) { reply.send($0) }
        } else {
            assets.unsubscribe(configs: configs, subscriberId: client) { reply.send($0) }
        }
        let answered = reply.wait(30), errors = reply.value ?? nil
        try require(answered && (errors == nil || (errors as? NSDictionary)?.count == 0), "Speech owner did not confirm removal")
        for index in indices {
            try require(try retry(5, every: 1) { try absent(owner, journal.entries[index], user: user) }, "Speech owner is still present")
            try journal.finish(index)
        }
        details.append("Released \(configs.count) speech owner requests.")
    }
    /// Siri speech models left on disk with no owner at all: MobileAsset no longer tracks them, rates them `GCTypeNone` and keeps
    /// them for 15 days from their install (a quarter of that at the strongest purge), so no purge frees them on the click. Siri's
    /// Portuguese model stayed so, 475 MB, after Siri's language had changed (2026-10-19, issue 32). Each is adopted again for a
    /// moment with Siri's own embedded-speech owner for its language, read from the model's own `AssetSpecifier`: MobileAsset takes
    /// it back, holds it a moment and lets it go as unreferenced, which the purge that follows removes at once. Then the owner is
    /// withdrawn. Measured on 26B5112a: lock seen at about 30 s, gone by 50 s, no download, 683 MB purged in 0.14 s, still gone at
    /// five minutes. A language with any owner is left to the release above; nothing runs while Siri or Dictation is on.
    static func readoptLeftovers(owner: UAFManager, user: String, details: inout [String]) throws {
        guard try speechOff() else { return }
        let client = "com.apple.siri.embeddedspeech"
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        let all = try rows()
        let languages = try leftoverSpeechLanguages().filter { language in
            guard !language.isEmpty, language.count < 40, language.unicodeScalars.allSatisfy(allowed.contains) else { return false }
            return try row(all, client: client, name: "assistant." + language, user: user) == nil
                && row(all, client: client, name: "hammer." + language, user: user) == nil
        }
        guard !languages.isEmpty else { return }
        let entitled: AnyClass = try objcClass("SFEntitledAssetManager"), configType: AnyClass = try objcClass("SFEntitledAssetConfig")
        try check(entitled, "subscriptionNameForConfig:", "@24@0:8@16", classMethod: true)
        try check(entitled, "assetSetUsageForConfig:", "@24@0:8@16", classMethod: true)
        try check(entitled, "_assetSetSubscriptionWithConfig:expiration:", "@32@0:8@16@24", classMethod: true)
        try check(entitled, "unsubscribeFromAssetsWithConfigs:subscriberId:completionHandler:", "v40@0:8@16@24@?32", classMethod: true)
        try check(configType, "initWithLanguage:assetType:", "@32@0:8@16Q24")
        let assets = messaging(entitled, as: EntitledAssets.self)
        var configs: [AnyObject] = []
        var names: [String] = []
        for language in languages {
            let config = try makeConfig(configType, language: language, assetType: 3)
            let name = "assistant." + language
            try require(equal(assets.subscriptionName(for: config), name)
                        && equal(assets.assetSetUsage(for: config), ["asr.language": language] as NSDictionary), "Speech config does not match its model")
            guard let subscription = assets.subscription(with: config, expiration: nil) else { continue }
            let reply = Reply<Void>()
            owner.subscribe(client, subscriptions: [subscription], user: user, userInitiated: true, queue: nil) { reply.send(()) }
            try require(reply.wait(30), "Model adoption did not answer")
            configs.append(config)
            names.append(name)
        }
        guard !configs.isEmpty else { return }
        // Withdrawn whatever happens next: an adopted owner is never left behind.
        defer {
            let reply = Reply<AnyObject?>()
            assets.unsubscribe(configs: configs, subscriberId: client) { reply.send($0) }
            _ = reply.wait(30)
        }
        // MobileAsset takes the models back and lets them go: wait for its hold on them to come and go, at most a minute. A download
        // (a newer version in the catalog) ends the wait at once; the purge then finds nothing new to keep.
        let prefix = "AutoAssetLocker_Entry_com.apple.MobileAsset.UAF.Siri.Understanding_"
        var held = false
        _ = retry(60, every: 1) {
            let staged = (try? FileManager.default.contentsOfDirectory(atPath: SystemAssetGuard.stagingFolder)) ?? []
            if staged.contains(where: { $0.contains("Siri_Understanding") }) { return true }
            let locked = ((try? FileManager.default.contentsOfDirectory(atPath: ModelDescriptors.lockDirectory)) ?? []).contains { $0.hasPrefix(prefix) }
            if locked { held = true }
            return held && !locked
        }
        let gone = retry(5, every: 1) { (try? rows())?.contains { $0.client == client && names.contains($0.name) } == false }
        details.append(gone ? "Released \(names.count) Siri speech models that had no owner." : "Siri speech models were adopted; their release is being checked.")
    }

    /// The languages of Siri speech models on disk (`com.apple.siri.asr.assistant.<language>`), read from each model's Info.plist.
    static func leftoverSpeechLanguages(root: String = "/System/Library/AssetsV2", fileManager: FileManager = .default) -> [String] {
        let folder = (root as NSString).appendingPathComponent("com_apple_MobileAsset_UAF_Siri_Understanding/purpose_auto")
        let prefix = "com.apple.siri.asr.assistant."
        var languages: [String] = []
        for name in ((try? fileManager.contentsOfDirectory(atPath: folder)) ?? []).sorted() where name.hasSuffix(".asset") {
            let info = ((folder as NSString).appendingPathComponent(name) as NSString).appendingPathComponent("Info.plist")
            guard let plist = NSDictionary(contentsOfFile: info), let properties = plist["MobileAssetProperties"] as? NSDictionary,
                  let specifier = properties["AssetSpecifier"] as? String, specifier.hasPrefix(prefix) else { continue }
            let language = String(specifier.dropFirst(prefix.count))
            if !languages.contains(language) { languages.append(language) }
        }
        return languages
    }

    /// `[[SFEntitledAssetConfig alloc] initWithLanguage:assetType:]`, with Objective-C's ownership: init consumes the allocation.
    static func makeConfig(_ type: AnyClass, language: String, assetType: UInt) throws -> AnyObject {
        typealias Allocate = @convention(c) (AnyClass, Selector) -> Unmanaged<AnyObject>?
        typealias Initialize = @convention(c) (Unmanaged<AnyObject>, Selector, NSString, UInt) -> Unmanaged<AnyObject>?
        let allocate = NSSelectorFromString("alloc"), initialize = NSSelectorFromString("initWithLanguage:assetType:")
        guard let metaclass = object_getClass(type),
              let allocated = unsafeBitCast(class_getMethodImplementation(metaclass, allocate), to: Allocate.self)(type, allocate),
              let config = unsafeBitCast(class_getMethodImplementation(type, initialize), to: Initialize.self)(allocated, initialize,
                                                                                                                language as NSString, assetType) else {
            throw Refusal("Speech config does not match its owner")
        }
        return config.takeRetainedValue()
    }

    // MARK: Voices

    /// sirittsd's voice requests, through its own daemon protocol after its reviewed method encodings are checked.
    final class VoiceConnection {
        let connection: NSXPCConnection
        init() throws {
            try load("/System/Library/PrivateFrameworks/SiriTTSService.framework/SiriTTSService")
            guard let daemon = NSProtocolFromString("SiriTTSService.DaemonProtocol") else { throw Refusal("Missing voice owner protocol") }
            let encodings = ["subscribedVoicesWithClientId:reply:": "v32@0:8@16@?24", "subscribeWithVoices:clientId:accessoryId:reply:": "v48@0:8@16@24@32@?40",
                             "isSpeakingWithAccessoryId:reply:": "v32@0:8@16@?24"]
            for (name, encoding) in encodings {
                let description = protocol_getMethodDescription(daemon, NSSelectorFromString(name), true, true)
                try require(description.types.map { String(cString: $0) } == encoding, "Unreviewed voice owner protocol")
            }
            let interface = NSXPCInterface(with: daemon)
            let allowed = NSSet(array: classes()) as! Set<AnyHashable>
            interface.setClasses(allowed, for: NSSelectorFromString("subscribedVoicesWithClientId:reply:"), argumentIndex: 0, ofReply: true)
            interface.setClasses(allowed, for: NSSelectorFromString("subscribeWithVoices:clientId:accessoryId:reply:"), argumentIndex: 0, ofReply: false)
            connection = NSXPCConnection(machServiceName: "com.apple.sirittsd")
            connection.remoteObjectInterface = interface
            connection.resume()
        }
        func close() { connection.invalidate() }
        func daemon(_ failed: @escaping @Sendable () -> Void) -> VoiceDaemon {
            messaging(connection.remoteObjectProxyWithErrorHandler { _ in failed() } as AnyObject, as: VoiceDaemon.self)
        }
        func requests() throws -> [AnyObject] {
            let reply = Reply<AnyObject?>()
            daemon { reply.fail() }.subscribedVoices(clientId: nil) { reply.send($0) }
            guard reply.wait(20), let requests = reply.value as? NSArray else { throw Refusal("Cannot read voice owners") }
            return requests.map { $0 as AnyObject }
        }
        func speaking() -> Bool {
            let reply = Reply<Bool>()
            daemon { reply.fail() }.isSpeaking(accessoryId: nil) { reply.send($0) }
            return !reply.wait(10) || reply.value != false
        }
        func subscribe(_ voices: [AnyObject], client: String) -> Bool {
            let reply = Reply<NSError?>()
            daemon({ reply.send(NSError(domain: NSCocoaErrorDomain, code: NSXPCConnectionInterrupted)) })
                .subscribe(voices: voices, clientId: client, accessoryId: nil) { reply.send($0) }
            return reply.wait(30) && reply.value! == nil
        }
    }
    static func voiceViews(_ requests: [AnyObject], excluding client: String? = nil) throws -> NSArray {
        var views: [NSDictionary] = []
        for request in requests where try client == nil || !equal(value(request, "clientId"), client) {
            let voice = try value(request, "voice")
            var view: [String: Any] = [:]
            for (key, value) in [("client", try value(request, "clientId")), ("accessory", try value(request, "accessoryId")),
                                 ("language", try value(voice, "language")), ("name", try value(voice, "name")), ("version", try value(voice, "version"))] {
                view[key] = value ?? NSNull()
            }
            views.append(view as NSDictionary)
        }
        return views.sorted { $0.description < $1.description } as NSArray
    }
    /// The feature's own voice requests; other clients and accessory requests are kept. Returns the requests left active.
    static func releaseVoices(_ journal: Journal, details: inout [String]) throws -> [AnyObject] {
        let client = journal.scope == .phone ? "com.apple.TelephonyUtilities" : "com.apple.AssistantServices"
        let voices = try VoiceConnection()
        defer { voices.close() }
        if NSWorkspace.shared.isVoiceOverEnabled {
            details.append("VoiceOver is enabled; shared voice models were kept.")
            return try voices.requests()
        }
        try require(!voices.speaking(), "Speech is active or unreadable; voice models were kept")
        let before = try voices.requests()
        var targets: [AnyObject] = []
        for request in before where equal(try value(request, "clientId"), client) {
            try require(try value(request, "accessoryId") == nil, "Accessory voice request was kept")
            targets.append(request)
        }
        guard !targets.isEmpty else { return before }
        let data = try archive(targets as NSArray)
        try require(try voiceViews((try decode(data) as? NSArray).map { $0.map { $0 as AnyObject } } ?? []).isEqual(try voiceViews(targets)),
                    "Voice rollback roundtrip failed")
        let index = try journal.record("tts", client: client, name: "voices", archive: data)
        try journal.submit(index)
        try require(voices.subscribe([], client: client), "Voice owner did not confirm removal")
        let after = try voices.requests()
        try require(try voiceViews(before, excluding: client).isEqual(try voiceViews(after, excluding: client)), "Another voice owner changed; cleanup stopped")
        for request in after { try require(!equal(try value(request, "clientId"), client), "Voice owner is still present") }
        try journal.finish(index)
        details.append("Released the feature's voice requests.")
        return after
    }

    // MARK: Mapped Siri and voice owners

    /// Siri's language hold, whichever of macOS's Siri language aliases it uses: `legacy` on 26B5112a in the research, `assistantengine`
    /// once Siri asked again on the same build (2026-10-18), which the old fixed name left in place with 2.4 GB of Understanding models.
    /// An alias qualifies by what macOS itself defines it to request (`UsageAliases`), never by a list of names.
    static func allowedAlias(_ row: OwnerRow, _ object: Any) throws -> Bool {
        guard let aliases = try value(object, "usageAliases") as? NSDictionary, aliases.count == 1,
              let alias = aliases.allKeys.first as? String, let target = aliases[alias] as? String, !target.isEmpty else { return false }
        if ["com.apple.siri.assistant", "com.apple.siri.intelligenceengine"].contains(row.client), row.name == "language.hold" {
            guard isSiriLanguageAlias(alias) else { return false }
        } else if row.client == "com.apple.siri.nl", ["system.language", "system.language.hold"].contains(row.name) {
            guard alias == "com.apple.siri.nl.system.language" else { return false }
        } else { return false }
        return try value(object, "assetSets") == nil
    }

    static let usageAliasFolder = "/System/Library/UnifiedAssetFramework/UsageAliases"

    /// One of Siri's language aliases (`com.apple.siri.assistant.<kind>.language`) whose macOS definition requests Siri's
    /// understanding models for some language.
    static func isSiriLanguageAlias(_ alias: String, folder: String = usageAliasFolder) -> Bool {
        guard alias.hasPrefix("com.apple.siri.assistant."), alias.hasSuffix(".language"), !alias.contains("/"),
              let config = NSDictionary(contentsOfFile: (folder as NSString).appendingPathComponent(alias + ".plist")),
              config["UsageAliasName"] as? String == alias, let values = config["UsageAliasValues"] as? NSDictionary else { return false }
        return values.allValues.contains { ($0 as? NSDictionary)?["com.apple.siri.understanding"] != nil }
    }
    /// Only the premium voice/resource owners measured in Issue 16, never custom or personal voices, and none an active voice uses.
    static func allowedVoice(_ row: OwnerRow, _ object: Any, active: [AnyObject]) throws -> Bool {
        guard !NSWorkspace.shared.isVoiceOverEnabled,
              row.client == "siritts" || (row.client == row.name && row.name.hasPrefix("com.apple.siri.tts.")),
              let sets = try value(object, "assetSets") as? NSDictionary, sets.count == 1, try value(object, "usageAliases") == nil,
              let voice = sets["com.apple.siri.tts"] as? NSDictionary, let language = voice["tts.language"] as? String else { return false }
        let name = voice["tts.name"] as? String
        func normalized(_ value: String) -> String { value.replacingOccurrences(of: "-", with: "_") }
        for request in active {
            let activeVoice = try value(request, "voice")
            guard let activeLanguage = try value(activeVoice, "language") as? String else { return false }
            let activeName = try value(activeVoice, "name") as? String
            if normalized(activeLanguage).caseInsensitiveCompare(normalized(language)) == .orderedSame,
               name == nil || activeName == nil || activeName!.caseInsensitiveCompare(name!) == .orderedSame { return false }
        }
        return (row.name.hasPrefix("com.apple.siri.tts.voice.") && equal(voice["tts.quality"], "premium")
                && ["natural", "neural"].contains(voice["tts.technology"] as? String ?? "")) || row.name.hasPrefix("com.apple.siri.tts.resource.")
    }
    static func releaseMappedOwners(_ journal: Journal, owner: UAFManager, user: String, activeVoices: [AnyObject], details: inout [String]) throws {
        let siri = try journal.scope == .siri && speechOff()
        var count = 0
        for row in try rows() where row.user.caseInsensitiveCompare(user) == .orderedSame {
            let aliasCandidate = siri && ["com.apple.siri.assistant", "com.apple.siri.intelligenceengine", "com.apple.siri.nl"].contains(row.client)
            let voiceCandidate = row.client == "siritts" || (row.client == row.name && row.client.hasPrefix("com.apple.siri.tts."))
            guard aliasCandidate || voiceCandidate else { continue }
            let object = try decode(row.archive)
            guard try (aliasCandidate && allowedAlias(row, object)) || (voiceCandidate && allowedVoice(row, object, active: activeVoices)) else { continue }
            let current = try subscription(owner, client: row.client, name: row.name)
            try require(current != nil && facts(object).isEqual(try facts(current)), "Owner changed during preflight")
            try require(facts(object).isEqual(try facts(decode(archive(object)))), "Owner rollback roundtrip failed")
            let index = try journal.record("uaf", client: row.client, name: row.name, archive: row.archive, user: user, expiry: row.expiry)
            try withdraw(journal, index, owner: owner, user: user)
            count += 1
        }
        details.append("Released \(count) mapped asset owners.")
    }

    // MARK: Language data

    static let languageDataType = "com.apple.MobileAsset.LinguisticData"
    /// The current account's DataDeliveryServices requests by assertion identifier: query, policy and client.
    static func languageDataOwners() throws -> [String: NSDictionary] {
        let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/DataDeliveryServices/ddsassertiondata.plist")
        guard FileManager.default.fileExists(atPath: path.path) else { return [:] }
        let data = try attempt("Unknown DDS archive root") { try Data(contentsOf: path) }
        guard let assertions = try decode(data) as? NSArray else { throw Refusal("Unknown DDS archive root") }
        var result: [String: NSDictionary] = [:]
        for assertion in assertions {
            for descriptor in (try value(assertion, "descriptors") as? NSArray) ?? [] {
                guard let identifier = try value(descriptor, "assertionIdentifier") as? String, !identifier.isEmpty,
                      let client = try value(descriptor, "clientIdentifier") as? String, result[identifier] == nil,
                      let query = try value(assertion, "query"), let policy = try value(descriptor, "policy") else {
                    throw Refusal("Unknown or duplicate DDS identity")
                }
                result[identifier] = ["query": query, "policy": policy, "client": client]
            }
        }
        return result
    }
    static func sameLanguageData(_ lhs: NSDictionary?, _ rhs: NSDictionary?) throws -> Bool {
        guard let lhs, let rhs, equal(lhs["client"], rhs["client"]), let query = lhs["query"] as? NSObject, let other = rhs["query"] else { return false }
        try check(Swift.type(of: query), "isEqualToAssetQuery:", "B24@0:8@16")
        typealias Compare = @convention(c) (AnyObject, Selector, AnyObject) -> Bool
        let selector = NSSelectorFromString("isEqualToAssetQuery:")
        guard unsafeBitCast(class_getMethodImplementation(Swift.type(of: query), selector), to: Compare.self)(query, selector, other as AnyObject) else { return false }
        for key in ["preferredDownloadFrequency", "downloadOverCellular", "downloadWithoutPower", "idleUsageEvictionPeriod",
                    "notificationDownloadTriggers", "downloadCompletionNotification"] where !equal(try value(lhs["policy"], key), try value(rhs["policy"], key)) {
            return false
        }
        return true
    }
    static func languageDataCenter() throws -> LanguageDataCenter {
        let type: AnyClass = try objcClass("DDSAssetCenter")
        try check(type, "sharedInstance", "@16@0:8", classMethod: true)
        try check(type, "removeAssertionWithIdentifier:assetType:", "v32@0:8@16@24")
        try check(type, "addAssertionsForAssetsWithQueries:policies:assertionIDs:clientID:", "v48@0:8@16@24@32@40")
        return messaging(messaging(type, as: SharedInstance.self).sharedInstance(), as: LanguageDataCenter.self)
    }
    /// System Data's one-shot release: only the three researched LinguisticData clients; every other request must stay identical.
    /// Spelling and dictionary preferences are untouched, so those requesters may return.
    static func releaseLanguageData(_ journal: Journal, details: inout [String]) throws {
        let baseline = try languageDataOwners()
        let clients = ["com.apple.DataDeliveryServices.AssetService", "com.apple.DictionaryServices", "com.apple.ProofReader.LinguisticData"]
        var removed: Set<String> = []
        for (identifier, item) in baseline {
            guard equal(try value(item["query"], "assetType"), languageDataType), clients.contains(item["client"] as? String ?? "") else { continue }
            let data = try archive(item)
            try require(try sameLanguageData(try decode(data) as? NSDictionary, item), "DDS rollback roundtrip failed")
            try require(try sameLanguageData(try languageDataOwners()[identifier], item), "Language-data owner changed before removal")
            let index = try journal.record("dds", client: item["client"] as! String, name: identifier, archive: data)
            try journal.submit(index)
            try languageDataCenter().removeAssertion(identifier: identifier, assetType: languageDataType)
            try require(try retry(20, every: 0.25) { try languageDataOwners()[identifier] == nil }, "DDS owner is still present")
            try journal.finish(index)
            removed.insert(identifier)
            let after = try languageDataOwners()
            let expected = Set(baseline.keys).subtracting(removed)
            try require(expected == Set(after.keys), "Another language-data owner changed; cleanup stopped")
            for key in expected { try require(try sameLanguageData(baseline[key], after[key]), "Another language-data request changed; cleanup stopped") }
        }
        details.append("Released \(removed.count) unused language-data requests. macOS may request them again.")
    }

    // MARK: Restore

    /// Explicit enablement or uninstall: restores only MacSpace's saved owners. An owner changed elsewhere is kept, never overwritten.
    static func restore(_ journal: Journal, owner: UAFManager, user: String, details: inout [String]) throws {
        for index in journal.entries.indices where journal.entries[index].phase != .restored {
            let entry = journal.entries[index]
            switch entry.kind {
            case "uaf":
                try require(entry.user?.caseInsensitiveCompare(user) == .orderedSame, "Rollback belongs to another account")
                let original = try decode(entry.archive)
                if let current = try subscription(owner, client: entry.client, name: entry.name) {
                    try require(facts(original).isEqual(try facts(current)), "An asset owner changed outside MacSpace; it was kept")
                } else {
                    try require(try row(rows(), client: entry.client, name: entry.name, user: user) == nil, "Owner API and database disagree; restore stopped")
                    let expiry = try value(original, "expiration") as? Date
                    if expiry.map({ $0.timeIntervalSinceNow > 0 }) ?? true {
                        try require(entry.phase != .restoring, "An interrupted owner restore is still ambiguous")
                        try journal.set(index, .restoring)
                        let reply = Reply<Void>()
                        owner.subscribe(entry.client, subscriptions: [original as AnyObject], user: user, userInitiated: true, queue: nil) { reply.send(()) }
                        try require(reply.wait(30), "Owner restore did not answer")
                        let restored = try subscription(owner, client: entry.client, name: entry.name)
                        try require(restored != nil && facts(original).isEqual(try facts(restored)), "Owner restore could not be verified")
                    }
                }
            case "tts":
                let voices = try VoiceConnection()
                defer { voices.close() }
                let saved = ((try decode(entry.archive) as? NSArray) ?? []).map { $0 as AnyObject }
                let before = try voices.requests()
                let current = try before.filter { equal(try value($0, "clientId"), entry.client) }
                if !current.isEmpty {
                    try require(try voiceViews(current).isEqual(try voiceViews(saved)), "Voice settings changed outside MacSpace; they were kept")
                } else {
                    var restoring: [AnyObject] = []
                    for request in saved {
                        try require(equal(try value(request, "clientId"), entry.client) && value(request, "accessoryId") == nil, "Invalid saved voice owner")
                        guard let voice = try value(request, "voice") else { throw Refusal("Invalid saved voice owner") }
                        restoring.append(voice as AnyObject)
                    }
                    try require(entry.phase != .restoring, "An interrupted voice restore is still ambiguous")
                    try journal.set(index, .restoring)
                    try require(voices.subscribe(restoring, client: entry.client), "Voice restore did not answer")
                    let after = try voices.requests()
                    let target = try after.filter { equal(try value($0, "clientId"), entry.client) }
                    try require(try voiceViews(target).isEqual(try voiceViews(saved))
                                && voiceViews(before, excluding: entry.client).isEqual(try voiceViews(after, excluding: entry.client)),
                                "Voice restore could not be verified")
                }
            case "dds":
                let saved = try decode(entry.archive) as? NSDictionary
                if let current = try languageDataOwners()[entry.name] {
                    try require(try sameLanguageData(current, saved), "Language-data settings changed outside MacSpace")
                } else {
                    guard let saved, let query = saved["query"], let policy = saved["policy"] else { throw Refusal("Language-data restore could not be verified") }
                    try require(entry.phase != .restoring, "An interrupted language-data restore is still ambiguous")
                    try journal.set(index, .restoring)
                    try languageDataCenter().addAssertions(queries: [query as AnyObject], policies: [policy as AnyObject],
                                                           assertionIDs: [entry.name], clientID: entry.client)
                    try require(try retry(20, every: 0.25) { try languageDataOwners()[entry.name] != nil }
                                && sameLanguageData(try languageDataOwners()[entry.name], saved), "Language-data restore could not be verified")
                }
            default: throw Refusal("Unknown rollback operation")
            }
            try journal.set(index, .restored)
        }
        details.append("Saved model requests restored. macOS may download their models again.")
    }
}

// The private methods, by their reviewed selectors. Each is checked against its installed type encoding before it is sent.
@objc protocol SharedManager { @objc(sharedManager) func sharedManager() -> AnyObject }
@objc protocol SharedInstance { @objc(sharedInstance) func sharedInstance() -> AnyObject }
@objc protocol SharedPreferences { @objc(sharedPreferences) func sharedPreferences() -> AnyObject }
@objc protocol UAFManager {
    @objc(subscriptionsForSubscriber:) func subscriptions(forSubscriber subscriber: String) -> AnyObject?
    @objc(unsubscribe:subscriptionNames:user:userInitiated:queue:completion:)
    func unsubscribe(_ subscriber: String, subscriptionNames: [String], user: String, userInitiated: Bool, queue: DispatchQueue?,
                     completion: @escaping () -> Void)
    @objc(subscribe:subscriptions:user:userInitiated:queue:completion:)
    func subscribe(_ subscriber: String, subscriptions: [AnyObject], user: String, userInitiated: Bool, queue: DispatchQueue?,
                   completion: @escaping () -> Void)
}
@objc protocol EntitledAssets {
    @objc(subscriptionNameForConfig:) func subscriptionName(for config: AnyObject) -> AnyObject?
    @objc(assetSetUsageForConfig:) func assetSetUsage(for config: AnyObject) -> AnyObject?
    @objc(_assetSetSubscriptionWithConfig:expiration:) func subscription(with config: AnyObject, expiration: AnyObject?) -> AnyObject?
    @objc(unsubscribeFromAssetsWithConfigs:subscriberId:completionHandler:)
    func unsubscribe(configs: [AnyObject], subscriberId: String, completionHandler: @escaping (AnyObject?) -> Void)
}
@objc protocol SpeechAssets {
    @objc(unsubscribeFromAssetsWithConfigs:clientIdentifier:completionHandler:)
    func unsubscribe(configs: [AnyObject], clientIdentifier: String, completionHandler: @escaping (AnyObject?) -> Void)
}
@objc protocol VoiceDaemon {
    @objc(subscribedVoicesWithClientId:reply:) func subscribedVoices(clientId: String?, reply: @escaping (AnyObject?) -> Void)
    @objc(subscribeWithVoices:clientId:accessoryId:reply:)
    func subscribe(voices: [AnyObject], clientId: String, accessoryId: String?, reply: @escaping (NSError?) -> Void)
    @objc(isSpeakingWithAccessoryId:reply:) func isSpeaking(accessoryId: String?, reply: @escaping (Bool) -> Void)
}
@objc protocol LanguageDataCenter {
    @objc(removeAssertionWithIdentifier:assetType:) func removeAssertion(identifier: String, assetType: String)
    @objc(addAssertionsForAssetsWithQueries:policies:assertionIDs:clientID:)
    func addAssertions(queries: [AnyObject], policies: [AnyObject], assertionIDs: [String], clientID: String)
}
