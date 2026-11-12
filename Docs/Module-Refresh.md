# Module refresh behavior

Implemented on `fixes-and-improvements-v111`, 2026-10-18. Module contract version 5.

## Loading and updating

- **First load:** use the existing loading pill, progress and page cascade. **Every subsequent read, including explicit Refresh and returning from All done:** preserve the current page, scroll position, groups and choices. Explicit Refresh still invalidates measurements first.
- Graphs pulse with the existing loading wave during scans, except cached-page navigation verification, which stays silent. Apply completed measurements only where values changed; do not replay the whole-page cascade. Home captions show loading text/progress immediately for ordinary scans, regardless of duration. Cached/status-only reads remain silent.
- **Automatic scan:** retain the current page, group stack, choices and scroll-view identity. Report real progress in the existing widget/pill; page details remain visible and interactive. Forced automatic invalidation (such as profile approval checks) follows this rule too.
- **Status update:** refresh live operation counters from the last measurement without querying services or enumerating files. It produces no loading state.
- Cached reads report no scan progress. A newer read or action supersedes older progress immediately, so a late result cannot restore old data or leave the widget loading.
- Page cleanup uses the same live page as reload: keep existing details visible and interactive and pulse the graph while working; retain the All done completion. Row actions use only the inline text flag and its progress fill, without hiding the page. `ActionRequest.rowID` identifies the target UI row.
- A verified `ActionResult.presentation` updates the tile and page atomically without another scan. Modules retain unrelated cached measurements. Background row actions publish `Row.activity` using the same flag.
- The dock renders the current phase directly in a stable container; it never mirrors a loading/action phase in view state. Dock lifetime controls only the bottom fade reservation: hold it until the outgoing button's removal transaction finishes, then release it. A new visibility generation cancels a stale departure completion.
- Back dismisses All done to the module page before considering group or home navigation.
- Confirmations share a left-aligned icon, heading and message, including cache cleanup.

`ModuleHandle.isRefreshing` describes visible scan feedback. `isReloading` describes only the first load without an existing page. `ScreenView` uses only `isReloading` for the initial details cascade; page cleanup never hides existing details.

## What is followed

Each canvas registers its destination and uses the existing `WindowReader` to identify its window. Visible destinations are combined across windows:

- Home follows all dashboard tiles; automatic normal reads request tile progress without constructing unused module pages.
- An open module follows that module's tile and page. Opening it shows its cached page immediately and verifies quietly, even when its tile was just read on Home. Concurrent presentation requests join a shared read; a tile-only read is followed by a page read when necessary. Explicit Refresh and changes to options/actions supersede older presentations.
- Settings does not poll modules. Modules covered by another page are not polled unless another visible window shows their page or a dashboard.
- Minimized/closed windows and a hidden app do not contribute visible destinations. Closing the last canvas does not re-enable polling.
- Separately enabled watches and automatic cleanup continue without a visible module. Their completion refreshes the UI only when that module is watched. User actions still verify their results.

## Intervals and caches

Ordinary polling is 60 seconds after the preceding refresh finishes while MacSpace is active, or 600 seconds when another app is active with a MacSpace window still visible. Fast operation polling overrides either interval; its minimum is two seconds.

| Module | Measurement cache | Fast status/scan polling |
|---|---|---|
| System Data | 600 seconds | Every 2 seconds during cloud removal using shared live counters; otherwise none. A failed helper measurement can be retried after 60 seconds without repeating the full scan. |
| Other System Files | 60 seconds; cloud eligibility separately 600 seconds | Every 2 seconds during cloud removal, using the status-only path. Periodic UI polls retain measured data even past its TTL while removals run. Completion remeasures only the affected provider, then reconciles its cached row in both modules. No whole-module measurement is requested. Explicit Refresh can still force a measurement during removal. |
| Siri & Apple Intelligence | 4 seconds | Every 5 seconds only while models are downloading, releasing, purging, automatically releasing, or an asset purge is being retried. AI being enabled alone uses the ordinary interval. |
| Debloat | 15 seconds | None. App activation forces a quiet invalidating read when this module is visible, so profile approvals are recognized without folding the page. |

