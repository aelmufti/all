# Session-notes — bridge-connect

> Démarrer la session suivante par : « lire les session-notes ».
> Notes courtes : état + décisions + prochaine étape. Le plan de fond vit dans
> `CADRAGE.md` (§8 = incréments), les invariants dans `CLAUDE.md`.

## 2026-09-22 (validation matériel) — ✅ FLUX BOUT-EN-BOUT VALIDÉ SUR MATÉRIEL

L'utilisateur confirme : **iPhone + Venu 2 OK, ça émet vers Pulse, la synchro fonctionne.**
Le flux complet est prouvé sur matériel réel : connexion → auto-download → `POST /api/ingest`
→ 2xx → archive montre. Le « à valider matériel » qui bloquait est **levé**. Les 2 bugs
matériel de la nuit (filtre `pull` + garde anti-course sur le slot) **tiennent**.

**Reste après ce jalon** : (a) commiter le delta `all` (rien n'est encore commité) ;
(b) observer la robustesse sur plusieurs sync (reprise fragment, hypothèse CRC, interleaving
ARCHIVE — corrects en théorie, pas encore éprouvés dans la durée) ; (c) vision long terme
= réimplémentation native iOS de Pulse.

## 2026-09-22 (soir) — download contenu + reprise, moteur de sync (code), endpoint Pulse, fix connexion, UI BT

### Livré cette session (tout revu Opus, builds/tests verts, RIEN commité, ZÉRO émission réseau)

1. **Couche transfert : download du CONTENU d'un fichier + reprise** (`GarminSession.swift`,
   nouveau `GFDI/FileTransferReassembler.swift`). Machine généralisée `DownloadTarget
   {.directory|.file}` + `downloadFile(entry)`. **Reprise** portée fidèlement de
   `garmin-bridge/GarminSession.answeredAFragmentOutOfStep`/`trackWhereTheTransferIs` (PAS
   du `FileTransferHandler` vendoré qui plante) : offset attendu→empile ; `<`/`>` attendu→
   ré-accuse notre offset courant (**jamais `TransferStatus.RESEND`** → la montre reprend
   seule) ; traînard après fin→accuse son propre offset+len. **HYPOTHÈSE non vérifiée
   matériel** : CRC invalide au bon offset→ré-accuse (le pont, lui, planterait). Octets
   écrits dans le Spool (`SpoolStore.recordAcquired`, nom canonique porté de
   `buildExportPath`, timestamp **UTC** — divergence assumée). Déclencheur **manuel**
   (tap) dans `BLEDiagnosticView`.
2. **Moteur de sync iOS (code seulement, jamais émis)** : `GarminSession.syncNewFiles()`
   (traversée récent→ancien, un fichier à la fois) + `Sync/SyncPlanner.swift` (diff pur vs
   journal Spool, `NEWEST_FIRST`) ; archivage différé `SetFileFlags(ARCHIVE)` (type 5008) ;
   `SpoolStore.markDelivered`/`markArchived` ; `Sync/PulseUploader.swift` (`URLSession`
   background — **`resume()` en commentaire, rien n'est émis**) ; `PulseConfig` (token en
   **Keychain**). Câblage UI/trigger/auto-sync **pas encore fait** (tâche restante).
3. **Endpoint serveur `POST /api/ingest`** dans **custom-connect** (`server/src/ingest/*`) :
   octet-stream brut (`express.raw` scopé, 8 Mo), `IngestTokenGuard` + `INGEST_TOKENS`,
   gating source `phone` (403), `X-Watch-Filename` requis, `X-Content-SHA256` optionnel,
   map `ingestBuffer`→200 (`imported`/`wellness`/`duplicate`/`skipped`) / 422 (`error`).
   **201 tests verts.** Contrat complet : `all/docs/pulse-ingest-contract.md`.
4. **Fix bug connexion fantôme** (`BLEManager.swift`, `allApp.swift`) : au relancement,
   l'app affichait « Connecté » sur un lien mort (CoreBluetooth restitue un `.connected`
   périmé). Désormais nouvel état `.reconnecting`, « Connecté » **seulement sur preuve d'un
   lien réel** (handshake GFDI dépassé `.idle`, ou `isNotifying` confirmé), revalidation au
   passage premier-plan (`scenePhase`), watchdog 10 s→reconnexion propre. Limite connue :
   chemin de repli non-Garmin boucle le watchdog (sans impact Venu 2).
