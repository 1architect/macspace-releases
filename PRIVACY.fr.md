[English](PRIVACY.md) · [Português](PRIVACY.pt-BR.md) · [Español](PRIVACY.es.md) · **Français** · [Deutsch](PRIVACY.de.md)

# Politique de confidentialité — MacSpace

**Dernière mise à jour : 6 octobre 2026 · S’applique à MacSpace 1.0.0 et aux versions ultérieures**

MacSpace ne collecte, ne stocke et ne transmet aucune donnée d’usage. Il n’y a ni analyse d’usage,
ni télémétrie, ni rapport de plantage, ni publicité. MacSpace n’a pas de système de comptes : vous
ne créez donc jamais de profil et ne vous connectez jamais.

Ce document décrit précisément ce que MacSpace lit, où il le conserve, et le seul moment où il
utilise le réseau.

---

## Ce qui reste sur votre Mac

MacSpace mesure votre disque, lit quelques réglages système et écrit quelques petits fichiers sur
votre propre machine. Rien de tout cela ne quitte votre Mac.

| Données | Où elles sont stockées |
|---|---|
| Vos réglages : thème, choix de fenêtre, modules activés, options des modules, nettoyage automatique, choix de notifications, la dernière tuile affichée par chaque module, l’étape du premier lancement | Préférences macOS (`UserDefaults`) de MacSpace, `~/Library/Preferences/com.macspace.app.plist` |
| Réglages propres à Sparkle : recherche automatique des mises à jour ou non, et date de la dernière vérification | Le même fichier de préférences |
| Historique de nettoyage : quand, quel module, combien d’espace libéré, comment il a démarré, un résumé d’une ligne | `~/Library/Application Support/MacSpace/cleanup-history.json` |
| Espace que macOS a conservé alors que MacSpace lui avait demandé de le libérer | `~/Library/Application Support/MacSpace/purge-holdouts.json` |
| Journal Debloat : chaque réglage que MacSpace a modifié, sa valeur avant et après, le build de macOS, et la date | `~/Library/Application Support/MacSpace/debloat-journal.json` et, pour les modifications faites par l’assistant, `/Library/Application Support/MacSpace/debloat-journal.json` |
| Surveillance Debloat : les fonctions que macOS a réactivées, et quand (les 20 derniers événements) | `~/Library/Application Support/MacSpace/debloat-watch.json` |
| Le profil Debloat, tel qu’il est préparé pour votre approbation | `~/Library/Application Support/MacSpace/Profiles/MacSpace.mobileconfig` |
| Votre langue et votre voix de Siri, enregistrées pendant qu’Apple Intelligence est désactivé pour que MacSpace puisse les rétablir | `~/Library/Application Support/MacSpace/ai-guard-saved-siri-settings.json` |
| Surveillance d’Apple Intelligence (seulement si vous l’activez) : le dernier état observé, et un journal des changements | `~/Library/Application Support/MacSpace/ai-watch-state.json` et `~/Library/Logs/MacSpace/ai-watch.jsonl` |
| Une sauvegarde de la base de données d’abonnements de macOS, seulement si vous supprimez les abonnements Apple Intelligence restants de comptes supprimés | `/Library/Application Support/MacSpace/backups/` |
| Téléchargements de mises à jour | Dossier de cache de Sparkle, `~/Library/Caches/com.macspace.app/` |

