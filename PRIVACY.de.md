[English](PRIVACY.md) · [Português](PRIVACY.pt-BR.md) · [Español](PRIVACY.es.md) · [Français](PRIVACY.fr.md) · **Deutsch**

# Datenschutzerklärung — MacSpace

**Zuletzt aktualisiert: 6. Oktober 2026 · Gilt für MacSpace 1.0.0 und neuer**

MacSpace erfasst, speichert oder überträgt keine Nutzungsdaten. Es gibt keine Analyse, keine
Telemetrie, keine Absturzberichte und keine Werbung. MacSpace hat kein Account-System, du legst
also nie ein Profil an und meldest dich nie an.

Dieses Dokument beschreibt genau, was MacSpace liest, wo es das ablegt und den einzigen Moment,
in dem es das Netzwerk nutzt.

---

## Was auf deinem Mac bleibt

MacSpace misst deinen Speicher, liest einige Systemeinstellungen und schreibt einige kleine
Dateien auf deinen eigenen Mac. Nichts davon verlässt deinen Mac.

| Daten | Wo sie gespeichert werden |
|---|---|
| Deine Einstellungen: Thema, Fensterauswahl, welche Module aktiviert sind, Moduloptionen, automatische Bereinigung, Mitteilungseinstellungen, die zuletzt von jedem Modul gezeigte Kachel, der Schritt beim ersten Start | macOS-Einstellungen (`UserDefaults`) für MacSpace, `~/Library/Preferences/com.macspace.app.plist` |
| Eigene Einstellungen von Sparkle: ob automatisch nach Updates gesucht wird und wann zuletzt gesucht wurde | Dieselbe Einstellungsdatei |
| Bereinigungsverlauf: wann, welches Modul, wie viel freigegeben wurde, wie es gestartet wurde, eine einzeilige Zusammenfassung | `~/Library/Application Support/MacSpace/cleanup-history.json` |
| Speicher, den macOS behalten hat, obwohl MacSpace ihn zur Freigabe angefordert hatte | `~/Library/Application Support/MacSpace/purge-holdouts.json` |
| Debloat-Journal: jede Einstellung, die MacSpace geändert hat, ihr Wert davor und danach, der macOS-Build und der Zeitpunkt | `~/Library/Application Support/MacSpace/debloat-journal.json` und, für Änderungen durch das Hilfsprogramm, `/Library/Application Support/MacSpace/debloat-journal.json` |
| Debloat-Überwachung: welche Funktionen macOS wieder eingeschaltet hat und wann (die letzten 20 Ereignisse) | `~/Library/Application Support/MacSpace/debloat-watch.json` |
| Das Debloat-Profil, so wie es zu deiner Genehmigung bereitliegt | `~/Library/Application Support/MacSpace/Profiles/MacSpace.mobileconfig` |
| Deine Siri-Sprache und deine Siri-Stimme, gesichert, solange Apple Intelligence aus ist, damit MacSpace sie wiederherstellen kann | `~/Library/Application Support/MacSpace/ai-guard-saved-siri-settings.json` |
| Apple Intelligence-Überwachung (nur wenn du sie einschaltest): der zuletzt gesehene Zustand und ein Protokoll der Änderungen | `~/Library/Application Support/MacSpace/ai-watch-state.json` und `~/Library/Logs/MacSpace/ai-watch.jsonl` |
| Ein Backup der Abonnement-Datenbank von macOS, nur wenn du übrige Apple Intelligence-Abonnements gelöschter Accounts entfernst | `/Library/Application Support/MacSpace/backups/` |
| Update-Downloads | Der Cache-Ordner von Sparkle, `~/Library/Caches/com.macspace.app/` |

