# Disk implementation — approved plan and task progress

The user authorized implementation with parallel agents. Existing local changes are preserved. App and visual checks belong to the user: do not launch the app or run rendering tests.

## Tasks

| Task | Agent | Initial status |
| --- | --- | --- |
| Persistent selection, controls, aggregate-folder maps, Refresh | Locke | Integrated; session and map tests passing |
| Compact inventory, branch reconciliation, minimum cache/scan cost | Huygens + parent | Integrated compact parent IDs and eligible inventory; measurements pending |
| Category-first pages, Show smaller files, Applications management | Raman + parent | Integrated; in-place expansion and one list surface added |
| Structured System Data cleanup and prompt target publication | Gauss | Integrated; publication regressions passing |
| Automatic incremental duplicate verification, bounded memory | Newton + parent | Real 128/512 MiB content and bounded-memory regressions passing |
| Independent security review | Socrates | Blocking findings assigned; final review pending |
| Shared removal policy, integration, localization, verification, notarization | Parent | Implementing |

## Accepted behavior

- No Recommended section. Apps, Folders, then Large files and duplicates; duplicates belong in that last class.
- Content categories Archives / Installers / Media / Other contain folder groups. No raw mixed-file preview.
- Show smaller files at each category's end; no size menu or new navigation hierarchy. Revealing files never selects them automatically.
- Full category and folder selection spans pagination in the current size scope. All explicitly chosen files persist across Disk navigation and leaving/returning during the app session. Global totals and confirmation reflect all choices. No review page in this version.
- Other folders opens the exact contained folders as a synthetic navigable map; nested aggregates too. Other files stays a list.
- Recognized Applications folder maps show scoped uninstall and honest unmatched-data review at the top.
- Standard top-right Refresh throughout. Existing compact/wide layout and motion only.
- Navigation/Finder/retained-keeper rows have no disabled checkboxes. Blocked files have factual reasons.
- System Data owns its caches/developer/system cleanup targets, excluded from Disk actionable inventories.
- Ordinary removal uses a positive personal-root policy, user UID, local regular-file status, no symlink redirection, protected flags, current-use evidence and unchanged reviewed identity. It is never elevated.
- Permanent deletion remains default; optional Trash setting and confirmations/execution agree. App uninstall/cache lifecycles remain separate and explicit.
- Duplicates run automatically outside blocking load/database writer: same-size groups, inode collapse before reads, cached fingerprints, samples to reject nonmatches, full verification for matches. Fixed buffers, limited workers, cancellation, progressive publication, preserve a verified unselected keeper.
- Small files contribute to totals without whole-disk detailed persistence. Compact directory IDs/names and necessary large-file records; explicit smaller-file browsing is bounded/lazy. Keep only necessary indexes/fingerprints, recover interrupted reads, bound WAL/generations.
- Cached presentation should be available promptly; changed branches update incrementally. Cleanup publishes verified affected target/list/graph/widget changes without unrelated probes or global free-space settling blocking it.
- Reduce production code where it removes duplication/retired machinery, without behavior, performance or security regressions.

## Delivery gates

Code-level selection/presentation/ownership/cleanup/duplicate/cache tests; realistic streaming-memory and scan/cache measurements; no fake timings; independent security review after integration; contract/localization refresh; signed notarized dev build and ticket/signature validation, left unopened. Record unresolved limitations explicitly. Commit/push only if separately requested.

The first independent review identified Trash restore/name semantics, confirmed-mode freezing, unmatched-directory descendant validation, incomplete initial-index recovery, late selection/page replies, root-execution refusal, and per-copy keeper revalidation. These are delivery blockers, not deferred recommendations. Carson is implementing guarded unmatched-directory removal.

Parent integration additionally corrected POSIX path canonicalization in ownership, receipts and events, event-replay synchronization for current snapshots, true >10,000-file selection with a 10,021-file native fixture, confirmed-mode execution and original keeper checks. Public SDK/models changed, so SDK 13 is required by all bundled modules.

Combined checks are passing (202+ executed behavioral/security checks; final counts in delivery log). Production diagnostic before shortening the folder-order index: first scan 79.37 s, cached open 0.120 s, 392,640 folders, 57,805 retained entries (including hardlink allocation records), 186,421,248 database bytes. Final integer-ID order index is under verification. No visual/manual app checks.

## Final integrated status

All requested functional slices are integrated and code-level checks pass. Final production snapshot: 141,828,096 bytes; first load 26.330 seconds; cached open 0.117 seconds in the measured sequential local run. 252 distinct tests passed. See Disk-Final-Security-Review.md for security findings, limitations and honest net line-count growth. Signed/notarized development assembly completed and was installed; signature, Gatekeeper and stapled-ticket checks are recorded by the parent. User visual/app verification remains outside automated work.
