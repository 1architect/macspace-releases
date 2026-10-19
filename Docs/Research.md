# Research

What was learned about macOS while building MacSpace, and how sure we are. This is the consolidated version: it replaces the
dated notes this file used to be, and folds in the findings of the research that came before the app
([section 7](#7-the-original-research) tells that story). Where a later measurement overturned an earlier reading, the
later one is here and the earlier one is listed under [Superseded readings](#superseded-readings).

Every claim carries one of three labels:

- **Measured**: observed on a real Mac or VM, with numbers.
- **Inferred**: follows from measurements but was not tested directly.
- **Unverified**: a working assumption; treat it as a question.

**Where, and on what.** One Apple Silicon Mac, not enrolled in MDM, System Integrity Protection (SIP) on unless stated. macOS 27.2,
build 26B5086k at first and 26B5091g from 23 September 2026 on, for almost everything. macOS 27.0.1 (26A434) in a virtual machine
for the helper installation and the Apple Intelligence checks. Other builds, and Macs with other apps, may differ. Private Apple
interfaces are used in a few places and every one of them is guarded (see [CacheDelete](#cachedelete)). Sizes are decimal
gigabytes, as System Settings shows them.

## What we know, in short

1. **System Data is a remainder, not a folder.** System Settings computes it as used space minus macOS minus every other category.
   Whatever no category claims is System Data. MacSpace computes it the same way ([section 1](#1-what-system-data-is)).
2. **Settings' categories are decoded** from the code of its Storage pane and service, and MacSpace's reading of them lands within
   0.1 to 0.2 GB of Settings on most categories; the rest of the gap is stated on the page.
3. **Most of what fills System Data cannot be reclaimed safely**: logs, indexes, caches macOS rebuilds, Apple's own containers,
   system assets other services subscribe to. What can be: version history, leftover update files, Chromium and Electron caches,
   unsubscribed system assets, and files apps marked purgeable ([section 2](#2-what-can-be-reclaimed)).
4. **Purgeable space comes in several kinds** and only one is worth offering as a purge. CacheDelete's own estimate lags what it
   removes, and one service (cloud downloads) is better handled per folder.
5. **Apple Intelligence's models stay after the feature is off**, held by locks that drop only when the account goes from
   available to unavailable, and by subscriptions of deleted accounts. Both are handled, and the release frees about 12 GB
   ([section 3](#3-apple-intelligence)).
6. **Deleting the models is not prevention.** What works for the Apple Intelligence models is the owner's own path: a Siri language
   that differs from the system language. Everything cleverer failed ([section 7](#7-the-original-research)).
   The same holds for the Siri, speech, language-data and Phone models: they can be released now by withdrawing each owner's
   request, and macOS can recreate the requests later, so cleaning is repeatable, not permanent
   ([Asset owners](#asset-owners-and-why-clean-now-is-not-prevent-forever)).
7. **The helper is the fragile part**: registration, approval and a stale process after an update. The failure modes are known and
   covered ([section 4](#4-the-privileged-helper)).
8. **With SIP on, only four kinds of debloat control hold**: plain preferences, configuration profiles, feature-flag overrides and
   two diagnostics tools. `launchctl disable` of Apple services does not survive a boot ([section 5](#5-debloat)).
9. **Some controls are undone by macOS itself** (the advertising identifier is reconciled back about daily), which is why Debloat
   watches and re-applies.
10. **Not yet verified before release**: a clean Mac with a notarized build, a Sparkle update through the helper, and several
    Apple Intelligence and cloud-download paths ([section 6](#6-open-questions)).

---

## 1. What System Data is

### It is a remainder

**Measured, from the code.** Read from `StorageManagementService` (`StorageManagement.framework/PlugIns`, the per-user agent
`com.apple.StorageManagement.Service`) and the Storage pane (`/System/Library/ExtensionKit/Extensions/Storage.appex`), disassembled
with selector stubs and CFStrings resolved (macOS 27.2, 26B5091g). Nothing here can be asked from outside: the service answers
only clients with `com.apple.storage-data`, and the pane's size messages are debug level, never in the log. The category rules in
`/System/Library/SpaceAttribution/*.plist` (read by `spaceattributiond`, which assigns paths to owner apps and daemons) are the
older, coarser view of the same idea; an app cannot ask it either (`SAAppSizer` answers `NSCocoaErrorDomain 4099`).

- **System Data** is `other = volume used − macOS − Σ every category item` (`-[STMStorageController updateSystemSidebarItemSubtitle]`,
  then `updateSystemSize:otherSize:`).
- **Used** for the Data volume is `in use − CacheDelete purgeable + system + hidden` (`-[SPInfoDiskAPFSVolume updateFreeSpace]`; the
  purgeable figure is CacheDelete's volume dictionary, `CACHE_DELETE_AMOUNT` and the shared-purgeable keys). The pane logs the same
  thing as `available = freespace + purgeableSpace`, what `volumeAvailableCapacityForImportantUsage` returns. With plain free
  space the disk tile said 230.9 GB used against Settings' 203.28; with that key, 203.24.
  Purgeable files leave "used" only as far as CacheDelete's figure goes, not by their APFS flag: of 21 GB of cloud downloads flagged
  purgeable, about 14 GB still counted as used.
- **macOS** is every volume of the startup container but Data (System, Preboot with the prepared update, Recovery, Update, VM)
  **plus the separate Recovery container on the same disk** (partition type `Apple_APFS_Recovery`), **plus about 3.9 GB of the Data
  volume**. Measured twice, 1.5 hours apart: 47.45 GB both times, volumes 44.8266 + 2.6191 = 47.4458 GB. Ruled out: CacheDelete's
  software update reserve (disabled, 0) and `/private/var/.overprovisioning_file` (absent). Which 3.9 GB of the Data volume
  belong to macOS is **unverified**; the system assets (`AssetsV2`, 9.0 GB, of which 1.39 for macOS software update) and the
  unified log (2.51 GB) are the likeliest. The Apple Intelligence models shown in macOS's detail are not added to it (adding them
  would read 48.16).
- **Documents** is the home folder sized without `~/Library`, `~/Applications`, the system Photos library, `~/Music/iTunes/iTunes
  Media/`, `~/Music/Music/Media/`, `~/Movies/Apple TV/Media/`, `~/Movies/TV/Media/`, `~/Movies/TV/TV Library/`, and every path a
  category extension claims; `~/Desktop` and `~/Documents` only when iCloud Desktop & Documents is on
  (`+[SPInfoDocumentsStorageUsageReporter defaultExcludedURLs]`, `operationDidFinish:`). So **anything in `~/Library` that no
  category claims is System Data**, including `~/Library/CloudStorage`, and the home folder's hidden tool folders (`.claude`,
  `.config`) are Documents. Settings' own figure is also stored in `com.apple.StorageManagement.Service` as `SPLastDocumentsSize`.
- **Documents also skips application bundles independently of Spotlight.** Rechecked on 2026-10-17: the callback in
  `SPInfoSizeDirectoryOperation` skips a path ending in `.app` when `NSURLIsApplicationKey` is true, whether indexed or not.
  MacSpace's Documents sizer now applies this same check; the original difference and post-fix comparison are measured below.
- **Applications** is app bundles, third-party
  containers and third-party group containers, Safari's container, and Apple's team-prefixed group containers
  (`PTN9T2S29T.com.apple.videoProApps`); only `group.com.apple.…` stays with macOS. Apps' support folders in
  `~/Library/Application Support` are **not** counted (Firefox: 536 MB in Settings' list is its bundle; its 2.31 GB profile is not
  in it).
  **Scope correction (2026-10-17):** `STMApplicationSizer` sets its Spotlight search scopes to the user's home directory,
  `/Applications/`, and `/System/Applications`, then filters user-Library apps, nested apps and several built-in identifiers.
  MacSpace retains the global `IndexedApps.paths()` lookup but filters its results for this category. The older claim that every indexed app anywhere belongs to this
  category was an inference, not a measured rule; system-wide helpers outside those scopes must not be added on that basis.
- **Mail** is `~/Library/Mail`; **Messages** is `~/Library/Messages/Attachments` only; **Music** is the library's media folder;
  **Other Users** is `/Users/Shared`; **Developer** is the Command Line Tools; **Photos** is the system library.

### Checked against Settings

**Measured side by side** (2026-10-06, MacSpace's `SettingsStorage` against Settings), GB unless marked:

| Category | MacSpace | Settings |
|---|---|---|
| Developer | 1.42 | 1.42 |
| Mail | 541 MB | 541 MB |
| Messages | 25.1 MB | 25 MB |
| Music | 58.8 MB | 58.6 MB |
| Other Users | 1.5 MB | 1.4 MB |
| Photos | 258 MB | 253.2 MB |
| Documents | 10.18 | 10.09 |
| Used | 191.59 | 191.46 |
| Applications | 0.92 short, before counting all of `/Applications` and Apple's prefixed group containers | 97.87 |
| macOS | 2.26 short, before counting the Recovery container | 47.45 |

After the OneDrive downloads were removed (2026-10-06, 18:00): used 188.68 = Applications 97.87 + Developer 1.42 + Documents 8.77 +
Photos, Mail, Messages, Music 0.88 + Other Users 0.0014 + macOS 47.45 + System Data 32.3. MacSpace's own sum, with the prepared
update left out, was 38.5 GB against 32.3, and the whole gap is accounted for as follows.

- **Measured: apps elsewhere; classification inference superseded on 2026-10-17.** Spotlight indexes 2.16 GB of app bundles outside `/Applications` (Autodesk installers' helper
  apps, Claude Code's own `claude.app`, the .NET runtimes in `/usr/local/share/dotnet`, development builds). **Inferred:** Settings
  lists every app Spotlight has indexed under Applications, wherever it is; about 2.0 GB of them sat in folders MacSpace counted as
  System Data and are now taken off them (`SystemDataItem.appBundleBytes`).
- **Measured: the prepared macOS update is macOS, not System Data.** The 10.70 GB update (`<volume group>/cryptex1/proposed` on
  Preboot, counting each clone family once with `ATTR_CMNEXT_CLONEID`; its images come in clone pairs, `os.dmg` and
  `os.clone.dmg`, and `du` reports double) is part of Settings' macOS. MacSpace had counted it as System Data. It is now left out
  of the total and listed in Other System Files ("Waiting to install").
- **Measured: APFS clones count once.** Counted per file, System Data's items added up to 1.2 GB more than Settings' remainder:
  `~/Library/Application Support` is 5.62 GB per file, 5.15 GB with each clone family once, 4.84 GB of blocks no other file shares;
  the system assets 9.02 / 8.91 / 8.36 GB. Items are now sized with one `CloneLedger` per scan (the first file of a family counts
  in full, later ones only `ATTR_CMNEXT_PRIVATESIZE`): 35.79 → 35.27 GB against a total of 34.65. The 0.62 GB left is stated on
  the page; not yet explained. Deleting a 6.12 GB code-signing clone of an app (`/var/folders/…/X/…code_sign_clone`) freed nothing
  measurable, because it shared its blocks with the app; Settings counts it at full size in System Data. **Measured (26B5101f,
  2026-10-13):** what a copy holds of its own is the sum of its files' `ATTR_CMNEXT_PRIVATESIZE`: SketchUp's and LayOut's copies,
  2.42 and 0.97 GB by size, held 0.04 and 0.01 GB. A copy of an app that was updated afterwards keeps the older version's blocks,
  which no other file shares (Mole deletes Chrome's for that reason). Copies are offered by that figure, from 50 MB, while the app is
  closed and nothing runs from the copy; macOS makes a new one when it next checks the app.
- **Measured: why total and breakdown differ.** Nothing has to list what System Data holds, because the total is Settings'
  remainder. The page's items are only the breakdown, and what they leave out of the total is a "Not identified" block, so a rule
  that goes wrong shows as a measured amount instead of a wrong total.

### Category discrepancy investigated on 2026-10-17

**Measured, without UI automation.** The signed app's earlier reading subtracted 35.24 GB of Applications and 21.56 GB of
Documents, against Settings' displayed 33.94 GB and 20.71 GB. Those are net category differences, not evidence of their cause.
Comparing the actual Apple implementations identifies two classification errors in MacSpace:

- `SPInfoSizeDirectoryOperation`'s callback excludes all real `.app` bundles. Calling that same read-only operation and
  MacSpace's `AllocatedSize` on the same folders, with identical exclusions, gave 1,692,827,648 versus 1,258,737,664 bytes for
  `~/.cache` (434,089,984 over in MacSpace), and 1,203,286,016 versus 875,343,872 for `~/.codex` (327,942,144 over).
  A controlled temporary folder with a 4 MB document and an unindexed 8 MB application returned 12,009,472 bytes from MacSpace
  and 4,001,792 from Apple, exactly excluding the 8,007,680-byte application. This proves the filter difference independently of
  live-file changes or stale Settings readings. Clones alone explain only 301 MB of the Documents tree and are not the full cause.
- `STMApplicationSizer.initWithDelegate:` constructs three query scopes: home, `/Applications/`, `/System/Applications`.
  MacSpace adds globally indexed apps from outside those scopes: 768,618,496 bytes under `/usr/local/share/dotnet` and
  822,824,960 under `/Library` in this run (Autodesk helpers and Apple helper bundles). The native category does not claim those
  simply because Spotlight calls them applications. They belong in the remainder unless another category claims them.

Both mistakes subtract bytes from the System Data remainder that Apple's corresponding categories do not subtract. The live
examples are not a byte-for-byte reconciliation of the earlier rounded readings: files and the indexed application set changed
between measurements. Evidence and reproducible programs are in `results/storage-discrepancy-20261017/`.

**Implemented and remeasured.** Documents now applies Apple's suffix/resource-key application exclusion during its walk, including
unindexed bundles. Application category paths and System Data's claimed paths now use the native search scopes and the verified
home Library, trash, identifier and nested-application filters. The global indexed-app lookup is retained for other callers.
The controlled fixture (also including a regular file named `.app`, which macOS marks as an application) now returns exactly
4,001,792 bytes from both implementations. Twelve of thirteen real Documents subtrees match Apple's operation exactly, including
`~/.cache` and `~/.codex`; the Documents folder itself differs by 4,096 bytes. This does not establish byte-perfect parity of the
complete live storage reading. Regression tests hold used space constant and check that both corrections raise System Data by
exactly the misclassified allocations. The earlier cloud-cleanup fix remains in this branch.

### Other System Files loading measured on 2026-10-17

The initial read-only baseline took 5.917 seconds to inspect cloud downloads, 0.992 seconds for a fresh CacheDelete query and
0.029 seconds for the remaining update/Time Machine checks (6.938 seconds sequentially). Cloud eligibility inspection now uses
four workers and memoizes inherited Keep Downloaded markers within the scan; eviction still checks every current marker again.
The cloud scan then took 2.860 seconds and returned exactly the same 4,109 files and 9,467,731,968 bytes. The complete live snapshot,
with independent service, cloud, update and Time Machine reads running together, took 2.785 seconds. These are local measurements,
not a bound for every provider or backup disk. The fresh CacheDelete query and cloud eligibility rules are retained. Source,
outputs and test evidence are in `results/module-loading-20261017/`.

### What fills it, and what each item is (one Mac, typical sizes)

| Item | Nature | In Settings' System Data? |
|---|---|---|
| Document version history (`/System/Volumes/Data/.DocumentRevisions-V100`) | revisiond's store | yes, 6.35 GB |
| Group Containers and Containers of third-party apps | app data | **no**, Applications |
| Apple's own containers, Daemon Containers, Biome, DuetExpertCenter | system services' data | yes |
| `~/Library/Caches`, `~/.cache` | caches | caches in `~/Library` yes; `~/.cache` is Documents |
| Chromium and Electron caches in Application Support | caches | yes |
| Unified log, `uuidtext`, diagnostics, power log (`/private/var/db`) | logs and databases | yes |
| Spotlight index, per-user CoreSpotlight (`~/Library/Metadata`) | indexes | yes |
| Symbolication cache (`coresymbolicationd`) | cache | yes, 1.69 GB |
| Swap and sleep files (`/private/var/vm`) | macOS (VM volume) | **no**, macOS |
| `/macOS Install Data` leftovers | finished update | yes, 1.27 GB |
| `~/Library/CloudStorage` | cloud file copies | yes (it is in `~/Library`); 12 GB of OneDrive downloads were here, not in Documents |
| Downloads, unfinished downloads, restore images, virtual machines | user files | **no**, Documents (see the lag below) |
| Homebrew, system assets (`AssetsV2`) | tools, Apple assets | yes / partly macOS (above) |

### The classification lag

**Measured.** A new 25 GB restore image first appeared in System Data (+19.12 GB there, used +19.75 GB) and minutes later moved to
Documents (+21.91 GB there, −21.91 GB in System Data, used unchanged). Settings' own figures: before the download used 112.13,
Documents 8.06, System Data 41.95; just after, 131.57, 12.44, 56.02; a while later, 131.57, 34.35, 34.11. New large files in user
folders sit in System Data until Settings has sized the home folder again. A reading taken straight after a download is therefore
not final. The file took about 21.9 GB in Settings against 25 GB by size; the reason (compression or shared blocks) is
**unverified**.

### Things the scan once missed or counted wrongly

**Measured**, found by tallying the whole Data volume with Full Disk Access (`du -x` to depth 4 takes about 28 s; 62 SIP datavault
paths stay unreadable): the prepared macOS update on Preboot, apps' files for all users in `/Library` (3.06 GB), Apple's per-user
data in `~/Library` (about 1.4 GB), tools' hidden folders in the home folder, the rest of `/private/var/db`, system logs and
temporary files. The scan now covers whole areas instead of a list taken from one Mac. Per-user `/var/folders` grew 7.8 GB in a
day from three code-signing clones (APFS clones, 6.2 GB) and two virtualization installation bundles (1.18 GB).

Files macOS may delete by itself carry the APFS flag `EF_IS_PURGEABLE` (`getattrlist`, `ATTR_CMNEXT_EXT_FLAGS`; file attributes
come before the extended ones in the buffer). System Data leaves them out, as Settings counts them as free space.

### What no folder accounts for

**Measured** (26B5101f, 2026-10-12, with Full Disk Access and the helper). The page's remainder ("Not identified") was 7.32 GB of
42.9 GB. The Data volume used 131.7 GB (`df`); a `du -x` with Full Disk Access read about 120.4 GB, and the helper's root-only places
about 1.4 GB more, so about 10 GB is read by no one. 68 folders refuse to open with "operation not permitted" even with Full Disk
Access, and as root (System Integrity Protection): Apple Intelligence's model families in `/System/Library/AssetsV2`
(`UAF_FM_GenerativeModels`, `UAF_FM_Visual`, `UAF_IF_Planner`…, whose manifests had been rewritten that morning, with Apple
Intelligence on), databases in `/private/var/db` (`Spotlight`, `CoreDuet/Knowledge`, `oah`, `AppleIntelligencePlatform`…), and
per-user service folders in `/private/var/folders`. No interface gives their size without listing them (`ATTR_DIR_ALLOCSIZE` is not
returned). With the file system's own metadata they make the remainder, so the page names them ("Protected by macOS") and lists them,
without sizes. Ruled out: local snapshots (none), files flagged purgeable (under 1 GB, mostly in places Settings counts elsewhere).

**Measured, and fixed: the listed items exceeded Settings' figure.** With the models released, the items added up to 35.27 GB
against 32.55 GB, so the page's remainder read zero and part of it had been hidden before. Two causes. Files reached by several hard
links were counted once per path: 2.14 GB over the Data volume, 1.49 GB of it in `~/Library/Metadata/CoreSpotlight`. And
CacheDelete counts 1.28 GB of apps' container caches as purgeable (Settings counts it as free space), which Apple's containers
counted in full; their caches folders held 1.90 GB. With hard links counted once and each container leaving out the service's
share of its caches, the items came to 32.67 GB against 33.00 GB. APFS clones shared between items and Settings' categories came to
0.06 GB only.

Two of MacSpace's own gaps were in the remainder too, about 0.85 GB, both fixed: Apple's containers under 100 MB (881 of them,
0.73 GB) were summed with third-party ones into one "Smaller items" item, which the page leaves out as Applications; and the parts of
`~/Library/Logs`, `~/Library/Messages`, `~/Library/Photos` and `/Library/Logs` that the entries for crash reports and Messages'
attachments do not measure were measured by nothing (0.11 GB).

**Measured, not System Data:** Time Machine's local snapshots do not exist on this Mac; the only snapshot is the sealed
OS-update snapshot on the System volume (required, not purgeable).

**Measured, Time Machine's local snapshots (26B5101f, 2026-10-13, as an admin user without Full Disk Access, no backup disk set).**
`tmutil localsnapshot`, `tmutil listlocalsnapshots /` and `tmutil deletelocalsnapshots <date>` all work without a password. Two
snapshots were made, a 1 GB file between them, then the file was deleted. macOS's purge service for them, `com.apple.TMCacheDelete`
(backupd-helper), reported nothing for about a minute, then 1.69 GB at urgency 3 and 4 and nothing at 1 and 2. Deleting the older
snapshot freed 602 MB, the newer 1.12 GB: 1.72 GB in all, measured on the volume. The service still reported 1.72 GB once both were
gone, so the page reads 0 whenever `tmutil` lists none. `diskutil apfs listSnapshots /System/Volumes/Data` lists them as purgeable;
neither tool gives one snapshot's size. They are purgeable space (Other System Files), not System Data. Other System Files lists
them and frees all but the newest and the newest ending in `.backup` (the one the next backup starts from), as Purge
(jithin-sabu/purge-app) does. Backups on a backup disk are listed without root (an APFS disk's snapshots through `diskutil`, an older
disk's `Backups.backupdb` folders); deleting one needs root and, by the man page, Full Disk Access (`tmutil delete`), so the helper
does it. **Not yet tried on a Mac with a backup disk.**

---

## 2. What can be reclaimed

### System assets (`/System/Library/AssetsV2`)

Who holds these assets, what releases them and why they come back is in
[Asset owners](#asset-owners-and-why-clean-now-is-not-prevent-forever). The Phone feature gates are in
[Phone feature gates](#phone-feature-gates).

**Measured.** 7.1 GB on one Mac (8.6 GB in 40 families before the Siri models went), almost all of it subscribed, so a purge frees
nothing until the subscription goes. Subscriptions live in `/private/var/db/assetsubscriptiond/UAFAssetSubscriptions.db`
(readable; opened read-only with `immutable=1`). Six families carry the SIP `restricted` flag and are unreadable even with Full
Disk Access, among them the Foundation Model families (`UAF_FM_GenerativeModels`, `UAF_FM_Overrides`, `UAF_FM_Visual`,
`UAF_IF_Planner`, `DuetExpertCenterAsset`); their size is known only from mobileasset's own log and from Settings.

| Family | Size | Held by |
|---|---|---|
| Siri speech models (en_US, pt_BR) | 2.19 GB | Siri speech service, speech recognition broker, phone call features |
| Apple developer documentation | 1.65 GB | Downloaded for Xcode; class "Precious", no subscription |
| Language data (spelling, text analysis) | 1.1 GB | One ProofReader subscription per language (13) |
| Spatial Photos "Relive" | 0.81 GB | macOS model catalog |
| Portuguese speech transcription | 0.34 GB | Siri speech service, phone call features |
| Siri voices | 0.52 GB | Siri text-to-speech |
| Dictionaries, accessibility speech samples, geo understanding | 0.28 GB | DictionaryServices, accessibility |

- **Measured: the Spelling setting does not control language data.** `NSLinguisticDataAssetsRequested` lists exactly the languages
  that have a subscription, but the system builds and refreshes that list itself (every 86 400 s). Removing one language by hand,
  and later dropping unused languages in the Settings UI, left every subscription and the purge unchanged.
- **Unverified:** the settings named for Siri voices, dictation, dictionaries and developer documentation. They appear in the app as
  "Setting" with a note that menu names can differ.
- Editing the subscription database for a live account is **not done**: the daemon re-adds rows and the file is Apple's.
  MacSpace edits it only to remove rows of accounts that no longer exist (backup first, one transaction).
- **Measured, the one supported removal:** the optional Metal Toolchain, through `xcodebuild -deleteComponent metalToolchain`,
  freed 903.9 MB and comes back with `-downloadComponent`. Developer documentation cannot be removed that way.

### Asset owners, and why clean-now is not prevent-forever

**Measured** on 26B5091g (13 to 15 October 2026) and 26B5112a (15 to 18 October 2026), SIP on. The question was whether the Siri,
speech, language-data and Spatial Photos assets can be released without a profile, private entitlements or SIP changes, and
whether they then stay released. The short answer: each family can be released by withdrawing its owners' requests and
purging once, and none stayed released once macOS ran normally again.

**Who keeps an asset on disk**

- mobileassetd decides per family what it may reclaim. Documentation, dictionary, suggestion and geo families are never
  reclaimed by it (`GCTypeNone`). The Siri, speech, language-data, translation and search families are reclaimed only when no
  UAF lock exists (`GCTypeLocked`). Spatial Photos Relive is reclaimed as soon as nothing references it
  (`GCTypeUnlockedUnreferenced`).
- A lock is a record in `/System/Library/AssetsV2/persisted/AutoAssetLocker/` with one reason per holder, here a UAF asset-set
  manager locking the latest version, with its own usage policy (across reboot, across an OS update, how long after use). Siri
  Understanding had dozens of such records, speech and language data a handful each.
- The requesters are client daemons, not model-catalog conditions: the speech recognition broker, Telephony (`callservicesd`),
  the embedded speech service, the spelling checker, DictionaryServices and the keyboard service. Only Spatial Photos is
  decided by ModelCatalog. A text search of the dyld shared cache for ModelCatalog conditions found nothing, and failed its own
  calibration on the known Spatial condition, so those conditions are compiled predicates and the code has to be read with
  `dyld_info` instead.
- **Measured:** Apple developer documentation has no release route at all without private entitlements or SIP off: it is never
  reclaimed by mobileassetd, Xcode's documentation code removes only its navigator index, and `xcodebuild` has no component type
  for it.

**What supported settings do**

- Siri and Dictation off removed one subscription row (the assistant language row) and changed no folder.
- The session language is not a release. Changing it to another language added subscription rows and downloaded that language's
  voice (the TTS folder doubled to 428 MB); changing it back removed the rows but not the files, and nothing became purgeable.
- The spelling setting does not control language data (above).
- **Spatial Photos is the one that releases.** Setting `LocallyDisabled` in `com.apple.spatialphotosrelive` and posting its
  enablement notification removed the family's subscription and usage rows within five minutes; the next purge freed the images
  (folder 426,696 KB to 8 KB; mobileassetd's estimate was 417 MB). Not tested: surviving a restart, reverting (expected to
  download the images again), the Photos UI, and the free-space effect, which APFS clones can hide.

**What the owner route does.** Withdraw each owner's own request through the framework that made it, check that the rows,
usages and locks are gone, then run the existing guarded CacheDelete pass. No database edit, no file deletion, no private
service call, no daemon suppression.

- *Speech recognition:* the exact `GeneralASR/pt` configuration Telephony requested, unsubscribed through the Speech framework.
  The 343 MB Portuguese payload went. About 16 MiB stays, held by a different requester (call-screening captions' language
  identification).
- *Language data:* 21 assertions in a persistent store (`~/Library/DataDeliveryServices`) from ProofReader, DictionaryServices and
  the keyboard service's embedding prewarm, removed through `DDSAssetCenter`. DDS initialization recreates UAF subscriptions
  from that store, which is why deleting database rows never held. Several languages have two requesters, so removing one
  assertion cannot be assumed to release a shared asset. In the full run the nine locks were gone after 30 seconds but the files
  stayed until a purge; the service's estimate rose from 124.5 MB to 1.13 GB. A first German-only run made 130 MB purgeable and
  was rolled back cleanly.
- *Siri voices:* four owner roots (AssistantServices, Telephony and the Simone voices). Two Portuguese rows came back during
  the run and were removed again. A saved premium Output Voice is itself a requester; clearing it, after a backup, removes it.
- *Siri Understanding and Hammer:* the exact `assistant.<locale>` embedded-speech configurations; the paired Hammer rows
  disappear with them. Four usage-alias owners (assistant and intelligence-engine holds, two `siri.nl` language rows) are
  withdrawn separately.
- *Early attempts left locks behind.* One Spanish test showed an older lock file held by the CDM process and, after that
  closed, an atomic-instance reference kept by `assistantd` for the whole ten-minute window; a controlled Siri language
  transition did not release it. The exact-configuration route is what later released everything.
- *The result:* all five families were absent from the inventory immediately and stayed so at 30 seconds, 2 minutes and 5
  minutes; the owner database passed its integrity check. The final Siri pass purged 1,425,600,512 bytes from a fresh estimate
  of 1,450,704,149. **CacheDelete's byte counts are service-wide**: only the absence of the target folders proves what was
  removed from them, and no byte figure may be attributed to one family.

**Why it comes back.** Measured on 26B5112a. Hours after the clean, with Siri and Dictation off, the session language
unchanged and the premium voice still cleared, normal system activity had recreated the assistant and Hammer rows, Telephony's
`transcription.pt`, the Portuguese voice and resource rows, a direct premium voice row and the `siri.nl` system-language
row, and the folders were back to about 1.3 GB (Understanding), 39 MB (Hammer), 276 MB (voices) and 363 MB (speech). Restarting
the protected speech services alone recreated embedded-speech ownership. The conditions that drive each requester, read from
the code on this build:

| Requester | What recreates it | Off-switch that holds |
|---|---|---|
| Siri Understanding and Hammer | CoreSpeech's Medoc/UOD start-up path preheats local speech and hardcodes subscribing. On a normal customer Mac its predicate (not Darwin, Medoc and UOD enabled for macOS, Apple Neural Engine present) is true. | None found; it ignores Siri and Dictation being off. |
| Siri voices | AssistantServices reconciles a saved Output Voice without checking whether Siri is on. | Clearing the saved voice. |
| Telephony voices | Greetings follow call screening, recording disclosure follows call recording, translation disclosure follows call translation. | The Phone gates ([Phone feature gates](#phone-feature-gates)). |
| Telephony speech (`GeneralASR/pt`) | The speech asset manager asks three features (FaceTime Live Captions, Live Voicemail, Call Transcription); any with nonzero availability subscribes. Live Voicemail and Call Transcription both report available here. | All three unavailable. |
| Spelling language data | Every language in the effective preferred-language, locale, input-source and checker set that the checker supports. | A language absent from all of them. |
| Dictionary language data | A language-dictionary asset that is active, prepared or downloaded and lists the language. | No such asset. |
| Embedding prewarm (language data) | The keyboard service, behind `GMAvailability.isDeviceEligible`. | Apple Intelligence unavailable: a restart logged that it skipped the prewarm and the store stayed empty. |

Only the last row has a verified suppression condition, and its payload is shared with the other requesters, so no family has a
verified permanent off.

**Things that looked like switches and are not** (all measured)

- Clearing the Siri `Session Language` is unsafe: macOS falls back to the system language, recreates demand for it and briefly
  expands the model-catalog subscriptions. Keeping the session language different from the system language is a safety rule.
- The Apple Intelligence opt-in getter returns a constant `true` without reading a preference, and the availability field is
  derived from the Settings use case's unavailability reasons, so neither Siri off nor `optedOutBuddy` stops downloads. Earlier
  suppression experiments failed because the configuration is applied before subscription persistence, so blocking the
  database insert changes nothing downstream.
- Screen Time's Intelligence restrictions disabled individual features and partners (Image Creation, Siri AI and others) but
  left the Apple Intelligence availability unchanged, and the 3B model stayed selected. Apple's declarative MDM keys are per
  feature, need supervision and offer no whole-product switch.
- An app cannot call Apple's Siri language setter: `assistantd` rejects the connection for lack of a private entitlement. A
  preference write plus the language-change notification does reach it and re-evaluates eligibility within milliseconds, but
  the eligible window is under a second and queues nothing.
- Editing `com.apple.siri.morphun.plist` does not remove subscriptions, and restarting `assistantd` does not re-register
  them. `assistantd` is also not respawned: its launch events are 24-hour background tasks needing external power, so it
  stays down until the next boot.
- Deleting subscription-database rows by hand, with the daemon signalled or restarted, removed lock bookkeeping and
  preference rows rather than the rows that drive acquisition, and the daemon rebuilt the usage rows from the subscriptions it
  kept. A language-data purge that followed removed unreferenced languages only because they were already unreferenced.
- A growth of 2.16 GB in Siri Understanding was caused by the Siri language being changed to Spanish by the app under test,
  which adds Spanish subscriptions (assistant and Hammer) and language-list entries.

**What this means for MacSpace.** Cleaning is a repeatable, owner-driven action, not a setting. It reads owners read-only,
saves the exact rollback objects first, withdraws only owners it can attribute, verifies, purges once, and checks the target
folders again; if an owner is recreated later, it reports it and can clean again. It restores owner requests, and the premium
voice, only when the user switches the feature back on, which downloads the models again. It never writes the subscription
database, deletes asset files, touches locks, or suppresses daemons. The implementation is described in
[Issue 16 implementation reference](#issue-16-implementation-reference). A future persistent mode would need, for every requester that
shares a payload, a build-specific suppression condition validated across a restart of the owner process, log out and in, a
reboot, locale changes and ordinary use.

### A model left with no owner

**Measured** on 26B5112a on 19 October 2026, SIP on. After Siri's language had changed and every Siri owner had been
withdrawn, one model stayed: Siri's Portuguese speech model, 475 MB. No subscription row asked for it, no lock held it, it was not
mounted, and it survived a restart.

- mobileassetd had forgotten it as an auto-asset (no descriptor) and rated it `GCTypeNone`. That verdict is a clock, not a hold:
  "will not delete, recent client interest", 15 days from the model's install, a quarter of that at purge urgency 3 and a tenth at
  urgency 4. No purge MacSpace can ask for frees it before then. Verified on every GC pass in the log.
- Unlike an owner withdrawal, nothing marked it unreferenced, so the usual purge found 0 bytes. The per-asset catalog query
  (`MAAssetQuery`) refuses Siri's model types to MacSpace, so asking for that one asset is not a route. Verified.
- **What frees it on the click.** Adopting the model again for a moment, with Siri's own embedded-speech owner request for its
  language (read from the model's `AssetSpecifier`), makes mobileassetd track it again: it locked the model, let it go about
  20 seconds later, and rated it `GCTypeUnlockedUnreferenced`, which has no threshold. The owner was withdrawn and one purge of
  mobileassetd's CacheDelete service freed 683 MB in 0.14 seconds (service-wide; the model's folder empty is the target-specific
  evidence). Nothing was downloaded, and the folder was still empty at 30 seconds, 2 minutes and 5 minutes. Verified once.
- **Inferred:** if Apple's catalog had a newer version of that model, the moment of adoption could start a download; the
  purge that follows then removes what is unreferenced. Not tested for the other families (voices, speech recognition).

**What this means for MacSpace.** The Siri cleanup adopts and releases such models itself (`AssetOwners.readoptLeftovers`):
only while Siri and Dictation are off, only for a language with no owner, and it always withdraws what it adopted. It is a rule
about a kind of model, not a list of files. The switch asks for a restart only if models stay after that, and only once; still
there after the restart, it says macOS keeps them.

### Phone feature gates

**Measured on 26B5112a (18 October 2026).** The question: can the Phone features (recording and transcription, Live Voicemail and
Call Screening, FaceTime captions, call translation) be switched off without a configuration profile? A cleanup-only control would
not do, because the features keep requesting their models.

| Feature | Native control / upstream gate | Evidence |
| --- | --- | --- |
| Recording and transcription | `TUUserConfiguration.setCallRecordingEnabled:`; backing key `CallRecordingDisabled` | Real setter and inverse getter tested against an in-memory dictionary: on, off, on, with the expected backing values. The installed check tests the disabled preference after activatability. |
| Live Voicemail / Call Screening | `TUUserConfiguration.setCallScreeningEnabled:`; backing key `CallScreeningDisabled` | Same in-memory round trip. The installed check is activatability AND not disabled. |
| FaceTime captions | `_AXSSetFaceTimeCaptionsEnabled`, `_AXSLiveTranscriptionInCallSetEnabled` | Exported setters and getters exist; getters read off here. Setter effects on persistent settings and the FaceTime UI are **unverified**. |
| Audio and video translation | `TelephonyUtilities/AudioCallTranslationMac`, `VideoCallTranslationMac` | The runtime getters resolve to these keys. With both false, `translationDisabledError` builds translation error 2. |

- **Five boot-time feature-flag overrides** in `TelephonyUtilities` cover them: `CallRecording`, `CallScreeningEnabled`,
  `CaptionDeliveryForFaceTime`, `AudioCallTranslationMac`, `VideoCallTranslationMac`. All five are declared on this build; the
  unsuffixed audio and video names are not the macOS keys. They are root-owned entries in
  `/Library/Preferences/FeatureFlags/Domain/TelephonyUtilities.plist`, the same mechanism as Debloat's feature flags
  ([section 5](#5-debloat)).
- **Measured:** after the user applied them as root and restarted, all five effective getters read false, and so did the recording
  and call-screening checks. So the overrides take effect without a profile. Saving the file proves nothing before the restart;
  the effective values must be read afterwards.
- **Unverified:** that the Phone and FaceTime screens behave as expected. The user could not find the options in the UI before or
  after, which does not show why they are missing (Live Translation also needs Apple Intelligence on, which was already off).
  Restoring the saved entries and re-reading the getters is also still to be checked.
- **Measured, a representation trap.** `CallScreeningDisabled` is stored as the number 1 where the recording and caption settings
  are real Booleans. A strict Boolean comparison reported the control as changed elsewhere and then as unknown, even though all
  five gates and both journals showed off, which stopped the recurring Phone cleanup. The reader now accepts a Boolean or a numeric
  0 or 1, rejects strings and other numbers, and restores the original data unchanged.
- **Method warnings.** The earlier research probe cast every Telephony function as taking no arguments, which crashes: the
  call-screening check forwards three objects to an activatability check, and the recording check takes a feature-flags object
  (nil selects the default). Native methods need their real encodings checked. `dyld_info -disassemble` rebuilds cache code with
  coordinates that differ from the runtime constants, so the exact keys had to be recovered from the actual instructions of each
  getter; that decoder is a research tool, and the app uses a reviewed per-release map and guarded calls.
- Raw transcription-availability lists can still request assets with the user features off, and list-expansion flags are not master
  switches, so a recurring download does not by itself show that a feature turned itself on.

**Rules for the implementation.** Journal the native settings and the full original override entries (including absence and the
original development-phase metadata) before changing anything, and keep unrelated entries and outside changes. Root operations
take a fixed feature scope and an on or off intent, never a path, domain or key. Report the combined switch off only when every
native setting and effective flag verifies off; an unreadable value, a partial failure, an unreviewed release or a pending restart
cannot authorize withdrawing the model owners. Keep the Apple Intelligence language control independent: turning Phone off never
changes the Siri session language.

### Issue 16 implementation reference

**Implemented boundaries**

- `Platform/Preferences/ModelFeatureSettings.swift`: reversible, fixed-catalog user settings for Siri, Spatial Photos and local Phone controls. Saves exact original values, including absence and the complete Siri voice dictionary. A user-owned journal is saved before writes. Interrupted transactions keep their originals; external drift stops writes. Session Language is never part of this catalog.
- `Platform/Preferences/PhoneFeatureFlags.swift`: the existing authenticated helper operation controls the five reviewed boot-time TelephonyUtilities flags. The effective gates must all verify off after restart. The root research trial is imported only during an explicit helper action, preserving its original rollback baseline.
- `Platform/AssetOwners/AssetModelCleanup.swift`: shared owner/reclaim service, strict known-unavailable eligibility gate, fixed scopes, CLI crash isolation, target presence checks and one service-wide purge per batch.
- `Platform/AssetOwners/Native/AssetOwnerBridge.m`: runtime/build/session/ABI guards; immutable read-only UAF inventory; secure rollback objects; owner-scoped Speech, sirittsd, UAF and DDS operations. No new UAF SQL writes, direct payload deletion, lock deletion, daemon suppression, profile or SIP changes.
- `ManagedModelCleanup`: every five minutes while the app is open, rechecks only explicitly managed-off controls. Ordinary external off settings are not silently adopted. Phone additionally requires its user settings and all effective system-wide gates to verify off. An action waits for an existing cleanup before changing a feature. All selected scopes withdraw owners before one shared CacheDelete pass, whose free-space gain is counted once.
- Siri uses normal ToggleRows, badges and existing tile refresh behavior. Feature actions reconcile only feature state. Cleanup completion reconciles assets and model measurements; it does not invalidate the page or replay its entry cascade.
- System Data uses its existing unused-system-assets row and `purgeAssets` action. An explicit Free can first withdraw reviewed LinguisticData DDS requests. Automatic general cleanup does not withdraw these owners. No reclaimable byte estimate is invented from installed model sizes. The row keeps the same action identity and uses `Row.activity` while the existing bounded purge retries run.

**Owner operations**

Siri embedded speech uses exact type-3 configs derived from actual current-user `assistant.<locale>` rows. Config name, usage and generated subscription semantics must match the captured owner. Paired Hammer requests are journaled and verified after the same Speech unsubscribe. Shared speech models are kept while Siri or Dictation is active.

Phone uses the same exact-config route for its type-7 `transcription.<language>` owners. Raw supported-language lists can remain nonzero even with user-facing features off; normal requester recreation is handled by repeating verified withdrawal, not by editing support lists.

Feature-specific AssistantServices/TelephonyUtilities voice requests are withdrawn through sirittsd. Other clients and accessory requests are preserved. Speaking/unknown speech status stops voice cleanup. VoiceOver keeps shared voices. Reviewed UAF premium voice/resource and Siri alias rows are withdrawn only after secure decoding, current-account and semantic owner/API checks. Active other voice clients retain the shared payload.

System Data's one-shot LinguisticData release handles only the three researched DDS clients. Exact query/policy/descriptor records are saved, removals use DDSAssetCenter, and unrelated descriptors must remain identical. It does not change spelling or dictionary preferences; those requesters may return.

The original owner objects are restored only on explicit enablement or uninstall. On an unreviewed later macOS build, feature preferences can still be restored, but private archives are not replayed against an unknown ABI; Apple features recreate their requests. Conflicting current owners are never overwritten. An ambiguous callback is reconciled read-only before a repeat mutation; an unresolved ambiguity remains deferred.

**Reclaim and safety**

Owner cleanup requires eligibility answer 2, not merely any answer other than 4. The pre-existing purge-only guard retains its prior behavior. New model cleanup supplies an additional policy to PurgeRun; it is checked before estimation, before the physical request and on each existing bounded retry. Explicit feature changes cancel pending MobileAsset retries.

Empty target inventories do not cause another purge. A fresh positive estimate is required for new model cleanup; a lagging estimate uses the existing bounded retry delays instead of claiming immediate savings. Native removal counts describe only the current cycle, not all prior journal entries.

The physical purge stays in CacheDeleteClient/PurgeRun. Reported bytes and volume gains are service-wide, never attributed byte-for-byte to Siri, Phone or an individual asset family. Remaining family inventory is nullable: unreadable is not zero. MacSpace does not force cleanup around Apple locks or other accounts' owners.

**Validation, and what is still unverified**

- The full test suite passes (548 tests, five optional skips, zero failures), and all eight UI languages pass the compiler
  string-extraction check.
- A read-only native preflight on the development Mac passed: method contracts, a secure DDS query/policy round trip, and the
  inventories (26 UAF subscriptions, two voice requests, seven DDS descriptors), with no feature writes, owner withdrawal or
  physical cleanup.
- The earlier root flag trial was live-tested after a restart: all five effective Phone flags were false. The Phone/FaceTime
  controls were not found in the UI afterwards; that remains **functional UI behavior unverified**, not proof that the flags caused it.
- The combined app flow (switches, inline flag animations, owner cleanup) has not been run live against real models. Do not claim
  permanent suppression, or that a Mac has been cleaned, on this evidence.

### CacheDelete

**Measured.** `CacheDelete` is macOS's own purge, the one that runs when the disk is nearly full.

- The functions are private. Their signature came from disassembly of one build, and a wrong signature crashes the caller. So the
  call runs in a throwaway child process, where a crash ends that process and is reported as an error. Every build that has the
  functions may use them; a purge first checks, read-only, that the service filter is honoured. The self-test
  (`MacSpaceCli purge-assets --self-test`) remains as a diagnostic. **Measured:** on 26A434 in a VM it found no answer right after
  the VM started and passed later, which is why a self-test result gates nothing.
- **Measured, a bug worth remembering.** The purge callback must be an escaping block. A trailing closure traps with "non-escaping
  closure has escaped" for services that answer after the call returns.
- **Measured, what "purgeable" on the disk tile is.** The tile shows available-for-important-use minus free: 7.03 GB on one Mac.
  Asked per service, CacheDelete reports about 1.5 GB at urgency 1 and 2, and 7.02 GB at urgency 3: `fspurgeable_data` 4.89 GB,
  app container caches 1.15 GB, `fspurgeable_document` 633 MB, Quick Look thumbnails 330 MB, Spotlight 13 MB, MobileAsset 4.4 MB.
  At urgency 4 MobileAsset reports 12.41 GB, assets still in use; not a candidate. The whole answer agrees:
  `CACHE_DELETE_TOTAL_AVAILABLE` 7 025 163 817, of which `CACHE_DELETE_TOTAL_FSPURGEABLE` 5 522 636 800. Both fspurgeable services
  belong to `deleted_helper`; the answer names no files or apps.
- **Measured, purging `fspurgeable_data` at urgency 3, as a normal user:** 4.66 GB reported removed, free space rose by 4.66 GB.
  Quick Look thumbnails reported 330 MB purgeable and removed nothing. Which apps' files went is not known, nor how fast they come
  back. The Other System Files module lists every service macOS counts as purgeable and frees `fspurgeable_data`; the disk tile's
  "purgeable" is that service's figure. The other two stay CLI-only (`--experiment`).
- **Measured, the estimate lags.** A first purge removed 111 MB; the next answered within 0.0013 s with `CACHE_DELETE_AMOUNT = 0`
  while the estimate at urgency 3 still said 911.7 MB. Asking at urgency 3 and then at 4 (critically full) removed what 3
  declined: 1.08 GB, after which the estimate said 63.5 MB. The app lists files as declined only when both remove nothing.
- **Measured, container caches are not worth offering.** `com.apple.cache_delete_app_container_caches` reports 1.15 GB and keeps
  reporting it. Purging freed 2.1 MB at urgency 1, 2.1 MB at 2, 95.7 MB at 3 and nothing at 4. Not in the app. Read with Full Disk
  Access (26B5101f, 2026-10-13), the containers' caches folders held 1.85 GB: Apple's 1.81 GB (the wallpaper agent 1.17 GB,
  mediaanalysisd 476 MB), third-party apps' 38 MB. The third-party ones are offered on System Data's caches page, deleted directly
  (Third-party app caches, below); Other System Files keeps the service as one figure.
- **Measured, what `fspurgeable_document` is.** 21.15 GB, up from 9.96 GB the same morning: OneDrive's files. File Provider apps
  flag files they downloaded and keep in the cloud as purgeable (22.94 GB in 8,065 files of one cloud folder, nothing flagged in
  Downloads, Documents or Desktop). macOS may delete these local copies; they download again when opened. Other System Files names
  the block after each cloud folder found, whichever provider it is, and skips folders still only in the cloud (`SF_DATALESS`) so
  the scan never makes a provider fetch anything.
- **Measured and inferred, removing cloud downloads on request.** Foundation sees the provider's files as cloud items
  (`isUbiquitousItem` 1, downloading status current, `ubiquitousItemIsUploaded` 1, on one file), so the public
  `FileManager.evictUbiquitousItem(at:)`, Finder's Free Up Space, is the way to remove a local copy, for iCloud Drive and every
  File Provider app alike. `fileproviderctl` and `brctl` have no evict command on this build. Remove Downloads takes uploaded local
  cloud files, not uploading and without conflicts, leaving Keep Downloaded markers (including inherited markers) alone. Removing 21 GB of
  downloads took Settings' System Data from 44.46 to 32.3 GB and used space from 203.24 to 188.81 GB. **Not yet run from the app:**
  whether every provider answers an eviction, and how fast for 8,000 files, is unknown. Purging `fspurgeable_document` would do
  it for every provider at once, unasked; not offered.
- **Measured, stale cloud estimates and missing manual cleanup (2026-10-17).** CacheDelete's ordinary query returned exactly
  17,342,464 bytes for `fspurgeable_document` while the same query with `CACHE_DELETE_NO_CACHE = true` returned 6,128,812,032.
  The native APFS purge statistics also increased while the cached answer stayed fixed. Actual service measurements now bypass
  this daemon cache; the modules still cache their snapshots. OneDrive held about 9.47 GB locally: initially 8.30 GB lacked
  `EF_IS_PURGEABLE`, and 1.18 GB carried it. Large files in both sets were uploaded, idle, conflict-free, and File Provider reported
  a lazy content policy with `isKeepDownloaded = 0`. Neither the pressure estimate nor the APFS flag determines whether the user
  can explicitly evict a local copy. The scan now checks cloud upload state directly (4,109 candidates, 9,467,731,968 bytes in
  9.44 seconds), runs independently of CacheDelete, and shows the actual candidates without scaling them to the pressure estimate.

### Caches in Application Support

**Measured.** Chromium and Electron apps keep their HTTP cache, compiled scripts and GPU shaders in their Application Support
folder, not in `~/Library/Caches`: `Cache`, `Code Cache`, `GPUCache`, `Dawn*Cache` (and VS Code's `CachedData`), 326 MB on one Mac
(one app 296 MB). A profile folder is recognised by its `Network Persistent State` or `Local State` file, so a folder named Cache in
any other app is never taken. Their storage (Local Storage, IndexedDB, Service Worker) holds data and is left alone. System Data
cleans these while the app is closed and takes them off the app's own figure. `~/Library/Caches` in general is listed, not
cleaned.

### Third-party app caches (`~/Library/Caches`)

**Measured** (26B5101f, 2026-10-12). Third-party folders held 0.88 GB, Apple's 0.39 GB. Owner lookups alone misjudge them: of the
folders over 1 MB, `pip` and `org.swift.swiftpm` (used in the last 6 days) and `SharedImageCache`, `SiriEntityCache`, `PassKit` and
`Animoji` (Apple's, without the `com.apple.` prefix) name no app; an app started from the Finder gets the system PATH only
(`launchctl getenv PATH` is empty), so `pip`, `bun` or `brew` are not found there either.

**Measured: what a file's dates say.** A read moves a file's access date only when that date is not newer than its last change: a
file read 6 days after its last access kept it (two files; `cat`, `head`, Python), and re-reads seconds or minutes after a first read
did not move it. So the access date is "first read after the last change", not "last read". A folder's own access date moves when
anything lists it, MacSpace's scan included. The newest creation, write or access date of a cache's files, and the newest write of
its folders, was within about a day of the owner app's last launch (`kMDItemLastUsedDate`) for 10 of 11 apps; the exception, a
menu-bar utility, was opened 3.5 days after its cache last changed, so an app opened recently keeps its cache whatever the dates say.

**What MacSpace does with it.** A cache unchanged for 30 days whose app was not opened for as long, or that is named after a bundle
identifier no installed app has, is offered checked; the rest are offered unchecked, those in use saying that they come back and
how much they wrote in the last two days (most of what a cleaner frees in `~/Library/Caches` is that: Firefox's 309 MB, at its
own size cap, wrote 38.5 MB in two days); a cache whose app or tool is running is not listed; a folder whose owner cannot be named
is never checked; media or documents with names people give (50 MB or more) keep a folder out; a name macOS has on
its system volume (a framework, a daemon, an app) is Apple's. Nothing is opened to read this. Each cache is read again just before
it goes, then the cleaner's checks apply (the owner not running, no file open), and the folder is renamed, then deleted. **Unverified:**
how much this frees on a Mac used for years: here, 92.7 MB of third-party cache files were unchanged for 30 days, all Homebrew
downloads.

**Measured: caches in sandboxed apps' containers** (26B5101f, 2026-10-13, with Full Disk Access). 35 third-party containers; their
`Data/Library/Caches` folders held 38 MB: WhatsApp 24 MB (22 MB of thumbnails named by hashes), OneDrive 11.6 MB and its file
provider 2.1 MB, the rest under 1 MB. A container is named after the bundle identifier of what runs in it, and an extension's
identifier begins with its app's, as Apple requires: LaunchServices named the app of 24 containers that way, 10 of the other 11
belonged to apps no longer installed, and one to HandBrake's XPC service, whose identifier does not begin with HandBrake's, so it
reads as not installed. WhatsApp's folder also holds `com.apple.nsurlsessiond/Downloads/net.whatsapp.WhatsApp`: nsurlsessiond keeps
an app's background downloads there and carries on with them while the app is closed, and it refuses to show its open files.

**What MacSpace does with them.** With Full Disk Access, each third-party container's caches folder is an app cache under the rules
above, named after its app. Apple's containers (`com.apple.`, `group.com.apple.`) and group containers are not offered. Freeing
deletes what is in the folder, never the folder, and never an entry named `com.apple.*` (left out of its size too). The cleaner may
delete only inside the chosen containers' caches folders, and checks the app by bundle identifier alone: the app, or a process
from inside its bundle. The name rule used for `~/Library/Caches` would have taken the Finder, always open, for the owner of
`com.microsoft.OneDrive-mac.FinderSync`. **Unverified:** how much this frees on a Mac with more sandboxed apps.

**Measured: Homebrew** (7.0.8). Plain `brew cleanup -n` failed with "Refusing to load cask … from untrusted tap": Homebrew 7 refuses
casks from a tap the user has not trusted, MacSpace's own here; `--prune=all` skips that check and worked (138.2 MB, against 33.4 MB
for the plain run when the tap is trusted). Plain `brew cleanup` also uninstalls formulae nothing needs (autoremove), and any brew
command reports to Homebrew's analytics and fetches its package list when it has none. MacSpace runs it with
`HOMEBREW_NO_AUTOREMOVE`, `HOMEBREW_NO_AUTO_UPDATE` and `HOMEBREW_NO_ANALYTICS`, from `/opt/homebrew/bin/brew` or
`/usr/local/bin/brew`, and only when the package list is already there. A dry run takes under 1.5 s.

**Rechecked, 2026-10-18 (26B5112a).** Both the standard and `--prune=all` dry runs returned success with no removable files on this
Mac; the 3 GB installed prefix is not a cleanup estimate. `/usr/local` has no `bin/brew`: its contents include a Node executable,
global npm packages, Python framework links and Parallels tools. It remains separate from `/opt/homebrew` and cannot safely be
deleted as a cache. The Homebrew info pill was absent because its cleanup description was empty; both rows now explain ownership
and the supported removal route. Dry-run output is in `results/issue-review-20261018/homebrew-*.txt`; no cleanup was executed.

### Other accounts' folders in `/private/var/folders`

**Measured** (26B5101f, 2026-10-12). `/private/var/folders` holds one folder per account that has ever run: the user's own, root's,
one for each macOS service account that ran (`_spotlight`, `_softwareupdate`, `_nsurlsessiond`… 32 here) and those of deleted
accounts (two of uid 502 here). Each folder is readable, but its `C` and `T` are mode 700 and owned by their account: 75 folders the
user cannot open. The scan measured only the user's own `C`, `X` and `T`, so the rest of this area was in no item. It is now one
item, measured by the helper. **Cited, not measured here:** idleassetsd runs as root and downloads Aerial wallpapers and screen
savers into `T/com.apple.idleassetsd` of root's folder; a stuck download left hundreds of GB of `CFNetworkDownload_*.tmp` files there
(Mole, issue #1253). That folder is named in advance and becomes its own row when the helper finds it.

The row is under Free now with a button of its own, never part of Clean or automatic cleaning. The helper's
`systemdata.wallpaper-downloads.delete` takes no path from the app: it opens `/private/var/folders/*/*/T/com.apple.idleassetsd`
itself, one folder at a time without following links (`openat` with `O_NOFOLLOW`), reads each entry with `lstat`, and deletes only
regular files named `CFNetworkDownload_*.tmp` directly in the folder whose modification time is more than 3 days old (Mole's
default for temporary files), so a download still running stays. A link, a folder or anything else with that name is refused, and
subfolders are not entered. Whether idleassetsd starts the same download again after its file is deleted is **not measured** here.

### Who is using a cache before it is deleted

**Measured** (26B5101f, 2026-10-12). The running apps (`NSWorkspace.runningApplications`) miss every process that is not an app:
a compiler using its module cache in `/var/folders/…/C/clang`, an app's helpers and background agents. Without root, `libproc`
lists all of the user's processes (`proc_listpids` with `PROC_UID_ONLY`: 440 here) and the open files and working folder of each
(`PROC_PIDLISTFDS`, `PROC_PIDFDVNODEPATHINFO`, `PROC_PIDVNODEPATHINFO`) in about 20 ms. Eight of Apple's own programs refuse the
paths of their files with `EPERM`, even to their own user: `lsd`, `nsurlsessiond`, `routined`, `dmd`, `UserEventAgent`,
`progressd`, `ScreenTimeAgent` and the QuickLook thumbnails agent. The kernel reports real paths (`/private/var/folders/…`).
Memory-mapped files whose descriptor was closed are not listed this way. The cleaner checks, before each item, for an owner
running as an app, as a process of the same name, or from inside the owner's app, and for any open file in the item. A refusal
from a program under `/System` or `/usr` is ignored, because those programs do not use third-party apps' caches. Any other
refusal, or a process list that cannot be read, keeps the item. **Measured** (2026-10-12): a file deleted while a process holds it
open has no path, and asking for it fails with `ENOENT` (two `opencode` processes held one). It is in no folder, so it is skipped;
counted as a refusal, it had made every answer unknown and Clean deleted nothing.

### Document version history

**Measured.** 6.35 GB by `du` (`/System/Volumes/Data/.DocumentRevisions-V100`); deleting it freed about 5 GB on the volume
(System Data fell about 5.05 GB). The folder is root-only and has no SIP flag. `launchctl bootout system/com.apple.revisiond` is
refused. What works: freeze the running `revisiond` (`kill -STOP`), delete the folder's contents (not the folder), then kill it so
launchd restarts a fresh one that builds an empty store. The documents themselves are untouched; the earlier versions of every
document are gone for good. **Unverified:** whether the freeze is safe while an app is saving; the confirmation tells the user to
save and close documents first.

### Leftover macOS update files (`/System/Volumes/Data/macOS Install Data`)

**Measured.** 1.27 GB dated 15 August on a system installed in September, with `softwareupdate --list` reporting nothing new: files
of an update that had long finished. `UpdateBundle` is root-owned with no SIP flag, so the helper deletes it; the `Locked Files`
subfolder carries the SIP `restricted` flag and stays. The helper only deletes when the folder is older than the installed
system's `SystemVersion.plist`. Deletion worked (confirmed by the maintainer; the freed amount was not recorded). Telling the
user to "install the waiting update" for such files was wrong, and the row now says that no update is waiting.

### The unified log (`/private/var/db/diagnostics`, `/private/var/db/uuidtext`)

**Measured (26B5101f, 2026-10-13).** 2.9 GB: 1.6 GB of entries (Persist 501 MB, rotated by size, about a day here; Special 976 MB,
kept by time-to-live up to 30 days; Signpost 106 MB) and 1.3 GB of format strings. Only 39 MB of entries were older than 7 days,
which is all that Mole's rule (delete files older than 7 days, `lib/clean/system.sh`) would free here. logd registers a CacheDelete
service, `com.apple.logd.cachedelete`, which reported 0 at every urgency: macOS never frees the log for space. Its purge, per the
strings in `logd`, is "Purging UUID Cache", the same as `log erase --uuidtext` ("Prune uuids from the database"); logd copies a
program's format strings again the next time it logs (`_logd_uuiddb_harvest`). `log erase` needs root. The page offers it: the helper
runs `log erase --all`, then `log erase --uuidtext`, with its own button that cannot be undone, never in Clean.

**Measured, a real erase (26B5101f, 2026-10-13, through the installed app's helper).** The two folders went from 3.11 GB to 555 MB:
entries 1.70 GB to 7.4 MB, format strings 1.41 GB to 548 MB (logd keeps those of programs still running). Free space on the volume
rose 2.72 GB. Logging went on at once: 8,383 entries in the next five minutes, none that `log show` failed to decode, the oldest a few
seconds after the erase.

### Symbols for crash reports (`/System/Library/Caches/com.apple.coresymbolicationd`)

**Measured.** One memory-mapped archive, `data`: 2.10 GB on 2026-09-30 (`MACSPACE/results/system-data-deep-2026-09-30`), 164 KB for
the whole of `/System/Library/Caches` on 2026-10-13. The folder is root's (`drwx------`), with no SIP flag. **Read in the binary**
(26B5101f): coresymbolicationd is started on demand by launchd (`MachServices`, `EnablePressuredExit`) and runs as root; its strings
include "%s does not exist, resetting cache", "%s did not validate, resetting cache" and "Failed to mark storage purgeable", so it
rebuilds a missing cache and may mark it purgeable. The page offers it from 50 MB of what it adds to System Data (a purgeable part is
free space already): the helper deletes the folder's contents, then stops the daemon (`kill -TERM`, `-KILL` after five seconds) so
the mapped archive's blocks come back; launchd starts it again on the next request. **Measured (2026-10-13, through the helper):**
1.55 GB, all of it flagged purgeable, so System Settings counts it as free space. Other System Files' Free up to (purgeable app
files, 2.74 GB estimated) then freed 2.66 GB, measured on the volume, and the cache read 0 after, with coresymbolicationd still
running: the purge takes it, and it was the largest part of that figure. It had grown back to 1.55 GB within a day of the previous
purge. System Data offers no row for it while it is purgeable; the purgeable app files row names it. The earlier "164 KB" was what
this account could read, not its size.

### The Trash

**Measured (2026-10-13).** Free on the Trash row, run through the installed app's command-line tool: 60 MB of test files in the
Trash, 62.9 MB freed on the volume, the Trash empty after.

### The helper measured nothing for a day

**Measured.** From `6b2058f` to `f594593` (2026-10-13) the helper opened folders with `O_NOFOLLOW` and `O_NOFOLLOW_ANY` together,
which `open` refuses on 26B5101f (EINVAL), so every place only root can read measured 0 bytes: the version history (86.4 MB), the
Spotlight index (725 MB) and the symbols cache (1.55 GB) left the page, their space counted under Protected by macOS. A test now
sizes a tree with every setting the scan and the helper use.

### Checked and not offered

- **Quick Look thumbnails (169 MB by macOS's figure):** in a folder no app can open, even with Full Disk Access. Apple's
  `qlmanage -r cache` resets them; on 26B5101f free space rose 145 MB right after, but macOS's figure stayed at 169.1 MB and other
  activity may account for the rise. Not offered until a cleaner reading.
- **Apple's own caches in `~/Library/Caches` and the per-user `C` folder:** the largest here were GeoServices (71 MB, Maps, read by an
  always-running daemon) and a few of 20 to 46 MB. Too small to be worth the risk of pulling a cache from under a daemon.
- **Apps' logs older than 7 days:** 0.15 MB in `~/Library/Logs`, 8.9 MB of root's in `/Library/Logs`. Not worth a button.
- **`/private/var/log` (88 MB):** mostly power management (51 MB) and launchd (20 MB) logs that newsyslog rotates; the rotated
  archives are kilobytes.

- **The prepared macOS update (10.7 GB):** installs at the next restart and macOS removes it then; nothing safe deletes it before.
- **Swap, power log:** in use or rotated by macOS. **Inferred.**
- **Aerial wallpaper (575 MB):** one video, the one in use.
- **Apps' own data** (messaging apps' group containers of several GB, cloud folders): guided manual cleanup, since the app owns it.

---

## 3. Apple Intelligence

**Measured on 26B5086k and 26B5091g.** On macOS 27 the on-device Foundation Model (a 3B-parameter base model, 6.2 GB, plus adapters
and smaller models) downloads automatically for users whose Siri and system languages match; the family is about 11.5 GB by
mobileasset's records.

### What holds the models

- The models stay installed and locked until the account's Apple Intelligence goes from available to unavailable. Switching between
  two ineligible Siri languages does not release them (en-US to en-GB: six decisions, lock stays).
- Setting the Siri language to the system language makes ModelCatalog take the models (23 decisions, the AutoSet configuration
  grows to 177 selectors; nothing is downloaded when they are already there). Setting it back (eligible to ineligible) makes
  mobileassetd log `AUTO-LOCKER ENTRY_REMOVE` within seconds, the configuration falls to 2 selectors, and the models are free to go.
  They are deleted only under disk pressure, which the CacheDelete purge does now. The original Siri language and voice are
  restored on every path.
- **Measured: the purge.** The itemised query offered 12.39 GB from `com.apple.mobileassetd.cache-delete` at urgency 1; a targeted
  purge of that one service freed 12.04 GB in 4.6 s as a normal user (Data volume 99.0 → 86.9 GB). Removed: 129 FM.Overrides,
  101 FM.GenerativeModels (the 3B base model ungrafted and removed), 6 FM.Visual, 4 Siri.TextToSpeech, 2 Siri.Understanding,
  2 Shortcuts.Generator, 1 Translation. Before it, mobileassetd's garbage collector listed 103 generative-model assets (11.47 GB),
  100 of them "will not delete, reason: never remove".
- **Models are shared by all accounts.** One eligible account, or a deleted account that still holds subscriptions, keeps them.
  **Measured:** deleted accounts each kept 23 model-catalog subscriptions (12 of them Apple Intelligence use cases) after a restart,
  their "last seen" times frozen, and mobileassetd grafted the models again at boot. Deleting an account and restarting does not
  release them. Removing the 87 subscription rows and 2 user-information rows of the deleted accounts (backup first, one
  transaction, the daemon running because SIP refuses `launchctl kill`) kept them removed after a restart, and the configuration
  fell to 2 selectors. Whether the rows would expire on their own was not measured.
- **Measured, the size.** Settings' "Apple Intelligence" (`aiModelsSize` in its Storage extension) is the size of
  `/System/Library/AssetsV2/com_apple_MobileAsset_UAF_FM_GenerativeModels` and `…_FM_Visual`: 19.89 GB (20.04 on another day). No
  app can open those folders, not even with Full Disk Access. The records (`AutoAssetDescriptors`) say 11.35 GB; releasing the
  models gained 9.48 GB on the volume with about 0.37 GB kept locked, in line with the records. The models staged for a waiting
  update (`AutoAssetStager`) are 0.22 GB. MacSpace shows the records' figure. Why Settings shows about 8.5 GB more is
  **unverified** (one guess: the grafted base model counted as image and as mounted content). `du` cannot see these folders: the
  Data volume grew while `du` shrank when the models were grafted.
- **Measured, virtual machines.** `kern.hv_vmm_present` is 1 and Apple Intelligence never becomes available, so the release flow
  waits and fails. MacSpace shows one explanation there and offers no controls.
- **Measured, iCloud.** The Siri language preference syncs through iCloud to iOS devices on the same Apple Account, so switching
  Apple Intelligence off on the Mac changes the Siri language on the iPhone too. (Not isolated: whether the release's short
  language round trip syncs as well.)
- **Measured, Siri's iCloud sync.** The switch is the `com.apple.Dataclass.Siri` data class among the iCloud account's enabled ones
  in `~/Library/Accounts/Accounts4.sqlite` (Full Disk Access). On macOS 27.2 `ZDATACLASS` has no identifier column: the name is a
  keyed archive of a string in `ZNAME`; the join table is `Z_2ENABLEDDATACLASSES` (`Z_2ENABLEDACCOUNTS`, `Z_7ENABLEDDATACLASSES`)
  and the iCloud account is type `com.apple.account.AppleAccount`. An earlier reader that looked for a `ZIDENTIFIER` column read
  nothing. `Cloud Sync Enabled` in `com.apple.assistant.backedup` is not the switch.

### Why the switch is the Siri language

The reasons are the failed alternatives, all **measured** and told in [section 7](#7-the-original-research): deleting the
files, suppressing the requester rows, patching the AutoSet configuration, boot ordering, the constant opt-in getter, Screen Time
restrictions, and a private API closed to third parties. One supported user action did hold across a cold boot, two hours online
and an OS update: a Siri language different from the system language.

### Full Disk Access

**Measured (SIP on).** Of the paths the Apple Intelligence check reads, `/private/var/db/os_eligibility/eligibility.plist` is
readable only with Full Disk Access (TCC); the user `TCC.db` stays closed even with it; the six SIP-`restricted` asset families stay
closed whatever the permission; and the stores `/private/var/MobileAsset/AssetsV2`, `/private/var/db/MobileAsset/AssetsV2` and
`/Library/Apple/System/Library/AssetsV2` are absent on this build (an early census had reported missing stores as unreadable). So
the permission is detected by probing a protected file that exists on every Mac, and when the installed-model folder is
unreadable the status relies on ModelCatalog's selection and says so.

---

## 4. The privileged helper

The helper is a launch daemon registered with `SMAppService.daemon`, reached over XPC, running only named operations. Behaviour we
had to learn (all **measured** on a Mac and a VM):

1. **Status "not found" (3).** Seen when the app ran from a build folder, and on a VM when the app was copied in by hand. The
   registration then fails with `SMAppServiceErrorDomain Code=1 "Operation not permitted"`.
   - Running `lsregister -f` on the app moved the status to **requires approval (2)**. MacSpace registers itself with Launch
     Services before registering the helper.
   - A quarantined (downloaded, not notarized) app runs from an App Translocation copy and cannot register the helper.
     `xattr -dr com.apple.quarantine` is the workaround; a notarized release avoids it (**inferred**; see
     [Open questions](#6-open-questions)).
2. **Requires approval (2)** is normal after registering. The register call reports an error while it waits; that is not a failure.
   The user allows MacSpace in System Settings → General → Login Items & Extensions.
3. **Replacing the app leaves the helper stale.** The old process keeps running and does not know new operations. MacSpace used to
   unregister and register the helper to load the new binary, but **measured (2026-10-04): registering again drops the user's
   approval**, so every new build asked for it again. Now the helper compares the binary on disk with the one it started from, on
   every new connection and every 20 s, and quits between requests when the app was replaced; launchd starts the new binary on the
   next request. The app re-registers only a helper that never answers.
4. **A dead connection stays dead.** An `NSXPCConnection` that failed once never recovers. The app drops a failed connection and
   retries once on a new one.
5. **A stable signature keeps Full Disk Access.** macOS ties the permission to the code requirement. Local builds are signed with
   the Developer ID identity so the requirement (identifier plus team) is the same on every build; ad-hoc builds change every time
   and lose the grant.
6. **The helper can read what the app cannot** (Spotlight index, version history, symbolication cache), with Full Disk Access
   granted to the app. It measures anything under the system's folders (`RootMeasuredLocations.allowedRoots`: `/private/var`,
   `/private/tmp`, `/Library`, `/System/Library`, the Data volume's root, `/opt`; never a home folder), sizes and purgeable bytes
   only. It accepts only clients that satisfy a code-signing requirement passed on its command line.

---

## 5. Debloat

**The design rule: verify the effect, not the setting.** On the research Mac the analytics toggle was off, yet a full analytics
submission succeeded that day; Siri was off, one launchd label disabled, and two Siri processes still ran under other labels. A
control says "not controllable here" rather than "pass", and an applied control is `pending` until the logout or reboot it needs has
happened, `ineffective` only if the process runs after that boundary. A KeepAlive respawn is not a failure.

### The mechanisms, and what held with SIP on

| Mechanism | Result (26B5091g) |
|---|---|
| Plain preference, written as System Settings writes it (`CFPreferences` on the owning domain, then its change notification) | **Holds**, unless the owner reconciles it back (see the advertising identifier). |
| Configuration profile, approved by the user, one profile for every policy | **Holds**: all 23 keys forced once approved, without MDM, across a reboot. |
| Feature-flag override (`/Library/Preferences/FeatureFlags/Domain/<Domain>.plist`) | **Holds after a reboot**; the value is computed at boot. |
| `tailspin disable`, crash-dialog settings | **Hold** (tailspin across a reboot). |
| `launchctl disable` of Apple services, system and user domains | **Does not survive a boot**: launchd cleared every override (`Clearing enabled state`) and every targeted daemon ran again. With SIP on, `bootout` is refused (error 150). Owner-enforced overrides persist, because the owning daemon re-sets them each boot. A published tool that does the same for 296 labels states the same limit. |
| SIP off, or sealed-volume changes | Excluded from the product. |

### The twelve controls

The catalog has fifteen entries; on one build twelve are shown, because two are retired (Generative search indexing and Apple
Intelligence features, below) and analytics is one entry for release builds (a plain
setting) and another for beta builds (a profile policy). On a beta: two feature flags, two plain preferences (Personalized ads,
Improve Siri & Dictation), tailspin, the crash dialog and six profile policies; on a release build the analytics preference
replaces one of the policies.

- **Feature flags.** `IntelligenceFlow/Campo = false` stops the Siri AI app (launchd does not load `com.apple.campo`) after a
  reboot. **Side effect, measured:** with the flag on, classic Spotlight is disabled; with it off, classic Spotlight loads in its
  place, so the override swaps the search UI back to classic rather than removing search. `Tamale/DaemonEnabled` stops
  `visualintelligenced`; `GenerativeLearningPlatform` flags stop `hybridsearchd`. Their other effects on neighbouring daemons were
  not visible (several on-demand services were spawned later "because xpc event"). **Unknown:** whether the override file (on the
  Data volume) survives an OS update, and release builds.
- **Tailspin.** Disabling frees a trace buffer of about 100 MB (wired memory dropped about that much; one sample before, so
  **inferred**) and stays off across a reboot. `tailspin info` records which app made the change.
- **Crash reporter.** Four launchd overrides survived a reboot, but `ReportCrash` and `ReportCrash.Root` run anyway because launchd
  marks them `force-enabled`. Crash reports cannot be switched off this way; the control is narrowed to the crash dialog and GPU
  restart reporting.
- **Analytics.** On a seed build the `AutoSubmit` preference alone does not stop submission (`optIn: IN`, uploads of about 70 kB and
  22 kB). A user-approved profile forcing `AutoSubmit` and `allowDiagnosticSubmission` makes SubmitDiagInfo decide `optIn: OUT`,
  and nothing is uploaded (two roughly 480-byte check-ins an hour). **Measured trap:** an opt-out run with nothing to send still
  records a successful full submission, so `LastFullSubmissionSuccess` is not evidence; the logged decision is. Which of the two
  keys is decisive was not isolated. On release builds the Settings switch is honoured; that control, `telemetry.diagnostics`, is
  the only one still marked "Not tested".
- **Corrected verification, 2026-10-18.** The fallback still used `LastFullSubmissionSuccess` as failure evidence when no logged
  decision was found, contradicting the measured check-in behavior above. On 26B5112a this Mac returned no matching decisions from
  three days of logs, including info-level messages; the screenshot's timestamp alone cannot establish an upload. Neither a new
  success timestamp nor silence now proves failure/success. A readable post-change IN/OUT decision remains authoritative; absent
  decisions are pending initially, then unverified. The UI translates that state rather than appending raw English CLI diagnostics.
- **Policies from ManagedConfiguration restriction keys** (not marked supervised-only): advertising identifier, on-device dictation
  and translation, Spotlight internet results, twelve Apple Intelligence feature keys, Game Center, News (an earlier catalog also
  forced `allowSiriServerLogging`; Improve Siri & Dictation is now a plain preference, written with its change notification,
  self-tested on 26B5091g). All
  read back forced and the controls read debloated. **Effects measured only in part:** with News restricted, `open -a News` fails
  but the app still launches by path (hidden, not blocked); with Game Center restricted, `gamed` still launches on demand and
  talks to Apple (the effect is in the UI or `gamed`'s own logic, unmeasured). The behavioural effect of the other keys, Apple
  Intelligence's among them, is unmeasured here because Apple Intelligence is ineligible on the research Mac. Several keys apply
  only to supervised or MDM Macs on paper; each was treated as unproven until measured.
- **Generative search indexing, retired (2026-10-12), breaks Mail search.** **Measured** on 26B5101f (issue #6): with its three
  `GenerativeLearningPlatform` flags off, every Mail search first asks `MailSearchClient`, which logs "Not ready since Generative
  Search feature flags are disabled", then falls back to Mail's Spotlight donations (22,000 of about 70,000 headers and 830 bodies
  donated here). A search for a name found 0 messages, with Apple Intelligence off and with it on. With the flags removed and a
  restart, the same search found 59. `hybridsearchd` is disabled only when all three flags are off, so the Mail flag cannot be
  kept on while the daemon stays stopped. The control is retired with `undoesWhenRetired`: wherever it is still applied, MacSpace
  switches it back on by itself (with the helper, once per run of the app, at launch and from the watch). The app shows nothing
  about it; the release notes do. It takes effect after a restart.
  **Measured, 1.0.3's restore was incomplete:** switching it back on removed `MailIndexing` and `ObservationIndexing` but left
  `PlatformDaemons = false` in `/Library/Preferences/FeatureFlags/Domain/GenerativeLearningPlatform.plist`, because 26B5101f no
  longer declares that flag and it read as unavailable. Harmless (the daemon runs once any flag is on, and Mail search worked), but
  MacSpace's own leftover. A flag macOS no longer declares is now read from the override file while an override is there, so the
  restore removes it, and the automatic switch-back cleans up Macs that kept it.
- **Apple Intelligence features, retired (2026-10-12).** Apple's device-management schema (`com.apple.applicationaccess.yaml`)
  lists 9 of its 12 keys as deprecated on macOS since 26.4, `allowImageWand` and `allowVisualIntelligenceSummary` as not applicable
  on macOS, and `allowPhotorealisticImageGeneration` not at all; their effect could not be measured here. The Siri module's Apple
  Intelligence switch, which was measured, makes macOS treat Apple Intelligence as unavailable, so the features go with it. The
  control stays in the catalog marked `retired`: it is never applied again, and the page lists it only on a Mac where it is still
  applied, so switching it back on removes its policies from the profile.
- **The advertising identifier is not a setting on macOS.** `com.apple.AdLib allowIdentifierForAdvertising` came back to 1 three
  times in two days while Personalized ads stayed off. `adprivacyd`'s `com.apple.ap.adprivacyd.reconcile` XPC activity runs roughly
  daily (11:16 on 10-04 and 10-05) and when profiles change, and the plist changed three seconds after it began. LimitAdTracking
  says why: "Cross App Tracking is not currently persisted on this platform", and the value is reconciled with the Apple Account.
  Only the `allowIdentifierForAdvertising` restriction in a profile holds, so the control is a policy.
- **Measured and left out:** nine launchd controls (SIP resets them at boot), and ten whose effect could not be confirmed.

### Configuration profiles

- **One profile.** Profiles named after the set of policies they held piled up in Device Management (three at once). There is
  now one, `com.macspace.policies`, holding every policy switched off; staging it again with the same identifier and approving it
  replaces the installed one, its UUID following its content. Switching the last policy back on removes it through the helper; the
  profiles of earlier versions are removed through the helper once the one profile holds everything they did. Removing a profile
  un-forces its keys at once (diagnostics were unforced for about a minute between two profiles).
- Installed profiles and their values are read with `system_profiler SPConfigurationProfileDataType -json`, without root.
- **Measured, reading forced values.** A long-running app's `CFPreferencesAppValueIsForced` kept the values from before a profile
  was approved (the page said "waiting" while a fresh CLI process read every policy on). Forced values are read from
  `/Library/Managed Preferences` (per user, then for the device) on every read.
- **Not yet watched end to end:** the full approve-and-clean-up round on another Mac.

---

## 6. Open questions

- Does a notarized, stapled build register the helper without any manual step on a **clean** Mac? A notarized build's signature,
  stapled ticket and Gatekeeper acceptance, and the helper installed and answering from it, were verified on the development Mac
  (2026-10-03); a clean macOS 27 VM has not been used yet.
- Does a Sparkle update leave the helper reachable? The self-repair covers it in theory; it has not been exercised through a real
  update.
- Does Remove Downloads work for iCloud Drive and each File Provider app, and how fast for thousands of files?
- Why does Settings count the 25 GB restore image as 21.9 GB, and Apple Intelligence at 19.89 GB when releasing the models frees
  about 10 GB?
- Which 3.9 GB of the Data volume does Settings count as macOS? What is the 0.62 GB left after the clone ledger?
- Which Settings are behind Siri voices, dictation, dictionaries and the developer documentation asset?
- Do the category rules hold on a Mac with different apps, with iCloud Desktop & Documents on, or on another build?
- Is the document-version freeze safe while an app is saving?
- Do feature-flag overrides survive an OS update? Do profile policies behave the same on another Mac and with Apple Intelligence
  eligible?
- Does deleting backups on a backup disk need Full Disk Access for the helper, as `tmutil`'s man page says? (Needs a Mac with a
  backup disk.)
- Does the Apple Intelligence off-switch hold online for days, and does a Siri re-enable or a language resync silently restore the
  match?
- Do the deleted accounts' subscription rows ever expire on their own?
- How long does a released Siri, speech or language-data owner stay released across a reboot, a log out and in, and an OS update?
  Only a five-minute window was observed after the clean, and the later check found the rows back.
- Does the Spatial Photos release survive a restart, revert cleanly, and free blocks that APFS clones keep allocated?
- Which requester keeps the remaining ~16 MiB of speech recognition, and does any family have a requester that is verifiably off
  for good?
- Do the five Phone feature overrides survive an OS update, and what do the Phone and FaceTime screens show with them off?

## 7. The original research

MacSpace started on 20 September 2026 as a research project, not an app, and stayed one for ten days. This section is a short
account of what that research set out to do, what it found, what failed, and which parts became the app. The research itself
(about 110 numbered checkpoints, more than 200 result files, forensic notes and small experiment programs) lives in the maintainer's
private repository. The findings that grew out of it are consolidated in sections 1 to 6; this section covers the work before them
and why the app is shaped the way it is.

Builds: macOS 27.2 build 26B5086k at first, then 26B5091g from the update on 23 September. One Apple Silicon Mac, not enrolled in MDM.
Apple Intelligence's eligibility depends on the account's Siri and system languages, so what held here may not on a Mac with other
languages. System Integrity Protection (SIP) was **off** for part of the work and **on** again from 28 September; the subsections
below say which.

### Where it started

The first goal was a storage forensics tool: explain the space macOS itself uses (APFS volume groups, Preboot, Recovery, snapshots,
cryptex mounts, update residue, system-managed assets) instead of being "another cache cleaner". Seven principles were written down
on day one and survived to the app:

1. Explain before deleting; every reclaimable byte needs a reason.
2. Never remove something a live installation, boot policy or active asset still references.
3. Read-only by default; destructive steps sit behind explicit gates and independent validation.
4. The normal product must not require disabling SIP.
5. Everything is version-aware: classifiers record the macOS build they were validated on.
6. Cleaning and debloating are different jobs. Evicting bytes is not durable unless the trigger that brings them back is understood.
7. Never promise persistence without a controlled before/after measurement.

The tooling was layered the same way: read-only forensics first, then a privileged helper, then only supported mutation. Direct
modification of the sealed system volume was excluded from the product.

### Storage forensics (checkpoints 1–16)

**Measured.**
- A read-only scanner could model the APFS container, the System and Data volume group, the sealed boot snapshot, other snapshots
  and Preboot objects, and it avoided double-counting mounted cryptex images (their usage and their MobileAsset backing are two
  views of the same bytes).
- "Reclaimable" had to stay unknown until unique ownership of the blocks could be established. APFS clones and shared extents make
  logical size a poor guide.
- A census of the system asset store (`/System/Library/AssetsV2`, 8.6 GB in 40 families on 26B5091g) became the base for everything
  later. Assets with no catalog reference, or marked as never collected, were treated as investigation signals, never as permission
  to delete.
- **One supported removal worked and was the only mutation the early tool allowed:** the optional Metal Toolchain through
  `xcodebuild -deleteComponent metalToolchain`, which freed 903.9 MB and is reversible with `-downloadComponent`. Developer
  documentation (1.73 GB) cannot be removed that way; Xcode's own settings are the route.
- With SIP on, six asset families are unreadable even with Full Disk Access (they carry the `restricted` flag, among them the
  Foundation Model families). Full Disk Access is still required for the Apple Intelligence eligibility state. The detector for that
  permission had to be changed: the user TCC database stays closed even with the permission, so a protected file that exists on
  every Mac is probed instead.

### The Apple Intelligence model (checkpoints 17–112)

This was the bulk of the research. On macOS 27 the on-device Foundation Model, a 3B-parameter base model plus adapters (about 12 GB
for the family), is downloaded automatically for users whose Siri and system languages match. The question: can a user who does not
want Apple Intelligence get the space back, **and keep it**?

#### What failed (all measured)

- **Deleting the files is not prevention.** The model reappeared after being removed, through the pipeline ModelCatalog → the Unified
  Asset Framework (`assetsubscriptiond`) → MobileAsset. At least one controlled absence window did not trigger immediate recreation,
  but owner-side requests later rebuilt the configuration and re-downloaded it.
- **Direct deletion hit protected boundaries.** Part of the asset could not be removed even by Apple's own `rm`, with SIP off:
  `Read-only file system`, `Resource busy`, and an `EPERM` in graft handling, about 6 GB of it. Simple explanations (live mount, open
  file, snapshot) were ruled out. An early "SIP-restricted" diagnosis was itself disproved with SIP off and then corrected (a
  false positive worth remembering: always test the explanation against a control).
- **Suppressing the requester rows failed.** The two live requesters were concrete rows in the subscription database, and removing
  exactly those rows (reversibly, with SQLite triggers as guards) held until a reboot, after which the rows were recreated and the
  model owned again.
- **Patching the configuration failed.** Changing the AutoSet configuration copies and quarantining assets did not stop
  reacquisition; the daemon restored the 177-entry configuration and downloads recurred.
- **Boot ordering defeated the guards.** After a cold boot with guards intact and 12 target rows absent, the configuration already
  contained the target. A later daemon restart rebuilt it without the target. The log ordering showed the configuration written
  before the subscription store finished persisting. Why that batch included the target was never identified.
- **The assumed global opt-out does not exist on that build.** Static analysis of the shared-cache frameworks showed the Swift
  `isOptedIn` getter returns a constant true, and the availability reporter derives its "toggle" field from the use case's
  unavailability reasons. Siri off and the reported opt-out flag are therefore not stop-download signals.
- **Restrictions did not help.** A Screen Time / Writing Assistance restriction left the 177-selector configuration and the
  target selector byte-identical.
- **A private API is closed to third parties.** Changing the Siri language through the private assistant settings interface is
  rejected by the daemon for lack of a private entitlement.

#### What worked (measured)

- **Make the Siri language differ from the system language.** One supported user action, Siri's language from Portuguese (Brazil)
  to English (US) with the system language unchanged, made Apple Intelligence unavailable. ModelCatalog dropped from 23 decisions
  to 6, the configuration fell from 177 selectors to 2 (none for the model), and MobileAsset released and evicted the model on its
  own, including the part direct deletion could not remove, with no guard, patch or deletion involved. Free space rose from about
  12 GiB to 19 GB.
- **It held** across a cold boot, two hours online and an OS update (26B5086k to 26B5091g). Remaining unknowns: online idle over
  days, and whether re-enabling Siri or a resync of the language silently restores the match.
- **An ordinary app can apply it.** Writing the Siri language preference and posting a Darwin notification works in both directions
  within about 10 ms and re-evaluates eligibility. Whether the change syncs to other devices through iCloud was not measured.
- **Later, in the app's own development**, the release of models that stay installed after the switch was automated: sending the
  account through available → unavailable releases the locks, and macOS's own purge (CacheDelete) then deletes what is unlocked,
  12.04 GB in 4.6 s as a normal user. Models are shared across accounts, so one eligible account, or a deleted account whose
  subscriptions remain, keeps them; a restart does not clear those, and removing the orphaned rows (with a backup, in one
  transaction) does.

#### Not resolved

Which boot-time input selects the model into the configuration; which one of the net-new subscriptions causes it; the condition
logic mapping eligibility, language and opt-out to each decision; what produces the "toggle enabled" availability field. A planned
network-level or file-level gate (a Network Extension filter, Endpoint Security) was designed and never built, because the
Siri-language method made it unnecessary for this asset.

### Debloat (checkpoints 17–18 and 2026-09-25 to 28)

An evaluation on 25 September asked how the Apple Intelligence approach could grow into a general debloat tool. Its baseline on the
research Mac (SIP off at the time) set the design rule: **verify the effect, not the setting.**

- The analytics toggle was off, yet a full analytics submission succeeded that day: on a seed build submission continues regardless.
  The tool must say "not controllable here", not "pass".
- Siri was off, one launchd label was disabled, and two Siri processes still ran under other labels.
- About 40 analytics and intelligence processes were running, and a partial opt-out existed (personalised ads off, advertising
  identifier on).

A ladder of mechanisms, most to least supported, framed the work: public setting, configuration profile, launchd override, private
surface, observation only for the network, and (excluded) SIP-off or sealed-volume changes.

**Experiments with SIP on (28 September, one shared reboot), measured:**
- **Feature-flag override works.** A root-owned override file turned the Siri AI agent off after a reboot (launchd did not load it;
  the app did not run). Side effect: with the flag off, classic Spotlight loads in its place. The same mechanism gates a few other
  daemons. Survival across an OS update was unknown at the time.
- **launchd overrides do not survive.** `launchctl disable` for ten Apple services, in the system and user domains, was cleared at
  the next boot; every targeted daemon was running again. With SIP on, owner services re-set their own overrides. The nine launchd
  controls proposed earlier were dropped for this reason. A published tool that does the same (296 labels) states the same limit.
- **Configuration profiles** carry the privacy policies that stayed (diagnostics, ads, advertising identifier, Siri server logging,
  on-device dictation, Spotlight internet results, Apple Intelligence features, Game Center, News). They need the user to approve
  the profile in System Settings, and several keys only apply to supervised or MDM Macs, so each was treated as unproven until
  measured.
- The `tailspin` trace buffer stays off across a reboot with SIP on. The crash reporter does not stop: launchd keeps `ReportCrash`
  force-enabled and ignores the override, so only the crash dialog and GPU-restart reporting became a control.
- **A profile stops analytics where the setting does not.** On a prerelease build the Share Mac Analytics preference alone left
  submission running (an upload of about 70 kB); a user-approved profile forcing both keys made the submission daemon decide to
  opt out and upload nothing, across a reboot and a day of hourly runs. The success timestamp keeps advancing even for an opt-out
  run, so the logged decision, not the timestamp, is the evidence.
- **A restriction is not always a block.** With News restricted the app still launches by path; with Game Center restricted its
  daemon still starts on demand. The advertising identifier was switched back on by macOS about once a day (see
  [section 5](#5-debloat)), which is why Debloat watches and re-applies.

The effect check also had to learn that a respawn by KeepAlive is not a failure: an applied control is `pending` until the required
logout or reboot has happened, and only `ineffective` if the process runs after that boundary.

### The product focus that followed (29 September)

After the experiments the scope was cut to three things that hold with SIP on: **clean System Data** (explain every large item,
clean only what regenerates, report space actually freed on the volume), **guide manual cleanup** of third-party apps, and
**debloat** with the mechanisms above plus the Apple Intelligence switch. Everything else in the research, including the reverse
engineering of ModelCatalog internals, stayed research.

### What carried into this repository

| Research result | In the app |
|---|---|
| Principles 1–7, effect-based verification | Every control and cleanup reports what was measured; untested controls are labelled "Not tested". Nothing is gated by macOS build. |
| Siri-language method, preference write plus notification, round trip | Siri & Apple Intelligence module: the off-switch, the watcher, the release flow. |
| Orphaned subscription rows, shared models, CacheDelete purge | The release flow's blockers and the "remove leftover models" step. |
| Metal Toolchain removal, asset census, Full Disk Access findings | System Data's asset families and the permission probe. |
| System Data investigations (clones, unfinished downloads, version store) | System Data module and the category rules in sections 1 and 2. |
| Debloat engine: probe, apply, revert, verify, undo journal | Debloat module with 14 controls (profile policies, feature flags, tailspin, crash reporter). |
| Privileged helper over XPC, designed in the first architecture | The signed helper and its install and self-repair logic. |

Left behind on purpose: the guard, patch and quarantine tooling, the ModelCatalog and UAF reverse engineering, the 60-odd
checkpoint-specific commands, the launchd controls SIP resets, and the controls whose effect could not be confirmed.

### Lessons about the method

- **Test the explanation against a control** before building on it (the SIP-restricted diagnosis, the opt-out flag).
- **Stamp every result** with build, boot, SIP state and a time window; a later OS update invalidated more than one conclusion.
- **Prefer owner-managed paths** (a supported setting that makes the owner release something) over fighting protections.
- **Make every change reversible and recorded**, with a root-only recovery report, before touching Apple's databases.
- **Say "observing" until a gate is passed**, not "protected" or "cleaned".
- Reading a log line is not proving causation: several chains were strongly supported but never proved.

## Superseded readings

Earlier notes that later measurements corrected, so nobody rebuilds on them.

| Earlier reading | Replaced by |
|---|---|
| Settings' macOS ≈ System volume + Preboot + `AssetsV2` (32.4 against 31.06 GB) | Every volume but Data, plus the Recovery container, plus about 3.9 GB of the Data volume (section 1). |
| Settings' Applications ≈ `/Applications` + both `Application Support` folders | Bundles + third-party containers and group containers; support folders are not counted. |
| Apps' support files are System Data (**inferred**) | Confirmed for `~/Library/Application Support`; the decoded rules say anything unclaimed is. |
| Every Spotlight-indexed app anywhere belongs to Applications (**inferred**) | The Applications extension searches home, `/Applications`, and `/System/Applications`; globally indexed helpers under `/Library` and `/usr/local` are outside those scopes. Documents also excludes unindexed application bundles while walking. Rechecked 2026-10-17. |
| MacSpace shows more than Settings (51 against 44.5 GB) because Settings over-counts Apple Intelligence (**inferred**) | Partly true while the models are installed (19.89 against 11.35 GB), but the larger gaps were the prepared update counted as System Data, CloudStorage (12 GB), apps outside `/Applications` and clones. MacSpace now computes Settings' remainder. |
| System Data total within 0.9 GB of Settings (42.83 against 41.95) | Replaced by the remainder rule; a "Not identified" block shows what the breakdown leaves out. |
| Command Line Tools 1.31–1.41 GB against Settings' 1.42 | The same 1.42 GB on the same build. |
| Deleting a clone or a code-signing copy frees its `du` size | It frees nothing when it shares blocks; clones are sized once. |
| "No notarized build exists yet" | A notarized build was made and checked on 2026-10-03; only the clean-Mac check is open. |
| Opening a folder like the Foundation Model folders to measure them | Not possible even with Full Disk Access (SIP `restricted`). |
| Siri, speech and language-data assets are held by ModelCatalog conditions, or by database rows that can be deleted | By client daemons' own requests (the broker, Telephony, embedded speech, ProofReader, DictionaryServices, the keyboard service). The usage rows come back, and only Spatial Photos is a ModelCatalog condition (Asset owners). |
| A release survives only while nothing asks again | A clean can be undone by normal system activity within hours; the five-minute check proved a clean-now, not durability (Asset owners). |
| The 2026-10-14 purge was undone by a reboot | Wrong: the three families together were 0.16 GB smaller than after the purge. Siri Understanding gave up 1.13 GB while the others took back 0.96 GB, and the reacquisition (11:23) came 27 minutes before the reboot (11:50). |
| Siri off, or `optedOutBuddy`, stops the model downloads | The opt-in getter is a constant `true`; neither signal is read (Asset owners). |
| Clearing the Siri session language is a harmless reset | macOS falls back to the system language and recreates demand for it (Asset owners). |
| Spanish growth came from an unknown source that regenerates at boot | The app under test had changed the Siri language to Spanish; editing the morphun list only removed the list entry. |
| The advertising identifier is a plain setting | A policy: the owner reconciles it back (section 5). |
| `launchctl disable` for Apple services as a debloat mechanism | Does not survive a boot with SIP on. |
