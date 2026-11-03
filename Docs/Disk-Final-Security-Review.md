# Disk plan — final security and delivery review

Date: 2026-11-03. Reviewed against the user-approved plan and existing local changes. Independent reviewer Socrates identified blockers during implementation; parent performed final integrated review and code-level validation after agent quota exhaustion. This is not a claim that the independent agent signed off on the final diff.

## Corrected findings

| Finding | Implemented correction | Evidence |
| --- | --- | --- |
| Staging filenames broke Trash filename / Put Back | Trash uses coordinated original URL with pinned-ancestor and original-file revalidation. Permanent unlink keeps descriptor-relative staging. | Source review; stale/symlink permanent-removal fixture. No user Trash/visual operation performed. |
| Removal mode could change after confirmation | Confirmed mode is captured once and passed unchanged through the full batch. Changed settings before execution require reconfirmation. | DiskMapModule and DiskFileRemoval; selection/presentation checks. |
| Current identity could silently replace reviewed identity | Frozen selection versions retain original identity and duplicate provenance. Full preflight checks current targets against these originals. | Real 10,021-file immutable-selection and replacement tests. |
| Duplicate keepers could change during multi-copy removal | Reject keeper membership in the complete selected snapshot; full content verification before mutation; recheck the original keeper identity before each copy removal. | Mixed-selection proof tests and keeper-change-after-first-copy regression. |
| Unmatched folder removal trusted only top folder | Full bounded descendant preflight, account/device/flags/type validation, observable-use check, private on-disk manifest, no-follow parent descriptors and guarded recursive removal. Failures preserve unremoved data. | Native recursive, symlink, stale child, foreign replacement, protected/special child and open descendant tests. |
| Privileged authority could leak into ordinary deletion | Ordinary and unmatched engines explicitly reject root or unequal real/effective UID. Personal-root policy enforced in backend; privileged helper remains uninstall-only with exact reviewed targets. | Policy/source review and target-validation tests. |
| Stale page/header replies could reopen or modify a retired context | Lifecycle/action/navigation generations reject late results. Disk-backed immutable versions isolate rejected UI replies from accepted selection. | Session/header cancellation, requested-page and bulk membership regressions. |
| Partial initial commits could be mistaken for completed index | Incomplete state is discarded/restarted before retry; failed/unreadable refresh preserves prior truth. | Interrupted committed walk and unreadable refresh tests. |
| Filesystem aliases broke identity and replay checks | POSIX canonical checks for ownership/reader operations; event alias normalization preserves actual scope, and current mutation snapshots await replay. | Open descriptor, canonical temporary-folder and changed-branch replay tests. |
| Hidden selection scope/limits | All eligible category members stream to a disk-backed selection, independently of temporary browse windows. No 10,000-member ceiling. Batch completion journal finalizes once. | 10,021-file actual filesystem test and 10,050-member / 51-batch selection test. |

## Security boundaries and remaining limits

- Approved personal roots plus UID, flags, package/managed-location exclusions and current identity define ordinary deletion authority. Account ownership is not app ownership or proof that a personal file is unimportant.
- Observable descriptors identify current use only. Inaccessible processes, closed descriptors and historical reads are not retrospectively known. Absence of an observed reader is never labeled unused.
- NSFileCoordinator cooperates with participating processes. Trash and cross-file keeper preservation cannot be fully atomic against uncooperative same-user processes changing files between OS calls. The implementation revalidates and refuses detected changes; it does not claim complete race immunity.
- Recursive unmatched-data review has depth/entry/manifest/target resource limits and refuses uncertain/excessive trees. It is not automatic orphan deletion. Shared/unknown app associations never expand uninstall authority.
- Duplicate fingerprints require unchanged device/inode/UID/size/mtime/ctime; metadata cannot replace required full verification for a new candidate. Hardlinks are collapsed before content reads. Verification is not evidence of nonuse.
- Selection snapshots expire when unreferenced; expired confirmations fail instead of silently changing membership. Completed choices are removed; rejected/blocked selection remains available for explicit correction.
- File sizes and map allocation are estimates for APFS clones/snapshots. Selected allocated bytes are not a promise of volume reclamation.

## Verification

252 distinct code-level tests passed across the broad suite, focused final navigation/confirmation checks, shared scanner/sizer compatibility and the actual complete backend diagnostic. The broad suite had one opt-in scan skip; that scan was run separately and passed. Real duplicate workloads use 128 MiB candidates; the repeated-reader memory check processes 1.5 GiB through a single 256 KiB reusable buffer with a 24 MiB growth ceiling. No app launch, NSWindow rendering, screenshots or manual UI interaction occurred.

Final sequential local production diagnostic (warmed filesystem): 392,678 folders; 57,805 retained file records including necessary hardlink allocation records; 141,828,096-byte database; first load 26.330 s; cached opening 0.117 s. Native phases: walk 21.815 s, index creation 0.283 s, totals 3.089 s. These measurements are not a guarantee for other disks/conditions. A previous same-session run took 79.372 s, demonstrating filesystem/system workload sensitivity.

The 50,011-folder / 100,000-small-file fixture persists zero ordinary small-file detail rows, uses approximately 2.16 MiB additional sampled footprint and reads 100 bounded folder pages in approximately 0.005 s. These are fixture figures, not live app footprint.

## Code size

Disk production Swift was 2,059 lines at the pushed baseline and approximately 2,412 lines at the start of this approved-plan implementation. The integrated module is approximately 3,240 lines, excluding new shared removal helpers. Obsolete category/age summary trees, duplicate whole-file representations and the manual comparison path were removed. Net reduction was **not** achieved: frozen disk-backed selections, incremental duplicate verification and security validation added required behavior. No cosmetic compression or deletion of safeguards was used to manufacture a lower count.

## Delivery

SDK 13 is consistent across all bundled modules and rejects the previous binary layout. New user-facing messages have all seven supported translations. The signed/notarized development assembly is validated separately; the application remains unopened for the user’s visual verification. No commit/push is performed without a separate instruction.