When a window becomes visible again, watched modules whose last UI refresh is at least two seconds old are read again. App activation otherwise catches up visible modules whose last UI refresh is at least 60 seconds old. The ordinary age refers to the last host refresh; each module independently owns the age of its measured snapshot.

The optional Siri watch runs every 900 seconds and is disabled by default. The Debloat watch also runs every 900 seconds and is enabled by default. Their schedules are independent of presentation polling. System Data, Other System Files and Siri participate in separately configured automatic cleanup.

## Module contract version 5

- `tile(context:progress:)` reads the dashboard presentation and reports real scan progress. All four shipped modules implement it and share the scan with concurrent page requests.
- `screen(context:progress:)` reads a page and reports scan progress. Cached presentations stay quiet.
- `status(context:)` optionally returns a lightweight `(tile, screen)` presentation based on already measured data and current counters. It must not enumerate files or query services. Returning nil asks for an ordinary read. The host checks this entry point on automatic reads and bypasses it for explicit invalidation.
- `Tile.refreshAfter` requests the next automatic update sooner. Other System Files and System Data implement `status` for shared background cloud removal. Other modules currently return nil and use their ordinary measurement/cache path.
- System Data remeasures only action targets, including remaining files after partial cleanup; Other System Files reconciles its affected service or backup target; Siri asset purges remeasure only assets/model sizes. Their action results return a verified cached presentation. System Data adjusts its displayed baseline by the same counted target delta as its graph, retaining the full scan age. That reconciled baseline remains an estimate until the next complete category measurement.
- Cloud completion keeps eligible downloadable bytes separate from total local bytes (pinned files may remain). Both modules use `CloudFileRows` and `CloudDownloadRemovals`; unknown/unreadable measurements retain the previous value. Volume free-space gains are history data, never item sizes.
- `invalidate()` drops measured data; it does not publish UI by itself. `ActionResult.refresh` requests a presentation refresh after an action.
- The host owns visibility, timers and whether loading is explicit or automatic. Modules supply measurements, counters and their progress; row actions reuse the existing capsule, hover and progress treatments.

The SDK and all four bundled manifests are version 5. A version-4 module is rejected by the existing compatibility check instead of being loaded against the changed protocol.

## Legend animation

The legend grid no longer animates its layout when measured segments change. Its inherited grid-layout animation is cleared; each element retains `PageItemReveal` for the existing vertical cascade, and each byte label retains the vertical roll/blur style with an anchored overlay that keeps outgoing glyphs out of layout. Fade-only content changes are reserved for Reduce Motion. Graph loading is independent of legend visibility, so live reads retain the legend. Page navigation transitions remain unchanged.

## Text motion and action labels

`ChangingText` routes numeric-only changes in an unchanged phrase through the native `.numericText()` transition with
`Theme.value`. Phrase changes use `TextMotionState` and the shared word renderer in `App/Shell/WordMotion.swift`, for captions,
row flags, page buttons and All done. The native numeric view is removed immediately at that boundary, so its unfinished 30% ->
60% transition cannot keep painting over “IA desativada.” A word playback has one generation; replacement cancels its task, and a
stale completion cannot clear a newer phrase. Counter updates during an entrance update its latest incoming snapshot without
restarting the word cascade.

Outgoing/incoming snapshots retain their fonts and measured bounds and share the caller's leading, center or trailing anchor.
Changed words alone use the original roll/blur treatment (0.45-second spring, 0.22-second exit, 0.025-second stagger). Unchanged
words draw once in the incoming paragraph. Native shaping and wrapping remain in one Text paragraph, with word attributes rather
than independently measured word HStacks. No horizontal motion, whole-line slide or fade-only replacement is added. Reduce Motion
uses the existing opacity fallback. A final renderer clip keeps glyphs/blur within each snapshot's trailing edge while retaining
vertical travel. Numeric views are recreated from the latest text after word playback, with no older phrase retained underneath.

