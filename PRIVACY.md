**English** · [Português](PRIVACY.pt-BR.md) · [Español](PRIVACY.es.md) · [Français](PRIVACY.fr.md) · [Deutsch](PRIVACY.de.md)

# Privacy Policy — MacSpace

**Last updated: 6 October 2026 · Applies to MacSpace 1.0.0 and later**

MacSpace does not collect, store, or transmit any usage data. There is no analytics, no
telemetry, no crash reporting, and no advertising. MacSpace has no account system, so you never
create a profile or sign in.

This document describes exactly what MacSpace reads, where it keeps it, and the only moment it
uses the network.

---

## What stays on your Mac

MacSpace measures your disk, reads a few system settings, and writes a few small files to your
own machine. None of it leaves your Mac.

| Data | Where it is stored |
|---|---|
| Your settings: theme, window choices, which modules are on, module options, automatic cleanup, notification choices, the last tile each module showed, the first-launch step | macOS preferences (`UserDefaults`) for MacSpace, `~/Library/Preferences/com.macspace.app.plist` |
| Sparkle's own settings: whether to check for updates automatically, and when it last checked | The same preferences file |
| Cleanup history: when, which module, how much it freed, how it started, a one-line summary | `~/Library/Application Support/MacSpace/cleanup-history.json` |
| Space that macOS kept although MacSpace asked it to free it | `~/Library/Application Support/MacSpace/purge-holdouts.json` |
| Debloat journal: each setting MacSpace changed, its value before and after, the macOS build, and when | `~/Library/Application Support/MacSpace/debloat-journal.json`, and for changes made by the helper `/Library/Application Support/MacSpace/debloat-journal.json` |
| Debloat watch: which features macOS switched back on, and when (the last 20 events) | `~/Library/Application Support/MacSpace/debloat-watch.json` |
| The Debloat profile, as it is staged for your approval | `~/Library/Application Support/MacSpace/Profiles/MacSpace.mobileconfig` |
| Your Siri language and voice, saved while Apple Intelligence is off so MacSpace can restore them | `~/Library/Application Support/MacSpace/ai-guard-saved-siri-settings.json` |
| Apple Intelligence watch (only if you turn it on): the last state it saw, and a log of changes | `~/Library/Application Support/MacSpace/ai-watch-state.json` and `~/Library/Logs/MacSpace/ai-watch.jsonl` |
| A backup of macOS's subscription database, only if you remove leftover Apple Intelligence subscriptions of deleted accounts | `/Library/Application Support/MacSpace/backups/` |
| Update downloads | Sparkle's cache folder, `~/Library/Caches/com.macspace.app/` |

You can delete all of it at any time. [README.md](README.md#uninstall) lists the commands.
Deleting these files makes MacSpace forget its history and settings. If you delete the Debloat
journals while Debloat switches are off, MacSpace can no longer restore the original values it
saved, and uses macOS's defaults instead. Press **Enable all** first.

### What MacSpace reads

MacSpace reads these things on your Mac, to do its job. It does not send any of them anywhere.

- **Names and sizes of files and folders**, on the whole disk once you give it Full Disk Access.
  It does not read what is in your documents, photos, mail or messages. It measures how much
  space they take.
- **A few system files:** the Apple Intelligence eligibility file, macOS's database of asset
  subscriptions, the list of installed configuration profiles, and the Apple Account database
  (read only, to learn whether Siri's iCloud sync is on).
- **The names of the user accounts on this Mac**, to say which account keeps Apple Intelligence on.
- **The state of macOS:** its version and build, whether System Integrity Protection is on, whether
  the Mac is enrolled in device management, the names of running processes (to check that a
  Debloat switch took effect), and a few lines of the system log that record macOS's own analytics
  decisions (to check that the analytics switch worked).

---

## When MacSpace uses the network

MacSpace uses the network for one purpose: **updates**. It has no analytics, no sign-in and no
other connection.

### When it checks for updates

MacSpace uses [Sparkle](https://sparkle-project.org) to find and install updates. It contacts the
network in these cases:

- when you choose **Check for Updates…** in the MacSpace menu, or **Check Now** in Settings;
- about once a day while MacSpace runs, if automatic checks are on.

Automatic checks are off until you switch on **Check for updates automatically** in Settings, or
say yes to the question Sparkle asks once, from the second launch. Until then, MacSpace does not
check by itself. A build you make from source has no update key, and never checks at all.

A check requests one file from GitHub:

```
https://github.com/1architect/macspace-releases/releases/latest/download/appcast.xml
```

As with any web request, GitHub can see your IP address. The request also carries the name and
version of MacSpace and the version of Sparkle, in the usual `User-Agent` header. MacSpace sends no
system profile, no hardware information, and no identifier of any kind. Sparkle's optional system
profile is not turned on. GitHub's handling of that request is covered by the
[GitHub Privacy Statement](https://docs.github.com/site-policy/privacy-policies/github-privacy-statement).

If you accept an update, Sparkle downloads it from GitHub Releases. Every update is signed.
Sparkle checks the signature against the public key inside MacSpace before it installs anything.

### What is not MacSpace

If you switch Apple Intelligence back on, macOS (not MacSpace) may download its models. When you
open a downloaded app, macOS may check it with Apple. Those are macOS's own connections.

---

## What MacSpace never does

- It never sends your file list, disk figures, settings, cleanup history or account names
  anywhere.
- It never reads the contents of your documents, photos, mail or messages.
- It never asks you to create an account or to sign in.
- It never reports crashes or usage, to the developer or to anyone else.

### About permissions and the helper

MacSpace asks for a few approvals, each in macOS's own dialog or in System Settings, so it never
sees your password:

- **Full Disk Access**, to measure everything on the disk and to read the state of Apple
  Intelligence.
- **A privileged helper**, a launch daemon (`com.macspace.helper`) that does the few things that
  need an administrator. It accepts only clients signed by the same developer team as MacSpace and
  runs only operations that are built into it.
- **A configuration profile**, only if you switch off a Debloat policy.
- **Notifications**, to tell you when something finished.

What the helper and the profile can do is listed in [SECURITY.md](SECURITY.md).

---

## Children

MacSpace is a utility for macOS and is not directed at children. It collects no personal
information from anyone, of any age.

## Changes to this policy

If MacSpace's behavior changes, this document changes with it, and the date at the top changes
too. The history of this file is public in this repository, so you can see exactly what changed
and when.

## Contact

Questions about privacy, or about anything in this document:

**dev@giomantovani.com.br**
