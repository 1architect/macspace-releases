# Disk — updated presentation and correctness fix plan

Status: implementation authorized by the user on 2026-11-03; implemented; code-level verification passed. App/UI verification remains with the user.
Date: 2026-11-03.

This plan incorporates the latest screenshot feedback and supersedes conflicting presentation decisions in earlier plans. The user’s implementation request authorizes these changes. App and visual verification remains with the user.

## 1. Objectives

- Make folder contents visible without redundant file-detail pages.
- Make file categories, types, duplicates and selection understandable.
- Preserve explicit selections across navigation.
- Fix false empty results, delayed checkboxes, incorrect zero measurements and untranslated folder names.
- Preserve the compact database, bounded memory, incremental updates and backend deletion protections.
- Reuse existing module controls, proportions and animation styles.

## 2. Standard top-right Refresh button

Every Disk page must have the same circular Refresh control in the top-right corner as the other module windows, including fullscreen and enlarged layouts.

Required pages:

- Disk overview.
- Real folder maps, including Applications folders.
- Synthetic Other folders maps and nested aggregates.
- Category and file-type review pages.
- Duplicate review pages.
- App uninstaller and unmatched app-data pages.

Behavior:

- Keep the normal top-left Back/breadcrumb presentation.
- Refresh the visible scope and its dependent counts using existing loading/progress feedback.
- Reconcile filesystem changes; do not discard the whole cache or rehash unchanged files unnecessarily.
- Keep existing content visible during refresh.
- Preserve valid explicit selections and their original review metadata.
- Clearly identify changed, unavailable or blocked selected targets; never silently replace them.
- Retain the standard control's enabled/busy behavior during conflicting operations.
- Do not add a second Refresh button inside a list or another animation style.

## 3. Disk overview structure

Proposed main page:

```text
‹ Disk                                                       ⟳

Apps                                  ┌─────────────────────────┐
Uninstall apps               …  ›     │                         │
Unmatched app data            …  ›     │          MAP            │
Installers                    …  ›     │                         │
                                      └─────────────────────────┘
Folders                                 Compact legend
Downloads                     …  ›
Documents                     …  ›
Desktop                       …  ›

Files
Duplicate files               …  ›
Archives                      …  ›
Documents                     …  ›
Media                         …  ›
Other                         …  ›
```

- No Recommended section.
- Use Files instead of Large files and duplicates to avoid mixing a size threshold with content types and duplicate relationships.
- Installers appears last under Apps on the main page, not repeated under Files there.
- During folder navigation, Installers can appear with other scoped content categories.
- Both installer entry points use the same inventory and review logic.
- Documents under Folders is a location; Documents under Files is a content category.
- Omit empty content categories.
- Do not expose System Data-owned cleanup targets as competing Disk candidates.
- Remove the folder icon beside Files / Large files and duplicates and category headings. Keep individual file Finder controls.
- Do not show scattered raw-file previews on the root overview.

The Files heading and Documents content category are proposed refinements discussed after the previous implementation; approve them with this design before implementation.

## 4. Duplicate visibility

Show the Duplicate files destination only when the current scope has an actual verified removable duplicate set with a valid surviving copy.

- Derive visibility, count, allocation and page contents from the same definition of a valid set.
- Do not create an empty destination merely because verification is running.
- Do not display estimated matches as verified duplicates.
- Preserve still-valid cached sets while checking for additional matches.
- Invalidated or inaccessible copies must not keep an empty duplicate destination visible.
- Background verification continues to use existing progress treatment where appropriate, not a Compare files button.

## 5. Duplicate review: user chooses which copies to remove

Do not permanently designate the lexicographically first copy as an untouchable keeper.

```text
‹ Disk › Duplicate files                                      ⟳

☐ Duplicate files                              Selected: …

Savage_Storm.zip                    2 identical copies
☐ Savage_Storm.zip  [Documents / Backup]     1.5 GB  [Finder]
☐ Savage_Storm.zip  [Downloads]              1.5 GB  [Finder]

IE_opening.bk2                     2 identical copies
☐ IE_opening.bk2    [Backup]                229 MB  [Finder]
☐ IE_opening.bk2    [Downloads]             229 MB  [Finder]

[Free selected …]
```

- Every eligible copy is selectable; nothing is preselected for removal.
- The user chooses which file from which folder to remove.
- Use a representative filename and copy count as the set heading, rather than repeatedly saying Identical files.
- Preserve actual filenames when matching copies have different names.
- Use concise location labels to distinguish copies. Full paths remain available through help/Finder, not quantity subtitles.
- Sort sets by removable allocation, largest first.
- Distinguish total set size, selected allocation and potential removable allocation; do not sum the same shared relationship into unrelated category totals.
- At least one verified copy must remain unselected before execution.
- If a select-all operation includes every copy, visibly flag the unresolved set and prevent execution until the user leaves a survivor. Never silently choose a keeper or alter the user's choices.
- Apply survivor validation to the complete selection, including files chosen through ordinary categories and other pages.
- Revalidate selected identities, contents and the unselected surviving copy before removal; check survivor identity again immediately before each copy removal.
- Ordinary category pages must not be cluttered with retained-copy badges. Any necessary duplicate conflict must be handled clearly and consistently rather than through unexplained missing checkboxes.

