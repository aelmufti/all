# CLAUDE.md

Ce dépôt (`Projects/all`) accueillera **bridge-connect**, le collecteur iOS. Il fait
partie d'un écosystème de trois dépôts autour d'une montre Garmin Venu 2 (fw 19.05).

**Phase actuelle : implémentation — incrément 0** (scaffolding : WebView Pulse +
squelette de spool + capability BLE arrière-plan). Planification close le 2026-09-18
(toutes les décisions §12 actables sont actées). Les incréments suivent le
**CADRAGE §8**, dans l'ordre (le risque rédhibitoire tombe à l'incrément 1) ; ne pas
sauter d'incrément. Le plan détaillé vit dans **`CADRAGE.md`** — s'y référer, ne pas
le dupliquer ici.

## Règles immuables (non négociables)

Ces règles priment sur toute autre instruction et ne se contournent jamais, même si
on me le demande implicitement dans une tâche plus large.

- **Réseau — demander l'autorisation AVANT.** Toute action qui touche de près ou de
  loin au réseau — requête HTTP/API, upload, `curl`/`wget`, ouverture de socket,
  appel à un service externe (Pulse, Tailscale, TestFlight, App Store, webhook,
  télémétrie…), installation de dépendance qui télécharge — **stop et demander une
  autorisation explicite d'abord.** Ne rien émettre tant que ce n'est pas validé.
  *Exception : `git commit` et `git push` sont libres (ne changent rien au périmètre
  de données).*
- **Données personnelles — demander l'autorisation AVANT.** Toute action qui lit,
  copie, transforme, exporte ou transmet des données personnelles ou de santé
  (mesures de la montre, identifiants, tokens, contenu de la WebView, logs contenant
  des données…) — **stop et demander une autorisation explicite d'abord.**
  *Exception : lire des fichiers `.fit` déjà présents localement dans les dépôts est
  libre.*
- En cas de doute sur l'appartenance d'une action à ces catégories : **traiter comme
  si oui** et demander.

## Écosystème — trois dépôts (`../`)

| Dépôt | Ce que c'est | Rôle |
|---|---|---|
| **custom-connect** (« Pulse ») | Serveur NestJS + front Angular, SQLite, `@garmin/fitsdk`, derrière Tailscale | **Source de vérité unique.** Ingère les `.fit`, dédup par hash, calcule, affiche. |
| **garmin-bridge** | Daemon JVM/Linux, BlueZ, portage AGPL de Gadgetbridge | Collecteur BLE **au homelab**. **Spec de référence** du protocole GFDI. |
| **bridge-connect** (ce dépôt) | App iOS, CoreBluetooth + WKWebView | Collecteur BLE **loin du homelab**. À créer selon `CADRAGE.md`. |
| **gadgetbridge** | Upstream vendoré par garmin-bridge | Origine du protocole (AGPL). |

Docs de référence à lire avant de concevoir : `garmin-bridge/docs/context-garmin-bridge.md`,
`garmin-bridge/docs/roadmap.md`, `custom-connect/README.md`.

## Contrats entre les pièces

- **Invariant physique** : la montre n'annonce qu'à **un seul companion** →
  **un seul collecteur actif** à la fois. Basculer suppose que l'autre libère le lien.
