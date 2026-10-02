# The original MacSpace research, summarized

MacSpace started on 20 September 2026 as a research project, not an app, and stayed one for ten days. This is a short account of
what that research set out to do, what it found, what failed, and which parts became the app in this repository. The research
itself (about 110 numbered checkpoints, more than 200 result files and folders, forensic notes and small experiment programs) lives in the maintainer's
private repository. Findings about macOS from the app's own development are in [Research.md](Research.md); this document covers the
work before it.

Evidence labels used throughout: **measured** (observed, with numbers), **inferred** (follows from measurements), **unverified**.
Builds: macOS 27.2 build 26B5086k at first, then 26B5091g from the update on 23 September. One Apple Silicon Mac, not enrolled in MDM.
System Integrity Protection (SIP) was **off** for part of the work and **on** again from 28 September; the sections below say which.

## 1. Where it started

The first goal was a storage forensics tool: explain the space macOS itself uses (APFS volume groups, Preboot, Recovery, snapshots,
cryptex mounts, update residue, system-managed assets) instead of being "another cache cleaner". Seven principles were written down
on day one and survived to the app:

1. Explain before deleting; every reclaimable byte needs a reason.
2. Never remove something a live installation, boot policy or active asset still references.
3. Read-only by default; destructive steps sit behind explicit gates and independent validation.
4. The normal product must not require disabling SIP.
5. Everything is version-aware: classifiers record the macOS build they were validated on.
6. Cleaning and debloating are different jobs. Evicting bytes is not durable unless the trigger that brings them back is understood.
7. Never promise persistence without a controlled before/after measurement.

The tooling was layered the same way: read-only forensics first, then a privileged helper, then only supported mutation. Direct
modification of the sealed system volume was excluded from the product.

## 2. Storage forensics (checkpoints 1–16)

**Measured.**
- A read-only scanner could model the APFS container, the System and Data volume group, the sealed boot snapshot, other snapshots
  and Preboot objects, and it avoided double-counting mounted cryptex images (their usage and their MobileAsset backing are two
  views of the same bytes).
- "Reclaimable" had to stay unknown until unique ownership of the blocks could be established. APFS clones and shared extents make
  logical size a poor guide.
- A census of the system asset store (`/System/Library/AssetsV2`, 8.6 GB in 40 families on 26B5091g) became the base for everything
  later. Assets with no catalog reference, or marked as never collected, were treated as investigation signals, never as permission
  to delete.
- **One supported removal worked and was the only mutation the early tool allowed:** the optional Metal Toolchain through
  `xcodebuild -deleteComponent metalToolchain`, which freed 903.9 MB and is reversible with `-downloadComponent`. Developer
  documentation (1.73 GB) cannot be removed that way; Xcode's own settings are the route.
- With SIP on, six asset families are unreadable even with Full Disk Access (they carry the `restricted` flag, among them the
  Foundation Model families). Full Disk Access is still required for the Apple Intelligence eligibility state. The detector for that
  permission had to be changed: the user TCC database stays closed even with the permission, so a protected file that exists on
  every Mac is probed instead.

## 3. The Apple Intelligence model (checkpoints 17–112)

This was the bulk of the research. On macOS 27 the on-device Foundation Model, a 3B-parameter base model plus adapters (about 12 GB
for the family), is downloaded automatically for users whose Siri and system languages match. The question: can a user who does not
want Apple Intelligence get the space back, **and keep it**?

### What failed (all measured)

- **Deleting the files is not prevention.** The model reappeared after being removed, through the pipeline ModelCatalog → the Unified
  Asset Framework (`assetsubscriptiond`) → MobileAsset. At least one controlled absence window did not trigger immediate recreation,
  but owner-side requests later rebuilt the configuration and re-downloaded it.
- **Direct deletion hit protected boundaries.** Part of the asset could not be removed even by Apple's own `rm`, with SIP off:
  `Read-only file system`, `Resource busy`, and an `EPERM` in graft handling, about 6 GB of it. Simple explanations (live mount, open
  file, snapshot) were ruled out. An early "SIP-restricted" diagnosis was itself disproved with SIP off and then corrected (a
  false positive worth remembering: always test the explanation against a control).
- **Suppressing the requester rows failed.** The two live requesters were concrete rows in the subscription database, and removing
  exactly those rows (reversibly, with SQLite triggers as guards) held until a reboot, after which the rows were recreated and the
  model owned again.
- **Patching the configuration failed.** Changing the AutoSet configuration copies and quarantining assets did not stop
  reacquisition; the daemon restored the 177-entry configuration and downloads recurred.
- **Boot ordering defeated the guards.** After a cold boot with guards intact and 12 target rows absent, the configuration already
  contained the target. A later daemon restart rebuilt it without the target. The log ordering showed the configuration written
  before the subscription store finished persisting. Why that batch included the target was never identified.
- **The assumed global opt-out does not exist on that build.** Static analysis of the shared-cache frameworks showed the Swift
  `isOptedIn` getter returns a constant true, and the availability reporter derives its "toggle" field from the use case's
  unavailability reasons. Siri off and the reported opt-out flag are therefore not stop-download signals.
- **Restrictions did not help.** A Screen Time / Writing Assistance restriction left the 177-selector configuration and the
  target selector byte-identical.
- **A private API is closed to third parties.** Changing the Siri language through the private assistant settings interface is
  rejected by the daemon for lack of a private entitlement.

### What worked (measured)

