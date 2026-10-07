# Contributing to MacSpace

Thank you for helping with MacSpace. This page says how to build and test it, what a good pull request contains, and which rules
keep the app safe. Everyone who takes part follows the [Code of Conduct](CODE_OF_CONDUCT.md).

MacSpace is released under the [MIT License](LICENSE). By sending a contribution, you agree that it is released under the same
license.

## Before you start

- Read [Docs/Handoff.md](Docs/Handoff.md). It covers the repository layout, how the app and its modules fit together, how the
  privileged helper works, what is verified and what is not, and the open work.
- Findings about macOS itself are in [Docs/Research.md](Docs/Research.md). Add a finding there, with an evidence label, when your
  change depends on how macOS behaves.
- Maintainers: [Docs/Releasing.md](Docs/Releasing.md) describes how a version is released.
- For a large change, open an issue first so we can agree on the approach before you write the code.
- To report a bug, a missing feature or a wrong translation, use the issue forms on GitHub.
- To report a security problem, follow [SECURITY.md](SECURITY.md). Never open a public issue for it.

## Requirements

- A Mac with Apple Silicon running macOS 27 or later.
- Xcode 27 (the beta is fine). The command-line tools alone are not enough: they lack the SwiftUI macros the app uses.
- A Developer ID or Apple Development certificate is optional. Without one, the build is signed ad hoc and is not notarized. An ad
  hoc signature changes with every build, so macOS asks you for Full Disk Access again each time.

MacSpace is a Swift package. There is no Xcode project.

## Build and test

Point the tools at the Xcode 27 toolchain in every new shell:

```bash
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
```

If your Xcode 27 has another name, use its path instead.

Run the tests:

```bash
swift test
```

Build the app and install it in `/Applications`:

```bash
INSTALL=1 Scripts/Assemble.sh
```

`Scripts/Assemble.sh` builds `Build/MacSpace.app` and signs it. `INSTALL=1` also quits a running copy and copies the app to
`/Applications`. It asks for an administrator password if that folder is not writable. The header of the script lists every setting
(`CONFIG`, `VERSION`, `BUILD`, `SIGN_IDENTITY`, `OUT_DIR` and more). To force an ad hoc signature, use `SIGN_IDENTITY=-`.

**Run the app from `/Applications`.** The privileged helper registers only from an Applications folder. A copy that runs from
anywhere else cannot install it.

A build without `SPARKLE_PUBLIC_KEY` never checks for updates. The signing identity, the notarization profile and the update keys
belong to the maintainer and are not in this repository. You do not need them to build, run or test MacSpace.

`Scripts/SelfTest.sh` checks the installed app on your own Mac. It switches Debloat settings off and puts them back, and it writes
its report to `results/`, which Git ignores. Read it before you run it. It is optional.

GitHub Actions builds the package, runs the tests and checks the translations on every pull request. A pull request needs a green
run.

## Localization

MacSpace speaks five languages: English, Portuguese (Brazil), French, Spanish and German. **Every text that appears on screen
needs a translation in all four other languages.** The check below fails without them.

Translations live in `Localization/<Table>.json`. `App.json` holds the app's texts, and there is one table for each module
(`SystemData.json`, `Siri.json`, `OtherSystemFiles.json`, `Debloat.json`). Each entry maps the English text, exactly as the code has
it, to its four translations in this order: Portuguese (Brazil), French, Spanish, German.

```json
"Recent cleanups": ["Limpezas recentes", "Nettoyages récents", "Limpiezas recientes", "Letzte Bereinigungen"]
```

After you change any text, run both commands from the repository root:

```bash
swift Scripts/Localize.swift
swift Scripts/Localize.swift --check
```

What they do:

