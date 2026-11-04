# Uninstaller and unmatched app data review

Reviewed on 2026-11-04. Verification uses automated fixtures and an opt-in read-only audit of an isolated disk-index backup. The app UI is verified by the maintainer.

## Findings and changes

- The uninstaller listed a separate destination for system components and extra copies. That destination and its navigation entry are removed. The underlying catalog retains those identities so their data is still protected from being treated as unmatched. Registered copies inside another app, user Library data, system Library data or temporary system locations are not classified as standalone uninstallable apps.
- Uninstall flags occupied different positions because grouped rows placed actions before the size while plain rows attached them to the title cluster. App rows now declare `Row.actionPlacement = .afterFinder`, honored in both rendering paths. Existing modules retain their default placement.
- Live catalog discovery deliberately cannot prove global exclusivity, so the automatically generated removal plan generally contained only the app bundle. Conventional Application Support folders, containers and preferences were preserved. The uninstaller now opens a review page before executing removal. The app is included; optional associated data starts unchecked. The confirmation names the chosen paths. Data inferred from identifiers, app names or vendor metadata is never silently promoted to verified ownership.
- Unmatched-data discovery previously examined only immediate children of Containers and Application Support, and required identifier-like names. It missed app-named support folders and other common Library scopes. It now reviews directory data in Application Support, Containers, Group Containers, Application Scripts, Caches, HTTPStorages, WebKit, Logs and Saved Application State, plus preference files, host-specific preferences and cookie files.
- An incomplete scan previously reused the preceding unmatched candidate list. An app installed since that list was built could retain a selectable entry. Candidates are now recomputed against the current app catalog, current ownership claims and indexed component identities. Unreadable directory scopes do not contribute candidates. Removal forces a new inventory and resolves the original frozen identities again.
- Matching now protects exact identifiers and namespace relationships, app names and versioned name variants, installed vendor/team identities, registered applications, indexed component names, installed launch-service metadata, explicit container metadata and overlapping ownership claims. A container's metadata identity is checked even when its folder has a UUID name. Component identities are grouped by containing app; related vendor components can contribute optional data associations, while unrelated bundled frameworks and system frameworks are used only to protect unmatched data. This covers cases such as Codex inside ChatGPT. App-named and declared vendor subfolders appear in associated-data review; a vendor parent containing another app's claimed data is preserved.

- Removing an already missing app bundle could fail to increment the catalog revision, allowing a deleted app to remain in the inventory. App and embedded-component scopes now invalidate the catalog before the missing-metadata branch. A regression test covers removal after the bundle disappears.

## Execution contract

The inline Uninstall flag opens a module review page through optional `Action.pageID` metadata; navigation does not execute a module mutation or require cleanup permissions. `Selection.includedBytes` includes the mandatory bundle allocation in the selected action's total. These SDK fields are additive and default to the previous behavior when absent.

Known shared data, claims overlapping another installation, receipt-derived paths, privileged helpers and unsupported locations cannot be selected as optional app data. System-managed document/synchronization stores are excluded. The normal app bundle plan is still freshly validated by the app and privileged helper. Helper permissions are not used to remove optional user data.

Each optional choice carries the original filesystem identity in its ID; preference files additionally retain size, change time and modification time. All selected locations are resolved and preflighted before mutation. User-data directories use the existing bounded, no-follow descriptor-based remover; regular settings files use the same guarded file-removal implementation with a separate explicit Library policy. Observable open files, owner changes, protected flags, symlinks and changed identities prevent removal. Trash settings apply to selected data. Data is processed before the app bundle; a data-removal failure preserves the app and reports the remaining failure. If bundle removal subsequently fails, already removed data cannot be rolled back automatically.

## Deliberate limits

- No public catalog proves that every installed copy, command-line tool or app on an unavailable volume has been discovered. “Unmatched” means no current match was found, not that an app was certainly removed. Choices are never preselected.
- Shared vendor roots are retained when another installation claims a descendant. Arbitrary nested vendor folders are not guessed to belong to a removed app.
- System-wide data, launch agents/daemons, registered helper lifecycle, receipts, keychain items, cloud documents and arbitrary folders outside the supported user Library locations are preserved. Receipt presence alone is historical evidence.
- Review is bounded to 32 data locations per removal batch. Directory preflight retains existing depth, entry and manifest bounds; a folder containing unsupported special files or symlinks can be preserved rather than partially guessed at.
- Applications and preference agents can recreate files after deletion. The selected app must be quit, observable use is checked, and later cleanup requires a new review.

Apple documents distinct [Application Support, cache and preference responsibilities](https://developer.apple.com/library/archive/documentation/FileManagement/Conceptual/FileSystemProgrammingGuide/MacOSXDirectories/MacOSXDirectories.html) and [sandbox container and Library layouts](https://developer.apple.com/library/archive/documentation/FileManagement/Conceptual/FileSystemProgrammingGuide/FileSystemOverview/FileSystemOverview.html). Those locations inform discovery; directory naming is not evidence of exclusive ownership.

## Local audit result

The isolated-cache audit found 440 app catalog entries: 65 standalone installed apps and 375 hidden system/background/extra copies, including 14 updater copies. It found 168 optional data associations across 39 apps and 137 unmatched locations requiring explicit review. These are observations from this Mac, not universal discovery or completeness guarantees. No app or user data was removed by the audit.
