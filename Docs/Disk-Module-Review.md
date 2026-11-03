# Disk module review — 2026-11-03

Baseline: `a57b39c82c9cb1fcb7ac8bbdde338b0a904b1c5e`, the last pushed commit on `ui-exp-unplanned`. The review covers every changed source hunk and each added source file after that baseline, plus the tests, contract, localization sources and generated resources. The module brief supplies context; the later explicit requests determine the final behavior.

## Findings and corrections

| Finding | Result |
| --- | --- |
| Empty or unavailable inventories manufactured twelve category links and described classification as “Measuring”. | Category rows now come only from nonempty scoped index summaries. Classification uses names, extensions, bundle structure and location. Missing legacy metadata is prepared inside normal module loading; no category is invented. |
| Large files dominated every overview as a separate repeated list. | Large files is a row within Categories, with the agreed 100 MB threshold. It is an overlapping size filter; it is excluded from content-partition totals. Its file page uses the normal batch-selection list and bounded pagination. |
| Categories were hidden after four entries. | All nonempty scoped categories appear in the standard list. Empty folders have no Categories shell. |
| Recommended repeated the unmatched-app-data entry and treated size alone as a recommendation. | Unmatched app data appears only under Apps. Pure size recommendations were removed. Review subsets require actual modification-date evidence. Cached source-category membership proves whether they repeat an entire content-category inventory; equal byte totals alone never establish duplication. |
| Archive review arbitrarily excluded older large archives. | Older archives includes every size. The 100 MB threshold belongs to the Large files filter. Missing/future dates do not qualify; modification date never means last use. |
| The uninstall catalog was treated as the complete set of installed component identities. | Matching also uses the bundle identities already recorded by the disk index, including system and embedded extensions. No vendor-prefix blacklist is used. Changed bundle metadata invalidates the catalog. |
| Unmatched identifiers were called removed-app leftovers without proof. | The page is named Unmatched app data and explains the uncertainty. Installed identifiers, matching container metadata, installed-app claims and zero-allocation entries are excluded. |
| One group per identifier repeated the same name in the heading and child row; nothing could be selected. | The page is one flat list with one row per location, factual location-kind badges and Finder controls. Eligible user data has unchecked choices and the existing yellow Free selected action. |
| Manual selection of unmatched data had no reviewed execution path. | A fresh catalog and exact path/identity choices determine the complete target set before mutation. Stale/forged selections fail before removal. Targets are limited to canonical, user-owned immediate child folders of recognized user Library locations. App-group folders, installed claims, protected/dataless locations and symlinks are excluded. Each target is checked again immediately before removal. Uninstall’s automatic ownership rules are unchanged. |
| Opening any folder loaded the disk-wide large-file inventory. | Maps now retain only their direct large files and cached subtree summaries. Category/review inventories load at most 200 files with a stable size/path cursor. Navigation does not scan the filesystem. Narrow folder queries use their path range instead of scanning a global type index; the large-file filter has a partial ordered index. |
| Every filter shared a folder-wide selection, allowing unrelated inventories to carry hidden choices. | Selection scopes distinguish folder and filter; pages of the same inventory share their cursor-independent scope. Graph file groups carry their own selection without a hidden overview action. Closing a scope clears its ephemeral choices. |
| Scoped choices could survive eligibility changes or miss synchronous completion progress. | Visible ineligible choices are excluded, completed IDs are collected independently of queued UI updates, and completed metadata is discarded. |
| Resolving an ordinary row eagerly rebuilt all graph aggregates. | Original rows and segments are searched first; aggregates are constructed only when needed for their destination. |
| A failed hardlink identity lookup could run updates using the empty unlinked identity. | Empty identities never trigger link-wide updates; the directory is marked incomplete. A regression fixture protects unrelated file sizes. |
| Ownership paths could disagree between ordinary and Data-volume views; failed ownership writes were acknowledged as current. | Paths normalize before persistence. Failed writes remain eligible for retry. |
| Public Swift model layouts changed while older binary modules were still accepted. | The shared contract and all five bundled manifests now use version 12. Version 11 binary modules are rejected before loading. Older saved JSON still decodes with defaults for new optional fields. |
| Packaged translations could lag behind their source tables. | Assembly validates/regenerates localization before copying resources. New texts have all seven translations; unused newly introduced “Measuring” and duplicate-review texts were removed. |
| File paths occupied count subtitles. | File rows keep locations in Finder controls. Subtitles are reserved for quantity sums and counts; individual files have no information pill or individual Delete action. |