5. **UI Bluetooth** : liste de scan (~30 périphériques) masquée dès `.connected`/`.reconnecting`.

## 2026-09-22 (nuit) — CÂBLAGE COMPLET : auto-sync à la connexion + upload réel Pulse ✅

Autorisation réseau **explicite donnée** par l'utilisateur (« Oui, émettre pour de vrai » +
« Tout auto à la connexion »). L'émission réseau réelle est désormais **active dans le code**.

### Livré (agent Sonnet pour l'iOS, revu Opus, BUILD+TEST verts 85 tests, installé device)

- **iOS — chaîne auto complète** : dès `.listed` (manifeste reçu), `GarminSession` appelle
  **automatiquement** `syncNewFiles()` (plus de sélection manuelle). Chaque fichier
  téléchargé → Spool (`recordAcquired`) → **upload réel Pulse** → sur 2xx :
  `markDelivered` + `archivePendingDeliveries` (SET_FILE_FLAG ARCHIVE). En début de sync,
  `uploadPendingAcquisitions()` **repousse tout ce qui est `acquired`-non-`delivered`**
  (les fichiers déjà tapotés en sessions précédentes partent enfin).
  - `PulseUploader.swift` : transport réel `URLSession(.default)` foreground,
    `task.resume()` **activé** ; `SpoolUploading`/`PulseSpoolUploader` relisent
    `PulseConfig` à chaque upload (token renseignable après connexion). Completions
    ramenées sur le main, `[weak self]`.
  - `BLEManager` : une `PulseSpoolUploader` partagée, injectée dans chaque `GarminSession`.
  - `BLEDiagnosticView` : section « Synchronisation » (état, compteur *X acquis · Y livrés*,
    bouton **Tout synchroniser** de secours) ; par fichier : ⏳ en cours / ☁️ livré (bleu) /
    ✓ acquis (vert). Section « Sync Pulse » : saisie du **token** (SecureField→Keychain) + URL.
- **Serveur custom-connect** : `PUT /api/sync/source` accepte **`phone`** ; front Réglages >
  Source propose « **iPhone (BLE)** ». Gating `/api/ingest` sur `phone` + `SyncSourceName`
  étaient déjà prêts. (Aucun test ne dépendait du changement.)

**Token d'ingestion copiable dans l'UI Pulse (2026-09-22, commité+poussé)** — custom-connect
`main` : `d60a55d` (endpoint `POST /api/ingest`) + `ff838ce` (token UI). Sélectionner « iPhone
(BLE) » dans Réglages > Source **affiche un token généré+persisté par le serveur**
(`settings.ingest_token`, `IngestTokenService`), copiable + régénérable — plus besoin d'éditer
`.env`. `IngestTokenGuard` accepte ce token **ET** les `INGEST_TOKENS` d'env (rétrocompat).
Endpoint `POST /api/sync/ingest-token/regenerate`. **Vérifié via Playwright** (login test/test,
sélection phone → token affiché, Copier/Régénérer OK), 206 tests serveur verts, `ng build` OK.
Déploiement serveur : `git pull && docker compose up -d`. Côté navigateur : **hard refresh**
requis après tout déeploiement (routes lazy sans handler d'erreur de chunk → un onglet ouvert
avant le build fige « le bouton ne réagit pas » ; fix = `Cmd+Shift+R`). Amélioration optionnelle
proposée non faite : handler global `ChunkLoadError` → `location.reload()` dans `app.config.ts`.

### À FAIRE côté utilisateur pour la 1re vraie sync (actions serveur — Claude n'y touche pas)

- Serveur Pulse lancé avec **`INGEST_TOKENS`** = le token saisi dans l'app.
- Pulse : Réglages > Source → **iPhone (BLE)** (sinon `/api/ingest` = 403).
- Dans l'app : onglet Pulse = saisir l'URL ; onglet BLE > Sync Pulse = saisir le token.

### BUG matériel corrigé (2026-09-22 nuit) : `downloadStatus=3` sur tous les fichiers

