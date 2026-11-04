# Disk revision: security and verification record

Date: 2026-11-03. Implements the user-authorized `Disk-Next-Fix-Plan.md` and the reported selection, background CPU, app-readiness and progress issues. App and visual verification remains with the user.

## Selection and removal

Every eligible verified duplicate copy is selectable. A complete frozen selection, including ordinary categories and other pages, must leave an eligible verified survivor. Selecting every copy preserves the user's choices, reports the conflict and removes the Free action. Unavailable selections are explicit and can be unchecked inline.

Selected file identities and original content digests remain frozen on disk. Full bounded preflight resolves an unselected survivor against the entire token, rechecks eligibility and open-file evidence, and verifies both contents. Execution checks the selected identity and survivor identity immediately before each removal. Choosing another surviving copy never changes the user's selected files. A disappeared, changed, unreadable or selected survivor cannot validate deletion.

The existing unprivileged personal-file boundary, no-follow ancestor handling, protected flags and permanent/Trash confirmation checks remain enforced. Unmatched-data deletion retains its separate bounded recursive validation and recovery manifest. Uninstall retains privileged exact-plan validation. No new deletion authority or automatic cleanup is introduced. Coordination and per-call checks do not make separate filesystem operations atomic against uncooperative same-user processes.

## Publication and background work

App catalog discovery and ownership preparation join module readiness. All app/unmatched measurements use global authoritative input; folder projections cannot erase valid prior totals. Missing measurements remain pending, with completed prior values preserved where available.

Completed Disk tiles no longer request five-second polling. Losing foreground activity cancels optional scan/hash/browse work and stops Disk filesystem watching; event history is replayed from the persisted watermark on return. Host automatic reads and periodic volume measurements are foreground-only. Real idle CPU has not been measured through the app and remains for the user's verification.

Smaller-file pages publish a bounded preview before full scoped metadata preparation. Full type totals remain separate from the bounded file window. A maximum of four scoped browse results/workers is retained; changed scopes invalidate their affected results. Generation checks reject canceled worker replies. Current content remains visible with reported loading percentages. File-map focus includes a represented file even outside the first window. Category/type selections stream independently of browse windows.

## Code-level validation

- 712 distinct tests passed across the broad code-only suite and final focused regressions; five tests were skipped. Native window/render/screenshot tests were excluded.
- Regression coverage includes choosing either duplicate copy, cross-category survivor conflicts, stale survivors, all-copy selection, 207-copy pagination and vanished cursors, complete type selection beyond bounded windows, 10,021/10,050-file frozen selections, metadata readiness, false-zero prevention, cancellation, quiet-refresh checkbox edits and progressive direct-file focus.
- The compiler localization extraction/check passed for all seven languages and built all package products. SDK 14 is consistent across bundled manifests. Whitespace verification passed.
- The existing real-content tests verify 128 MiB duplicate candidates and bounded repeated hashing. No app launch or manual UI checks were performed. The subsequent user-requested development assembly is recorded below.

## Performance evidence and limits

The final broad suite measured a 50,011-folder / 100,000-small-file fixture at 1.129 seconds for index construction, 0.031 seconds for 100 bounded page reads and 4.42 MiB additional sampled footprint. The fixture retains no ordinary whole-disk small-file detail inventory. A 4,001-name hardlink family scanned in 0.099 seconds initially and 0.148 seconds incrementally. A 10,050-member frozen selection used 51 bounded batches and one finalization in 3.165 seconds. These are backend fixture measurements, not production-disk or live-app CPU/footprint measurements.

Disk production Swift grew from 3,240 lines at the pushed baseline to 3,669 lines, a net increase of 429 lines, excluding shared host/SDK changes and tests. Obsolete keeper restrictions and background discovery logic were removed, but this revision does not achieve a net code-size reduction.

## Notarized development assembly

Built `1.1.5-dev` (`1.26307.182427`) with `DEV=1`, release optimization and SDK 14 into `Build/Dev/MacSpace.app`. Signed with Developer ID Application: Giovani Mantovani (J45ZXS2ZF6), accepted by Apple notarization and stapled. Deep strict code-sign verification, `stapler validate` and Gatekeeper assessment all passed on the final artifact. The app was left unopened; the installed copy was not replaced.

## Folder navigation regression correction