Du kannst alles jederzeit löschen. [README.de.md](README.de.md#deinstallation) listet die Befehle
auf. Löschst du diese Dateien, vergisst MacSpace seinen Verlauf und seine Einstellungen. Löschst
du die Debloat-Journale, während Debloat-Schalter ausgeschaltet sind, kann MacSpace die
gesicherten Originalwerte nicht mehr wiederherstellen und verwendet stattdessen die Standardwerte
von macOS. Klicke zuerst auf **Alle aktivieren**.

### Was MacSpace liest

MacSpace liest diese Dinge auf deinem Mac, um seine Aufgabe zu erfüllen. Nichts davon sendet es
irgendwohin.

- **Namen und Größen von Dateien und Ordnern**, auf dem gesamten Speicher, sobald du ihm
  Festplattenvollzugriff gibst. Es liest nicht, was in deinen Dokumenten, Fotos, E-Mails oder
  Nachrichten steht. Es misst, wie viel Speicher sie belegen.
- **Einige Systemdateien:** die Datei zur Verfügbarkeit von Apple Intelligence, die Datenbank
  von macOS für Ressourcen-Abonnements, die Liste der installierten Konfigurationsprofile und die
  Apple Account-Datenbank (nur lesend, um herauszufinden, ob die iCloud-Synchronisierung von Siri
  an ist).
- **Die Namen der Benutzeraccounts auf diesem Mac**, um zu sagen, welcher Account Apple
  Intelligence an lässt.
- **Der Zustand von macOS:** Version und Build, ob der Systemintegritätsschutz an ist, ob der Mac
  in einer Geräteverwaltung registriert ist, die Namen laufender Prozesse (um zu prüfen, ob ein
  Debloat-Schalter gewirkt hat) und einige Zeilen des Systemprotokolls, die die eigenen
  Analyse-Entscheidungen von macOS festhalten (um zu prüfen, ob der Schalter für Analysedaten
  gewirkt hat).

---

## Wann MacSpace das Netzwerk nutzt

MacSpace nutzt das Netzwerk für einen einzigen Zweck: **Updates**. Es hat keine Analyse, keine
Anmeldung und keine andere Verbindung.

### Wann es nach Updates sucht

MacSpace nutzt [Sparkle](https://sparkle-project.org), um Updates zu finden und zu installieren.
Es nimmt in diesen Fällen Verbindung zum Netzwerk auf:

- wenn du im Menü „MacSpace“ **Nach Updates suchen …** wählst oder in den Einstellungen **Jetzt
  prüfen**;
- etwa einmal am Tag, solange MacSpace läuft, wenn automatische Prüfungen an sind.

Automatische Prüfungen sind aus, bis du in den Einstellungen **Automatisch nach Updates suchen**
einschaltest oder die Frage, die Sparkle ab dem zweiten Start einmal stellt, mit Ja beantwortest.
Bis dahin sucht MacSpace nicht von selbst. Ein Build, den du selbst aus dem Quellcode erstellst,
hat keinen Update-Schlüssel und sucht nie nach Updates.

Eine Prüfung ruft eine Datei von GitHub ab:

```
https://github.com/1architect/macspace-releases/releases/latest/download/appcast.xml
```

Wie bei jeder Webanfrage kann GitHub deine IP-Adresse sehen. Die Anfrage enthält außerdem den
Namen und die Version von MacSpace sowie die Version von Sparkle, im üblichen
`User-Agent`-Header. MacSpace sendet kein Systemprofil, keine Hardwareinformationen und keinerlei
Kennung. Das optionale Systemprofil von Sparkle ist nicht eingeschaltet. Wie GitHub diese Anfrage
behandelt, regelt die
[GitHub-Datenschutzerklärung](https://docs.github.com/site-policy/privacy-policies/github-privacy-statement)
(auf Englisch).

Wenn du ein Update annimmst, lädt Sparkle es von GitHub Releases herunter. Jedes Update ist
signiert. Sparkle prüft die Signatur gegen den öffentlichen Schlüssel in MacSpace, bevor es etwas
installiert.

### Was nicht von MacSpace stammt

Schaltest du Apple Intelligence wieder ein, lädt macOS (nicht MacSpace) möglicherweise dessen
Modelle. Wenn du eine geladene App öffnest, prüft macOS sie möglicherweise bei Apple. Das sind
eigene Verbindungen von macOS.

---

## Was MacSpace nie tut

- Es sendet nie deine Dateiliste, Speicherwerte, Einstellungen, deinen Bereinigungsverlauf oder
  Account-Namen irgendwohin.
- Es liest nie den Inhalt deiner Dokumente, Fotos, E-Mails oder Nachrichten.
- Es bittet dich nie, einen Account anzulegen oder dich anzumelden.
- Es meldet nie Abstürze oder Nutzung, weder an den Entwickler noch an sonst jemanden.

### Zu Berechtigungen und zum Hilfsprogramm

MacSpace bittet um einige Genehmigungen, jeweils im eigenen Dialog von macOS oder in den
Systemeinstellungen, daher sieht es nie dein Passwort:

- **Festplattenvollzugriff**, um alles auf dem Speicher zu messen und den Zustand von Apple
  Intelligence zu lesen.
- **Ein privilegiertes Hilfsprogramm**, ein Launch-Daemon (`com.macspace.helper`), der die
  wenigen Aufgaben erledigt, die einen Administrator erfordern. Es akzeptiert nur Clients, die
  vom selben Entwicklerteam wie MacSpace signiert sind, und führt nur Operationen aus, die fest
  in ihm eingebaut sind.
- **Ein Konfigurationsprofil**, nur wenn du eine Debloat-Richtlinie ausschaltest.
- **Mitteilungen**, um dir zu sagen, wenn etwas fertig ist.

Was das Hilfsprogramm und das Profil tun können, steht in [SECURITY.de.md](SECURITY.de.md).

---

## Kinder

MacSpace ist ein Dienstprogramm für macOS und richtet sich nicht an Kinder. Es erfasst von
niemandem personenbezogene Daten, in keinem Alter.

## Änderungen an dieser Erklärung

Ändert sich das Verhalten von MacSpace, ändert sich dieses Dokument mit, und das Datum oben
ändert sich ebenfalls. Der Verlauf dieser Datei ist in diesem Repository öffentlich, du kannst
also genau sehen, was sich wann geändert hat.

## Kontakt

Fragen zum Datenschutz oder zu allem in diesem Dokument:

**dev@giomantovani.com.br**