## Source coverage

Each entry below was reviewed against the baseline; newly added files were reviewed in full. Adjacent ownership/discovery and page-expansion code was read to trace the actual behavior rather than assessing helpers alone.

- `Modules/DiskMap/Module/DiskMapModule.swift`: background catalog loading, lazy routing, current-snapshot actions, exact file selection, manual data review, uninstall validation and post-action invalidation.
- `Modules/DiskMap/Module/Engine/DiskApplications.swift`: catalog reuse, allocation totals, installed identities, unmatched-data construction and reviewed target identities.
- `Modules/DiskMap/Module/Engine/DiskIndex.swift`: optional metadata, shallow projections, versioning and legacy decoding.
- `Modules/DiskMap/Module/Engine/DiskCategories.swift`: deterministic request IDs, scoped pagination, content/location classification and the independent size filter.
- `Modules/DiskMap/Module/Engine/DiskDatabase.swift`: schema, bounded caches, parameter binding, transactions, hardlinks, subtree removal and summary reconciliation.
- `Modules/DiskMap/Module/Engine/DiskDatabaseScanner.swift`: native streaming, timestamps, bundle identities, incremental updates, failed reads and hardlink updates.
- `Modules/DiskMap/Module/Engine/DiskDatabaseQueries.swift`: coherent snapshots, direct-file projections, inventory inputs and persisted ownership evidence.
- `Modules/DiskMap/Module/Engine/DiskDatabaseBrowse.swift`: category/review queries, folder boundaries, stable 200-file pagination, ownership and exact selected-file resolution.
- `Modules/DiskMap/Module/Engine/DiskDatabaseSummaries.swift`: incremental category/filter/review totals and metadata-only migration.
- `Modules/DiskMap/Module/Engine/DiskStore.swift`: reader/writer separation, unpublished generations, atomic publication, failure cleanup, shared progress, completed inventory publication and queued events.
- `Modules/DiskMap/Module/Engine/DiskFileRemoval.swift`: regular-file eligibility, canonical paths, protected/dataless flags, account ownership, exact IDs and progress.
- `Modules/DiskMap/Module/Engine/DiskUnmatchedRemoval.swift`: manual directory eligibility, all-target validation, stale identities and exact execution.
- `Modules/DiskMap/Module/Presentation/DiskMapScreenBuilder.swift`: actual overview widgets, Apps, flat data rows, graph segments and selection payloads.
- `Modules/DiskMap/Module/Presentation/DiskBrowseScreenBuilder.swift`: real category rows, deduplicated evidence-based review subsets and standard file lists.
- `App/Registry/ModuleHandle.swift`: selection retention, scopes, page navigation and synchronous progress completion.
- `App/Renderer/ScreenView.swift`: original/aggregate navigation, selection propagation and displayed legend counts.
- `App/Shell/TileArt.swift`: exact folder/file aggregation, preserved destinations, duplicate legacy row IDs, block limits, weights and compatible selection merging.
- `Sdk/Interface/Widgets.swift` and `Sdk/Contract/ModuleManifest.swift`: new fields, legacy decoding and binary compatibility.
- `Platform/Commands/DirectoryWalk.swift`: opt-in packed native modification timestamps; other callers retain their existing attribute request.
- `Scripts/Assemble.sh`: translation generation occurs before resource copying and signing.
- All five `Modules/*/Bundle/Manifest.json` files: contract version agrees with the shared SDK.
- `Docs/Module-Layout.md`: final requirements replace the contradictory overview, placeholders, duplicate recommendations and unsafe orphan terminology.

Test changes reviewed: `Tests/DiskMap/DiskMapTests.swift`, `DiskFileSelectionTests.swift`, `DiskBrowseTests.swift`, `DiskOverviewTests.swift`, `DiskUnmatchedDataTests.swift`; `Tests/App/BlockGeometryCacheTests.swift`, `FolderAggregationTests.swift`, `PageFileSelectionTests.swift`, `RegistryTests.swift`. Existing database, ownership and performance tests also exercise the corrected paths.

