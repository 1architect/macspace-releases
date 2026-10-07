[English](SECURITY.md) · [Português](SECURITY.pt-BR.md) · [Español](SECURITY.es.md) · [Français](SECURITY.fr.md) · **Deutsch**

# Sicherheitsrichtlinie

MacSpace ist eine kostenlose Open-Source-App (MIT) für macOS. Sie läuft mit deinem normalen
Benutzeraccount. Für die wenigen Aufgaben, die einen Administrator erfordern, nutzt sie ein
privilegiertes Hilfsprogramm, das du einmal genehmigst. Sie erfasst keine Daten über dich. Dieses
Dokument erklärt genau, was MacSpace auf deinem Mac berührt und wie du ein Problem meldest.

## Sicherheitslücke melden

Nutze die private Schwachstellenmeldung von GitHub:
[Sicherheitslücke melden](https://github.com/1architect/macspace-releases/security/advisories/new).
Oder schreibe eine E-Mail an **dev@giomantovani.com.br** mit den Details und den Schritten zur
Reproduktion. Bitte eröffne kein öffentliches Issue für eine Sicherheitsmeldung. Du erhältst
innerhalb weniger Tage eine Eingangsbestätigung.

Was zählt: alles, womit ein anderes Programm das Hilfsprogramm dazu bringen kann, etwas zu tun,
was du nicht verlangt hast, womit MacSpace etwas löschen oder ändern kann, was es nicht dürfte,
oder womit sich ein Update ohne die Signatur der Version installieren lässt.

## Unterstützte Versionen

Sicherheitskorrekturen erscheinen nur in der neuesten Version. Aktualisiere immer auf die neueste
Version, von [Releases](https://github.com/1architect/macspace-releases/releases/latest), mit
**Nach Updates suchen …** oder mit `brew upgrade --cask macspace` (füge `--greedy` hinzu, wenn
Homebrew es überspringt, weil sich MacSpace selbst aktualisiert).

## Was MacSpace auf deinem Mac tut

### Netzwerk

MacSpace baut Netzwerkverbindungen für einen einzigen Zweck auf: Updates. Wenn du **Nach Updates
suchen …** wählst (oder **Jetzt prüfen** in den Einstellungen) und, falls du **Automatisch nach
Updates suchen** eingeschaltet hast, etwa einmal am Tag, solange es läuft, liest es den
Update-Feed (`appcast.xml`), der mit den Versionen auf GitHub gehostet wird. Wenn du ein Update
annimmst, lädt es die neue Version von GitHub Releases herunter. Über dich wird nichts gesendet,
und das optionale Systemprofil von Sparkle ist nicht eingeschaltet.

Es gibt keine Analyse, keine Telemetrie und keine Absturzberichte. Die Einzelheiten stehen in der
[Datenschutzerklärung](PRIVACY.de.md).

### Wo deine Daten gespeichert sind

Alles bleibt auf deinem Mac. Die Dateien von MacSpace liegen in
`~/Library/Application Support/MacSpace/`, `~/Library/Logs/MacSpace/`, in der Einstellungsdatei
`~/Library/Preferences/com.macspace.app.plist` und, für das, was das Hilfsprogramm schreibt, in
`/Library/Application Support/MacSpace/`. Die [Datenschutzerklärung](PRIVACY.de.md) listet jede
Datei auf. Nichts davon wird irgendwohin hochgeladen.

### Was MacSpace löscht

| Was | Wo | Ausgeführt von |
|---|---|---|
| Caches von Apps, die geschlossen sind | Der Systemcache-Ordner pro Benutzer (`/var/folders/…/C`), außer den eigenen von Apple. Die Ordner `Cache`, `Code Cache`, `GPUCache`, `DawnCache`, `DawnGraphiteCache`, `DawnWebGPUCache`, `GrShaderCache`, `ShaderCache` und `CachedData` in einem Chromium- oder Electron-Profil in `~/Library/Application Support`. | Die App, als du |
| Diagnose- und Absturzberichte, die älter als 7 Tage sind | `/Library/Logs/DiagnosticReports` und `~/Library/Logs/DiagnosticReports`. Eine Datei, die du nicht löschen darfst, wird übersprungen. | Die App, als du |
| Ungenutzte Systemressourcen, freigegebene Apple Intelligence-Modelle, Dateien, die Apps als löschbar markiert haben | Der eigene Bereinigungsdienst von macOS (CacheDelete). MacSpace fordert ihn in einem kurzlebigen Kindprozess an, sodass ein Fehler dort die App nicht zum Absturz bringen kann. | macOS |
| Lokale Kopien von Cloud-Dateien | Jeweils ein Cloud-Ordner (`~/Library/CloudStorage/…` oder iCloud Drive). Nur Dateien, die hochgeladen sind und keinen Konflikt haben. Die Dateien bleiben in der Cloud. | Die App, als du |
| Versionsverlauf von Dokumenten | `/System/Volumes/Data/.DocumentRevisions-V100` | Das Hilfsprogramm |
| Übrige macOS-Update-Dateien | `/System/Volumes/Data/macOS Install Data`, nur wenn älter als das installierte System. Der Ordner `Locked Files` bleibt. | Das Hilfsprogramm |

Nichts landet im Papierkorb. Caches, Systemressourcen und löschbare Dateien werden bei Bedarf neu
aufgebaut oder erneut geladen, und Cloud-Kopien werden beim Öffnen der Datei erneut geladen.
Berichte, Versionsverlauf und Update-Überbleibsel kommen nicht zurück. Jedes davon fragt zuerst
nach einer Bestätigung, außer der Schaltfläche **Freigeben** für die Caches einer einzelnen App.

### Was MacSpace ändert (Debloat)

Jede Änderung wird zuerst in ein Journal geschrieben, damit sie sich mit **Alle aktivieren** oder
durch Wiedereinschalten der Funktion rückgängig machen lässt.

| Schalter | Was sich ändert | Ausgeführt von |
|---|---|---|
| Personalisierte Werbung | `com.apple.AdLib`, Schlüssel `allowApplePersonalizedAdvertising` | Die App, als du |
| Siri & Diktat verbessern | `com.apple.assistant.support`, Schlüssel `Siri Data Sharing Opt-In Status` | Die App, als du |
| Absturzbericht-Dialog | Eine launchd-Überschreibung für `com.apple.DiagnosticsReporter` und `com.apple.ReportGPURestart` | Die App, als du |
| Analysedaten mit Apple teilen (Release-Builds von macOS) | `/Library/Application Support/CrashReporter/DiagnosticMessagesHistory.plist`, Schlüssel `AutoSubmit` und `ThirdPartyDataSubmit` | Das Hilfsprogramm |
| Siri AI, Visuelle Intelligenz, Indizierung für generative Suche | Überschreibungen von Feature-Flags in `/Library/Preferences/FeatureFlags/Domain/` | Das Hilfsprogramm |
| Hänger-Aufzeichnung (tailspin) | `tailspin disable` und `tailspin enable`, um es rückgängig zu machen | Das Hilfsprogramm |
| Die Richtlinien (sechs; sieben in einer Betaversion von macOS) | Ein Konfigurationsprofil, `com.macspace.policies` (siehe unten) | Du genehmigst es in den Systemeinstellungen |

Diese Änderungen bleiben bestehen, wenn du die App löschst, ohne sie wieder einzuschalten.

### Apple Intelligence

Der Schalter **Apple Intelligence** ändert den Schlüssel `Session Language` in
`com.apple.assistant.backedup`, das ist die Sprache von Siri. Ist er ausgeschaltet, erhält Siri
eine andere Sprache als die des Systems, und deine Siri-Stimme (`Output Voice`) bleibt
unverändert. MacSpace sichert beides in
`~/Library/Application Support/MacSpace/ai-guard-saved-siri-settings.json` und stellt es wieder
her, wenn du Apple Intelligence einschaltest oder wenn die Änderung nicht wirkt. Behält macOS die
Modelle, nachdem der Schalter aus ist, setzt MacSpace die Sprache möglicherweise auf die
Systemsprache und wieder zurück, was etwa eine Minute dauert, damit macOS sie freigibt. Bei aktiver
iCloud-Synchronisierung von Siri erreichen diese Änderungen auch deine anderen Geräte mit
demselben Apple Account. MacSpace kann diese Synchronisierung nicht ausschalten. Es sagt dir, wo
du das tun kannst.

### Berechtigungen

macOS übernimmt jede Abfrage, daher sieht MacSpace nie dein Passwort.

| Berechtigung | Wo | Wofür MacSpace sie nutzt |
|---|---|---|
| Festplattenvollzugriff | Systemeinstellungen > Datenschutz & Sicherheit | Messen von Ordnern, die macOS schützt, und Lesen des Zustands von Apple Intelligence |
| Privilegiertes Hilfsprogramm | Systemeinstellungen > Allgemein > Anmeldeobjekte & Erweiterungen | Die Operationen unten |
| Konfigurationsprofil | Systemeinstellungen > Allgemein > Geräteverwaltung | Nur wenn du eine Debloat-Richtlinie ausschaltest |
| Mitteilungen | macOS fragt | Dir sagen, dass etwas fertig ist |

### Das privilegierte Hilfsprogramm

Das Hilfsprogramm ist ein Launch-Daemon, `com.macspace.helper`, der aus der App heraus bei macOS
registriert wird. launchd startet ihn, wenn MacSpace etwas anfordert. Er läuft als root und
akzeptiert eine Verbindung nur von einem Programm, das diese Codesignatur-Anforderung erfüllt, die
macOS prüft:

```
anchor apple generic and (identifier "com.macspace.app" or identifier "com.macspace.cli")
and certificate leaf[subject.OU] = "<the developer's team ID>"
```

Ohne eine solche Anforderung startet er nicht. Er führt nur benannte Operationen aus, die fest in
ihm eingebaut sind. Ein Aufrufer kann ihm keine Befehle schicken. Wird die App durch ein Update
ersetzt, bemerkt das Hilfsprogramm es und beendet sich, damit das neue startet.

| Operation | Was sie tut | Grenzen |
|---|---|---|
| `systemdata.measure` | Größen von Ordnern | Nur lesend. Nur unter `/private/var`, `/private/tmp`, `/Library`, `/System/Library`, dem Stammverzeichnis des Datenvolumes und `/opt`, nie ein Benutzerordner. Größen, nie Inhalte. |
| `systemdata.versions.delete` | Löscht den Versionsverlauf von Dokumenten | Beendet zuerst `revisiond` oder hält es an, wenn macOS das verweigert. Löscht den Inhalt des Speichers, nicht den Ordner, und startet `revisiond` dann wieder. Kann es `revisiond` nicht beenden, löscht es nichts. |
| `systemdata.staged-update.delete` | Löscht übrige Update-Dateien | Nur wenn der Ordner älter ist als das installierte System. Behält `Locked Files`. |
| `debloat.status`, `.apply`, `.revert` | Liest Debloat-Objekte, schaltet sie aus und wieder ein | Nur Kennungen von Einstellungen aus dem eingebauten Katalog. Sonst nichts. |
| `debloat.removeProfile` | Entfernt ein MacSpace-Profil | Nur die Kennungen `com.macspace.policies` und `com.macspace.policies.…`. Jedes andere Profil wird abgelehnt. |
| `siri.orphan-subscriptions.plan`, `.execute` | Findet und entfernt die Apple Intelligence-Abonnements von Accounts, die es nicht mehr gibt | Sichert zuerst die Datenbank in `/Library/Application Support/MacSpace/backups/`, ändert sie in einer einzigen Transaktion, berührt nur Zeilen, die zu keinem lokalen Account passen, und lehnt ab, wenn die Account-Liste falsch aussieht. Die App hat dafür noch keine Schaltfläche. |
| `helper.ping` | Antwortet, damit die App weiß, dass das Hilfsprogramm läuft | Keine |

Das Befehlszeilenwerkzeug der App, `MacSpaceCli`, im App-Bundle, kann ebenfalls mit dem
Hilfsprogramm sprechen. Es ist mit demselben Team signiert.

### Das Konfigurationsprofil

Die Richtlinien von Debloat sind Einstellungen, die nur ein Konfigurationsprofil erzwingen kann.
MacSpace erstellt ein Profil, `com.macspace.policies` (angezeigt als **MacSpace: policies**,
Organisation „MacSpace“), mit jeder Richtlinie, die du ausgeschaltet hast. Es öffnet das Profil,
und du genehmigst es unter Systemeinstellungen > Allgemein > Geräteverwaltung. Die Genehmigung
ersetzt das frühere Profil. Es ist nicht als unentfernbar markiert. Schaltest du die letzte
Richtlinie wieder ein, wird es über das Hilfsprogramm entfernt, ohne dass etwas zu genehmigen
ist. Du kannst es auch selbst in den Systemeinstellungen entfernen.

### Codesignatur und Updates

MacSpace ist mit einer Apple Developer ID signiert, mit Hardened Runtime, und von Apple
notarisiert. Das Notarisierungs-Ticket ist an die App angeheftet, sie öffnet sich also auch
offline. Die eigenen Komponenten von Sparkle sind mit derselben Identität signiert.

Updates sind außerdem mit einem EdDSA-Schlüssel signiert. Seine öffentliche Hälfte steckt in
MacSpace (`SUPublicEDKey`), und Sparkle prüft jeden Download dagegen, bevor es installiert. Die
private Hälfte dieses Schlüssels und die Signaturidentität sind nicht in diesem Repository. Eine
ohne den öffentlichen Schlüssel gebaute Kopie von MacSpace sucht nie nach Updates.

## Download prüfen

Lege `MacSpace-x.y.z.dmg` und `MacSpace-x.y.z.dmg.sha256` in einen Ordner:

```bash
shasum -a 256 -c MacSpace-x.y.z.dmg.sha256
```

Dann, nachdem du MacSpace in „Programme“ gezogen hast:

```bash
codesign -dv --verbose=4 /Applications/MacSpace.app
codesign --verify --deep --strict --verbose=2 /Applications/MacSpace.app
spctl -a -vv /Applications/MacSpace.app
xcrun stapler validate /Applications/MacSpace.app
```

Du solltest `Authority=Developer ID Application`, `TeamIdentifier=J45ZXS2ZF6`, das Flag
`runtime` und `Notarization Ticket=stapled` sehen, und `spctl` sollte `accepted` mit
`source=Notarized Developer ID` melden.

## Vollständig deinstallieren

Es gibt kein Deinstallationsprogramm in der App. Die vollständigen Schritte stehen in der
[README](README.de.md#deinstallation). Kurz gesagt:

1. Klicke in **Debloat** auf **Alle aktivieren**. Das entfernt die Überschreibungen und das
   Profil, das es angelegt hat.
2. Ist das Profil **MacSpace: policies** noch in Systemeinstellungen > Allgemein >
   Geräteverwaltung vorhanden, entferne es.
3. Beende MacSpace. Schalte es unter Systemeinstellungen > Allgemein > Anmeldeobjekte &
   Erweiterungen aus oder führe
   `/Applications/MacSpace.app/Contents/MacOS/MacSpaceCli helper --unregister` aus.
4. Entferne die App: `brew uninstall --cask macspace` oder ziehe **MacSpace** in den Papierkorb.
5. Entferne ihre Daten und Einstellungen:
   ```bash
   rm -rf ~/Library/Application\ Support/MacSpace ~/Library/Logs/MacSpace ~/Library/Caches/com.macspace.app
   defaults delete com.macspace.app
   sudo rm -rf /Library/Application\ Support/MacSpace
   ```
6. Entferne MacSpace aus Systemeinstellungen > Datenschutz & Sicherheit > Festplattenvollzugriff.
