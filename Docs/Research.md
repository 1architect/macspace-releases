# Research notes

What was measured about macOS while building MacSpace, and how sure we are. Every claim carries one of three labels:

- **Measured** – observed on a real Mac or VM, with numbers.
- **Inferred** – follows from measurements but was not tested directly.
- **Unverified** – a working assumption; treat it as a question.

Where, and on what: macOS 27 build 26B5091g (Apple Silicon, SIP on) for almost everything; macOS 27.0.1 (26A434) in a virtual machine
for the helper installation and Apple Intelligence checks. Other builds may differ. Private Apple interfaces are used in a few places
and every one of them is guarded (see [CacheDelete](#cachedelete)).

## 1. What "System Data" is

**Measured.** System Settings does not measure System Data. It computes it as what is left of the used space after its named
categories. On one Mac: used 109.55 GB − macOS 31.08 − Applications 28.48 − Documents 6.7 − Developer 1.42 − Photos, Mail, Messages,
Music (0.9) = 41 GB. Consequences:

- Anything the other categories claim is not System Data, whatever folder it is in.
- The figure moves when files are re-classified, not only when space is freed (see the lag below).
- APFS clones count once (physical accounting): deleting a 6 GB code-signing clone changed nothing.

How MacSpace maps what it can measure onto Settings' categories (all **measured**, one Mac):

| Item | Settings counts it under |
|---|---|
| Cloud copies (`~/Library/CloudStorage`) | Documents |
| Downloads, unfinished downloads, restore images (`.ipsw`), virtual machines | Documents (after indexing) |
| Third-party apps' containers and group containers | Applications (about 9.4 GB here) |
| Apple's own containers | System Data |
| Command Line Tools | Developer (1.42 GB there vs 1.31–1.41 GB measured) |
| Swap and sleep files | macOS (VM volume) |
| Homebrew, unified log, system assets, version history, Spotlight index, symbolication cache, staged update | System Data |

**The classification lag (measured).** A new 25 GB restore image first appeared in System Data (+19.12 GB there, used +19.75 GB) and
minutes later moved to Documents (+21.91 GB there, −21.91 GB in System Data, used unchanged). New large files in user folders sit in
System Data until Spotlight has indexed them. A reading taken straight after a download is therefore not final. The file took about
21.9 GB in Settings against 25 GB by size; the reason (compression or shared blocks) is **unverified**.

With the rules above the app's total came within about 0.9 GB of Settings (42.83 vs 41.95 GB). **Inferred:** the remainder is small
items and rounding; no single missing source was found. The mapping was calibrated on one Mac and may be off on another.

## 2. What can actually be reclaimed

### System assets (`/System/Library/AssetsV2`)

**Measured.** 7.1 GB on one Mac, almost all of it subscribed, so the purge frees nothing until the subscription goes. Subscriptions
live in `/private/var/db/assetsubscriptiond/UAFAssetSubscriptions.db` (readable; opened read-only with `immutable=1`).

| Family | Size | Held by |
|---|---|---|
| Siri speech models (en_US, pt_BR) | 2.19 GB | Siri speech service, speech recognition broker, phone call features |
| Apple developer documentation | 1.65 GB | Downloaded for Xcode; no subscription |
| Language data (spelling, text analysis) | 1.1 GB | One ProofReader subscription per language |
| Spatial Photos "Relive" | 0.81 GB | macOS model catalog |
| Portuguese speech transcription | 0.34 GB | Siri speech service, phone call features |
| Siri voices | 0.52 GB | Siri text-to-speech |

- **Measured – the Spelling setting does not control language data.** `NSLinguisticDataAssetsRequested` lists exactly the
  languages that have a subscription, but the system builds and refreshes that list itself (every 86 400 s). Removing one language by
  hand, and later dropping unused languages in the Settings UI, left every subscription and the purge unchanged.
- **Unverified:** the settings named for Siri voices, dictation, dictionaries and developer documentation. They appear in the app as
  "Setting" with a note that menu names can differ.
- Editing the subscription database for a live account is **not done**: the daemon re-adds rows and the file is Apple's.
  MacSpace edits it only to remove rows of accounts that no longer exist (backup first).

### CacheDelete

**Measured.** `CacheDelete` is macOS's own purge, the one that runs when the disk is nearly full. MacSpace calls it for one service,
`com.apple.mobileassetd.cache-delete`, to remove unlocked assets now (12.04 GB in 4.6 s once, as a normal user).

- The functions are private. Their signature came from disassembly of one build, and a wrong signature crashes the caller. So the
  call runs in a throwaway child process, and each macOS build is self-tested once (query answers, service filter honoured, purge
  against a nonexistent volume answers) before it is trusted. Builds checked by hand are listed in `CacheDelete.swift`.
- **Measured – a bug worth remembering.** The purge callback must be an escaping block. A trailing closure traps with "non-escaping
  closure has escaped" for services that answer after the call returns.
- **Measured – container caches are not worth offering.** The service `com.apple.cache_delete_app_container_caches` reports
  1.15 GB purgeable and keeps reporting it. Purging freed 2.1 MB at urgency 1, 2.1 MB at 2, 95.7 MB at 3 and nothing at 4 (volume free
  space measured each time). It is not in the app.
- **Measured – what "purgeable" on the disk tile is (2026-10-02, development Mac).** The tile shows available-for-important-use
  minus free: 7.03 GB. Asked per service, CacheDelete reports about 1.5 GB at urgency 1-2 and 7.02 GB at urgency 3, so the tile's number
  is the urgency-3 total: `fspurgeable_data` 4.89 GB, app container caches 1.15 GB, `fspurgeable_document` 633 MB, Quick Look
  thumbnails 330 MB, Spotlight 13 MB, MobileAsset 4.4 MB. At urgency 4 MobileAsset reports 12.41 GB, assets still in use; not a
  candidate. No local Time Machine snapshots. The query's whole answer agrees: `CACHE_DELETE_TOTAL_AVAILABLE` 7 025 163 817 bytes,
  of which `CACHE_DELETE_TOTAL_FSPURGEABLE` 5 522 636 800 (`fspurgeable_data` plus `fspurgeable_document`). Both fspurgeable services
  belong to `deleted_helper`; the answer names no files or apps.
- **Measured – purging at urgency 3 (2026-10-02, development Mac, as a normal user, from the CLI with `--experiment`).**
  `fspurgeable_data` reported 4.66 GB removed and the Data volume's free space rose by 4.66 GB (97.55 → 102.21 GB). Quick Look
  thumbnails reported 330 MB purgeable but removed nothing. Which apps' files went is not known, nor how fast they come back.
  `fspurgeable_document` not tried.

### Document version history (`/System/Volumes/Data/.DocumentRevisions-V100`)

**Measured.** 6.35 GB by `du`; deleting it freed about 5 GB on the volume (System Data fell about 5.05 GB). The folder is root-only
and has no SIP flag. `launchctl bootout system/com.apple.revisiond` is refused. What works: freeze the running `revisiond`
(`kill -STOP`), delete the folder's contents (not the folder), then kill it so launchd restarts a fresh one that builds an empty
store. The documents themselves are untouched; the earlier versions of every document are gone for good.

### Leftover macOS update files (`/System/Volumes/Data/macOS Install Data`)

**Measured.** 1.27 GB dated 15 August on a system installed in September, with `softwareupdate --list` reporting nothing new: files of
an update that had long finished. `UpdateBundle` is root-owned with no SIP flag, so the helper deletes it; the `Locked Files`
subfolder carries the SIP `restricted` flag and stays. The helper only deletes when the folder is older than the installed system's
`SystemVersion.plist`. Deletion worked on the development Mac (confirmed by the maintainer; the freed amount was not recorded).
Telling the user to "install the waiting update" for such files was wrong, and the row now says that no update is waiting.

### Other

- **Homebrew (2.9 GB):** most of it is the installed packages. `brew cleanup` removes only old versions and downloads. **Inferred.**
- **Unified log, swap, power log, symbolication cache:** in use or rotated by macOS; not worth touching. **Inferred.**

## 3. Apple Intelligence

**Measured on 26B5091g** (details in the maintainers' private notes):

- The on-device models stay installed and locked until the account's Apple Intelligence goes from available to unavailable. Switching
  between two ineligible Siri languages does not release them.
- Setting the Siri language to the system language makes ModelCatalog take the models (nothing is downloaded); setting it back makes
  mobileassetd drop its locks within seconds. They are then deleted only under disk pressure, which the CacheDelete purge does now.
  The original Siri language and voice are restored on every path.
- Models are shared by all accounts, so one eligible account, or a deleted account that still holds subscriptions, keeps them.
- **Measured – virtual machines.** `kern.hv_vmm_present` is 1 and Apple Intelligence never becomes available, so the release flow
  waits and fails. MacSpace shows a single explanation there and offers no controls.
- **Unverified:** whether the Siri language preference syncs through iCloud.

## 4. The privileged helper

The helper is a launch daemon registered with `SMAppService.daemon`, reached over XPC, running only named operations. Behaviour we
had to learn (all **measured** on a Mac and a VM):

1. **Status "not found" (3).** Seen when the app ran from a build folder, and on a VM when the app was copied in by hand. The
   registration then fails with `SMAppServiceErrorDomain Code=1 "Operation not permitted"`.
   - Running `lsregister -f` on the app moved the status to **requires approval (2)**. MacSpace now registers itself with Launch
     Services before registering the helper.
   - A quarantined (downloaded, not notarized) app runs from an App Translocation copy and cannot register the helper.
     `xattr -dr com.apple.quarantine` is the workaround; a notarized release avoids it (**inferred**, not yet tested).
2. **Requires approval (2)** is normal after registering. The register call reports an error while it waits; that is not a failure.
   The user allows MacSpace in System Settings → General → Login Items & Extensions.
3. **Replacing the app leaves the helper stale.** The old process keeps running and does not know new operations, or the job is
   left unloaded so nothing answers. MacSpace asks the helper which binary it started from (modification time and size) and compares
   it with the one in the app; if they differ or nothing answers, it unregisters and registers again.
4. **A dead connection stays dead.** An `NSXPCConnection` that failed once never recovers. The app drops a failed connection and
   retries once on a new one.
5. **Stable signature keeps Full Disk Access.** macOS ties the permission to the code requirement. Local builds are signed with the
   Developer ID identity so the requirement (identifier plus team) is the same on every build; ad-hoc builds change every time and
   lose the grant.
6. The helper itself can read the root-only locations System Data needs (Spotlight index, version history, symbolication cache).
   **Measured** on the development Mac with Full Disk Access granted to the app.

## 5. Debloat

Fourteen controls ship, each either verified on 26B5091g or enforced by a configuration profile: five direct settings (the Siri AI, Visual Intelligence and generative-indexing feature flags, the tailspin trace buffer, the crash report dialog) and nine profile-enforced policies
(diagnostics, ads, advertising identifier, Siri server logging, on-device dictation, Spotlight internet results, Apple
Intelligence features, Game Center, News). **Measured and left out:** nine launchd controls (SIP resets them at boot), and ten whose effect could
not be confirmed. Profile controls need the user to approve the MacSpace configuration profile in System Settings.

## 6. Open questions

- Does a notarized, stapled build register the helper without any manual step? (Not tested; no notarized build exists yet.)
- Does a Sparkle update leave the helper reachable? The self-repair covers it in theory; it has not been exercised.
- Why does Settings count the 25 GB restore image as 21.9 GB?
- Which Settings are behind Siri voices, dictation, dictionaries and the developer documentation asset?
- Do the category mappings in section 1 hold on a Mac with different apps?
- Is the document-version freeze safe while an app is saving? The confirmation tells the user to save and close documents first.