Sur device, la 1re vraie sync échouait : listing OK (« plein de fichiers ») mais chaque
download refusé par la montre avec `downloadStatus=3`, 0 acquis, ~5k notifications, « des
plombes ». **Cause** : on téléchargeait TOUS les types listés, y compris les non-`pull`
(SETTINGS, SPORTS, DEVICE, GOALS…) que la Venu 2 refuse de servir. Le pont ne tire que les
types `pull=true` (`FileType.java`). **Fix** : porté le flag `pull` (~29 (type,subtype)) dans
`GarminFileType.pullableKeys`/`isPullable` + `GarminDirectoryEntry.isPullable` ; `SyncPlanner.
filesDue` ne met en file que les `pull`. Listing UI inchangé (affiche tout). BUILD+TEST verts,
installé device. **À confirmer matériel** : si des fichiers `pull` (Monitor/Sleep/Activity)
échouent ENCORE en `downloadStatus=3` → souci séquencement/slot de transfert, capturer les logs
Console.app (subsystem `CleanYourRoom.all`). `downloadStatus` enum (pont) : OK=0, INDEX_UNKNOWN=1,
INDEX_NOT_READABLE=2, NO_SPACE_LEFT=3, INVALID=4, NOT_READY=5, CRC_INCORRECT=6.

### BUG matériel #2 (2026-09-22 nuit) : course sur le slot de transfert → `.failed` après listing

Après le filtre `pull`, ça échouait encore : listing OK (fichiers affichés) puis « Échec :
downloadStatus=3 » ~1 s après. **Déduction** : dans notre code, `state=.failed` ne peut venir
QUE d'un échec de download **directory** (`failCurrentDownload` ne met `.failed` que pour
`.directory`). Le 1er listing réussit ; un 2e `DOWNLOAD_REQUEST(0)` échoue. Seul déclencheur
d'un re-listing = `handleFilterStatus` (la montre re-liste d'elle-même : SYNCHRONIZATION →
FILTER). Or `requestDirectoryListing()` **n'avait aucun garde** : appelé pendant qu'un download
de fichier occupait le slot unique, il écrasait `downloadTarget` par `.directory` → 2
`DOWNLOAD_REQUEST` concurrents → la montre en refuse un (`downloadStatus=3`) → `.failed`. Le pont
ne lance jamais un transfert tant qu'`isDownloading()`. **Fix** (`GarminSession.swift`) : garde
sur `requestDirectoryListing()` (ne jamais écraser un transfert en cours) + `pendingDirectoryRelisting`
qui diffère la re-list et la rejoue quand le slot se libère (`advanceDownloadQueue`, file épuisée).
BUILD+TEST verts, installé device. À confirmer matériel.

### À valider sur matériel

- Le flux bout-en-bout (connexion → auto-download → POST Pulse → 2xx → archive montre).
- Repris de la session précédente : reprise de fragment + hypothèse CRC ; watchdog 10 s.
- Interleaving SET_FILE_FLAG(ARCHIVE) pendant un download suivant (fidèle au pont, non mesuré).

### Installé sur device

Build device + `devicectl install` sur « iPhone de Ali » (00008130-000164C40261001C) —
contient **tout le câblage ci-dessus** (émission réseau réelle active). **Rien commité.**

## 2026-09-22 — JALON MAJEUR : listing GFDI V2 sur matériel réel ✅

### Ce qui marche maintenant (Venu 2 fw 19.05 + iPhone de Ali réel)

Le collecteur iOS **parle GFDI V2 à la Venu 2 et liste ses fichiers** (vus : fichiers
« Monitor »). Chaîne complète prouvée sur matériel : handshake → `DOWNLOAD_REQUEST`
index 0 → manifeste directory descendu/parsé → liste affichée. **Aucun contenu `.fit`
téléchargé** (frontière autorisée = listing/métadonnées seulement).

Séquence handshake qui passe : `closeAllServices` → `CLOSE_ALL_RESP` → register GFDI
(handle 1, non fiable) → `DEVICE_INFORMATION` (fw 19.05, Venu 2, maxPaquet 512) →
`CONFIGURATION` → `SYNC_READY` → `DOWNLOAD_REQUEST(0)` → `FILE_TRANSFER_DATA` réassemblé
→ `[GarminDirectoryEntry]` publié.

### Pivot décidé par l'utilisateur — le rédhibitoire tombe

- **BLE arrière-plan ABANDONNÉ.** L'utilisateur ne veut PAS de collecte en tâche de
  fond. Objectif = **premier plan** : « j'ouvre l'app → mes données sont là ». Donc le
  risque §1 du CADRAGE (stabilité BLE arrière-plan) n'est plus un gate.
- **Sync à l'ouverture** : à chaque lancement, DIFF (manifeste actuel − journal local
  `Spool/`, la montre réordonne → pas de curseur) → télécharger les **nouveaux** →
  pousser Pulse → sur 2xx, archiver montre. Parcours récent→ancien.

