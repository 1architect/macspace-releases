# Module loading performance

The target is a 50% reduction in module data-loading time relative to `2efc7f3`, preserving presentations, actions, safety boundaries and refresh policy. Visual page-opening time is outside this target. **This target is not yet achieved.**

## Latest comparable measurements

Measured on 2026-11-14, Apple M4, macOS 27.2 (26B123), optimized release builds and Full Disk Access. A detached reference checkout at `2efc7f3` and the candidate use identical benchmark source. Pre-existing unrelated model-cleanup edits were retained identically. Reference/candidate order alternates between pairs to reduce filesystem-cache and machine-load bias. The table contains medians from three complete pairs; values are seconds, reference → candidate.

| Module | New inventory index | Completed inventory index |
| --- | ---: | ---: |
| Disk Map | 46.120 → 37.045 | 17.282 → 14.127 |
| System Data | 23.682 → 27.398 | 20.233 → 16.299 |
| Siri & Apple Intelligence | 3.243 → 5.131 | 3.017 → 3.705 |
| Debloat | 8.852 → 11.002 | 0.438 → 0.335 |
| Other System Files | 10.148 → 11.744 | 8.861 → 9.875 |
| **All five ready** | **46.120 → 37.045** | **20.233 → 16.299** |

The aggregate reductions are **19.7%** and **19.4%**, below the required 50%. Per-module results include regressions; faster aggregate completion is not proof that every module became faster. Earlier separate runs reported reductions above 50%, but paired measurements did not reproduce them. Those earlier results are not treated as completion evidence.

These latest three pairs are in `results/module-loading-20261114-enumerated-paired/`. The candidate is `83dcda6` plus the directory-metadata changes recorded by the runner's diff hash. The preceding three-pair comparison (`module-loading-20261114-lazy-paired`) showed aggregate reductions of 16.2% and 13.6%. Differences between those two experiments cannot isolate the effect of the newest change because filesystem and machine state also changed.

## Scope and safeguards

The opt-in target runs all five real snapshot readers and presentation builders concurrently at `userInitiated`, matching foreground UI tasks. It never calls module actions, automatic cleanup, profile repair, notifications or UI verification. Disk Map uses a private temporary encrypted inventory and memory-only fixture keys. Its completed state, summary version and personal-inventory version are checked so a failed/partial load cannot count as fast. Other System Files bypasses its initializer's legacy preference migration.

Scenarios are kept separate: `first` uses new stores and a new index; `cachedIndexStartup` uses new stores with the completed index. Shared cloud measurements are invalidated between scenarios. The additional `reopen` reading uses the same instances and may perform I/O after cache expiry or filesystem events.

Reports record the scan root, build configuration and request priority. Comparisons reject mismatches, incomplete module sets and fewer than three samples. They measure backend work, excluding bundle loading, helper readiness/root-only work, the production Keychain/session gate and UI rendering. No full application launch or visual verification is claimed.

## Reproduction

Build the same harness in both checkouts, then run:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
python3 Scripts/RunModuleLoadingComparison.py \
  --baseline /path/to/reference-checkout --candidate /path/to/candidate-checkout \
  --output results/new-private-comparison --pairs 4