- **Make the Siri language differ from the system language.** One supported user action, Siri's language from Portuguese (Brazil)
  to English (US) with the system language unchanged, made Apple Intelligence unavailable. ModelCatalog dropped from 23 decisions
  to 6, the configuration fell from 177 selectors to 2 (none for the model), and MobileAsset released and evicted the model on its
  own, including the part direct deletion could not remove, with no guard, patch or deletion involved. Free space rose from about
  12 GiB to 19 GB.
- **It held** across a cold boot, two hours online and an OS update (26B5086k to 26B5091g). Remaining unknowns: online idle over
  days, and whether re-enabling Siri or a resync of the language silently restores the match.
- **An ordinary app can apply it.** Writing the Siri language preference and posting a Darwin notification works in both directions
  within about 10 ms and re-evaluates eligibility. Whether the change syncs to other devices through iCloud was not measured.
- **Later, in the app's own development**, the release of models that stay installed after the switch was automated: sending the
  account through available → unavailable releases the locks, and macOS's own purge (CacheDelete) then deletes what is unlocked,
  12.04 GB in 4.6 s as a normal user. Models are shared across accounts, so one eligible account, or a deleted account whose
  subscriptions remain, keeps them; a restart does not clear those, and removing the orphaned rows (with a backup, in one
  transaction) does.

### Not resolved

Which boot-time input selects the model into the configuration; which one of the net-new subscriptions causes it; the condition
logic mapping eligibility, language and opt-out to each decision; what produces the "toggle enabled" availability field. A planned
network-level or file-level gate (a Network Extension filter, Endpoint Security) was designed and never built, because the
Siri-language method made it unnecessary for this asset.

## 4. Debloat (checkpoints 17–18 and 2026-09-25 to 28)

An evaluation on 25 September asked how the Apple Intelligence approach could grow into a general debloat tool. Its baseline on the
research Mac (SIP off at the time) set the design rule: **verify the effect, not the setting.**

- The analytics toggle was off, yet a full analytics submission succeeded that day: on a seed build submission continues regardless.
  The tool must say "not controllable here", not "pass".
- Siri was off, one launchd label was disabled, and two Siri processes still ran under other labels.
- About 40 analytics and intelligence processes were running, and a partial opt-out existed (personalised ads off, advertising
  identifier on).

A ladder of mechanisms, most to least supported, framed the work: public setting, configuration profile, launchd override, private
surface, observation only for the network, and (excluded) SIP-off or sealed-volume changes.

**Experiments with SIP on (28 September, one shared reboot), measured:**
- **Feature-flag override works.** A root-owned override file turned the Siri AI agent off after a reboot (launchd did not load it;
  the app did not run). Side effect: with the flag off, classic Spotlight loads in its place. The same mechanism gates a few other
  daemons. Survival across an OS update was unknown at the time.
- **launchd overrides do not survive.** `launchctl disable` for ten Apple services, in the system and user domains, was cleared at
  the next boot; every targeted daemon was running again. With SIP on, owner services re-set their own overrides. The nine launchd
  controls proposed earlier were dropped for this reason. A published tool that does the same (296 labels) states the same limit.
- **Configuration profiles** carry the privacy policies that stayed (diagnostics, ads, advertising identifier, Siri server logging,
  on-device dictation, Spotlight internet results, Apple Intelligence features, Game Center, News). They need the user to approve
  the profile in System Settings, and several keys only apply to supervised or MDM Macs, so each was treated as unproven until
  measured.
- The `tailspin` trace buffer and the crash reporter can be stopped with SIP on, and became controls.

The effect check also had to learn that a respawn by KeepAlive is not a failure: an applied control is `pending` until the required
logout or reboot has happened, and only `ineffective` if the process runs after that boundary.

## 5. The product focus that followed (29 September)

After the experiments the scope was cut to three things that hold with SIP on: **clean System Data** (explain every large item,
clean only what regenerates, report space actually freed on the volume), **guide manual cleanup** of third-party apps, and
**debloat** with the mechanisms above plus the Apple Intelligence switch. Everything else in the research, including the reverse
engineering of ModelCatalog internals, stayed research.

## 6. What carried into this repository

| Research result | In the app |
|---|---|
| Principles 1–7, build gating, effect-based verification | Every control and cleanup reports what was measured; unverified builds are disabled or labelled. |
| Siri-language method, preference write plus notification, round trip | Siri & Apple Intelligence module: the off-switch, the watcher, the release flow. |
| Orphaned subscription rows, shared models, CacheDelete purge | The release flow's blockers and the "remove leftover models" step. |
| Metal Toolchain removal, asset census, Full Disk Access findings | System Data's asset families and the permission probe. |
| System Data investigations (clones, unfinished downloads, version store) | System Data module and the category rules in Research.md. |
| Debloat engine: probe, apply, revert, verify, undo journal | Debloat module with 14 controls (profile policies, feature flags, tailspin, crash reporter). |
| Privileged helper over XPC, designed in the first architecture | The signed helper and its install and self-repair logic. |

Left behind on purpose: the guard, patch and quarantine tooling, the ModelCatalog and UAF reverse engineering, the 60-odd
checkpoint-specific commands, the launchd controls SIP resets, and the controls whose effect could not be confirmed.

## 7. Lessons about the method

- **Test the explanation against a control** before building on it (the SIP-restricted diagnosis, the opt-out flag).
- **Stamp every result** with build, boot, SIP state and a time window; a later OS update invalidated more than one conclusion.
- **Prefer owner-managed paths** (a supported setting that makes the owner release something) over fighting protections.
- **Make every change reversible and recorded**, with a root-only recovery report, before touching Apple's databases.
- **Say "observing" until a gate is passed**, not "protected" or "cleaned".
- Reading a log line is not proving causation: several chains were strongly supported but never proved.