### Vision long terme (donnée par l'utilisateur ce jour)

À terme, **« All » (cette app) = réimplémentation native iOS de Pulse** (mêmes pages,
« mêmes prompts ») **+** le collecteur BLE. En parallèle, **Pulse (custom-connect) sera
réécrit** → les contrats bridge-connect↔Pulse ne sont plus figés (endpoint d'ingestion
à (re)définir librement).

### Code ajouté cette session (agent Sonnet, sur socle codec existant)

`all/all/GFDI/CommunicatorV2.swift` (transport ML V2 réel : discovery paire
0x2810/0x2820, closeAllServices, registration handles, canal GFDI),
`GarminSession.swift` (machine handshake + orchestration directory + accusés protobuf
codés en dur), `GarminByteIO.swift`, `GarminFileType.swift` (table FILETYPE + parseur
manifeste), `allTests/GarminProtocolTests.swift`. `BLEManager`/`BLEDiagnosticView`
câblés (bascule auto sur GFDI si service ML détecté, sinon repli générique incr. 1).
**MLR non porté** — justifié : garmin-bridge tourne `mlrEnabled=false` sur Venu 2.

### DEUX fixes trouvés via le matériel (essentiels)

1. **Signature** : `DEVELOPMENT_TEAM = NN424AMHS3` (le `4HX776MQV4` du nom de cert est
   l'ID perso, PAS le team ; team = champ OU du cert). **Persisté dans le pbxproj cette
   session** (configs Debug+Release de la target `all`). Build device :
   `xcodebuild -project all/all.xcodeproj -scheme all -destination 'id=00008130-000164C40261001C' -allowProvisioningUpdates build`
   Install : `xcrun devicectl device install app --device 00008130-000164C40261001C <...>/all.app`
2. **Écriture BLE sans réponse** : la Venu 2 **rejette** « avec réponse » sur la
   caractéristique d'émission ML (`Writing is not permitted`) bien qu'elle annonce
   Write+WriteWithoutResponse (0x0C). Corrigé dans `CommunicatorV2.preferredWriteType`
   → `.withoutResponse` privilégié. **C'était la cause du « listing en cours » infini**
   (nos écritures échouaient → DOWNLOAD_REQUEST jamais reçu → montre retransmet en
   boucle toutes les 5 s).

### Recettes matériel utiles

- **Bond BLE en limbo** (montre plus trouvée en scan) : oublier des DEUX côtés (app
  « Oublier l'appareil » + iOS Réglages>Bluetooth + montre Paramètres>Connectivité>
  Téléphone) puis power-cycle iPhone + montre. Sinon l'auto-reconnexion (keeper)
  entretient l'entre-deux.
- **Logs device** : `log` est shadowé par un alias → chemin complet. Nécessite root :
  `sudo /usr/bin/log collect --device-udid 00008130-000164C40261001C --last 12m --output /tmp/x.logarchive`
  puis `/usr/bin/log show /tmp/x.logarchive --predicate 'subsystem == "CleanYourRoom.all"' --info --debug --style compact`.

### Sécurité du pipeline (validée conceptuellement, rien émis)

BLE chiffré (bonding/passkey) → repos chiffré (Data Protection `completeUnlessOpen` sur
`Spool/`) → upload **HTTPS/TLS via Tailscale (WireGuard) + token dédié téléphone** ;
ATS iOS bloque le clair par défaut. **Endpoint futur Pulse = HTTPS+token uniquement, pas
de fallback HTTP.** Rien en clair de bout en bout.

### Prochaine étape

1. **Télécharger le CONTENU** d'un fichier → exige **autorisation explicite (données de
   santé)**. Compléter `DOWNLOAD_REQUEST`/`FILE_TRANSFER_DATA` + porter la reprise
   **`RESEND`** (non portée : un fragment en avance interrompt le transfert au lieu de
   demander une reprise).
2. **Pipeline sync à l'ouverture** : diff manifeste vs journal `Spool/` → download
   nouveaux → **push Pulse** (POST, 2xx=ack — **autorisation réseau requise avant**) →
   `SetFileFlags(ARCHIVE)` après ack.
3. **Définir l'endpoint d'ingestion** du futur Pulse (HTTPS+token, `.fit` brut, dédup
   par hash côté serveur ; ne pas parser le FIT sur le téléphone).

### Non fait volontairement