The first SDK 14 development build introduced navigation work that the prior tests did not cover at production index scale. Folder entry waited for all-size duplicate preparation. Direct-file metadata also paged through every cached descendant, while its OR-only SQLite predicate rebuilt a subtree ordering on each page. Preview traversal counted eligible folders only, so a managed subtree with no eligible folders could exhaust the entire subtree before returning. Those paths explain long zero-percent waits and sustained CPU/allocation growth.

Folder and duplicate-page navigation now use the completed cache without starting duplicate discovery or content hashing. Folder pages reuse the ready app catalog without recomputing global app ownership. Direct-file requests touch exactly one directory; managed scopes complete without optional workers. Recursive personal-file review uses explicit indexed ranges within eligible personal roots, and previews count every visited directory toward their bound. Full selection streaming shares that scope traversal. Foundation metadata objects drain inside bounded directory/entry autorelease pools.

The new synthetic module-level regression covers parent/nested/managed navigation with 20,000 cached managed folders and asserts zero app-catalog reads and no fingerprint table creation. A separate backend check used an isolated SQLite backup of the existing 420,885-folder cache: seven initial folder reads took 0.198 seconds with 0.1875 MiB additional sampled footprint. Repeating those locations twenty times completed 140 reads in 3.122 seconds with 0.53125 MiB additional sampled footprint. These are backend cache reads, not live app CPU or UI measurements. The current code-only suite plus the opt-in cache regression passed 713 distinct tests; five remain skipped. No app/UI interaction was performed.

Corrected development assembly: `1.1.5-dev` build `1.26307.185259`, in `Build/Dev/MacSpace.app`. Developer ID signing, Apple notarization, stapling, final deep/strict signature verification and Gatekeeper assessment passed. This supersedes build `1.26307.182427`. The app remains unopened and the installed copy was not replaced.

## Final user-directed revision and independent duplicate review

The user requested an independent agent review of duplicate logic. The reviewer checked the screenshot's actual icon and test-fixture pairs: each pair had matching SHA-256 contents and separate inodes, including two differently named files in the same folder. Asset manifests and test source referenced these intentional project resources. Same-folder placement itself is not a false duplicate signal.

The implemented duplicate eligibility narrows automatic duplicate cleanup for evidenced project resources, including cached results and fresh execution batches, without changing ordinary personal-file review authority. The reviewer initially flagged repeated whole-projection pagination, missing Xcode-only project evidence, stale execution policy and survivor substitution after preflight. Each was corrected: one verified-scope stream, an indexed candidate digest relation, bounded early-stop proof lookup/per-batch survivor reuse, explicit Xcode evidence, fresh execution policy and action-specific disk-backed frozen survivor proofs. Final independent read-only verdict found no remaining blocking duplicate-logic issues. Custom project formats and non-atomic operations against uncooperative same-user filesystem changes remain stated limitations.

Duplicate header Select All now selects safe removable copies per complete set rather than all copies: two copies selects one; larger sets leave a survivor. It preserves previous manual choices, supports an open verified survivor, computes semantic header state across pagination and clears only the scoped duplicate subset. Original global/cross-category all-copy conflicts remain blocked. Set, row and action figures use allocated space consistently.

Cached navigation no longer begins Loading by default; only real progress reports create that state and completed page generations reject late callbacks. Pending metadata completion refreshes only the current page, avoiding cancellation/restart loops from unrelated filesystem events. Installers use the existing all-size indexed inventory. File-type/set headings are list titles outside file rows. Folder views include descendant personal files even when a direct `.ini` exists; photo-library internals are inspectable read-only and are rejected as cleanup-selection scopes.

Final broad code-only validation: 727 tests executed, six skipped, zero failures. Focused additions cover page loading/late progress, installers without workers, direct `.ini` plus nested images, read-only photo libraries, duplicate sets beyond 200 members, manual-first preservation, open survivor, fresh project/Xcode evidence and exact preflight proof reuse. Native window/render/screenshot tests were excluded. SDK 15 is consistent across bundled modules. App/UI/live CPU verification remains with the user.

Final SDK 15 delivery: `1.1.5-dev` build `1.26307.203606` at `Build/Dev/MacSpace.app`. Release optimization with development tools enabled; Developer ID signing, Apple notarization and stapling completed. Final deep/strict signature verification, Gatekeeper assessment and stapled-ticket validation passed. Compiler localization extraction passed for all seven languages. The app was left unopened; the installed copy was not replaced. Working changes remain uncommitted.