Loading percentages keep their natural width and tabular digits, normal word spacing and the caption's right inset. Digit-count
changes take their natural width. Other figures retain proportional spacing. All done alone reserves width from its explicit
counting template. Single-line split fields use leading paragraph alignment to preserve trailing spaces; current text alone
measures layout. Word layers are overlays and cannot change pill height, reserved row widths, footer space or button truncation.
Changed text keeps the page cascade delay.

Idle row flags fit their title. `ReservedPillLabel` reserves known numeric variants of the current phase; unrelated future phrases
such as background cleanup do not widen “Freeing space.” `PillMorph` handles phase-boundary shell resizing with the existing page
button behavior. Optional `Action.labelSamples` supplies numeric variants; it decodes as nil for older saved actions and does not
change the module protocol version. Full messages remain available in help.

The orange page button keeps horizontal `PillMorph` resizing but is always 31 points high and one line. `SingleLineActionLabel`
measures its ideal width independently of the shell's intermediate proposal and caps it to the dock's available width. Long notices
truncate with full help text. No wrapping fallback is allowed. The original label measurements inherited a narrow intermediate
proposal during shell resizing, which could make even “Carregando” wrap; the separate ideal measurement prevents that feedback.

Progress fills carry the fraction without duplicate percentage text; cloud flags retain the removed-byte count. Inserted/removed
rows and flags keep the vertical cascade, while unchanged rows remain in place. A row flag's phase change also animates its containing
controls through the capsule's presented width. `PillMorph` measures/places its destination with an unspecified proposal, independent
of the parent's intermediate allocation. The surrounding HStack has no second phase spring: its controls follow that single width
each frame. A second spring and proposal-dependent measurements repeatedly squeezed the warning badge and retargeted the flag.
Fraction-only ticks do not retarget the shell; Reduce Motion updates its width immediately.