Aucun commit. Aucun upload réseau. Aucun contenu `.fit` lu. Le harnais « 5 métriques »
arrière-plan de l'incrément 1 subsiste dans le code mais n'est plus l'objectif (pivot
premier-plan).

## 2026-09-18

### État atteint — code vérifiable sans montre : bouclé et vert

- **Incrément 1 (code, pas la mesure)** : harnais BLE complet et branché dans l'app.
  - `all/all/BLE/BLEManager.swift` — singleton `CBCentralManager` avec restauration
    d'état (`willRestoreState`), scan/connect, discovery services+caractéristiques,
    abonnement à la **première caractéristique notifiable** trouvée (pas de GFDI),
    reconnexion **keeper** sans scan (`retrievePeripherals` + `connect`, sans timeout),
    garde `shouldReconnect` contre la reconnexion après oubli volontaire.
  - Les **5 métriques** du Go/No-Go sont journalisées via `os.Logger`
    (subsystem `CleanYourRoom.all`, category `ble`) : 1 durée de fenêtre, 2 notifs/fenêtre,
    3 latence retour-de-portée → reconnexion, 4 `willRestoreState` (survie terminaison),
    5 dernière notif → chute (supervision timeout effectif).
  - Câblage : `allApp.swift` → `@UIApplicationDelegateAdaptor(AppDelegate)` → touche
    `BLEManager.shared` **tôt** (requis pour la restauration). `ContentView` = TabView
    (WebView Pulse existante + onglet **Diagnostic BLE**, `BLEDiagnosticView`).
- **Incrément 2 (complet)** : transport GFDI mécanique, `all/all/GFDI/`.
  - `Cobs.swift`, `Crc16.swift`, `GfdiFrame.swift` (build/parse : longueur, type, CRC16),
    `GfdiTransport.swift` (réassemblage fragments → trames + acks génériques RESPONSE 5000,
    `GfdiStatus`), `CommunicatorVersion.swift` (fragments V1/V2, strip handle V2).
  - **30 tests verts** (`allTests`, framework `Testing`) : `CobsTests`, `Crc16Tests`,
    `GfdiFrameTests` (vecteurs dérivés du pont `GfdiFrames.java`), `GfdiTransportTests`.
  - Fidélité au pont **vérifiée** : `CommunicatorV1/V2.sendMessage` utilisent tous deux
    le cap `maxWriteSize - 1` (V1 sans handle, V2 avec handle préfixé) → le port Swift
    est correct. Pas de bug fragmentation.

### Fait notable de la session

- L'utilisateur avait un **build Xcode cassé** (fichiers pas dans la target `allTests`),
  qu'il a corrigé lui-même avant cette session. Après fix : **build + tests OK** au
  simulateur (`iPhone 16`, iOS 18.3.1, id `255FC575-…`). Commande de test :
  `xcodebuild test -project all/all.xcodeproj -scheme all -destination 'platform=iOS Simulator,id=255FC575-0DB9-4132-AE9C-87152158B4DE' -only-testing:allTests`
  (le simulateur `name=iPhone 16` sans `id`/`OS` ne matche pas → passer l'`id`).

### Décision de fin de session

- Le **front de code vérifiable sans matériel est atteint**. Tout ce qui suit dans
  l'ordre CADRAGE §8 est **verrouillé par le matériel** ; règle « ne pas sauter
  d'incrément » respectée → on **n'attaque pas** l'incrément 3 tant que le Go/No-Go
  n'est pas passé. (Option « prendre de l'avance sur l'incr. 3 » écartée ce jour.)

### Prochaine étape — exige le matériel (Venu 2 fw 19.05 + iPhone réel)

1. **Terminer l'incrément 1 = Go/No-Go du projet** : lancer l'app sur device réel,
   connecter la Venu 2, mettre le téléphone en poche, lire les 5 métriques dans
   Console.app (filtre subsystem `CleanYourRoom.all`). Le BLE arrière-plan **ne se
   mesure pas au simulateur**.
2. Selon le résultat (stabilité du lien arrière-plan = risque rédhibitoire §1),
   décider Go/No-Go, puis incrément 3 (poignée de main GFDI) sur matériel.

### Non fait volontairement

- Aucun commit (CLAUDE.md : committer seulement sur demande). Delta non commité :
  scaffold + BLE/ + GFDI/ + Spool/ + Pulse*/ + tests. `all/build/` est un artefact,
  à ne pas committer.