Final cumulative Disk production Swift: 3,882 lines versus 3,240 at the pushed baseline, a net increase of 642 lines. This includes project-context eligibility, safe duplicate header semantics and frozen preflight proofs; no net reduction is claimed.

## Latest settings/navigation/row follow-up

Removed the implicit re-enable path for the storage destination and added disabled-destination checks. Deactivation suspends optional module work and retires pending page/loading/refresh state; activation/visibility callbacks recheck readiness. Smaller-file expansion changes page identity at the same breadcrumb depth so the existing page transition plays. Page-follow replies are fenced against newer navigation and changed destinations. Navigation reads only visible frozen membership before publication, rather than collecting complete category scopes.

Removed redundant ordinary category headings and location badges. Existing Finder paths remain available, with the user-requested shared-renderer experiment placing Finder controls after size/chevron. Directory counts are collected with existing scanner metadata and persisted optionally; visible legacy counts are measured per directory/revision. Empty ownership tables skip needless per-folder ancestor lookups.

Regressions cover disabled Disk dashboard/navigation, replacement transition identity, real module Show smaller files with a retained map and expanded inventory, truthful small-file/subfolder counts across reopening and legacy null metadata, plus previous selection/removal protections. App/UI verification remains with the user.

Verification for the latest follow-up: the broad code-only suite executed 730 tests with six skips and zero failures. A final focused rerun passed after the disabled-lifecycle guards and bounded membership read were added. Frozen selection counts, known header states and previously reported issues are retained during bounded navigation reads; complete fresh identity/content/survivor validation remains mandatory at deletion preflight. No app/UI/render verification was performed. The shared Finder-placement change remains an isolated renderer experiment at the user's request.

Latest follow-up delivery: `1.1.5-dev` build `1.26307.211855`, built with release optimization and development tools into `Build/Dev/MacSpace.app`. Final Developer ID signature, Apple notarization, stapled ticket, deep/strict verification and Gatekeeper assessment passed. App remains unopened; installed copy not replaced. Changes are uncommitted.

## Latest explicit user correction

Show all files now opens a new list-only page with no graph, adding one breadcrumb through the default page push. The prior same-depth replacement is superseded. Normal push starts immediately before lazy metadata resolution; pending destinations are not treated as completed cached pages, and late replies remain fenced by navigation/action/lifecycle state. A gated host regression asserts the new path is present synchronously before page metadata is released.

Ordinary file selections no longer inherit duplicate provenance. The user explicitly authorized selecting/deleting both identical files through ordinary categories/folders without the duplicate-survivor alert. Original identity, positive deletion boundaries, current-use checks, mode confirmation and unprivileged execution remain mandatory. Duplicate review provenance retains its survivor and content-verification requirements. Regressions exercise two ordinary identical files through complete frozen selection, preflight and execution resolution and verify both are eligible for the explicit batch; a separate duplicate-origin manual all-copy regression still requires a survivor. Ordinary navigation omits unrelated duplicate evidence queries.

Validation of the latest user correction: the broad code-only suite ran 730 tests with six skips and zero failures. The final focused run passed ten navigation/duplicate regressions, including the additional duplicate-origin all-copy protection test. The gated page test establishes that the normal destination is pushed before metadata returns; the module regression establishes that Show all files resolves a graph-free `.singleColumn` page. The ordinary identical-file regression carries both selected files through frozen selection and execution resolution with no duplicate warning/proof. No app/UI verification occurred.

Delivery for the default-push/ordinary-origin correction: `1.1.5-dev` build `1.26307.215231` in `Build/Dev/MacSpace.app`. Apple notarization, ticket stapling, final deep/strict signature verification and Gatekeeper assessment passed. Left unopened and uninstalled; changes remain uncommitted.

## Checkbox feedback and completed-removal correction

Selection and deselection now preserve the Free selected pill, projecting visible totals immediately while backend token changes remain serial. Action execution is guarded until edits settle; projected totals are never accepted as a deletion token. Passive page progress no longer masks an existing selected-size action.

A confirmed stale-read race was removed: finished-choice progress invalidated visible membership and allowed the old selection to be revalidated after those targets had already been deleted. Membership follow-up is now suspended throughout removal/post-action presentation, and late responses are fenced. The regression injects a files-changed response if a membership read happens during removal and confirms that no such read occurs.

