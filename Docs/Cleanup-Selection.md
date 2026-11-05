# Cleanup selection contract (SDK 20)

Cleanup rows publish a `CleanupTarget` in `Row.cleanup` instead of a per-row Free action. The target has a stable operation ID, the current allocation estimate, the guarded module action, availability and an automatic-execution policy. Utility actions remain ordinary row actions. Shipped cleanup modules do not publish tile Free shortcuts or aggregate Free primaries that could bypass selection.

The host draws the same left checkbox for rows and drill-down headings, and one Free selected action for the active cleanup scope. Confirmations and permissions are assembled from the selected targets. A batch validates its selection and permissions before mutation, executes existing module handlers sequentially and reports partial failures and completed allocations. An already-running cloud job remains a progress row, without a second Free button or a premature completion celebration.

The host stores explicit true and false preferences per module, preference scope and stable ID. Preference keys are encoded tuples, not localized titles or measured sizes. Temporarily absent rows retain their decisions. Newly discovered optional operations start unchecked. Existing recommended cache, report and purge defaults apply until explicitly changed. A completed cleanup does not clear the future preference.

App-cache sub-selections retain the module's `CacheChoices` contract. The host also writes each checkbox and section decision synchronously; System Data applies those decisions to snapshots and automatic execution even before the compatibility save action finishes. Selecting all of a cache section retains its established meaning for later entries in that section. Backup-disk selections persist by destination ID and backup stamp and retain their manual review flow.

Automatic cleanup receives the preferences through `ModuleContext.cleanupChoices` and resolves a fresh module screen's currently available automatic targets. It uses the same guarded handlers as the UI. Unchecked, unavailable and manual-only targets are excluded. Missing permissions are skipped with details; app-cache jobs pass the automatic flag and leave running applications alone. Retention, ownership, open-file, cloud upload, model-use and backup protections remain in the existing engines. Choices changed during a running cleanup apply to subsequent runs; the already-started work keeps its existing lifecycle.

Ordinary file deletion and app uninstall selections remain session choices and retain their manual review. Background feature lifecycle tasks (for example releasing a model after its feature was explicitly disabled) remain separate from the scheduled cleaner.

All bundled manifests use SDK 20. Older contracts are rejected by the normal module compatibility check.
