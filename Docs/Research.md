# Research notes

What was measured about macOS while building MacSpace, and how sure we are. Every claim carries one of three labels:

- **Measured** – observed on a real Mac or VM, with numbers.
- **Inferred** – follows from measurements but was not tested directly.
- **Unverified** – a working assumption; treat it as a question.

Where, and on what: macOS 27 build 26B5091g (Apple Silicon, SIP on) for almost everything; macOS 27.0.1 (26A434) in a virtual machine
for the helper installation and Apple Intelligence checks. Other builds may differ. Private Apple interfaces are used in a few places
and every one of them is guarded (see [CacheDelete](#cachedelete)).

- **Measured – after the OneDrive downloads were removed (2026-10-06, 18:00).** Settings: used 188.68 GB = Applications 97.87 +
  Developer 1.42 + Documents 8.77 + Photos, Mail, Messages, Music 0.88 + Other Users 0.0014 + macOS 47.45 + System Data 32.3 (no
  Apple Intelligence row with it off). Volumes: System 18.58, Preboot 21.94 (the running system and the 10.70 GB prepared update),
  Recovery 3.04, Data 145.44, VM 0. **Settings' macOS is every volume but Data, plus about 3.9 GB of the Data volume**, so the
  prepared update is macOS there, not System Data; MacSpace had counted it in System Data (now left out of the total, still listed).
  Removing 21 GB of OneDrive downloads took Settings' System Data from 44.46 to 32.3 GB and used space from 203.24 to 188.81 GB: about
  12 GB of those downloads had been in Settings' System Data, not Documents. MacSpace never counted them, which the Apple Intelligence
  over-count above had hidden.
- **Measured – what is left: MacSpace 38.5 GB without the update against 32.3.** Settings' Applications (97.87) is 2.48 GB more than
  app bundles (24.18) + third-party containers (65.19, of which UTM's virtual machine 64.57) + third-party group containers (6.02).
  **Measured – not apps' support folders:** Firefox is 536 MB in Settings' Applications list, its bundle alone; its 2.31 GB profile
  in Application Support is not counted with it. **Measured – apps elsewhere:** Spotlight indexes 2.16 GB of app bundles outside
  /Applications (Autodesk installers' helper apps in `/Library/Application Support`, Claude Code's own `claude.app` in its
  Application Support folder, the .NET runtimes in `/usr/local/share/dotnet`, development builds). **Inferred:** Settings lists every
  app Spotlight has indexed under Applications, wherever it is; about 2.0 GB of them sat in folders MacSpace counted as System Data,
  and are now taken off them (`SystemDataItem.appBundleBytes`). The other 3.9 GB are the Data-volume part of Settings' macOS;
  **unverified** which, the system assets (`AssetsV2`, 9.0 GB, of which MacSoftwareUpdate 1.39) or the unified log (2.51) and the
  Spotlight index the likeliest.

### How System Settings computes its categories (decoded 2026-10-06, macOS 27.2 26B5091g)

**Measured – from the code.** Read from `StorageManagementService` (`StorageManagement.framework/PlugIns`, the per-user agent
`com.apple.StorageManagement.Service`) and the Storage pane (`/System/Library/ExtensionKit/Extensions/Storage.appex`), disassembled
with selector stubs and CFStrings resolved. Nothing here can be asked from outside: the service answers only clients with
`com.apple.storage-data`, and the pane's size messages are debug level (never in the log).

- **System Data is a remainder:** `other = volume used − macOS − Σ every category item` (`-[STMStorageController
  updateSystemSidebarItemSubtitle]`, then `updateSystemSize:otherSize:`).
- **Used** for the Data volume: `in use − CacheDelete purgeable + system + hidden` (`-[SPInfoDiskAPFSVolume updateFreeSpace]`; the
  purgeable figure is CacheDelete's volume dictionary, `CACHE_DELETE_AMOUNT` and the shared-purgeable keys). The pane logs the same
  thing as `available = freespace + purgeableSpace` (class *Essential*): what `volumeAvailableCapacityForImportantUsage` returns.
  Purgeable files therefore leave "used" only as far as CacheDelete's figure goes, not by their APFS flag: of 21 GB of OneDrive
  downloads flagged purgeable, about 14 GB still counted as used.
- **macOS** = every volume of the startup container but Data (System, Preboot with the prepared update, Recovery, Update, VM) **plus
  the separate Recovery container on the same disk** (partition type `Apple_APFS_Recovery`). Measured twice, 1.5 hours apart: Settings
  47.45 GB both times, volumes 44.8266 + 2.6191 = 47.4458 GB. Adding the ISC container would read 47.47; adding the Apple Intelligence
  models (716.7 MB in the macOS detail) would read 48.16, so the models shown in macOS's detail are not added to it. Ruled out on the
  way: CacheDelete's software update reserve (disabled, 0), `/private/var/.overprovisioning_file` (absent).
- **Documents** = the home folder sized without `~/Library`, `~/Applications`, the system Photos library, `~/Music/iTunes/iTunes
  Media/`, `~/Music/Music/Media/`, `~/Movies/Apple TV/Media/`, `~/Movies/TV/Media/`, `~/Movies/TV/TV Library/`, and every path a category
  extension claims; `~/Desktop` and `~/Documents` only when iCloud Desktop & Documents is on (`+[SPInfoDocumentsStorageUsageReporter
  defaultExcludedURLs]`, `operationDidFinish:`). So **anything in `~/Library` that no category claims is System Data**, including
  `~/Library/CloudStorage` (the 12 GB drop above), and the home folder's hidden tool folders (`.claude`, `.config`…) are Documents.
- **Checked against Settings here:** Mail = `~/Library/Mail` (541.0 MB, Settings 541 MB); Messages = `~/Library/Messages/Attachments`
  only (25.1 MB, Settings 25 MB); Music = the library's media folder (58.6 MB, 58.6 MB); Other Users = `/Users/Shared` (1.4 MB, 1.4 MB);
  Developer = the Command Line Tools (1.42 GB, 1.42 GB); Photos = the system library (257.1 MB, Settings 252.7 MB); Documents = home
  9.29 GB without Library, less the Photos library and music media = 8.97 GB, and less the apps Spotlight finds in the home folder
  (development builds, an app in Downloads) about 8.8 GB (Settings 8.77); Applications = app bundles in /Applications 24.18 + apps
  elsewhere 2.16 + third-party containers 65.19 + third-party group containers 6.02 + Safari's container 0.30 = 97.85 GB (Settings 97.87).
- **Measured side by side (19:32, 2026-10-06), MacSpace's `SettingsStorage` against Settings:** Developer 1.42/1.42 GB, Mail 541/541 MB,
  Messages 25.1/25 MB, Music 58.8/58.6 MB, Other Users 1.5/1.4 MB, Photos 258/253.2 MB, Documents 10.18/10.09 GB (Settings' own figure
  is also in `com.apple.StorageManagement.Service` `SPLastDocumentsSize`: 10 089 025 536), used 191.59/191.46 GB. Applications was
  0.92 GB short: Settings counts **the whole `/Applications` folder** (0.77 GB there is beside the app bundles: Autodesk's and Chaos's
  support folders) and Apple's team-prefixed group containers (`PTN9T2S29T.com.apple.videoProApps`, 0.1 GB); only `group.com.apple.…`
  stays with macOS. macOS was 2.26 GB short until the Recovery container was counted.

- **Measured – APFS clones (2026-10-06).** Counted per file, MacSpace's System Data items added up to 1.2 GB more than Settings'
  remainder. Clones are stored once: `~/Library/Application Support` is 5.62 GB per file, 5.15 GB with each clone family once, 4.84 GB
  of blocks no other file shares; the system assets 9.02 / 8.91 / 8.36 GB. Items are now sized with one `CloneLedger` per scan (the
  first file of a family counts in full, later ones only `ATTR_CMNEXT_PRIVATESIZE`): 35.79 → 35.27 GB against a total of 34.65 GB.
  The 0.62 GB left is stated on the page; not yet explained.
- **Decided – a prepared macOS update is not System Data:** it is part of Settings' macOS (Preboot), so it is listed in Other System
  Files ("Waiting to install"), not on the System Data page.

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

### How Settings attributes space (2026-10-06, 26B5091g)

- **Measured.** The categories come from `spaceattributiond` (SpaceAttribution framework). It assigns paths to an *owner* app or
  daemon, from rules in `/System/Library/SpaceAttribution/*.plist` (Spotlight owns `.Spotlight-V100` and `~/Library/Metadata/CoreSpotlight`;
  `logd`, `mobileassetd`, `nsurlsessiond` and others are mapped to owners) and computes System Data last (`calculateSystemDataSize`).
  An app cannot ask it: `SAAppSizer` answers `NSCocoaErrorDomain 4099` without Apple's entitlement, and its cache in
  `/var/db/spaceattribution` is not readable.
- **Measured.** Settings' "used" is capacity minus `volumeAvailableCapacityForImportantUsage`: purgeable space counts as free. With
  plain free space the disk tile said 230.9 GB used against Settings' 203.28; with this key 203.24 (41.87 GB available against 41.83).
- **Measured.** Settings' Applications (97.81 GB) is close to app bundles plus third-party containers and group containers (95.21 GB),
  so apps' support files (`~/Library/Application Support`, 7.72 GB of third-party ones here) are mostly not in it. **Inferred:** they
  are System Data.
- **Measured – what the scan did not cover** (whole Data volume tallied with Full Disk Access against the scan): a prepared macOS update
  on the Preboot volume (`<volume group>/cryptex1/proposed`, 10.70 GB counting each clone family once with `ATTR_CMNEXT_CLONEID`; the
  images come in clone pairs, `os.dmg`/`os.clone.dmg`, and `du` reports double), apps' files for all users in `/Library` (3.06 GB),
  Apple's per-user data in `~/Library` (Biome, DuetExpertCenter, HTTPStorages…, about 1.4 GB), tools' hidden folders in the home folder,
  the rest of `/private/var/db`, system logs and temporary files. The scan now covers whole areas instead of a list from one Mac.
- **Measured.** Files macOS may delete by itself carry the APFS flag `EF_IS_PURGEABLE` (`getattrlist`, `ATTR_CMNEXT_EXT_FLAGS`; file
  attributes come before the extended ones in the buffer). System Data leaves them out, and the purgeable figures CacheDelete reports
  for the Spotlight index and the system assets, as Settings counts them as free space.
- **Inferred – why MacSpace now shows more than Settings (51.06 against 44.46 GB).** System Data is Settings' remainder, so whatever it
  over-counts elsewhere comes off System Data. It counts Apple Intelligence at 19.89 GB where releasing the models gained 9.48 GB on
  the volume (section 3). Rebuilt with the real model size: Data volume 48.2 GB for macOS and System Data, minus 11.35 GB of models,
  plus the other volumes less macOS's own share (System volume 18.58 + the running system's Preboot copy 10.76) gives about 52.4 GB.
  That split also matches Settings' macOS figure (49.2 against 48.52 GB).

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
  call runs in a throwaway child process, where a crash ends that process and is reported as an error. Every build that has the
  functions may use them (no list of builds); a purge first checks, read-only, that the service filter is honoured. The self-test
  (`MacSpaceCli purge-assets --self-test`) remains as a diagnostic. **Measured:** on 26A434 in a VM it found no answer right after
  the VM started and passed later, which is why a self-test result no longer gates anything.
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
  `fspurgeable_document` not tried. Which category the files counted under is not known (System Data was not noted before the
  purge), so the purge is not in System Data: the Other System Files module lists every service macOS counts as purgeable and frees
  `fspurgeable_data`, and the disk tile's "purgeable" is that service's figure. The other two stay CLI-only (`--experiment`).
- **Measured – purging again from the app (2026-10-03, development Mac, urgency 3).** The first purge removed 111 MB; the next
  answered within 0.0013 s with `CACHE_DELETE_AMOUNT = 0` while the estimate at urgency 3 still said 911.7 MB (free space 107.3 GB,
  goal set to free + the 100 GB asked). The estimate lags what CacheDelete will actually remove. The app now asks at urgency 3 and
  then at urgency 4 (critically full), and lists the files as declined, not freeable, only when both remove nothing.
- **Measured – urgency 3 then 4, from the app (2026-10-03, development Mac).** macOS reported 1.08 GB removed and the volume's free
  space rose by 1.08 GB; the estimate at urgency 3 then said 63.5 MB. What urgency 3 declined, urgency 4 removed.

- **Measured – what `fspurgeable_document` is (2026-10-06).** 21.15 GB here, up from 9.96 GB the same morning: OneDrive's files.
  File Provider apps flag the files they downloaded and keep in the cloud as purgeable (22.94 GB in 8,065 files of
  `~/Library/CloudStorage/OneDrive-Pessoal`, nothing flagged in Downloads, Documents or Desktop). macOS may delete these local
  copies; they download again when opened. Other System Files names the block after each cloud folder found, whichever provider it is,
  and skips folders still only in the cloud (`SF_DATALESS`) so the scan never makes a provider fetch anything.

- **Measured and inferred – removing cloud downloads on request (2026-10-06).** Foundation sees OneDrive's files as cloud items
  (`isUbiquitousItem` 1, downloading status current, `ubiquitousItemIsUploaded` 1, measured on one file), so the public
  `FileManager.evictUbiquitousItem(at:)`, Finder's Free Up Space, is the way to remove a local copy, for iCloud Drive and every File
  Provider app alike. `fileproviderctl` and `brctl` have no evict command on this build. Other System Files gives each cloud folder a
  Remove Downloads button: only files APFS flags purgeable (Always Keep on This Device files are not), uploaded, not uploading and
  without conflicts. **Not yet run:** an eviction was not tried here, so whether every provider answers it, and how fast for
  8,000 files, is unknown. Purging `fspurgeable_document` through CacheDelete would do it for every provider at once, unasked;
  not offered.

### Caches in Application Support (2026-10-06, development Mac)

**Measured.** Chromium and Electron apps keep their HTTP cache, compiled scripts and GPU shaders in their Application Support folder,
not in `~/Library/Caches`: `Cache`, `Code Cache`, `GPUCache`, `Dawn*Cache` (and VS Code's `CachedData`), 326 MB here (Claude
296 MB). A profile folder is recognised by its `Network Persistent State` or `Local State` file, so a folder named Cache in any
other app is never taken. Their storage (Local Storage, IndexedDB, Service Worker) holds data and is left alone. System Data cleans
these while the app is closed and takes them off the app's own figure.

### Other candidates checked (2026-10-06, development Mac)

- **App container caches (1.42 GB reported):** purging the service frees almost nothing (above); this terminal cannot read inside
  `~/Library/Containers` to measure the caches directly. Not offered.
- **The prepared macOS update (10.7 GB):** installs at the next restart and macOS removes it then; nothing safe deletes it before.
- **Unified log (2.48 GB):** the helper could run `log erase --all`; it removes the diagnostic history. Not offered.
- **Homebrew:** 37 MB of downloads and 401 MB in the Cellar; `brew cleanup` stops on an error in a third-party tap here.
- **Aerial wallpaper (575 MB):** one video, the one in use.
- **Time Machine local snapshots:** none; only the system's update snapshots.

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
- **Measured (2026-10-04):** the Siri language preference syncs through iCloud to iOS devices on the same Apple Account, so switching
  Apple Intelligence off on the Mac changes the Siri language on the iPhone too, and so does the minute-long model release.
- **Measured – the models' size (2026-10-06).** Settings' "Apple Intelligence" (`aiModelsSize` in its Storage extension) is the size of
  `/System/Library/AssetsV2/com_apple_MobileAsset_UAF_FM_GenerativeModels` and `…_FM_Visual`: 19.89 GB. No app can open those folders,
  not even with Full Disk Access. MobileAsset's records (`AutoAssetDescriptors`) say 11.35 GB; on 2026-10-05 releasing the models
  gained 9.48 GB on the volume with about 0.37 GB kept locked, in line with the records. The models staged for the waiting update
  (`AutoAssetStager`, target 26B5101f) are 0.22 GB. MacSpace shows the records' figure. Why Settings shows 8.5 GB more is
  **unverified** (one guess: the grafted base model counted as image and as mounted content).
- **Measured – Siri's iCloud sync (2026-10-06).** The switch is the `com.apple.Dataclass.Siri` data class among the iCloud account's
  enabled ones in `~/Library/Accounts/Accounts4.sqlite` (Full Disk Access). On macOS 27.2 `ZDATACLASS` has no identifier column: the
  name is a keyed archive of a string in `ZNAME`; the join table is `Z_2ENABLEDDATACLASSES` (`Z_2ENABLEDACCOUNTS`,
  `Z_7ENABLEDDATACLASSES`) and the iCloud account is type `com.apple.account.AppleAccount`. Here the account has 16 classes enabled
  (Mail, Notes, Keychain…) and not Siri, so the page says the sync is off; the earlier reader looked for a `ZIDENTIFIER` column and
  read nothing. `Cloud Sync Enabled` in `com.apple.assistant.backedup` is not the switch.

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
3. **Replacing the app leaves the helper stale.** The old process keeps running and does not know new operations. MacSpace used to
   unregister and register the helper to load the new binary, but **measured (2026-10-04): registering again drops the user's
   approval**, so every new build asked for it again and System Data warned until it was given. Now the helper compares the binary
   on disk with the one it started from, on every new connection and every 20 s, and quits between requests when the app was
   replaced; launchd starts the new binary on the next request. The app re-registers only a helper that never answers.
4. **A dead connection stays dead.** An `NSXPCConnection` that failed once never recovers. The app drops a failed connection and
   retries once on a new one.
5. **Stable signature keeps Full Disk Access.** macOS ties the permission to the code requirement. Local builds are signed with the
   Developer ID identity so the requirement (identifier plus team) is the same on every build; ad-hoc builds change every time and
   lose the grant.
6. The helper itself can read the root-only locations System Data needs (Spotlight index, version history, symbolication cache).
   **Measured** on the development Mac with Full Disk Access granted to the app. It now measures anything under the system's folders
   (`RootMeasuredLocations.allowedRoots`: `/private/var`, `/private/tmp`, `/Library`, `/System/Library`, the Data volume's root, `/opt`;
   never a home folder), sizes and purgeable bytes only.

## 5. Debloat

Fourteen controls ship, each either verified on 26B5091g or enforced by a configuration profile: five direct settings (the Siri AI, Visual Intelligence and generative-indexing feature flags, the tailspin trace buffer, the crash report dialog) and nine profile-enforced policies
(diagnostics, ads, advertising identifier, Siri server logging, on-device dictation, Spotlight internet results, Apple
Intelligence features, Game Center, News). **Measured and left out:** nine launchd controls (SIP resets them at boot), and ten whose effect could
not be confirmed. Profile controls need the user to approve the MacSpace configuration profile in System Settings.

- **Measured – the advertising identifier is not a setting on macOS (2026-10-06).** `com.apple.AdLib allowIdentifierForAdvertising`
  came back to 1 three times in two days (journal, 2026-10-04 to 10-06) while Personalized ads stayed off. LimitAdTracking says why:
  "Cross App Tracking is not currently persisted on this platform", and the value is reconciled with the Apple Account. Only the
  `allowIdentifierForAdvertising` restriction in a profile holds, so the control is a policy again.
- **Measured – one profile (2026-10-06).** Profiles named after the set of policies they held piled up in Device Management (three at
  once). There is now one, `com.macspace.policies`, holding every policy switched off; staging it again with the same identifier and
  approving it replaces the installed one, its UUID following its content. Switching the last policy back on removes it through the
  helper; the profiles of earlier versions are removed through the helper once the one profile holds everything they did.
  Installed profiles and their values are read with `system_profiler SPConfigurationProfileDataType -json`, without root.
- **Measured – reading forced values.** A long-running app's `CFPreferencesAppValueIsForced` kept the values from before a profile was
  approved (the page said "waiting" while a fresh CLI process read every policy on). Forced values are read from
  `/Library/Managed Preferences` (per user, then for the device) on every read.

## 6. Open questions

- Does a notarized, stapled build register the helper without any manual step? (Not tested; no notarized build exists yet.)
- Does a Sparkle update leave the helper reachable? The self-repair covers it in theory; it has not been exercised.
- Why does Settings count the 25 GB restore image as 21.9 GB?
- Which Settings are behind Siri voices, dictation, dictionaries and the developer documentation asset?
- Do the category mappings in section 1 hold on a Mac with different apps?
- Is the document-version freeze safe while an app is saving? The confirmation tells the user to save and close documents first.
- Why does Settings count Apple Intelligence at 19.89 GB when releasing the models frees about 10 GB?
- How much do Time Machine's local snapshots hold, and does Settings count it as System Data? (Not measured; needs root.)
