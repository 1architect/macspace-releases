# Releasing

How a MacSpace version gets from this repository to people's Macs, and how installed copies update. Everything here is public.
The steps that need a secret (signing, notarization, the update key, publishing) run from a separate private repository, so no
credential ever exists in this one.

## Versions and tags

- Versions follow [Semantic Versioning](https://semver.org): `MAJOR.MINOR.PATCH`. A pre-release adds a suffix: `1.1.0-rc.1`.
- Every release is an annotated tag on `main`, named `v` plus the version (`v1.0.0`), and a GitHub release of the same name.
- The version is the app's `CFBundleShortVersionString`. The build number (`CFBundleVersion`) is the number of commits at the tag,
  so it only ever grows; Sparkle compares build numbers to decide what is newer.
- [CHANGELOG.md](../CHANGELOG.md) has a dated section per version. `ReleaseNotes/<version>/` holds the short notes in the five
  app languages (`en.md`, `pt-BR.md`, `fr.md`, `es.md`, `de.md`); they are shown on the GitHub release (English) and in the
  app's update window (in the user's language).

## What a release contains

| Asset | What it is |
|---|---|
| `MacSpace-<version>.dmg` | The app, signed with Developer ID, hardened runtime, notarized and stapled; the disk image is signed and notarized too |
| `MacSpace-<version>.dmg.sha256` | Its SHA-256 checksum (`shasum -a 256 -c MacSpace-<version>.dmg.sha256`) |
| `appcast.xml` | The update feed: this version and every earlier one, each with its EdDSA signature and notes in five languages |

Three channels deliver it, and all three move together:

1. **GitHub Releases**: the page and the download links.
2. **Sparkle**: the app reads `https://github.com/1architect/macspace-releases/releases/latest/download/appcast.xml`
   (`SUFeedURL` in `App/Resources/Info.plist`). Only the release marked *Latest* answers there, so drafts and pre-releases are
   never offered to anyone.
3. **Homebrew**: the cask `macspace` in [1architect/homebrew-macspace](https://github.com/1architect/homebrew-macspace)
   (`brew install --cask 1architect/macspace/macspace`). It is marked `auto_updates`, so Homebrew leaves updating to Sparkle.

## Making a release

1. **Main is ready.** CI is green, and the clean-Mac checks in [Handoff.md](Handoff.md#the-helper-making-sure-it-always-works)
   pass on the build you mean to ship.
2. **Notes.** In `CHANGELOG.md`, turn `## [Unreleased]` into `## [X.Y.Z] - YYYY-MM-DD`, start a new empty `## [Unreleased]`
   above it, and update the links at the bottom. Write `ReleaseNotes/X.Y.Z/en.md` and its four translations: short, in the
   app's own words (the texts in `Localization/*.json`), because they appear in the update window.
3. **Tag.** Commit (`MacSpace X.Y.Z`), then:
   ```bash
   git tag -a vX.Y.Z -m "MacSpace X.Y.Z"
   git push origin main vX.Y.Z
   ```
   CI's `release-metadata` job checks that the tag is a valid version, that the changelog has a dated section for it and that
   the notes exist in all five languages.
4. **Build the draft** (private repository): `Release/Scripts/Release.sh --ref vX.Y.Z --publish draft`, or *Actions › Release*.
   It builds the tag, runs the tests, signs, notarizes the app and the disk image, signs the update with MacSpace's Sparkle key,
   writes the feed and creates a **draft** release. Nothing is public yet.
5. **Try the draft.** Download the disk image from the draft, install it over the previous version on a Mac that is not the
   development Mac, and check that it opens without a Gatekeeper warning, that the helper answers (Settings › Permissions) and
   that each page loads.
6. **Publish** (private repository): `Release/Scripts/Publish.sh vX.Y.Z`. It checks the draft (assets, checksum, feed),
   publishes it as *Latest*, waits until the update feed offers the new version, and updates the Homebrew cask. From this moment
   installed copies find the update.

## Pre-releases and testing an update

A version with a suffix (`1.1.0-rc.1`) becomes a GitHub **pre-release**: downloadable, but never *Latest*, so the update feed and
Homebrew ignore it. Use pre-releases to test a version, and to test the update itself before it reaches anyone:

1. Release `vX.Y.Z-rc.1` built with `--feed-url https://github.com/1architect/macspace-releases/releases/download/vX.Y.Z-rc.2/appcast.xml`
   (the app then reads its updates from the next pre-release's feed; `FEED_URL` in `Scripts/Assemble.sh`).
2. Install rc.1 on a test Mac. Release `vX.Y.Z-rc.2` and publish it.
3. In rc.1, *Check for Updates…* must find rc.2, install it and relaunch; the helper must answer afterwards
   (`MacSpaceCli helper --ping` reports the new binary).

## How installed copies update

Sparkle asks on the second launch whether to check automatically; the choice can be changed in Settings › General (*Check for
updates automatically*, and *Check Now*), and *MacSpace › Check for Updates…* in the app menu checks at any time.
An update is downloaded from GitHub, its EdDSA signature is checked against the public key inside the app (`SUPublicEDKey`),
and Gatekeeper checks its Developer ID signature and notarization before it replaces the app. After an update the app compares
the helper it finds running with the one in its bundle and registers the new one.

## Stopping a bad release

Turn the release back into a draft:

```bash
gh release edit vX.Y.Z --repo 1architect/macspace-releases --draft=true
```

The previous release becomes *Latest* again, and the feed stops offering the bad version at once. Copies that already updated
stay on it (Sparkle never installs an older build), so ship the fix as the next patch version. If the cask was updated, publishing
the patch updates it again.

## What never goes in this repository

The Developer ID certificate and its private key, the notarization credentials, MacSpace's Sparkle private key, the token that
can publish releases, and the release workflow that uses them. The app carries only the Sparkle *public* key and the Team ID,
both visible in any signed build. `.gitignore` refuses the usual file types for each.
