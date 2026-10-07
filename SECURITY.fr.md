[English](SECURITY.md) · [Português](SECURITY.pt-BR.md) · [Español](SECURITY.es.md) · **Français** · [Deutsch](SECURITY.de.md)

# Politique de sécurité

MacSpace est un utilitaire gratuit et open source (MIT) pour macOS. Il s’exécute avec votre compte
utilisateur habituel. Pour les quelques tâches qui demandent un administrateur, il utilise un
assistant privilégié que vous approuvez une fois. Il ne collecte aucune donnée sur vous. Ce document
explique précisément ce que MacSpace touche sur votre Mac et comment signaler un problème.

## Signaler une vulnérabilité

Utilisez le signalement privé de vulnérabilités de GitHub :
[signaler une vulnérabilité](https://github.com/1architect/macspace-releases/security/advisories/new).
Ou écrivez à **dev@giomantovani.com.br** avec les détails et les étapes pour reproduire le
problème. Merci de ne pas ouvrir de ticket public pour un signalement de sécurité. Vous recevez un
accusé de réception sous quelques jours.

Ce qui compte comme vulnérabilité : tout ce qui permet à un autre programme de faire exécuter à l’assistant ce que vous
n’avez pas demandé, permet à MacSpace de supprimer ou de modifier ce qu’il ne devrait pas, ou
permet d’installer une mise à jour sans la signature de la version.

## Versions prises en charge

Les correctifs de sécurité ne sont publiés que dans la dernière version. Passez toujours à la
version la plus récente, depuis
[Releases](https://github.com/1architect/macspace-releases/releases/latest), avec **Rechercher des
mises à jour…**, ou avec `brew upgrade --cask macspace` (ajoutez `--greedy` si Homebrew l’ignore,
car MacSpace se met à jour lui-même).

## Ce que fait MacSpace sur votre Mac

### Réseau

MacSpace établit des connexions réseau dans un seul but : les mises à jour. Quand vous choisissez
**Rechercher des mises à jour…** (ou **Vérifier maintenant** dans Réglages) et, si vous avez activé
**Rechercher les mises à jour automatiquement**, environ une fois par jour tant qu’il est ouvert,
il lit le flux de mises à jour hébergé avec les versions sur GitHub (`appcast.xml`). Si vous
acceptez une mise à jour, il télécharge la nouvelle version depuis GitHub Releases. Rien n’est
envoyé à votre sujet, et le profil système facultatif de Sparkle n’est pas activé.

Il n’y a ni analyse d’usage, ni télémétrie, ni rapport de plantage. Les détails se trouvent dans la
[Politique de confidentialité](PRIVACY.fr.md).

### Où sont stockées vos données

Tout reste sur votre Mac. Les fichiers de MacSpace se trouvent dans
`~/Library/Application Support/MacSpace/`, `~/Library/Logs/MacSpace/`, le fichier de préférences
`~/Library/Preferences/com.macspace.app.plist` et, pour ce que l’assistant écrit,
`/Library/Application Support/MacSpace/`. La [Politique de confidentialité](PRIVACY.fr.md) liste
chaque fichier. Rien n’est envoyé nulle part.

### Ce que MacSpace supprime

| Quoi | Où | Effectué par |
|---|---|---|
| Caches des apps fermées | Le dossier de cache système de chaque utilisateur (`/var/folders/…/C`), sauf ceux d’Apple. Les dossiers `Cache`, `Code Cache`, `GPUCache`, `DawnCache`, `DawnGraphiteCache`, `DawnWebGPUCache`, `GrShaderCache`, `ShaderCache` et `CachedData` dans un profil Chromium ou Electron de `~/Library/Application Support`. | L’app, avec vos droits |
| Rapports de diagnostic et de plantage de plus de 7 jours | `/Library/Logs/DiagnosticReports` et `~/Library/Logs/DiagnosticReports`. Un fichier que vous n’avez pas le droit de supprimer est ignoré. | L’app, avec vos droits |
| Ressources système inutilisées, modèles Apple Intelligence libérés, fichiers que les apps ont marqués comme purgeables | Le service de purge propre à macOS (CacheDelete). MacSpace le sollicite dans un processus enfant de courte durée, si bien qu’une défaillance à ce niveau ne peut pas faire tomber l’app. | macOS |
| Copies locales de fichiers du cloud | Un dossier cloud à la fois (`~/Library/CloudStorage/…` ou iCloud Drive). Seulement les fichiers déjà envoyés et sans conflit. Les fichiers restent dans le cloud. | L’app, avec vos droits |
| Historique des versions des documents | `/System/Volumes/Data/.DocumentRevisions-V100` | L’assistant |
| Fichiers restants de mise à jour de macOS | `/System/Volumes/Data/macOS Install Data`, seulement s’il est plus ancien que le système installé. Le dossier `Locked Files` reste en place. | L’assistant |

Rien ne va dans la Corbeille. Les caches, les ressources système et les fichiers purgeables sont
recréés ou retéléchargés au besoin, et les copies cloud sont retéléchargées quand vous ouvrez le
fichier. Les rapports, l’historique des versions et les restes de mises à jour ne reviennent pas.
Chacune de ces actions demande d’abord confirmation, sauf le bouton **Libérer** des caches d’une
seule app.

### Ce que MacSpace modifie (Debloat)

Chaque modification est d’abord inscrite dans un journal, de sorte qu’elle peut être annulée avec
**Tout activer** ou en réactivant la fonction.

| Interrupteur | Ce qui change | Effectué par |
|---|---|---|
| Publicités personnalisées | `com.apple.AdLib`, clé `allowApplePersonalizedAdvertising` | L’app, avec vos droits |
| Améliorer Siri et Dictée | `com.apple.assistant.support`, clé `Siri Data Sharing Opt-In Status` | L’app, avec vos droits |
| Fenêtre de rapport de plantage | Une surcharge launchd pour `com.apple.DiagnosticsReporter` et `com.apple.ReportGPURestart` | L’app, avec vos droits |
| Partager l’analyse avec Apple (versions finales de macOS) | `/Library/Application Support/CrashReporter/DiagnosticMessagesHistory.plist`, clés `AutoSubmit` et `ThirdPartyDataSubmit` | L’assistant |
| Siri AI, Intelligence visuelle, Indexation pour la recherche générative | Surcharges d’indicateurs de fonctionnalité dans `/Library/Preferences/FeatureFlags/Domain/` | L’assistant |
| Suivi des blocages (tailspin) | `tailspin disable`, et `tailspin enable` pour l’annuler | L’assistant |
| Les règles (six ; sept sur une version bêta de macOS) | Un profil de configuration, `com.macspace.policies` (voir ci-dessous) | Vous l’approuvez dans Réglages Système |

Ces modifications restent en place si vous supprimez l’app sans les avoir réactivées.

### Apple Intelligence

L’interrupteur **Apple Intelligence** modifie la clé `Session Language` de
`com.apple.assistant.backedup`, qui correspond à la langue de Siri. Une fois désactivé, Siri reçoit
une langue différente de celle du système, et votre voix de Siri (`Output Voice`) reste inchangée.
MacSpace enregistre les deux dans
`~/Library/Application Support/MacSpace/ai-guard-saved-siri-settings.json` et les rétablit quand
vous réactivez Apple Intelligence, ou si la modification ne prend pas effet. Si macOS garde les
modèles après la désactivation, MacSpace peut régler la langue sur celle du système, puis revenir à
la précédente, ce qui prend environ une minute, pour que macOS les libère. Avec la synchronisation
iCloud de Siri activée, ces modifications atteignent aussi vos autres appareils utilisant le même
compte Apple. MacSpace ne peut pas désactiver cette synchronisation. Il vous indique où le faire.

### Autorisations

macOS gère chaque demande : MacSpace ne voit donc jamais votre mot de passe.

| Autorisation | Où | À quoi MacSpace l’utilise |
|---|---|---|
| Accès complet au disque | Réglages Système > Confidentialité et sécurité | Mesurer les dossiers que macOS protège et lire l’état d’Apple Intelligence |
| Assistant privilégié | Réglages Système > Général > Ouverture et extensions | Les opérations ci-dessous |
| Profil de configuration | Réglages Système > Général > Gestion de l’appareil | Seulement quand vous désactivez une règle Debloat |
| Notifications | macOS le demande | Vous dire que quelque chose est terminé |

### L’assistant privilégié

L’assistant est un démon de lancement, `com.macspace.helper`, enregistré auprès de macOS depuis
l’app. launchd le démarre quand MacSpace lui demande quelque chose. Il s’exécute en tant que root,
et n’accepte une connexion que d’un programme qui satisfait à cette exigence de signature de code,
que macOS vérifie :

```
anchor apple generic and (identifier "com.macspace.app" or identifier "com.macspace.cli")
and certificate leaf[subject.OU] = "<the developer's team ID>"
```

Il refuse de démarrer sans exigence. Il n’exécute que des opérations nommées, intégrées à son code.
Un appelant ne peut pas lui envoyer de commandes. Quand l’app est remplacée par une mise à jour,
l’assistant s’en aperçoit et s’efface pour que le nouveau démarre.

| Opération | Ce qu’elle fait | Limites |
|---|---|---|
| `systemdata.measure` | Tailles de dossiers | Lecture seule. Seulement sous `/private/var`, `/private/tmp`, `/Library`, `/System/Library`, la racine du volume Data et `/opt`, jamais un dossier de départ. Des tailles, jamais des contenus. |
| `systemdata.versions.delete` | Supprime l’historique des versions des documents | Arrête d’abord `revisiond`, ou le met en pause si macOS refuse. Supprime le contenu du stockage, pas le dossier, puis redémarre `revisiond`. S’il ne peut pas l’arrêter, il ne supprime rien. |
| `systemdata.staged-update.delete` | Supprime les fichiers de mise à jour restants | Seulement si le dossier est plus ancien que le système installé. Conserve `Locked Files`. |
| `debloat.status`, `.apply`, `.revert` | Lit, désactive et réactive des éléments Debloat | Seulement des identifiants de contrôle, issus du catalogue intégré. Rien d’autre. |
| `debloat.removeProfile` | Supprime un profil MacSpace | Seulement les identifiants `com.macspace.policies` et `com.macspace.policies.…`. Tout autre profil est refusé. |
| `siri.orphan-subscriptions.plan`, `.execute` | Trouve et supprime les abonnements Apple Intelligence de comptes qui n’existent plus | Sauvegarde d’abord la base de données dans `/Library/Application Support/MacSpace/backups/`, la modifie en une seule transaction, ne touche que les lignes qui ne correspondent à aucun compte local, et refuse si la liste des comptes semble erronée. L’app n’a pas encore de bouton pour cela. |
| `helper.ping` | Répond, pour que l’app sache que l’assistant est actif | Aucune |

L’outil en ligne de commande de l’app, `MacSpaceCli`, situé dans le paquet de l’app, peut aussi
dialoguer avec l’assistant. Il est signé par la même équipe.

### Le profil de configuration

Les règles de Debloat sont des réglages que seul un profil de configuration peut imposer. MacSpace
construit un seul profil, `com.macspace.policies` (affiché sous le nom **MacSpace: policies**,
organisation « MacSpace »), avec chaque règle que vous avez désactivée. Il ouvre le profil, et vous
l’approuvez dans Réglages Système > Général > Gestion de l’appareil. L’approuver remplace le
précédent. Il n’est pas marqué comme impossible à supprimer. Réactiver la dernière règle le
supprime, par l’intermédiaire de l’assistant, sans rien à approuver. Vous pouvez aussi le supprimer
vous-même dans Réglages Système.

### Signature du code et mises à jour

MacSpace est signé avec un Apple Developer ID, avec l’environnement d’exécution renforcé, et
notarisé par Apple. Le ticket de notarisation est agrafé à l’app, qui s’ouvre donc aussi hors
ligne. Les composants propres à Sparkle sont signés avec la même identité.

Les mises à jour sont aussi signées avec une clé EdDSA. Sa moitié publique est dans MacSpace
(`SUPublicEDKey`), et Sparkle y confronte chaque téléchargement avant d’installer. La moitié privée
de cette clé et l’identité de signature ne sont pas dans ce dépôt. Une copie de MacSpace compilée
sans la clé publique ne recherche jamais de mises à jour.

## Vérifier un téléchargement

Placez `MacSpace-x.y.z.dmg` et `MacSpace-x.y.z.dmg.sha256` dans un même dossier :

```bash
shasum -a 256 -c MacSpace-x.y.z.dmg.sha256
```

Puis, après avoir glissé MacSpace dans Applications :

```bash
codesign -dv --verbose=4 /Applications/MacSpace.app
codesign --verify --deep --strict --verbose=2 /Applications/MacSpace.app
spctl -a -vv /Applications/MacSpace.app
xcrun stapler validate /Applications/MacSpace.app
```

Vous devriez voir `Authority=Developer ID Application`, `TeamIdentifier=J45ZXS2ZF6`, l’indicateur
`runtime`, `Notarization Ticket=stapled`, et `spctl` doit indiquer `accepted` avec
`source=Notarized Developer ID`.

## Désinstaller complètement

Il n’y a pas de programme de désinstallation dans l’app. Les étapes complètes se trouvent dans le
[README](README.fr.md#désinstallation). En bref :

1. Dans **Debloat**, appuyez sur **Tout activer**. Cela supprime les surcharges et le profil qu’il a
   créés.
2. Si le profil **MacSpace: policies** figure encore dans Réglages Système > Général > Gestion de
   l’appareil, supprimez-le.
3. Quittez MacSpace. Désactivez-le sous Réglages Système > Général > Ouverture et extensions, ou
   exécutez `/Applications/MacSpace.app/Contents/MacOS/MacSpaceCli helper --unregister`.
4. Supprimez l’app : `brew uninstall --cask macspace`, ou glissez **MacSpace** vers la Corbeille.
5. Supprimez ses données et ses préférences :
   ```bash
   rm -rf ~/Library/Application\ Support/MacSpace ~/Library/Logs/MacSpace ~/Library/Caches/com.macspace.app
   defaults delete com.macspace.app
   sudo rm -rf /Library/Application\ Support/MacSpace
   ```
6. Retirez MacSpace de Réglages Système > Confidentialité et sécurité > Accès complet au disque.