Disk removal receipts sum allocation only after each successful target removal. SDK 16 carries this as optional `removedBytes` separately from `freedBytes` volume observations. All done displays the verified removed-file allocation with a “removed” label; an immediate 100 MB volume delta cannot replace a completed 1 GB file total. Partial failures count completed targets only. Existing history retains measured volume reclamation, and other modules keep their prior completion semantics.

The broad code-only suite executed 733 tests with six skips and zero failures. Additional focused checks cover rapid/serial checkbox edits, immediate selected totals and idle pill state, no stale membership during deletion, 1 GB removed versus 100 MB actual volume reclamation, partial-target accounting and legacy result JSON decoding. No app/UI/render checks were performed.

## Prepared all-size personal inventory correction

The user reported that Show all still triggered loading and overlapping content during navigation. The prior design intentionally discarded ordinary small-file details after measuring totals, so opening that page started another native metadata walk and published a preview followed by a reordered result. It now retains approved personal-file metadata of all sizes in the existing compact parent-ID/leaf-name inventory during the same disk scan. Ordinary Show all reads bounded SQLite pages with no metadata worker or loading fraction. The visible large-file overview keeps its size threshold. Read-only Photos-package inspection remains outside ordinary deletion authority.

Legacy indexes prepare only their approved personal roots once during module loading, then persist a personal-inventory version marker. Changed-branch reconciliation updates the metadata incrementally. The new tests verify marker persistence, no repeated preparation, no temporary smaller-file table on Show all, complete counts across bounded pages, no graph/loading on the all-files screen and continued frozen bulk-selection behavior.

First publication into the pushed page disables new local content animations so it cannot race the default parent page transition. A filesystem-event lifetime race observed during the broad tests was also corrected: FSEvents retains a weak-target context rather than holding an unretained raw pointer to the watcher during teardown.

Earlier zero-small-detail storage measurements describe the previous design and are historical. The updated design trades additional compact on-disk personal metadata for cached all-size navigation; the 100,000-personal-file fixture now explicitly checks persistence while retaining its 64 MiB additional-memory bound and bounded page queries. No whole-disk Swift file graph, download of cloud-only content or additional deletion authority is introduced.

Final verification of prepared all-size browsing: 738 code-only tests executed with six skips and zero failures. The 50,011-folder/100,000-personal-file fixture retained its 100,000 compact file rows on disk, indexed in 3.555 seconds, served 100 bounded folder queries in 0.030 seconds, and used 15.52 MiB additional sampled footprint. These are synthetic backend measurements, not live app memory/CPU or UI measurements. The successful broad rerun includes watcher teardown, personal-inventory marker persistence, incremental updates, ordinary/duplicate deletion boundaries and selection-feedback/completion regressions. No app/UI/render checks were performed.

Delivery including prepared personal inventory and the preceding selection/completion fixes: `1.1.5-dev` build `1.26307.222027` at `Build/Dev/MacSpace.app`, SDK 16. Apple accepted notarization; stapling, final deep/strict code-sign verification and Gatekeeper assessment passed. Existing caches prepare approved personal metadata once at module load, not on Show all. App remains unopened and uninstalled; working changes are uncommitted.

## Whole-page transition and Apps and files rename

Removed the empty destination published before lazy resolution: complete destination rows/graph and bounded visible membership are now installed before the standard page push. Pending callbacks remain guarded by navigation, action and lifecycle state. Subpages no longer inherit the root loading-detail reveal delay. The gated host regression asserts that no destination/page path is published until data is ready and that rows exist when navigation starts. No new animation or timing was introduced.

The user-facing module name is Apps and files, localized as Apps e arquivos in Portuguese and in all other supported languages. Manifest, root/title/tile labels, breadcrumb fallback and relevant Settings help copy were updated. Stable module/cache/permission IDs are preserved. Actual Full Disk Access system labels remain unchanged. Root/tile-name regressions were added. User performs app/visual verification.

Whole-page/rename verification: the broad code-only suite ran 739 tests with six skips and zero failures. Final focused destination/selection/library regressions and compiler localization extraction passed. Read-only library page preparation also returns its completed projection before navigation, with its former preview path removed. Delivery: `1.1.5-dev` build `1.26307.223651` in `Build/Dev/MacSpace.app`; the packaged manifest says Apps and files and its Portuguese resource says Apps e arquivos. Apple notarization, stapling, final deep/strict signature verification and Gatekeeper checks passed. Left unopened and uninstalled, with working changes uncommitted.