Vous pouvez tout supprimer à tout moment. [README.fr.md](README.fr.md#désinstallation) donne les
commandes. Supprimer ces fichiers fait oublier à MacSpace son historique et ses réglages. Si vous
supprimez les journaux Debloat alors que des fonctions Debloat sont désactivées, MacSpace ne peut
plus rétablir les valeurs d’origine qu’il avait enregistrées, et utilise à la place les valeurs par
défaut de macOS. Appuyez d’abord sur **Tout activer**.

### Ce que MacSpace lit

MacSpace lit ces éléments sur votre Mac pour faire son travail. Il n’en envoie aucun nulle part.

- **Les noms et les tailles des fichiers et des dossiers**, sur tout le disque une fois l’accès
  complet au disque accordé. Il ne lit pas le contenu de vos documents, photos, e-mails ou
  messages. Il mesure l’espace qu’ils occupent.
- **Quelques fichiers système :** le fichier d’éligibilité à Apple Intelligence, la base de données
  d’abonnements aux ressources de macOS, la liste des profils de configuration installés, et la
  base de données du compte Apple (en lecture seule, pour savoir si la synchronisation iCloud de
  Siri est activée).
- **Les noms des comptes utilisateur de ce Mac**, pour indiquer quel compte garde Apple
  Intelligence activé.
- **L’état de macOS :** sa version et son numéro de build, l’état de la protection de l’intégrité
  du système, l’inscription ou non du Mac à la gestion des appareils, les noms des processus en
  cours (pour vérifier qu’un interrupteur Debloat a pris effet), et quelques lignes du journal
  système qui consignent les décisions d’analyse de macOS (pour vérifier que l’interrupteur
  d’analyse a fonctionné).

---

## Quand MacSpace utilise le réseau

MacSpace n’utilise le réseau que dans un but : les **mises à jour**. Il n’a ni analyse d’usage, ni
connexion à un compte, ni aucune autre connexion.

### Quand il recherche des mises à jour

MacSpace utilise [Sparkle](https://sparkle-project.org) pour trouver et installer les mises à
jour. Il contacte le réseau dans ces cas :

- quand vous choisissez **Rechercher des mises à jour…** dans le menu MacSpace, ou **Vérifier
  maintenant** dans Réglages ;
- environ une fois par jour tant que MacSpace est ouvert, si la recherche automatique est activée.

La recherche automatique est désactivée tant que vous n’activez pas **Rechercher les mises à jour
automatiquement** dans Réglages, ou que vous ne répondez pas oui à la question que Sparkle pose une
seule fois, à partir du deuxième lancement. Jusque-là, MacSpace ne recherche rien de lui-même. Une
version que vous compilez depuis les sources n’a pas de clé de mise à jour et ne recherche jamais
rien.

Une recherche demande un seul fichier à GitHub :

```
https://github.com/1architect/macspace-releases/releases/latest/download/appcast.xml
```

Comme pour toute requête web, GitHub peut voir votre adresse IP. La requête contient aussi le nom
et la version de MacSpace et la version de Sparkle, dans l’en-tête `User-Agent` habituel. MacSpace
n’envoie ni profil système, ni information sur le matériel, ni identifiant d’aucune sorte. Le
profil système facultatif de Sparkle n’est pas activé. Le traitement de cette requête par GitHub
est couvert par la
[Déclaration de confidentialité de GitHub](https://docs.github.com/site-policy/privacy-policies/github-privacy-statement).

Si vous acceptez une mise à jour, Sparkle la télécharge depuis GitHub Releases. Chaque mise à jour
est signée. Sparkle vérifie la signature avec la clé publique contenue dans MacSpace avant
d’installer quoi que ce soit.

### Ce qui ne relève pas de MacSpace

Si vous réactivez Apple Intelligence, macOS (et non MacSpace) peut télécharger ses modèles. Quand
vous ouvrez une app téléchargée, macOS peut la faire vérifier par Apple. Ce sont des connexions
propres à macOS.

---

## Ce que MacSpace ne fait jamais

- Il n’envoie jamais nulle part votre liste de fichiers, vos chiffres de disque, vos réglages,
  votre historique de nettoyage ou les noms de vos comptes.
- Il ne lit jamais le contenu de vos documents, photos, e-mails ou messages.
- Il ne vous demande jamais de créer un compte ni de vous connecter.
- Il ne signale jamais de plantages ni d’usage, ni au développeur ni à personne d’autre.

### À propos des autorisations et de l’assistant

MacSpace demande quelques approbations, chacune dans la fenêtre propre à macOS ou dans Réglages
Système, si bien qu’il ne voit jamais votre mot de passe :

- **Accès complet au disque**, pour mesurer tout le disque et lire l’état d’Apple Intelligence.
- **Un assistant privilégié**, un démon de lancement (`com.macspace.helper`) qui effectue les
  quelques tâches qui demandent un administrateur. Il n’accepte que les clients signés par la même
  équipe de développement que MacSpace et n’exécute que les opérations intégrées à son code.
- **Un profil de configuration**, seulement si vous désactivez une règle Debloat.
- **Notifications**, pour vous dire quand quelque chose est terminé.

[SECURITY.fr.md](SECURITY.fr.md) liste ce que l’assistant et le profil peuvent faire.

---

## Enfants

MacSpace est un utilitaire pour macOS et ne s’adresse pas aux enfants. Il ne collecte aucune
information personnelle, auprès de personne, quel que soit l’âge.

## Modifications de cette politique

Si le comportement de MacSpace change, ce document change avec lui, et la date en haut aussi.
L’historique de ce fichier est public dans ce dépôt : vous pouvez voir exactement ce qui a changé
et quand.

## Contact

Questions sur la confidentialité, ou sur tout point de ce document :

**dev@giomantovani.com.br**