Localization coverage: `Localization/App.json`, `Localization/DiskMap.json`, all seven corresponding App and DiskMap `Localizable.strings` files, and generated `App/Resources/TextCatalog.json`. Generated resources are validated against their source generators, rather than treated as independent implementations. Placeholder and language completeness checks apply to every entry.

## Verification

The Disk and shared data-model checks pass: 51 Disk tests, 25 selected App tests (including compatibility checks) and 13 SDK tests — 89 passed, none skipped. They cover real database-to-screen navigation, scoped empty/nonempty categories, 100 MB filtering, small files, pagination, stale/forged manual removal, installed extension matching, selection retention and legacy decoding. The compatibility check additionally rejects the preceding binary contract.

The synthetic inventory check indexes 100,001 records and returns a 200-file page. The native timestamp and incremental-reread fixtures operate only in temporary directories. The production database fixture indexes 100,000 files across 50,011 directories, builds summaries and reads 100 small folder pages. It completed indexing in 2.645 seconds and page reads in 0.005 seconds, with 4.844 MiB of additional sampled peak memory. The 16,001-directory Unicode summary fixture completed in 0.494 seconds. Performance figures describe these fixtures, not a claim about live app memory or visual responsiveness.

App and visual verification remains with the user. No app launch, UI navigation, control interaction or screenshot capture is part of this review.

## Loading refactor follow-up — 2026-11-03

The separate file-inventory phase was a regression. Legacy maps could publish before file metadata was ready, and page navigation kept displaying a reading banner. The store now publishes only after the native scan, metadata preparation and directory summaries finish, through the existing shared module loading progress. Subsequent navigation uses the completed reader. Concurrent ownership updates cannot publish an unfinished inventory. Failed loads retain an explicit error rather than an endless reading state.

The full summary traversal used an OR cursor that restarted the directory index for each batch. Two indexed seeks now advance past completed paths, including equal-length and Unicode paths. A standalone SQLite traversal of 100,000 directory records took 0.313 seconds with the old cursor and 0.015 seconds with the replacement; these are query timings, not whole-disk scan or app timings. Direct summary queries explicitly use the parent index. Fresh scans no longer search an empty old index or populate unnecessary dirty-ancestor records. Scan progress also advances within large directories.

Removed the enrichment task/retry state, reading-page builder, legacy large-file presentation fallback, navigation-time summary scans and duplicate generation-copy logic. Tests now exercise prepared inventories instead of polling a second background phase; the redundant synthetic legacy overview test is replaced by the existing real database-to-screen coverage. New checks cover shared completion/progress and child-before-parent summary traversal across 16,001 Unicode directories.

The follow-up also removes the unused in-memory scanner, framed-cache import/write layer, coalescing cache writer and tree-based ownership attribution. Existing SQLite caches remain compatible; only caches predating complete file metadata need a scan. Folder and file ownership use one conservative evidence-combination rule with provenance preserved. Retired-implementation benchmarks and duplicate scanner tests were removed; sparse files, cloud placeholders, hardlinks, changed-parent updates, shared ownership and receipt uncertainty now exercise the production database. The memory benchmark now creates 50,011 directories and 100,000 file records and measures indexing, summaries and bounded navigation without opening the app or reading the user's disk.

## Live loading bottleneck — hard-link updates

A five-second sample of the running app located repeated full-table scans in the scanner’s hard-link UPDATE statements. Both tables use partial indexes restricted to nonempty link identities; the UPDATE predicates omitted that restriction, so SQLite scanned every record per alias. Both predicates now include it and use the existing indexes. No cache format change or forced rebuild is needed.

Read-only queries against the live index matched the same 129 records across 20 identities: 0.6575 seconds with the old predicate and 0.00009 seconds with the indexed predicate. This measures those queries, not total startup. A native filesystem regression scans 600 hard-linked files with 100,000 unrelated records already indexed, checks once-only allocation, then changes an inode and verifies all aliases—including an alias outside the reread folder—receive the new size. The scan took 0.0397 seconds. All 52 Disk tests passed. The earlier synthetic benchmark omitted a realistic hard-link workload and was insufficient evidence of whole-disk loading performance.

## Complete loading review and category-regression correction