- `swift Scripts/Localize.swift` reads every table and writes `<language>.lproj/Localizable.strings` into `App/Resources` (for
  `App.json`) and into `Modules/<Module>/Bundle` (for a module's table). `Scripts/Assemble.sh` copies these files into the app. The
  generated files are committed, so commit them with your change and never edit them by hand. The script stops if a translation
  drops a placeholder (`%@`, `%lld`, `%%`) from the English text, or if an entry does not have exactly four translations.
- `--check` does the same and then builds the whole package with the compiler's string extraction, in a temporary folder, so it
  takes a while. It lists every text the code shows that no table has, and it exits with an error when any is missing. It skips the
  developer tools, the command-line tool and the helper, which stay in English. A format with no words to translate (`%@ · %@`)
  needs no entry.

How a text reaches the screen:

- In the app, SwiftUI literals are localized by themselves. Other text goes through `String(localized:)`.
- In a module, text goes through the module's own `loc(...)` (`Support/Localization.swift`), which reads the module's bundle.
- The names in Debloat's catalog, which the helper shares, go through `locKey`.

Write texts in plain language and keep them short. If you are not sure of a translation, say so in the pull request and a native
speaker can review it. The translation issue form is the way to report a wrong text without changing code.

## Adding a module

Each module is a separate bundle that describes its screens for the app to draw. The steps are in
[Docs/Handoff.md](Docs/Handoff.md#adding-a-module). In short:

1. Create `Modules/<Name>/{Module,Bundle}`, and `Privileged/` if the module needs root.
2. Subclass `MacSpaceModuleEntry`, return a `MacSpaceModule` from `makeModule()`, and set the class as the bundle's
   `NSPrincipalClass`.
3. Write `Manifest.json` and `Bundle/Info.plist`.
4. Add the targets to `Package.swift`. The dynamic library product must have exactly the name of the folder.
5. Add `Localization/<Name>.json` and run the localization commands above.
6. Write tests in `Tests/<Name>`. Build the screens with pure functions of a snapshot, so the tests need no special Mac.

## Conventions

- Folder names start with a capital letter.
- Do not change a bundle identifier (`com.macspace.*`). Full Disk Access, the helper approval and update signatures depend on them.
- Anything new that uses a private Apple interface needs a guard that checks it on the running macOS build, and crash isolation.
  CacheDelete is the model: it runs in `MacSpaceCli` as a child process, so a crash there never takes the app down.
- Changes that need administrator rights go through the privileged helper, as a named operation in the module's `Privileged/`
  library. The helper answers only the signed app.
- `Sdk` and `Platform` are separate packages on purpose. Do not merge them into the main package (the reason is in the Handoff).
- Every switch shows the feature: on means the feature runs, off means MacSpace switched it off.
- Give a row a description only when its title is not enough. Keep it to one or two short sentences.
- Commit titles start with a capital letter and say what changed. Naming the area first is fine ("Debloat: ...").
- Do not commit signing material, keys, tokens or experiment results. The `.gitignore` covers the usual files.

## Pull requests

Keep each pull request to one change. Before you open it:

1. `swift test` passes.
2. `swift Scripts/Localize.swift --check` is clean, and the generated `.strings` files are in your commit.
3. New or changed on-screen text has a translation in all five languages.
4. UI changes include screenshots, in the night and the day look when both are affected.
5. [CHANGELOG.md](CHANGELOG.md) has an entry under "Unreleased", in the right group (Added, Changed, Deprecated, Removed, Fixed
   or Security), written for people who use the app.
6. [Docs/Handoff.md](Docs/Handoff.md) is updated if you changed how the app is built, tested or put together.
7. The pull request says how you tested the change, and on which macOS build.

The pull request template has the same list.

## Documentation in five languages

`README`, `PRIVACY` and `SECURITY` each exist in five languages: the English file (`README.md`) and `.pt-BR.md`, `.fr.md`,
`.es.md` and `.de.md` versions next to it. If you change one of them, update all five. If you cannot, change the English file and
say in the pull request which translations are out of date, so a maintainer or another contributor can bring them up to date.

`CHANGELOG.md`, `CONTRIBUTING.md`, `CODE_OF_CONDUCT.md`, `NOTICE` and the files in `Docs/` are in English only. Release notes are
written in five languages, in `ReleaseNotes/<version>/` (`en.md`, `pt-BR.md`, `fr.md`, `es.md` and `de.md`).

## Contact

Write to [dev@giomantovani.com.br](mailto:dev@giomantovani.com.br) for anything that does not fit an issue. For security problems,
use [SECURITY.md](SECURITY.md).