```

The runner builds both variants first, alternates execution order and invokes `CompareModuleLoading.py`. It exits unsuccessfully when either aggregate median misses the 50% target or any module median regresses. Four Python acceptance tests cover aggregate improvement, hidden module regressions, target misses and mismatched context. Both variants use root `/` by default, release optimization and the same benchmark SHA-256. Output contains timing/phase evidence, not snapshot contents; the output directory is private and ignored by Git.

## Implemented and investigated

The candidate reduces initial inventory directory statements, rejects impossible personal-file candidates before the SQLite writer, bounds independent app metadata/ownership reads, and starts root file projections from the partial personal-file index. Navigation preparation fell from approximately 5.8 s to 0.15 s in a diagnostic sample. It also avoids unnecessary full-path construction, coordinates sizing workers and propagates foreground read priority while keeping timers/scheduled work at utility priority. Regression tests cover exclusions, Unicode, hard links, dataless placeholders, metadata ownership and original reviewed identities.

Increasing the foreground helper count worsened measured contention and was removed. Bounded directory-list reuse was also removed after a scoped trial returned zero reuse hits; its memory and complexity were not justified. The remaining target requires further reduction of the dominant filesystem work, not a claim based on a favourable isolated run.

Raw evidence is kept locally under ignored `results/module-loading-20261113/` and `results/module-loading-20261114-*-paired/` directories.

The host can also request a joint tile/screen reading from the five bundled modules. This optional SDK capability uses one snapshot orchestration when both outputs are needed; dashboard-only reads remain tile-only, and older modules retain their existing calls. Host tests cover activation, explicit refresh and the dashboard-to-page transition. This does not establish a loading-time reduction: the paired reader benchmark still uses the same independent entry points in both variants.

The inventory walker now carries each directory's enumerated owner through its bounded work queue. Initial collection reuses that owner, and both initial/full traversal reuse the directory flags already returned by the native batch. Missing attributes and injected metadata readers retain the stat fallback. Enumeration still opens directories without following their final symlink. Tests compare initial and full-refresh metadata, parent relations and aggregate sizes against the stat path, including empty directories, a partial batch, Unicode, symlinks and cross-parent hard links.

The next bottleneck to address is duplicated tree traversal by System Data's item measurements and storage-category measurements. A shared pass must keep independent accounting ledgers, per-consumer exclusions, device boundaries, application exclusions and unreadable-directory handling; a listing cache alone did not provide reuse. The latest results do not justify claiming that all modules became faster.

## Shared traversal experiment (removed)

A snapshot-local shared pass was implemented and tested for System Data's item and category readers. It passed 537 selected regression cases, including full-report/category equivalence, independent clone/hard-link ledgers, intermediate symlinks and children readable behind an unlistable parent. It enumerated 211,913 directories for 259,716 consumer-directory visits in a native diagnostic. The first full pilot reported 40.671 s with a new index and 21.384 s with an existing index; its latter phase was sampled for profiling, so this pilot is not a matched performance comparison or completion evidence. The separate utility-priority System Data diagnostic took 17.604 s. Native open/getattrlistbulk calls dominated the sample.

This experiment did not establish an end-to-end gain and was removed, including its integration and test-only scaffolding. Its source patch, functional-test log and diagnostic evidence remain privately under `results/module-loading-20261114-shared-pass-experiment/`. Do not repeat a listing cache or this shared-pass implementation without new evidence of sufficient benefit. The next investigation should target the cost of native directory access itself and expensive independent OS queries; Debloat still reads profiles through `system_profiler SPConfigurationProfileDataType -json`. The stable candidate and latest comparable table above remain unchanged by this removed experiment.

After removing that experiment, the retained implementation passed 807 unique selected tests with zero failures; eight opt-in tests were skipped. Validation covered the five module targets, Platform, SDK and the relevant host/startup/navigation/refresh/cleanup tests without opening the app. Log: `/tmp/macspace-module-loading-final-validation.log`.

## Further experiments (removed)

The following were investigated on the same machine. Their patches and evidence remain private under the named `results/` folders. None is part of the retained app implementation:

- `module-loading-20261114-relative-open-experiment`: bounded parent descriptors and `openat` preserved results, no-follow checks and descriptor limits, but three alternating pairs reduced native-reader medians only from 6.317 to 6.115 s in extended mode and 18.222 to 18.130 s in inventory mode. It did not justify the added lifetime/race complexity.
- `module-loading-20261114-directory-batch-experiment`: 64-directory inserts with a separate parent-link pass preserved Unicode parent links and recovery after unpublished 8,192-row checkpoints. In three isolated SQLite pairs over 160,201 directories, the original median was 1.877 s and the batch implementation took 2.048 s. The full pilot took 42.367/17.000 s for new/completed indexes. The additional machinery was removed.
- `module-loading-20261114-worker-budget-experiment`: optional helpers yielded capacity to newly arriving readers without blocking the readers' own workers. Tests passed, but limits of eight and four did not improve all-ready time in pilots (40.791/21.846 s and 47.071/17.091 s respectively, versus 39.122/16.169 s for the profiled control). These are exploratory runs, not a matched completion gate. The mechanism was removed.
- `module-loading-20261114-cloud-bulk`, `-cloud-pruned`, and `-cloud-flags`: an isolated cloud profile was dominated by physical FTS enumeration. Bulk readers produced identical SHA-256 summaries of all source paths, byte counts, file counts and folders over three alternating pairs (211 eligible files), and isolated medians improved by 9.3% and 11.5%. Checking Keep Downloaded on every directory was slower. More importantly, the five-module comparison did not establish a useful end-to-end improvement, and an identical-code FTS/flags-only control produced 39.128/21.172 s versus 40.509/22.292 s. These readers, directory pruning and diagnostic overrides were removed. Only opt-in enumeration/eligibility stage timings remain.

The rejected cloud reader's full three-pair comparison is in `module-loading-20261114-cloud-bulk-paired`: aggregate medians were 56.814 → 45.251 s (20.4%) and 26.302 → 23.033 s (12.4%), with regressions in Debloat, Siri and Other System Files. It failed both the aggregate target and the per-module regression gate. It is not evidence for the retained implementation's performance.

The remaining investigation needs a larger reduction in repeated filesystem work. A potential next implementation is persisted directory facts for read-only module snapshots, validated against complete FSEvents history, directory identity, current permissions, metadata-key/session availability and OS/schema changes. It must conservatively rescan on lost history and new clone/hard-link groups, keep clone-private-size accounting current, and leave destructive actions on fresh evidence. First-start and completed-index scenarios must both remain in the gate, with isolated caches for the benchmark. This is required work to investigate, not a claim that a cache has been implemented or that 50% is achievable from these experiments alone.

The final retained code after these experiments passed 807 unique selected Swift tests with no failures; eight opt-in tests were skipped. The comparison gate passed its four Python acceptance tests. Evidence: `/tmp/macspace-loading-investigation-final-validation.log`. No app or visual UI checks were performed.

## Experimental persisted directory facts

The opt-in archive is implemented in `DirectoryListingArchive`, with raw attribute-batch validation and FSEvents invalidation. It remains **disabled by default**: only `MACSPACE_DIRECTORY_ARCHIVE` explicitly selects a cache directory. The common five-module harness now assigns a new isolated directory per first sample and reuses it for that sample's completed-index scenario; both reference and candidate use that identical harness. This does not change the 50% target or permit a slower module.

The archive uses the existing inventory key with a distinct HKDF context and a single shared SQLCipher library. Files/sidecars use the pinned no-follow boundary; interrupted generations retain a zero watermark and cannot become current. Every hit still opens the current directory and checks identity/permissions. Cache reuse is restricted to the cache's device and to the user or world-readable system directories. Strict helper reads and actions keep fresh readers. A bounded 64 MiB SQLite page cache is released with the snapshot.

Native testing found that an immediately preceding write could be absent after an immediate history flush. A delivered unique write in the cache directory now fences that device's asynchronous delivery; failed fences/history, dropped/wrapped events and mount/root changes invalidate facts. Persisted watermarks come only from fully processed callback IDs. The stream watches both startup-volume paths. The native closed-cache write fixture passes without sleeping before its read. This follows the conservative snapshot approach described in [Apple's FSEvents guide](https://developer.apple.com/library/archive/documentation/Darwin/Conceptual/FSEvents_ProgGuide/UsingtheFSEventsFramework/UsingtheFSEventsFramework.html); the observed-write fence is an implementation safeguard verified by the native fixture, not a claim made by that guide.

File IDs preserve hard-link accounting even when a cached single-link source gains an alias elsewhere. A duplicate clone family's private allocation is measured live, since creating/writing another member changes the original's private bytes without changing its allocated size. Tests cover those cases, repeated ordinary roots, exact native/replayed metadata, malformed/truncated batches, encryption, scope invalidation, lost history, interruption recovery and no-follow boundaries. The selected Swift suite passed **818 unique tests, zero failures**, with eight unrelated opt-in cases skipped. The local Developer ID artifact at `Build/DirectoryArchivePerformance/MacSpace.app` assembled and verified successfully, including the shared cipher dependency; it was not installed, launched or notarized.

Three alternating pairs at `2efc7f3` versus this experimental implementation are in `results/module-loading-20261114-directory-archive-paired/`. Aggregate medians were **62.012 → 46.193 s (25.5%)** for a new index and **28.390 → 14.536 s (48.8%)** for a completed index. All five completed-index module medians improved, but the new-index medians regressed for Debloat, Siri, Other System Files and System Data. One candidate new-index sample took 87.220 s. The comparison correctly failed. These results cannot be described as achieving 50% or as the default app's performance.

The next required implementation work is reducing the remaining first-read traversal, including potential reuse between inventory and System Data readers. It must preserve original request semantics, snapshot lifetime, current permissions, clone/private-size and hard-link accounting, and publication only after the complete inventory. The full new-index and completed-index gate remains required. The archive is not ready for default activation merely because its safety tests pass.

## Shared inventory/sizing archive (under measurement)

The experimental archive now has reference-counted snapshot leases shared by the initial inventory and System Data readers. A joining reader advances the event boundary, invalidates changed paths and discards native output started before that boundary. The final lease publishes the watermark and releases the database/file lock, even if completed lease objects remain referenced. Reads use one attribute superset while preserving each consumer's original date/extended-field visibility; cached records must carry their own device ID.

Two added fixture tests cover shared lifetimes/generation rejection and exact native-versus-replayed attribute visibility. The native refresh comparison also seeds identical directory IDs before comparing hard-link attribution: independent parallel first collections could previously compare different starting states. The extended release validation on 2026-11-15 completed without failures (`/tmp/macspace-shared-readers-full-validation.log`), including the live history fixture. The archive remains opt-in; performance has not yet been established for this shared implementation.

That validation contained **820 passing unique tests**, zero failures and eight skipped opt-in cases. The shared-superset implementation at `62af729` then failed its three alternating pairs (`results/module-loading-20261115-shared-archive-paired/`): new-index median **37.992 → 41.288 s (-8.7%)**, completed-index **18.532 → 11.508 s (37.9%)**. Initial inventory, Siri and System Data regressed; completed-index Siri regressed too.

The follow-up limits archive population to extended sizing readers; inventory misses retain their basic native request. A fixed 512 KiB negative membership filter avoids SQL lookups for absent paths and is rebuilt from the encrypted database on open. Filter collisions can only cause redundant queries, never bypass payload/identity validation. Hard-link/last-link events outside the cache now invalidate the archive globally because aliases can change metadata in other parents; a live fixture covers a cached source gaining an alias elsewhere. The focused release suite passed **26 tests**, including both native history cases (`/tmp/macspace-demand-archive-history-tests-v2.log`).

The follow-up's three alternating pairs (`results/module-loading-20261115-demand-archive-paired/`) still failed: new-index **44.828 → 39.660 s (11.5%)**, completed-index **19.003 → 11.870 s (37.5%)**. Initial Debloat, Siri and System Data regressed; completed-index Debloat had a small regression. These results do not meet the target and do not justify activating the archive by default. A single earlier pilot's 33.390/11.573 s is exploratory evidence only, superseded by the paired comparison.

## Demand-driven private allocation

Ordinary sizing/category reads now ask for a file's clone-private allocation only when a clone family repeats. The first member counts allocated bytes, so its private size was previously queried and discarded. DirectoryWalk's default request/public Entry semantics remain unchanged. Strict helper reads retain private sizes in their pinned native batch, preserving intermediate-symlink refusal; `unsharedBytes` also retains its complete batch because it uses every private size. The archive keys distinguish requests that include private size from those that omit it.

The fixture compares the previous eager calculation with demand reads, parallel sizing and category totals, including intact/diverged clones and hard links. The native diagnostic over the unchanged Xcode bundle returned identical logical/allocated/purgeable totals in three alternating pairs; median attribute-read time was **1.468 → 1.067 s (27.4%)**. A smaller build-tree diagnostic also matched totals and exercised 105 repeated clone families. Evidence: `/tmp/macspace-private-size-xcode-comparison.log` and `/tmp/macspace-private-size-native-comparison.log`. These are isolated reader measurements, not full-module completion evidence.

Three full alternating pairs against `2efc7f3` (`results/module-loading-20261115-demand-private-paired/`) reported new-index **46.310 → 41.646 s (10.1%)** and completed-index **22.984 → 12.115 s (47.3%)**. Initial Debloat and Siri regressed; all completed-index module medians improved. The gate still failed. The preceding single pilot's 32.138/10.122 s does not supersede these paired results. These comparisons include the opt-in archive and cannot be claimed as the default product's end-to-end gain.

The final release validation with native history enabled passed without failures (`/tmp/macspace-demand-private-full-validation.log`). No app was launched or manually checked. The next investigation should profile the remaining native first-collection and ownership work rather than repeat these cache/attribute experiments; a container-cache stage also had a roughly five-second outlier in one paired sample. The 50% target for both scenarios and the per-module regression gate remain outstanding.

## Archive contention profile and negative lookups

A separate profiled run at `96f125c` found 2,393 collapsed leaf samples in mutex waits, versus 1,084 in native batch reads and 574 in opens. The call trees identify the archive's shared SQL lock as a substantial contributor: even absent-path lookups queued behind commits/checkpoints. This run is diagnostic evidence, not timing-comparison evidence (`/tmp/macspace-loading-cold-sample-20261115.txt`, `/tmp/macspace-loading-ownership-sample-20261115.txt`).

Negative membership hints/generation counters now have a separate short lock. Proven misses return without acquiring the SQL lock; possible hits still take the fully validated database path. The generation advances only after the history fence/invalidation finishes, so native output started while the fence runs cannot become current. Two new tests cover concurrent population across checkpoints and a controlled blocked fence that must neither block a negative lookup nor accept its pre-boundary output. All **16 focused tests passed**, including native history (`/tmp/macspace-archive-negative-concurrency-tests-v2.log`).

The native pilot reported 24.655/7.420 s, but the three alternating pairs in `results/module-loading-20261115-negative-hints-paired/` are authoritative: new-index **34.523 → 26.688 s (22.7%)**, completed-index **16.882 → 9.572 s (43.3%)**. Initial and completed-index Siri/Debloat medians regressed. The gate failed and the archive remains disabled by default. The next experiment is bounded write-behind for archive population, preserving generation rejection, immediate pending-read correctness and final durability before publication.

## Bounded archive write-behind

Shared leases now enqueue archive population on one serial writer with a **16 MiB / 16,384-record admission bound**, including a metadata/closure allowance per entry. A full queue drops optional cache writes and leaves readers on the native fallback. Pending facts are immediately readable only with matching directory identity/request/generation and an available metadata session. A completed fence retires pending generations; the final lease closes admission and drains accepted writes before saving its history cursor and releasing the lock. Standalone archives keep synchronous lifetime semantics, including interruption recovery.

The new saturation fixture holds a fence, fills the queue beyond its bound, checks immediate pending reads and verifies that pre-fence output never survives reopening. Native batch replay now also exercises a lease. The selected release suite passed **825 unique tests**, zero failures, with nine opt-in diagnostics skipped (`/tmp/macspace-directory-write-behind-full-validation.log`). The native pilot reported 19.683/5.866 s and dropped 31,942 optional cache writes during initial collection; completed-index fallback still produced complete module snapshots.

The authoritative three alternating pairs are in `results/module-loading-20261115-write-behind-paired/`: new-index **31.095 → 21.850 s (29.7%)**, completed-index **15.559 → 7.472 s (52.0%)**. Completed-index aggregate speed met 50%, but Debloat regressed by 2.3%; initial Siri and Debloat also regressed. The complete gate therefore still failed. The archive remains opt-in and the full objective remains outstanding. The next investigation is the initial inventory's own serialized producer/writer path, without repeating the removed SQL directory-batching/parent-resolution experiment.

## Initial numeric totals and rejected scheduling changes

A bounded serial inventory writer was tested without changing its SQL statements. It passed 218 Disk Map tests, plus 20 focused cancellation/retry cases, but its native pilot was 19.606/5.581 s versus the preceding archive-only pilot's 19.683/5.866 s; traversal was 11.994 versus 12.118 s. This did not establish a useful gain, so the implementation and its two new fixtures were removed. Patch/logs remain in `results/module-loading-20261115-inventory-writer-experiment/`.

For initial totals, fresh collection's parent-before-child ID order now permits a reverse numeric fold in a vector capped at **8 MiB**. Hard-link representatives keep the existing smallest-parent/name policy. Bounded 512-row updates preserve unchanged totals; reordered/oversized ID ranges retain the existing general algorithm. The general/incremental pass is unchanged. Fixtures compare every total against the previous algorithm and cover reversed parents and a two-million-ID fallback. The native pilot's totals stage took **0.650 s**, versus roughly 2 s in the preceding pilots.

Lowering optional archive writes to utility priority was also tested, alongside numeric totals. It increased dropped cache records in one paired first read to 159,441; the completed-index read then had 139,968 misses. That combination's three pairs (`results/module-loading-20261115-numeric-totals-paired/`) failed at **43.320 → 29.252 s (32.5%)** and **19.165 → 14.058 s (26.6%)**, with initial Siri/Debloat regressions. Utility priority was removed; its patch/log remain in `results/module-loading-20261115-cache-utility-experiment/`.

The retained caller-priority writer plus numeric totals passed **826 unique release tests**, zero failures, with nine opt-in diagnostics skipped (`/tmp/macspace-numeric-totals-retained-validation.log`). Its separate three-pair run (`results/module-loading-20261115-numeric-totals-retained-paired/`) still failed: new-index **44.618 → 32.242 s (27.7%)**, completed-index **20.419 → 15.869 s (22.3%)**. Initial Siri/Debloat regressed; all completed-index module medians improved. Queue overflow and remaining native filesystem work still need investigation. Do not substitute the earlier favourable 52% completed-index aggregate for this latest retained-code comparison, or claim default activation: the archive remains opt-in and the full target remains outstanding.