The earlier alias-index fix was necessary but insufficient. This follow-up reread the complete Disk module, all eight existing Disk test files, the native directory walker, shared loading progress, and the host loading lifecycle. Read-only query plans ruled out the suspected cloud-folder subtree deletes: they already used path indexes. The user's observation that categories introduced the regression is consistent with the new all-file inventory and per-folder category work.

A separate opt-in backend test now runs the production `DiskStore.view` path against `/`, writes only its own temporary index, waits for completion, then reopens that index. It does not launch MacSpace, interact with its UI, or remove scanned files. The original diagnostic was stopped after 196 seconds while still collecting. Profiles and the existing cache exposed one inode with 3,911 names: the scanner rewrote every known alias for every new alias, even when metadata was identical. Indexed access alone did not eliminate this quadratic write workload.

Corrections:

- Fresh collection records each alias once. Incremental reads compare one indexed representative and update the family only when its metadata changed. The new 4,001-name regression exercises both initial collection and unchanged rereading; the existing changed-inode regression still checks aliases outside the changed folder.
- Initial filesystem reads use eight bounded workers from the existing native walker. Each worker buffers at most 256 file records; database batches remain serialized. Native timestamps, cloud-placeholder exclusions, volume boundaries, bundle identities and incomplete-folder state are preserved. A 32-branch Unicode fixture checks per-folder direct allocation and once-only hardlink totals.
- Fresh unpublished collection omits per-directory rollback journals and unnecessary old-index deletes. It builds the eleven secondary indexes once after collection, instead of maintaining all of them per file. Incremental reads keep indexes and directory rollback protection. Writes checkpoint bounded 8,192-statement batches.
- File classification uses literal filesystem-marker searches. It reads metadata already collected by the scan, not file contents and not a second category scan.
- Initial direct category/filter/review summaries use set-based passes over the persisted inventory. Child totals then accumulate into parents. Targeted refreshes use the same filter logic restricted to the changed parent. This removes millions of repeated per-directory summary queries.
- Collection, index construction, direct summaries and parent accumulation all use the existing module loading-progress relay. No separate loading page or new animation was added.

Measured complete fresh-index runs on this Mac: serial collection after the alias fix **262.81 s**, initial parallel implementation **183.70 s**, batched collection/bulk index construction **94.12 s**, and the final set-based summary implementation **38.95 s**. The final completed-cache reopening took **0.306 s** and returned all 13 nonempty categories/filters. These were sequential local backend runs with warmed filesystem caches; they are not UI timings or a promise for every disk. The remaining first-load cost is distinguished from cached reopening. Interrupting an unfinished initial generation still requires rebuilding it; resumable partial generations were not added.

The full non-UI regression run passed: 55 Disk tests (including the opt-in full-load diagnostic), 13 SDK tests, and 25 selected App data/layout tests. The final progress-only adjustment passed 16 overview, database and memory checks. Four existing shared native-walker/helper-sizing tests also passed, bringing distinct code-level coverage to 97 tests. App/visual verification remains with the user.

## Revised user brief: review-focused Disk and configurable removal

The later final layout replaces the broad Categories overview and modification-age recommendations. Disk now shows Duplicate files / Developer cleanup, Apps, nonempty Downloads / Documents / Desktop, and a five-file Large files preview with the 100 MB More items destination. Folder file pages group rows by folder and expose Finder, with optional type subfilters inside Large files. The disk graph continues to navigate folders. System/app data and package/build internals remain visible but cannot be selected as ordinary personal files. Ownership evidence additionally suppresses file choices on browse pages.

The user explicitly corrected Trash behavior: General Settings contains a toggle, OFF by default. Default ordinary Disk-file removal remains permanent deletion. Turning it on moves selected files to Trash; prepared confirmations carry the selected mode, and execution rejects a changed mode rather than silently using different behavior. Uninstall and cache lifecycle removal are separate. No file-removal operation was run against user data to verify this change.

Duplicate comparison is explicit and streams in fixed chunks. It hashes only matching-size local candidates of at least 100 MB, filters personal-file eligibility and ownership claims, excludes repeated inode identities, paginates extra copies and preselects none. An unselected matching copy is required and both contents are reverified before removal. This is not evidence that either copy is unused. Initial comparison may be expensive for many large files; it is not part of normal loading. Subsequent file changes require comparing again before removing stale matches.

