# Research

What was learned about macOS while building MacSpace, and how sure we are. This is the consolidated version: it replaces the
dated notes this file used to be, and folds in the findings of the research that came before the app
([Original-Research.md](Original-Research.md) tells that story). Where a later measurement overturned an earlier reading, the
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
6. **Deleting the models is not prevention.** What works is the owner's own path: a Siri language that differs from the system
   language. Everything cleverer failed ([Original-Research.md](Original-Research.md)).
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
- **Applications** is app bundles (the whole `/Applications` folder, plus apps Spotlight has indexed elsewhere), third-party
  containers and third-party group containers, Safari's container, and Apple's team-prefixed group containers
  (`PTN9T2S29T.com.apple.videoProApps`); only `group.com.apple.…` stays with macOS. Apps' support folders in
  `~/Library/Application Support` are **not** counted (Firefox: 536 MB in Settings' list is its bundle; its 2.31 GB profile is not
  in it).
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

- **Measured: apps elsewhere.** Spotlight indexes 2.16 GB of app bundles outside `/Applications` (Autodesk installers' helper
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
  measurable, because it shared its blocks with the app; Settings counts it at full size in System Data. Such clones are shown as
  managed by macOS with an expected reclaim of 0.
- **Measured: why total and breakdown differ.** Nothing has to list what System Data holds, because the total is Settings'
  remainder. The page's items are only the breakdown, and what they leave out of the total is a "Not identified" block, so a rule
  that goes wrong shows as a measured amount instead of a wrong total.

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

**Measured, not System Data:** Time Machine's local snapshots do not exist on this Mac; the only snapshot is the sealed
OS-update snapshot on the System volume (required, not purgeable). How much local snapshots hold elsewhere is **unmeasured**.

---

## 2. What can be reclaimed

### System assets (`/System/Library/AssetsV2`)

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
  reporting it. Purging freed 2.1 MB at urgency 1, 2.1 MB at 2, 95.7 MB at 3 and nothing at 4. Not in the app. (The caches
  themselves cannot be read from here: `~/Library/Containers` is closed to a terminal.)
- **Measured, what `fspurgeable_document` is.** 21.15 GB, up from 9.96 GB the same morning: OneDrive's files. File Provider apps
  flag files they downloaded and keep in the cloud as purgeable (22.94 GB in 8,065 files of one cloud folder, nothing flagged in
  Downloads, Documents or Desktop). macOS may delete these local copies; they download again when opened. Other System Files names
  the block after each cloud folder found, whichever provider it is, and skips folders still only in the cloud (`SF_DATALESS`) so
  the scan never makes a provider fetch anything.
- **Measured and inferred, removing cloud downloads on request.** Foundation sees the provider's files as cloud items
  (`isUbiquitousItem` 1, downloading status current, `ubiquitousItemIsUploaded` 1, on one file), so the public
  `FileManager.evictUbiquitousItem(at:)`, Finder's Free Up Space, is the way to remove a local copy, for iCloud Drive and every
  File Provider app alike. `fileproviderctl` and `brctl` have no evict command on this build. Remove Downloads takes only files APFS
  flags purgeable (Always Keep on This Device files are not), uploaded, not uploading and without conflicts. Removing 21 GB of
  downloads took Settings' System Data from 44.46 to 32.3 GB and used space from 203.24 to 188.81 GB. **Not yet run from the app:**
  whether every provider answers an eviction, and how fast for 8,000 files, is unknown. Purging `fspurgeable_document` would do
  it for every provider at once, unasked; not offered.

### Caches in Application Support

**Measured.** Chromium and Electron apps keep their HTTP cache, compiled scripts and GPU shaders in their Application Support
folder, not in `~/Library/Caches`: `Cache`, `Code Cache`, `GPUCache`, `Dawn*Cache` (and VS Code's `CachedData`), 326 MB on one Mac
(one app 296 MB). A profile folder is recognised by its `Network Persistent State` or `Local State` file, so a folder named Cache in
any other app is never taken. Their storage (Local Storage, IndexedDB, Service Worker) holds data and is left alone. System Data
cleans these while the app is closed and takes them off the app's own figure. `~/Library/Caches` in general is listed, not
cleaned.

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

### Checked and not offered

- **The prepared macOS update (10.7 GB):** installs at the next restart and macOS removes it then; nothing safe deletes it before.
- **Unified log (2.48 GB):** `log erase --all` removes the diagnostic history. Not offered.
- **Homebrew (2.9 GB):** most is the installed packages (401 MB Cellar, 37 MB downloads). `brew cleanup` removes only old versions
  and downloads and stopped on an error in a third-party tap. **Inferred.**
- **Swap, power log, symbolication cache:** in use or rotated by macOS. **Inferred.**
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

The reasons are the failed alternatives, all **measured** and told in [Original-Research.md](Original-Research.md): deleting the
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

### The fourteen controls

The catalog has fifteen entries; on one build fourteen are shown, because analytics is one entry for release builds (a plain
setting) and another for beta builds (a profile policy). On a beta: three feature flags, two plain preferences (Personalized ads,
Improve Siri & Dictation), tailspin, the crash dialog and seven profile policies; on a release build the analytics preference
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
- **Policies from ManagedConfiguration restriction keys** (not marked supervised-only): advertising identifier, on-device dictation
  and translation, Spotlight internet results, twelve Apple Intelligence feature keys, Game Center, News (an earlier catalog also
  forced `allowSiriServerLogging`; Improve Siri & Dictation is now a plain preference, written with its change notification,
  self-tested on 26B5091g). All
  read back forced and the controls read debloated. **Effects measured only in part:** with News restricted, `open -a News` fails
  but the app still launches by path (hidden, not blocked); with Game Center restricted, `gamed` still launches on demand and
  talks to Apple (the effect is in the UI or `gamed`'s own logic, unmeasured). The behavioural effect of the other keys, Apple
  Intelligence's among them, is unmeasured here because Apple Intelligence is ineligible on the research Mac. Several keys apply
  only to supervised or MDM Macs on paper; each was treated as unproven until measured.
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
- How much do Time Machine's local snapshots hold, and does Settings count them as System Data? (Needs root and a Mac that has them.)
- Does the Apple Intelligence off-switch hold online for days, and does a Siri re-enable or a language resync silently restore the
  match?
- Do the deleted accounts' subscription rows ever expire on their own?

## Superseded readings

Earlier notes that later measurements corrected, so nobody rebuilds on them.

| Earlier reading | Replaced by |
|---|---|
| Settings' macOS ≈ System volume + Preboot + `AssetsV2` (32.4 against 31.06 GB) | Every volume but Data, plus the Recovery container, plus about 3.9 GB of the Data volume (section 1). |
| Settings' Applications ≈ `/Applications` + both `Application Support` folders | Bundles + third-party containers and group containers; support folders are not counted. |
| Apps' support files are System Data (**inferred**) | Confirmed for `~/Library/Application Support`; the decoded rules say anything unclaimed is. |
| MacSpace shows more than Settings (51 against 44.5 GB) because Settings over-counts Apple Intelligence (**inferred**) | Partly true while the models are installed (19.89 against 11.35 GB), but the larger gaps were the prepared update counted as System Data, CloudStorage (12 GB), apps outside `/Applications` and clones. MacSpace now computes Settings' remainder. |
| System Data total within 0.9 GB of Settings (42.83 against 41.95) | Replaced by the remainder rule; a "Not identified" block shows what the breakdown leaves out. |
| Command Line Tools 1.31–1.41 GB against Settings' 1.42 | The same 1.42 GB on the same build. |
| Deleting a clone or a code-signing copy frees its `du` size | It frees nothing when it shares blocks; clones are sized once. |
| "No notarized build exists yet" | A notarized build was made and checked on 2026-10-03; only the clean-Mac check is open. |
| Opening a folder like the Foundation Model folders to measure them | Not possible even with Full Disk Access (SIP `restricted`). |
| The advertising identifier is a plain setting | A policy: the owner reconciles it back (section 5). |
| `launchctl disable` for Apple services as a debloat mechanism | Does not survive a boot with SIP on. |