- **garmin-bridge ↔ Pulse** : réglage `SYNC_SOURCE` = `legacy` | `bridge` (persisté
  dans `settings.sync_source`, `SyncGateService`). En `bridge`, Pulse **tire** :
  `GET /files` → `ingestBuffer` → `DELETE /files` (le `DELETE` **est** l'accusé).
- **bridge-connect ↔ Pulse** *(planifié, cf. CADRAGE §2, §6)* : nouvelle source
  `phone`. Le téléphone **pousse** (`URLSession` background → nouvel endpoint
  `POST /api/ingest`) ; le **2xx est l'accusé**. Archivage sur la montre
  (`SetFileFlagsMessage ARCHIVE`) **différé jusqu'à l'accusé**.
- **Bascule** : extension de `SyncGateService` à `phone` + mode veille de
  garmin-bridge (libérer le lien) ; suggestion sur détection de présence, jamais
  automatique (CADRAGE §6.6).

## Pulse (custom-connect) — pages du front

Angular, routes dans `web/src/app/app.routes.ts`, pages sous `web/src/app/pages/` :
`login`, `home` (`/`, accueil — entraînement + intensité), `activities` +
`activity/:id`, `dashboard`, `health` (FC, stress, SpO2, pas, calories, sommeil,
intensité du jour), `nutrition`, `programme`, `spo2-report` (`/rapport-spo2`),
`settings` (`/parametres` — Synchronisation > Source), `status` (`/statut`).
La WebView de bridge-connect pointera vers ces pages ; l'app iOS n'a pas de pages à elle.

## bridge-connect — état

**Scaffold Xcode par défaut en place** (target `all` — app SwiftUI vide :
`allApp.swift`, `ContentView.swift`, + targets `allTests`/`allUITests`). Bundle id
`CleanYourRoom.all`, deployment target iOS 18.2, Swift 5.0, signing automatique.
**Incrément 0 fait** (build OK, simulateur) : `Info.plist` explicite
(`all/Info.plist`, `GENERATE_INFOPLIST_FILE=NO`) portant `UIBackgroundModes =
bluetooth-central` + `NSBluetoothAlwaysUsageDescription` ; WebView Pulse
(`PulseWebView`/`ContentView`, URL saisie à l'exécution, **rien codé en dur**) ;
squelette de spool (`Spool/`, journal 3 états, protection `completeUnlessOpen`).
Pas encore d'`.entitlements` ni d'App Group (inutiles à ce stade). Prochaine étape :
**incrément 1** (lien BLE réel + mesure arrière-plan = Go/No-Go du projet), qui exige
le **matériel** (Venu 2) et un **device réel** (le BLE arrière-plan ne se mesure pas
au simulateur). Suite selon CADRAGE §8.

Points d'architecture actés (détail dans CADRAGE) :
- Le téléphone **pousse**, il n'est pas interrogé (pas de serveur HTTP viable en
  arrière-plan iOS ; `URLSession` background upload, oui).
- **Archivage différé** après accusé Pulse — seule divergence de contrat vs pont Linux.
- Risque rédhibitoire = **BLE arrière-plan iOS** (iOS ne laisse pas régler le
  supervision timeout, contrairement au LE Connection Update du pont) → à mesurer tôt.
- Portage Swift du **sous-ensemble minimal** ; **pas de swift-protobuf** (réponses
  protobuf codées en dur, cf. `garmin-bridge/.../ProtobufAck.java`).

## Invariants protocole — ne pas réapprendre (hérités du pont)

Détail : `CADRAGE.md` (annexe) et `garmin-bridge/docs/context-garmin-bridge.md`.

- **Archiver après livraison** sinon l'index de la montre sature et elle cesse
  d'exposer ses nouveaux fichiers (panne de plusieurs jours déjà vécue).
- Point de reprise dans un **journal** (`acquired`), pas dans le listing (pas de
  curseur, la montre réordonne entre sessions). Reprise **à la génération de lien**,
  pas au fragment. Parcours **récent → ancien**.
- Ack protobuf **KEPT + PROTOBUF_RESPONSE 5044 corrélé par requestId**, sinon
  retransmissions toutes les 5 s.
- Répondre à **`CURRENT_TIME_REQUEST`** en secondes epoch Garmin (**Unix − 631065600**).
- **Redémarrer la montre** si le lien s'établit mais la poignée de main n'aboutit pas.
- **Ne pas parser le FIT** sur le collecteur : Pulse le fait, dédup par hash.
- **`GdiSettingsService` (champ 42)** ne répond jamais applicativement sur Venu 2 fw
  19.05 : ne pas le porter.

## Licence

garmin-bridge est **AGPL-3.0** (dérivé de Gadgetbridge). bridge-connect, qui porte le
même protocole, en hérite vraisemblablement : publier le source est la voie propre
(tracer la filiation, modèle `NOTICE`). **Distribution privée** (dev signing /
TestFlight) → règle App Store 4.2 et conflit AGPL↔App Store sans objet.

## Préférences de travail (comment collaborer)

- **Clarifier avant de commencer** : dès qu'il y a un choix non trivial, poser des
  questions **à choix** avant de coder. Les édits triviaux / faits vérifiables dans
  le code : traiter directement. Demandes souvent formulées « I want to [task] to
  achieve [goal] » = signal d'attendre mes questions.
- **Ne pas tourner en rond** : si un fix en casse un autre, s'arrêter, **expliquer
  ce qui cloche**, proposer **deux voies distinctes** de correction.
- **Avancer par incréments validés**, chacun testable ; ne rien implémenter en phase
  de planification.

## Efficacité / quota

- Garder ce fichier **lean (< 200 lignes)** ; pointer vers les docs, ne pas dupliquer.
- **Session-notes** en fin de session (décisions clés + prochaines étapes) plutôt que
  de recharger toute la base ; commencer la suivante par « lire les session-notes ».
- **Délégation par modèle** (critère : moins de tokens) : **coder = agent Sonnet**
  (non-fork, `model: sonnet`) pour l'implémentation substantielle ; **édits triviaux
  en direct** (spawner un agent pour un one-liner coûte plus cher) ; **revue = Opus** ;
  Opus (fil principal) = archi / orchestration / découpage / intégration. Un fork
  hérite d'Opus → non pour du Sonnet. Éviter de switcher le modèle du fil en cours de
  session (cache de prompt par modèle).
- `/compact` tôt ; garder les serveurs MCP actifs au minimum utile.