The cache was retaining abandoned generations after interrupted reads. Retention now preserves the active index and its WAL/SHM, removes only recognized stale generations, and retires the obsolete framed cache. A new fixture checks missing first-run directories and active sidecar preservation. An actual cache listing showed multiple discarded databases totaling several GB; the active database can still be large because it indexes filesystem metadata. No fixed maximum cache size is claimed.

Menu-bar Disk navigation now uses the same storage destination as its dashboard widget, eliminating the fallback tint. Returning to a loading tile uses the existing close/open chart motion. Header selections are supplied for titled lists and use the existing scoped-selection machinery. Row action flags already match the published row contract: attached to the right immediately before the size; automated placement checks cover both cases.

Developer cleanup now recognizes Rust target and Swift .build only with a parent project manifest and generated metadata, offers them as manual review items and revalidates them before cleanup. Source project roots are never offered. Discovery is bounded to common user project locations, 2,000 visited/queued directories and five levels. System Data runs at most two disjoint cache entries concurrently; overlaps and Homebrew remain serial. Existing fresh process/open-file checks are retained per job. Fixtures cover both recognized output folders and overlap scheduling. No live cleanup benchmark or user-data deletion was performed.

File-read history is not available retrospectively from ordinary filesystem metadata. The design therefore removes age-only recommendations rather than interpreting modification/access dates as nonuse. A future read-monitoring feature would require a separately scoped OS integration and must distinguish current descriptors, observed opens and actual reads. It is not implemented or claimed here.

Final verification for the revised brief: 120 System Data, 13 SDK, 55 executed Disk and 14 selected non-rendering App tests passed (202 checks). The opt-in whole-disk diagnostic was skipped in that run; the prior measured complete scan/reopen is recorded above. A final rerun after adding duplicate totals passed the Disk, developer-cleanup and row-layout checks. No app launch or visual verification was performed. The prior notarized build completed successfully; the revised build is assembled separately with the same signing/notarization pipeline.

## Completion review (Astra)

Read and traced deletion, duplicate comparison, index collection/migration, browse selection, cross-module navigation, the shared renderer and the attached final brief. Confirmed v1.1.5 is the latest public GitHub release and read its RowActionFlag/WidgetView sources. Its flag is after the title/control cluster when a size exists; the previous claim that right-before-size matched the release was incorrect. Restored the published placement and its regression expectation.

Added canonical current-open-descriptor attribution through libproc, with process names and read-open capability internally distinguished. The user explicitly chose current open-file evidence instead of an Endpoint Security extension. A native temporary-file regression checks attribution and removal refusal. Backend selected-file lookup now rejects any persisted app ownership claim, including unknown/shared evidence; this applies to ordinary and duplicate removal. Separate filter scopes prevent hidden selection carryover. Empty type filters disappear; parent-first pagination keeps folders contiguous. A folder's Finder control opens the folder itself.

Added a dedicated developer-cleanup lazy page, pending cross-module page routing and a recently measured developer/Homebrew total. Untitled selectable single-list screens acquire the page title. Removed obsolete category-page routes. Ordinary native scans no longer build unused age/category summaries or renew them daily, and old caches drop two global file indexes plus summary rows and VACUUM in an unpublished generation. A read-only backup of the actual active index compacted from 1,386,315,776 to 896,823,296 bytes in 6.83 seconds; the live index was not modified by that benchmark.

The full queued code-level suite and backend diagnostic completed without failures after fixing the canonical path mismatch. The newest whole-filesystem run took 168.07 seconds and reopening took 4.59 seconds, slower than the earlier 38.95/0.31 run under different system conditions. Do not present the earlier faster run as a guarantee for this build. A universal cache-size cap, proof of nonuse and historical read monitoring are not claimed. Remaining filesystem I/O varies with disk workload. Final focused tests and notarization follow below.

Final completion checks: 202 executed non-UI tests passed (120 System Data, 13 SDK, 57 Disk, 12 App). One explicitly opt-in full-disk diagnostic was skipped in this last focused run; its most recent actual run is reported above. Public v1.1.5 row placement was fetched and compared from the release source. No app or visual interaction was performed.
