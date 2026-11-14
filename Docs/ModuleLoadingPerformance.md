# Module loading performance

The target is a 50% loading-time reduction relative to `2efc7f3`, preserving presentations, actions, safety boundaries and refresh policy. **This target is not yet achieved.**

## Latest comparable measurements

Measured on 2026-11-14, Apple M4, macOS 27.2 (26B123), optimized release builds and Full Disk Access. A detached reference checkout at `2efc7f3` and the candidate use identical benchmark source. Pre-existing unrelated model-cleanup edits were retained identically. Reference/candidate order alternates between pairs to reduce filesystem-cache and machine-load bias. The table contains medians from three complete pairs; values are seconds, reference → candidate.

| Module | New inventory index | Completed inventory index |
| --- | ---: | ---: |
| Disk Map | 38.857 → 32.558 | 17.443 → 12.998 |
| System Data | 26.498 → 23.590 | 18.118 → 15.650 |
| Siri & Apple Intelligence | 3.382 → 3.834 | 2.684 → 3.580 |
| Debloat | 7.227 → 7.858 | 0.317 → 0.370 |
| Other System Files | 8.710 → 10.613 | 8.486 → 8.443 |
| **All five ready** | **38.857 → 32.559** | **18.118 → 15.650** |

The aggregate reductions are **16.2%** and **13.6%**, below the required 50%. Per-module results include regressions; faster aggregate completion is not proof that every module became faster. Earlier separate runs reported reductions above 50%, but paired measurements did not reproduce them. Those earlier results are not treated as completion evidence.

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

The runner builds both variants first, alternates execution order and invokes `CompareModuleLoading.py`. It exits unsuccessfully when either median misses the 50% target. Both variants use root `/` by default, release optimization and the same benchmark SHA-256. Output contains timing/phase evidence, not snapshot contents; the output directory is private and ignored by Git.

## Implemented and investigated

The candidate reduces initial inventory directory statements, rejects impossible personal-file candidates before the SQLite writer, bounds independent app metadata/ownership reads, and starts root file projections from the partial personal-file index. Navigation preparation fell from approximately 5.8 s to 0.15 s in a diagnostic sample. It also avoids unnecessary full-path construction, coordinates sizing workers and propagates foreground read priority while keeping timers/scheduled work at utility priority. Regression tests cover exclusions, Unicode, hard links, dataless placeholders, metadata ownership and original reviewed identities.

Increasing the foreground helper count worsened measured contention and was removed. Bounded directory-list reuse was also removed after a scoped trial returned zero reuse hits; its memory and complexity were not justified. The remaining target requires further reduction of the dominant filesystem work, not a claim based on a favourable isolated run.

Raw evidence is kept locally under ignored `results/module-loading-20261113/` and `results/module-loading-20261114-*-paired/` directories.