## 6. Ordinary category pages: file-type organization

Remove folder headings, full-path list items and folder-level selection rows from ordinary file-category pages.

Use category → file type → files:

```text
‹ Disk › Documents › Other                                    ⟳

☐ Other                                  24 items · …

☐ PDF documents                           12 items · …
☐ drawing.pdf                                  9.2 MB  [Finder]
☐ detail.pdf                                   6.4 MB  [Finder]

☐ SketchUp projects                        2 items · …
☐ model.skp                                    609 KB  [Finder]

☐ Other formats                            3 items · …
☐ plot.log                                      73 KB  [Finder]

[Free selected …]
```

- One coherent list surface with lightweight type headings; no new shaded box for every folder or file.
- Only nonempty type groups appear.
- Group related formats under understandable translated names; use an extension-based label or Other formats where a reliable friendly type is unavailable.
- Order type groups by their total size; order files largest-first within each group.
- Avoid a separate heading for every individual file where a broader type group is meaningful.
- Keep file location on the existing individual Finder control. Add a short location badge only where identical filenames need disambiguation.
- Category and type headings select all eligible files in their current size scope across pagination.
- Classification describes content, not safety or historical usage.

## 7. Smaller files

Use a Show smaller files row at the end of each content category. Do not introduce a size-filter menu.

- Expand the same category page in place, without another breadcrumb level.
- Provide immediate feedback using existing progress styling.
- Retain the current visible list while reading additional metadata.
- Deliver the first bounded result promptly; avoid waiting for the entire subtree solely to show initial rows.
- Insert smaller files into their type groups using existing reveal/layout animation.
- Do not add folder list items.
- Preserve prior choices, but never select newly revealed files automatically.
- The category heading becomes partially selected when the expanded scope includes additional unselected eligible files.
- Selecting the expanded category includes eligible files of all sizes across pagination.
- Type/header counts must identify the scope accurately; a bounded cache window must not masquerade as the complete category total.

### Automatic fallback

When a folder has no eligible large files, automatically show its smaller-file content categories on the main folder UI. Do not require an empty-page visit and an extra Show smaller files click.

### Installers

- Installer review includes recognizable installer files of all sizes.
- Use reliable formats/evidence; an arbitrary executable is not automatically an installer.
- Do not duplicate installer inventory between Apps and Files on the same page.
- Detect candidates during existing metadata collection where practical, without adding another whole-disk scan.

## 8. Real folder pages must show actual files

| Folder state | Left-side content |
| --- | --- |
| Contains direct files | Actual direct files grouped by type, with eligibility and selection already resolved. |
| Contains only smaller files | Those files appear automatically, classified by type. |
| Contains files and subfolders | Direct files on the left; subfolders remain navigable on the map. |
| Contains only subfolders | Nonempty scoped file-category summaries for descendants. |
| Contains no reviewable personal files | Explicit explanation; never claim the filesystem folder is empty. |
| Truly empty | Explicit empty-folder state. |

At a leaf folder, show its actual contents instead of forcing another category/file-detail page.

Applications folder behavior remains: app uninstaller and unmatched-data review at the top, with appropriate scope and truthful global labels where correspondence is unknown. App bundles are managed through uninstall, not ordinary file deletion.

## 9. Graph and list interaction

- Folder tile: navigate into that folder using the normal page transition.
- Individual file tile: highlight and scroll to its corresponding row on the current page. Do not open a one-file page or automatically select the file for deletion.
- Other files tile: reveal its corresponding files in the current list, including smaller files when necessary, without a redundant aggregate-file page.
- Other folders tile: open a map of the exact contained folders; nested aggregates also remain maps.
- Graph/list identities and scope must agree. A represented individual file must have a reachable row even if its bounded list page has not yet loaded.
- Synthetic folder maps must not reserve an unexplained blank left column. Show meaningful scoped summaries, or use available width for the map when no meaningful list exists.
- Do not invent filesystem paths or broaden an aggregate to unrelated sibling folders.

## 10. Load checkboxes with the page

- Resolve eligible IDs and visible checked membership before publishing the completed page.
- Do not display bare filenames and attach checkboxes afterward.
- Keep controls stable through refresh; update their state with the corresponding data.
- Navigation, Finder actions, headings that are not selection controls and explanatory rows never receive file checkboxes.
- Blocked files have specific factual reasons rather than unexplained disabled controls.
- Explicit selections persist across categories, folders, Back, pagination and leaving/returning to Disk during the app session.
- Deduplicate selections across entry points; keep original review identities and exact global count/allocation.
- No separate review page is included in this revision.

## 11. Truthful empty/loading/unavailable states

Distinguish these situations:

- Filesystem folder is empty.
- No files match the current size/type scope.
- Inventory is loading.
- Contents could not be read.
- Managed/protected files are excluded from personal cleanup.
- Duplicate verification has not produced valid matches.

Do not reduce them to a blank list, an empty navigation destination, or a fabricated zero. Existing progress, layout and page transition styles apply.

## 12. Localization and unmatched-data measurement

### Folder display names

Translate recognized folder names, including Documents, Desktop, Pictures, Movies, Music and Applications. Preserve actual filesystem paths. Do not blindly translate arbitrary user-created folders that happen to share a name.

### Unmatched app data

- Build its inventory and measurements from authoritative global inputs, never from a folder-map projection lacking Library/app metadata.
- Separate catalog discovery state from measurement completeness.
- Missing/stale measurements must not replace a valid previous result with 0 KB / 0 items.
- Display zero only when a completed authoritative result establishes zero.
- Use an explicit pending/unknown state when no valid completed measurement exists.
- Root, Applications and review pages must use consistent count/size definitions.
- Keep System Data cleanup ownership and conservative app-data review safeguards.

## 13. Performance, storage and safety requirements retained

- Compact directory IDs/parent IDs, necessary file metadata and minimal indexes.
- No whole-disk persistent detail inventory for every ordinary small file.
- Bounded small-file browsing and frozen disk-backed complete selections.
- Incremental changed-branch reconciliation and prompt completed-cache presentation.
- Automatic duplicate pipeline: size groups, inode collapse before reads, cached fingerprints, samples to reject nonmatches, complete verification, bounded buffers/concurrency and cancellation.
- No Compare files button and no restart-from-zero verification of unchanged candidates.
- Positive personal-file removal boundary enforced in the backend; no privilege escalation for ordinary deletion.
- Preserve default permanent deletion and optional Trash mode, with matching confirmation and execution.
- Preserve current-use evidence, original identity checks and surviving-copy validation. No claim that age or absence of an observed reader proves nonuse.
- Publish verified cleanup target/parent/list/graph/widget changes without unrelated full scans or global settling delays.
- Remove obsolete/duplicate logic where possible. Report actual code-size changes honestly; do not compress formatting or remove safeguards to manufacture a lower count.

## 14. Implementation order after approval

1. Agree on duplicate-copy choice, file-type grouping and in-place smaller-file presentation shown here.
2. Fix authoritative data completeness: duplicate visibility, smaller-file fallback, unmatched counts and folder display names.
3. Unify folder-map/list inventories so leaf/direct files are present and graph clicks focus existing rows.
4. Build presentation and selection membership together before page publication.
5. Implement the approved ordinary/duplicate/smaller-file UI, remove redundant paths/heading icons and preserve transitions.
6. Verify scoped Refresh on every page, including synthetic maps and Applications.
7. Run focused code-level regressions and realistic performance/memory/storage checks.
8. Perform final security review, update module contract/translations, then build and validate notarized dev if requested/authorized.

## 15. Acceptance checks

- Empty scopes show no Duplicate files link; actual verified sets appear with correct totals.
- User can choose any eligible duplicate copy by location; selecting every copy blocks removal without silently choosing a survivor.
- Ordinary inventories group by file type, never full-path folder rows.
- No-large-file folders automatically expose smaller-file categories/contents.
- Leaf folders list their real direct files; file tiles focus rows without opening redundant pages.
- Checkboxes and checked states are present on the first completed frame.
- Show smaller files is responsive, preserves choices, adds none automatically and uses existing animation without a new breadcrumb.
- Top-right Refresh matches other module windows throughout Disk.
- Category/overview heading folder icons are absent; individual file Finder controls remain.
- Known folder names are localized; actual paths and user-defined names remain intact.
- Unmatched app-data results cannot become false zeros because of navigation or incomplete input.
- Complete category/type selection spans pagination with bounded memory and exact confirmation count/size.
- Safety and failure recovery remain enforced for every entry point.
- No manual app/UI checks are run by the agent unless the user explicitly requests them.

## Implementation record

The implementation follows this revision and the accompanying selection, idle CPU, app-readiness and progress reports. SDK 14 carries page progress, foreground suspension and explicit selection issues. The current contract is documented in `Docs/Module-Layout.md`; code-level verification and limitations are recorded in `Docs/Disk-Final-Security-Review.md`. App/UI verification remains with the user.

## Latest user-directed corrections (2026-11-03)

The user subsequently changed duplicate-header behavior: Select All must automatically choose removable copies while preserving a verified survivor (one selected file for a two-copy set). This supersedes section 5's earlier requirement that header Select All select every copy and report a conflict. Manual/cross-category all-copy conflicts still fail closed.

The approved follow-up also removes loading on cached page transitions, routes Installers directly to its indexed all-size inventory, moves subcategory headings outside file lists, includes descendant files in folder scope even when direct metadata files exist, and provides read-only photo-library inspection. These changes, the requested independent duplicate review and verification are recorded in the module contract/security review.