Cells (including shade and separator), headers and sections use SwiftUI's `geometryGroup()` before their cascade modifiers. This
resolves ancestor placement as one transform before descendants' independent text transactions; labels and pill text cannot cancel
the cell's motion and detach from its background. This is the row-animation use described in
[Apple's geometryGroup documentation](https://developer.apple.com/documentation/swiftui/view/geometrygroup()). Text/number content
motion retains its existing renderer, anchors and timings.

The form's flattened item identities, rather than only section ids, drive structural layout. `PageCascade.Structure` preserves the
previous whole-page order/offset/count. Gap closure waits for the latest departing item's existing reverse-cascade delay plus its
0.22-second duration, then uses `Theme.layout` to move survivors and following sections together. Initial loads, numeric/status
updates, reorder-only changes and insertions add no departure delay. New changes are ordinary SwiftUI transactions, with no timers
or stale asynchronous removal callbacks. Reduce Motion retains opacity departure and closes the gap without spatial animation.

Other System Files retains the `purgeFiles` row action during retries, with “Freeing in the background” in `Row.activity` rather than
a separate badge. The same flag owns foreground progress and background work. A successful result whose verified presentation
contains matching row activity (action id and exact target parameters) does not create a second completion flag or All done page.
Failures, restart requests and unrelated background targets still keep their result UI. Savings/history are recorded as before.
The orange dock fades out with an opacity transition in a stable 31-point frame. `ActionDockLifetime` retains footer space until
SwiftUI's `.removed` animation completion, without a timer; a newer phase invalidates the old completion. Footer animation belongs
to the scroll area and cannot reposition the exiting dock.

## Window controls and confirmations

Inactive controls use the same fallback as Reduce Transparency, with day/night colors and a fading transition. Active glass also
uses the selected day/night appearance. Last-window closure hides the active app first and defers accessory-policy demotion until
activation has passed to another app. Status/popover windows cannot promote the app back to regular presence. This addresses a
suspected cause of the reported menu-bar flicker; the visible result requires user verification.

Every app-owned dialog must use `AppAlert`, including module/cache cleanup, startup, About, uninstall and error dialogs. Its modal
entry explicitly installs the shared alignment pass. Both layout and the final view drawing pass align icon, heading and message to
the native 20-point leading inset. Alignment applies to the image inside its frame and to attributed paragraph runs as well as the
text-field property; an attributed centered paragraph can otherwise remain visibly centered while the cell reports left alignment.
Preserve native buttons, fonts, complete messages and alert appearance. Do not add per-module confirmation layouts.

## Verification and references

The refresh, loading, cleanup and motion behavior above is covered by automated tests (the last full run of this series: 513 tests,
508 passed, five optional tests skipped: live CacheDelete opt-ins and saved render snapshots) and by localization checks in all
eight languages. The tests cover live and manual refresh, immediate loading captions, retained choices, stale reads, targeted partial
cleanup, excluded clones, repeated purges, shared cloud progress, All done verification, inline permission failures, confirmation
frames, window presence, the text-motion rules (numeric and phrase routing, stale-completion cancellation, Reduce Motion, fixed
percentage and byte-figure widths through 100%), pill geometry with intrinsic measurement, and alert alignment for all three native
styles. Motion and animation are checked by the maintainer by eye; no GUI automation is used.

macOS's **Allow Notifications** for MacSpace was found disabled during the 2026-10-18 notification investigation. That setting blocks
every notification type regardless of the app's own switches; the user enables it in System Settings, and MacSpace changes no
notification rules.

Main sources: `App/Registry/ModuleHandle.swift`, `App/Registry/ModuleHost.swift`, `App/Shell/MainView.swift`, `App/Renderer/ScreenView.swift`, `Sdk/Contract/Module.swift`, `Sdk/Interface/Tile.swift`, and each module's snapshot store/screen builder.

## Feature model cleanup (2026-10-18)

Siri and Spatial Photos use the existing ToggleRow control; Phone combines local preferences with verified post-restart gates. The AI language control remains first. Changing a feature reconciles switch state only. Cleanup completion reconciles model measurements and assets without a full-page reload. The module requests five-second presentation polling during active feature cleanup, with existing badges and text transitions.

The separate default-enabled `featureModels` background task checks explicitly managed-off Siri, Phone and Spatial Photos controls every 300 seconds while MacSpace is open; the optional 900-second AI watch remains separate. Shared owner operations run in the signed CLI, and one guarded CacheDelete pass serves a batch. Unknown eligibility stops new owner cleanup and its deferred purge attempts. Empty target inventories do not start another purge. System Data retains the `purgeAssets` action identity and `Row.activity` flag during model-cleanup background retries.

Implementation and validation: [Issue 16 implementation reference](Research.md#issue-16-implementation-reference).


## Apps and Files cached refresh work (2026-11-04)

Recursive refreshes mark each affected folder and its ancestors for total reconciliation. A mark now stops at the first ancestor already present in the transaction's dirty table: that ancestor's chain is already covered. Path validation runs once at the input boundary. This retains hard-link alias reconciliation and rollback behavior without repeatedly validating and inserting the shared root chain for every directory. No unbounded Swift path cache is added.

Refresh progress uses the cached directory and entry counts for the affected scopes, including directory-only work. Caches with missing entry counts report measured directory work until those counts have been filled by a completed reread. Traversal retains its 0–80% scan phase, followed by totals counted through the existing database cursor; the host's existing module-stage weights and monotonic relay still apply. Cached progress uses work performed rather than a timer or the old fixed 100,000-entry heuristic. Entirely new subtrees retain a work-based estimate until their first inventory is available, instead of claiming their traversal is complete prematurely. Cached content remains visible throughout.


## Focus and scan lifetime (2026-11-04)

Switching to another application stops future automatic polling but lets an already-running read of a visible MacSpace window finish. Returning to MacSpace retains that read and its progress instead of starting another generation. Lazy page reads and action verification use the same activity rule. Activity updates are serialized and coalesced so an old queued suspension cannot cancel a newer read.

Closing/hiding the last visible window still suspends optional inventory work. The host retires its read/page generations before suspension, so a cancelled module reply containing the previous cache cannot be published or recorded as a successful refresh. Disk inventory retains exact interrupted directory scopes independently of its watcher and retries a cancelled flight when a newly active caller joins it. Cancelled shallow directory scopes are not reinterpreted as file events on their parents.

## Filesystem history and full-root reconciliation (2026-11-04)

A queued root rescan subsumes pending historical details. FSEvents callbacks retain lazy CF path access and continue handling history-completion flags, without decoding every covered file path. The pending directory ledger is bounded at 8,192 scopes; a larger backlog conservatively becomes one root rescan. Native dropped/wrapped/root-change flags likewise invalidate the whole root, regardless of the event path's exclusion. Draining restores precise tracking for later events. No change coverage is silently discarded.

Lexical path checks use a single UTF-8 pass with the same absolute-path, NUL, duplicate-separator and dot-component rejection. Existing no-follow, ownership and filesystem checks remain authoritative.

A full-root reconciliation already recalculates every directory, so it avoids per-directory hard-link parent expansion and repeated dirty-ancestor insertion. Per-directory savepoints track seen entry names, retain unchanged rows, remove absent names only after a complete enumeration, and preserve the prior cache on unreadable directories. Global depth-ordered totals still cover hard-link allocation transfers, including aliases beneath an unreadable directory. Conditional updates avoid rewriting identical directory, file and total rows.

Opt-in `MACSPACE_DISK_METRICS=1` phase timings can also be written to `MACSPACE_DISK_METRICS_FILE`, allowing a complete native replay from an isolated SQLite backup to be profiled without controlling the app UI. The measured stale-cache full-root pass over about 386,000 directories fell from approximately 150 seconds to 69 seconds; a new module/store reopening the completed checkpoint took approximately 5.7 seconds. This is an end-to-end backend measurement, not an animation or a synthetic percentage.

## Further loading reductions (2026-11-04)

An already-required full-root read can begin without waiting for historical FSEvents delivery. The watcher records a current-event coverage boundary before that read; historical IDs through the boundary are covered by the forthcoming full scan, while newer IDs remain tracked. Native loss/wrap/root-change control flags and history completion are processed even for covered batches. Wrapped IDs clear the old boundary, including combined completion/wrap flags. Cancelled full-root scopes retain this coverage rule on retry. This removes the old replay wait without advancing a completed index before its scan actually commits.

Receipt manifests and their plist/BOM timestamps are retained in a versioned, owner-only cache. The receipt adapter still checks current source timestamps before reuse; a changed BOM is reread. No app signing, classification, ownership decision or removal plan is persisted by this cache, and forced app reviews bypass its seed.

Ownership-path normalization filters valid candidates once and tests ancestors directly against that set, retaining the previous outermost-path semantics and lexical output order without repeated grapheme-length sorting. File-allocation fallbacks are deduplicated within a bounded cache tied to the scan root and revision; a new revision rereads the files, and authoritative projected measurements always take precedence. Fresh destructive preflight remains unchanged. The reconciled allocation view is also retained in the inventory actor so later status reads do not revert to an earlier presentation.

Against the same isolated cache baseline, release-mode full catch-up improved from 70.9 to 53.8 seconds, and cached reopening from 5.6 to 2.4 seconds. Two final measured runs yielded approximately 54 seconds / 2.4 seconds. A trial reusable directory-buffer API did not improve end-to-end timing and was removed. Measurements use the full tile/screen backend load; visual app verification remains with the maintainer.

## Parallel full refresh and startup progress (2026-11-04)

Full-root refreshes now reuse the existing eight-reader native directory walker. One SQLite writer stages file rows and per-directory completion records in temporary on-disk tables. Staging uses bounded worker batches; incomplete directories never replace their previous file memberships or measurements. Only fully enumerated directories are merged. Missing branches are removed only beneath a fully enumerated parent. Pending parent IDs are resolved before removals, and changed hard-link families still update retained aliases beneath unreadable branches. Cancellation preserves the completed index; published generations remain atomic. The existing sequential path remains the comparison/reference path and handles targeted refreshes.

A retained cache is not considered current merely because its event watcher has not delivered history yet. Startup validates that history first. Completed, filtered/empty history advances its consumed event cursor without claiming a new measurement revision, preventing old history from being replayed indefinitely on each launch. If historical delivery has not completed within one second, a current full-root read conservatively covers the old backlog. Its watcher restarts at the coverage boundary so newer changes are replayed and old callbacks cannot consume the scan's resources. Wrapped/lost-event handling retains root invalidation.

Bootstrap and event-preparation stages report work as they finish (2% and 4% of the storage read); the traversal follows its measured cached workload. No time-based percentage filler is used. Native enumeration now reports an incomplete directory when a per-entry error or missing name occurs, allowing its previous truth to be retained rather than publishing a partial replacement.

The final opt-in release-mode cold-start replay starts timing before cache bootstrap and does not pre-open or force a root invalidation. Against the same stale cache, first positive module progress arrived at 0.39 seconds, the full history catch-up and module presentation completed in 27.6 seconds, and a new store/module reopened in 2.7 seconds. The preceding full refresh was approximately 54 seconds. A separate forced-root run completed in 23.4 seconds. Cold replay includes an explicit maximum-first-progress and total-load validation. Synthetic parallel/sequential comparisons verify the final directory/file measurements, new nested parents, removals, symlink exclusion, changed hard-link aliases, unreadable/dataless branches, partial enumeration and cancellation/retry.

Loading progress now gives metadata scanning 4–92% of the storage read, followed by personal-inventory migration through 94% and duplicate verification through completion. This replaces the old 65% scan endpoint and large reserved tail for often-empty stages. The module maps storage to its first 90%; app discovery, registration lookup, ownership review and allocation reconciliation report their measured work through 99%. Shared inventory callers join the same progress relay. Full totals reconciliation reports actual completed directory counts, including within small batches, rather than starting one quarter complete. The module reports 100% only after navigation and screen construction finish. Percentages remain work estimates; a skipped or very fast stage may still advance immediately.

## Protected-storage session checks (2026-11-07)

Inventory statements use a lock-notification gate with a 100 ms fallback session probe. They no longer issue one WindowServer
session request per SQL statement. Keychain reads/writes still force a current session check. This preserves immediate
notification-driven suspension while avoiding per-row OS round trips. The isolated measurement and its end-to-end limits are in
[Research.md](Research.md#session-probing-during-inventory-writes-2026-11-07).


## Apps and Files totals at 66% (2026-11-10)

The page truncates its loading percentage. The start of full folder-total reconciliation maps to
`0.9 * (0.04 + 0.88 * 0.8) = 0.6696`, displayed as 66%. The scan can therefore appear stuck there
while totaling a large inventory. Native refresh also reaches that boundary before merging its
staged rows. The screenshot alone does not identify which of these operations is pending.

Totals now have a covering partial index by parent for hard-link rows, avoiding reads of ordinary
file records already accounted for in each directory's direct bytes. Full reconciliation updates
bounded groups of equal-length paths in bottom-up order, rather than issuing an update for every
folder. Equal-length paths cannot contain one another; the existing hard-link representative
ordering and conditional writes remain unchanged. Smaller inventories use smaller batches so
measured progress continues throughout reconciliation.

Native initial/full scans and targeted reads also skip redundant parent insertion checks when
writing file records: those scanner paths have already ensured the parent before enumeration.
Other database callers retain the parent check. No file classification, scan coverage, deletion
policy, or content verification is skipped. The new synthetic totals regression compares the
previous per-folder calculation against the optimized result, including shared hard links and
subsequent partial reconciliation; existing native/sequential tests cover scanner equivalence.

Snapshot construction also reads direct child directory records in one indexed query, using the
same decoder as individual directory reads. This removes one-query-per-child startup/navigation
work for broad folders without changing projected records or the child order. The initial debug
synthetic totals run (2,000 folders, 132,000 file records) measured 1.02 seconds for the former
per-folder/index configuration and 0.18 seconds for grouped/indexed totals, with identical bytes.
A subsequent run measured 109 ms versus 28 ms (3.8×). These are phase timings on a generated
database, not an end-to-end app launch measurement. The 48 targeted checks passed (one opt-in
audit skipped), including measured progress and four navigation requests over 20,000 cached
managed folders in 1.03 seconds with no app-discovery or content-hashing work.

The broad regression run also exposed a cancellation cleanup crash: a throwing database initializer
finalized its prepared statements in its failure defer, then deinitialization finalized the same
pointers again. Failure cleanup now clears the statement cache before closing the connection.
A cancelled-initialization regression verifies both safe unwinding and reopening the unpublished
cache. This was confirmed by an XCTest crash report in `msc_sqlite3_finalize` during cancelled
cache-generation initialization; it is separate from the expensive totals phase in the screenshot.

Final follow-up validation: 70 tests executed, one opt-in audit skipped, no failures, including
cancelled initialization, totals, ownership, removal and the previously load-sensitive navigation
timing check (0.90 seconds on rerun). A preceding 44-test run passed the cancellation regression
but exceeded the navigation timing threshold (2.04 seconds against 1.5); the complete-suite run
before the cleanup fix terminated in the cancellation crash rather than completing. The broad
memory check passed. No app was opened or visually inspected.


The follow-up filesystem profile covered about 401,500 directories and 66,800 retained file rows.
Traversal/staging took 109 seconds despite the earlier totals optimization. Directory readers were
waiting on the SQLite writer for failure checks, first-file hard-link lookups and empty flushes.
Walkers now use atomic failure/cancellation flags, a bounded set of linked directory paths with an
indexed fallback, and skip empty batches. Native exclusion prefixes are prepared once, with path
validation retained for matching candidates. Bulk scans temporarily use a 16 MiB page cache,
returning to the 2 MiB cache afterward. Native staging shares the compact entry primary-key layout.

Native merge now seeks past completed directory IDs, reconciles retained hard-link evidence before
joining staged aliases, and merges bounded parent-ID ranges. This removes the alias-family cross
product and reports completed merge work, with cancellation checks between batches. The original
hard-link query took 75.65 seconds for a generated 10,000-name family; the filtered query produced
the same result in 0.012 seconds. That fixture is separate from the real-filesystem timing.

The filesystem full-refresh measurement fell from 156.4 to 44.4 seconds, with traversal/staging
falling from 109.2 to 18.1 seconds. Cold scans were 51.7 and 53.5 seconds. Measurements used
isolated fixture-key databases on AC power with Low Power Mode off. The baseline already included
the merge instrumentation/compact staging changes, allowing the subsequent walker changes to be
measured independently. Thirty-seven release regression tests passed, including partial-merge
cancellation/rollback/retry and bounded linked-directory fallback. The opt-in filesystem diagnostic
also passed. Visual and Low Power Mode verification remain with the maintainer.


## Cached navigation and deferred warm-up (2026-11-12)

Reopening a measured module retains its page while a silent navigation read verifies it. Tile and page freshness are tracked
separately. Presentation requests share a read; opening a page during a tile-only read requests the missing page afterward.
Explicit invalidation, option changes and action verification retain their generation boundaries and supersede older output.
Initial loads and explicit Refresh keep their existing progress and animation treatment.

Home delays the first detailed Apps and Files read by one second. Its tile read warms both disk and app inventory using the
existing shared backend flights, without constructing an unused screen. A direct visit cancels that delay; hiding/closing the
last visible window cancels pending warm-up. Normal filesystem event reconciliation and fresh destructive preflight are unchanged.

Each module retains only session scroll offsets and expanded-section IDs in a bounded cache (12 entries, or the open stack plus
its root when larger). Deactivation drops those values. Rendered view trees and new persistent page caches are not retained.
Widget projections reuse the current content, selection, width and fitting inputs. Word motion prepares its tokens, matching and
paragraph descriptions outside interpolated frames; its shaping, anchors, blur, spring and timing remain the same.

Scan and lazy-navigation reports retain one pending main-queue delivery, with the first report dispatched immediately and later
updates at most once per 33 milliseconds. The latest monotonic value replaces intermediate reports; completing or superseding a
read rejects queued/late callbacks. Action progress and its completed-item accounting remain unchanged. Concurrent disk-capacity
requests also share one utility read.

Headless release diagnostics are opt-in:

```sh
MACSPACE_RESPONSIVENESS_BENCHMARK=1 swift test -c release -Xswiftc -enable-testing \
  --filter 'ResponsivenessBenchmarkTests|DiskWarmLoadingBenchmarkTests'
MACSPACE_RESPONSIVENESS_BENCHMARK=1 MACSPACE_BENCH_LOAD=1 swift test -c release -Xswiftc -enable-testing \
  --filter ResponsivenessBenchmarkTests
```

The host fixture intentionally emits 10,000 progress reports to exercise burst delivery. Its two optional CPU workers provide
controlled contention; its short heartbeat sample is a scheduling diagnostic, not an animation-frame benchmark. The host revisit
loop includes navigation cancellation/coalescing, so it does not imply 20 completed scans. The separate disk fixture measures
300 folders and 1,200 files with an injected 25 ms app-inventory read. These fixtures do not measure production launch, signing
checks or actual animation smoothness, and use no production cache, app window or helper.


Release fixture comparison against checkpoint `6014641` (medians; six disk runs, three host runs per CPU condition):

| Disk fixture | Checkpoint | Updated |
|---|---:|---:|
| Detailed tile warm-up | 31.1 ms | 106.9 ms |
| First page after warm-up | 41.8 ms | 13.7 ms |
| Twenty cached backend screens | 112.1 ms | 259.9 ms |
| Backend resume after suspension | 33.6 ms | 45.4 ms |

| Host progress fixture | Checkpoint idle / two CPU workers | Updated idle / two CPU workers |
|---|---:|---:|
| First read | 14.3 / 14.9 ms | 4.4 / 4.7 ms |
| Twenty navigation requests | 1.5 / 1.2 ms | 8.0 / 10.3 ms |
| Process CPU across the fixture | 22.0 / 50.2 ms | 14.5 / 48.6 ms |
| Process peak RSS | 88.6 / 88.8 MiB | 77.5 / 77.5 MiB |
| Short heartbeat p95 excess delay | 10.8 / 12.7 ms | 2.1 / 2.4 ms |

Prewarming deliberately moves app-discovery work into the tile read, reducing the first page's wait. The host previously
superseded navigation reads, while the updated host joins them, so navigation-loop duration is not a comparison of equal completed
scan counts. Cached disk/backend timings varied substantially: the first updated run took 106 ms for twenty screens, versus
260 ms across repeated runs. Those cached paths have no new scan algorithm, and this measurement does not establish a general
backend speedup; environmental contention was not held constant between the baseline and updated batches. The short host
heartbeat also has only two to seven samples per run. Animation frame rate and full app launch remain unmeasured.

Validation passed 202 distinct headless checks across the checkpoint, targeted, broad and optimized runs; one optional production
cache audit was skipped. The optimized selection passed all 52 checks. One existing scan-action test fixture was corrected to
publish its cleanup action, matching the already enforced executable-contract policy; its original failure was reproduced against
the checkpoint build. No app window was opened and no screenshots were taken.
