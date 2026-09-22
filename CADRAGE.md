# Cadrage — collecteur iOS (bridge-connect)

Document de cadrage, pas de code. Il tranche ce qui peut l'être depuis la lecture
du code existant, et signale comme telle chaque question qui ne se règle que sur
matériel. Le code viendra ensuite, par incréments validés.

Distribution visée : **privée** (dev signing personnel / TestFlight), mono-utilisateur,
derrière Tailscale. Ce choix est acté et il retire deux sujets du cadrage : la
règle App Store 4.2 (habillage web) et le conflit réputé AGPL ↔ conditions App
Store. Ils sont traités en une ligne chacun, plus bas, puis écartés.

---

## 0. Les trois pièces, et le rôle de la nouvelle

| Pièce | Ce que c'est | Rôle |
|---|---|---|
| **custom-connect** (« Pulse ») | Serveur NestJS/Angular, SQLite, `@garmin/fitsdk`, derrière Tailscale | **Source de vérité unique.** Ingère les `.fit`, dédup par hash, calcule, affiche. Ne change pas de rôle. |
| **garmin-bridge** | Daemon JVM/Linux, BlueZ, portage AGPL de Gadgetbridge | Collecteur BLE au homelab. **Spécification de référence** du protocole. Reste en service quand on est au homelab. |
| **bridge-connect** (à créer) | App iOS, CoreBluetooth + WKWebView | Collecteur BLE **quand on est loin du homelab**. Récupère les `.fit`, les livre à Pulse, n'ingère rien, n'affiche rien de propre. |

La règle physique qui gouverne tout : **la Venu 2 n'annonce pas tant qu'elle est
liée à un companion**. Un seul collecteur actif à la fois. Passer du Linux au
téléphone suppose que le Linux libère le lien, et réciproquement (§6).

Ce que l'app iOS **fait** : lien BLE, listing, download, spool local, livraison à
Pulse, archivage sur la montre **après** confirmation de Pulse, réponses
protocolaires que la montre exige (heure, acks protobuf), et une WebView vers
Pulse pour la consultation.

Ce que l'app iOS **ne fait pas** : parser du FIT, stocker de la santé structurée,
dédupliquer, afficher des données propres. Comme le pont Linux : elle transporte
des octets.

---

## 1. Verdict de faisabilité — franc

**C'est faisable, mais le maintien d'un lien BLE fiable en arrière-plan sur iOS
est le risque qui peut tout faire capoter, et il ne se lève que sur matériel.**

Deux faits, mesurés dans garmin-bridge, se combinent mal avec iOS :

1. **Le lien est fragile à cette portée.** RSSI −55 (contact) à −82 (3 m, à
   travers le corps), déconnexions au-delà. La montre émet ~30 dB plus faiblement
   qu'un téléphone.

2. **Le pont Linux ne tient ce lien que parce qu'il élargit le supervision
   timeout** de 4000 ms (imposé par la PPCP de la montre) à 10000 ms, par une
   commande **HCI LE Connection Update** émise par le central. **iOS n'expose
   aucune API équivalente.** CoreBluetooth ne laisse pas choisir l'intervalle de
   connexion ni le supervision timeout ; iOS négocie ses propres paramètres et
   accepte ou refuse la *Connection Parameter Update Request* du périphérique
   selon ses propres règles (Accessory Design Guidelines d'Apple). La seule
   mitigation qui rendait le lien tenable au homelab **n'est pas portable**.

Conclusion honnête : sur iOS on hérite du problème de fragilité **sans l'outil qui
l'a résolu**. Ça ne condamne pas le projet — le modèle de reprise du pont (reprise
à la génération de lien, jamais au fragment ; point de reprise dans un journal, pas
dans le listing) est précisément ce qui permet de vivre avec des liens courts qui
retombent. Mais cela veut dire que **la viabilité réelle est une mesure, pas une
déduction** : combien de fichiers passent par fenêtre de connexion en arrière-plan,
à portée réaliste, avant qu'iOS suspende l'app ou que le lien tombe. Si la réponse
est « zéro ou un », le projet n'a pas d'usage pratique en arrière-plan et se replie
sur un mode **premier-plan uniquement** (app ouverte, écran allumé, montre proche),
qui reste utile mais change l'ergonomie.

Le reste du cadrage est construit pour que cette mesure arrive **le plus tôt
possible** (incrément 1), avant tout investissement dans le portage complet.

---

## 2. Architecture cible

### 2.1 Décision centrale : le téléphone **pousse**, il n'est pas interrogé

Le mode `bridge` de Pulse **tire** aujourd'hui les fichiers du collecteur :
`POST /sync`, sonde `/sync/status`, `GET /files`, `ingestBuffer`, `DELETE /files`.
Ça marche parce que le pont Linux est un serveur HTTP toujours joignable sur le
tailnet.

**Un téléphone iOS ne peut pas être ce serveur.** Une app suspendue ne reçoit pas
de connexions entrantes ; un socket d'écoute en arrière-plan ne réveille pas l'app.
Compter sur Pulse pour joindre le téléphone quand il est en poche est un non-départ.

Donc on inverse : **le téléphone pousse vers Pulse.** Et l'outil qui rend ça
robuste existe et est fait pour ça — `URLSession` en configuration **background** :
une tâche d'upload continue hors-process, survit à la suspension **et à la
terminaison** de l'app, et relance l'app à la complétion. C'est le pendant iOS du
« ça part tout seul quand il y a du réseau ».

Conséquence côté Pulse : un **nouvel endpoint d'ingestion push**, authentifié,
qui reçoit un `.fit` brut et répond 2xx = accusé de réception. Il réutilise
`IngestService.ingestBuffer` (déjà public, déjà utilisé par le web upload et par
`bridge-sync`). C'est un ajout mince, symétrique de l'upload déjà offert par l'UI.

### 2.2 La seule divergence de contrat avec le pont Linux : l'archivage différé

Le brief l'impose et le code le rend gratuit.

- **Pont Linux** : archive (`SetFileFlagsMessage`, flag ARCHIVE) dès que les octets
  sont dans son inbox locale — parce que l'inbox et l'ingestion sont sur la même
  machine, « à nous » = « livré ».
- **Téléphone** : l'inbox (spool du téléphone) et l'ingestion (Pulse) sont sur deux
  machines, reliées par un réseau qui peut manquer. « À nous » ≠ « livré ».
  L'archivage ne doit intervenir qu'**après le 2xx de Pulse**.

Ce hook tombe exactement là où le pont a déjà un accusé de réception : en mode HTTP,
`DELETE /files/{nom}` **est** l'ack. Sur le téléphone, la chaîne devient :

```
download (BLE) → spool local → upload background → 2xx de Pulse (= ack)
   → marquer livré → à la prochaine fenêtre BLE : SetFileFlagsMessage(ARCHIVE)
```

L'archivage exige la radio ; il se fait donc **opportunément**, quand la montre est
de nouveau connectée, sur la liste des fichiers livrés-mais-non-archivés. Un fichier
livré mais pas encore archivé n'est pas un problème : Pulse dédup par hash, un
re-download éventuel est absorbé (§5, §6).

**Pourquoi l'archivage reste non négociable** : sans lui, l'index de la montre
sature et elle **cesse d'exposer ses nouveaux fichiers** — panne de plusieurs jours
déjà vécue côté Linux (commit `30a6b5c`). C'est le point le plus dangereux du
protocole. Le différer est correct ; l'oublier est fatal.

### 2.3 Schéma

```
LOIN DU HOMELAB (source = phone)

  Venu 2  ──BLE(GFDI)──►  iPhone (bridge-connect)
    ▲                        │  spool local (chiffré)
    │  SetFileFlags(ARCHIVE) │  URLSession background upload
    │  après ack Pulse       ▼
    └──────────────  Pulse (custom-connect)  ◄── WKWebView (consultation)
                     POST /api/ingest  → ingestBuffer → 2xx = ack
                     joignable en permanence via Tailscale

  (pendant ce temps, garmin-bridge au homelab est en veille : lien libéré)
```

Le téléphone est sur le tailnet (Tailscale) : il joint Pulse pour pousser et pour
la WebView. Pulse n'a jamais besoin de joindre le téléphone.

---

## 3. Viabilité iOS — CoreBluetooth en arrière-plan

Séparé en **ce qu'Apple garantit** et **ce qui relève de l'observation**. C'est la
section la plus importante et la plus incertaine.

### 3.1 Garanti par Apple (documenté)

- **Mode `bluetooth-central`** dans `UIBackgroundModes` (Info.plist) : l'app est
  réveillée pour les callbacks `CBCentralManagerDelegate` / `CBPeripheralDelegate`
  en arrière-plan — y compris les **notifications GATT** (`didUpdateValueFor`), qui
  sont exactement notre canal GFDI. Une connexion établie continue de délivrer ses
  notifications en arrière-plan.
- **State Preservation & Restoration** (`CBCentralManagerOptionRestoreIdentifierKey`) :
  si le système **tue** l'app (pression mémoire), iOS garde la pile Bluetooth vivante
  et **relance l'app en arrière-plan** quand un évènement pertinent survient
  (connexion, déconnexion, notification), en appelant `willRestoreState`. C'est le
  mécanisme qui permet de survivre à une terminaison système.
- **`connect(peripheral)` n'a pas de timeout** : une connexion en attente persiste.
  Si la montre s'éloigne puis revient, iOS rétablit le lien — et relance l'app pour
  le lui dire. C'est le pendant du *keeper* de garmin-bridge, mais fourni par l'OS.
- **Reconnexion par identifiant** : `retrievePeripherals(withIdentifiers:)` rend le
  périphérique connu sans scan. L'identifiant est un **UUID par app et par
  appareil** attribué par iOS — **pas l'adresse MAC** (iOS ne l'expose jamais). Il
  faut donc le persister au premier appairage.

### 3.2 Non garanti — relève de l'observation empirique

- **Pas de contrôle des paramètres de connexion.** Voir §1.2. Le supervision
  timeout de 4000 ms de la montre n'est pas élargissable. C'est **le** risque.
- **Fenêtres CPU courtes à chaque réveil.** Un réveil arrière-plan donne quelques
  secondes de traitement, pas un temps illimité. Un gros transfert n'est pas
  « garanti » de tenir dans une fenêtre.
- **Un transfert interrompu par une suspension : reprise ou reprise à zéro ?**
  Réponse à établir, mais la conception ne doit pas en dépendre. Le protocole
  Garmin n'offre pas de curseur fiable *entre sessions* (`REQUEST_TYPE.CONTINUE`
  reprend un transfert à un offset d'octets, mais le tampon à moitié rempli meurt
  avec le lien). garmin-bridge a tranché : **reprise à la génération de lien, pas
  au fragment** — nouvelle session, nouveau listing, fichier interrompu repris à
  zéro, le journal `acquired.log` garantissant qu'on ne rejoue pas ce qui est déjà
  pris. **On reprend ce modèle tel quel** : il rend la question de la reprise
  intra-fichier sans objet. Un fichier de monitoring fait quelques dizaines de Ko ;
  le perdre en cours et le reprendre coûte des secondes, pas un fichier.
- **Latence de reprise après suspension/terminaison : variable, à mesurer.**
- **Scan en arrière-plan fortement bridé** : filtrage par UUID de service
  obligatoire, pas de doublons, cadence lente. On l'évite en reconnectant un
  périphérique connu par identifiant, sans scanner.
- **Force-quit par l'utilisateur** (swipe up dans l'app switcher) **désactive** la
  relance arrière-plan jusqu'au prochain lancement manuel. À documenter pour
  l'utilisateur : ne pas tuer l'app.

### 3.3 Ce qu'on mesure, et quand

Tout ceci se mesure à l'**incrément 1** (lien + une caractéristique), avant tout
portage protocole. Métriques à relever, montre en poche, à portée réaliste :

1. Durée moyenne d'une fenêtre de connexion arrière-plan avant chute.
2. Nombre de notifications GATT reçues par fenêtre.
3. Latence entre « montre revenue à portée » et « app réveillée + reconnectée ».
4. Survie à une terminaison système (déclenchée à la main) via `willRestoreState`.
5. Le supervision timeout effectif qu'iOS négocie (via un log applicatif : temps
   entre dernière notif et détection de chute).

Si (1) et (2) donnent « on ne fait passer aucun fichier en arrière-plan », on bascule
sur le **plan de repli premier-plan** (§11) sans avoir écrit une ligne de GFDI.

---

## 4. Appairage

### 4.1 Ce qu'iOS impose

- iOS ne permet pas d'**initier** un bond par programme. Le bond se déclenche
  **implicitement** au premier accès à une caractéristique qui exige le
  chiffrement ; iOS affiche alors sa **popup système** de pairing (passkey). La
  Venu 2 affiche un passkey de son côté : appairage à confirmer des deux côtés,
  une fois.
- Une fois appairée, la montre apparaît dans Réglages > Bluetooth. Le bond est géré
  par iOS. On persiste l'**identifiant CoreBluetooth** (pas le MAC) pour reconnecter.

### 4.2 Effet sur le bond BlueZ existant — à vérifier sur matériel

La montre est aujourd'hui appairée à BlueZ (bond persistant, homelab). BLE permet
à un périphérique de tenir **plusieurs bonds** (jusqu'à une limite propre à
l'appareil ; les montres en tiennent en général quelques-uns). **Hypothèse** :
ajouter le bond iPhone **n'efface pas** le bond BlueZ. **À confirmer** — et surtout,
**dans quel ordre la montre évince un bond quand sa table est pleine** (souvent
LRU). Le risque concret : appairer l'iPhone pourrait, sur ce modèle, évincer le
homelab, imposant un **réappairage au retour**. C'est une **vérification
empirique**, pas une déduction. Procédure de test proposée : appairer l'iPhone,
puis vérifier que `bluetoothctl info <mac>` sur l'hôte dit toujours `Paired: yes`
et qu'un sync Linux repart sans réappairer.

### 4.3 L'app Garmin officielle

Si l'utilisateur a aussi l'app Garmin Connect installée et connectée, **elle tient
le lien companion** — et la montre n'annonçant qu'à un companion, bridge-connect ne
pourra pas connecter. Règle à poser : **une seule app companion active**. Pas de
mécanisme technique pour l'imposer côté iOS ; c'est une consigne d'usage (ne pas
laisser Garmin Connect connecté quand on veut collecter avec bridge-connect), plus
un diagnostic clair dans l'app quand la connexion échoue systématiquement (« une
autre app est peut-être connectée à la montre »).

---

## 5. Spool local et garantie de livraison

### 5.1 Principe

Les fichiers récupérés sont **conservés sur le téléphone jusqu'au 2xx de Pulse**.
L'archivage sur la montre ne suit **que** cette confirmation. C'est le cœur de la
garantie de livraison.

### 5.2 Journaux, calqués sur `AcquiredFiles` du pont

On reprend le modèle de `STATE_DIR` du pont, adapté à trois états au lieu de deux :

| État | Signifie | Transition |
|---|---|---|
| `acquired` | octets sur le disque du téléphone | après download BLE réussi |
| `delivered` | 2xx reçu de Pulse | après upload background |
| `archived` | flag ARCHIVE posé sur la montre | après SetFileFlags, à la prochaine fenêtre BLE |

L'identité d'un fichier est celle du pont : **type + date + index montre**
(`DirectoryEntry.getFileName()`), stable entre sessions, contrairement au rang dans
le listing (la montre fait tourner ses fichiers). Le listing d'inbox n'a pas de
curseur : on filtre chaque nouveau listing contre `acquired` pour savoir ce qui
reste dû, exactement comme le pont (`docs/context-garmin-bridge.md`, « Le rattrapage
reprend »).

### 5.3 Rétention, taille max, saturation

- **Rétention** : un fichier `archived` **et** `delivered` peut être purgé du spool.
  Un fichier `delivered` mais pas `archived` est gardé jusqu'à l'archivage (il porte
  encore une action due sur la montre). Un fichier `acquired` mais pas `delivered`
  est gardé **indéfiniment** — c'est la seule copie hors montre tant que Pulse ne
  l'a pas.
- **Taille** : les `.fit` de monitoring/activité font de l'ordre de la dizaine à la
  centaine de Ko. Même plusieurs centaines de fichiers en attente tiennent en
  quelques dizaines de Mo. Plafond de spool proposé : **configurable, défaut ~200 Mo**,
  large devant l'usage réel.
- **Saturation / absence de réseau prolongée** : le spool grossit tant que Pulse est
  injoignable. Comme les fichiers non livrés ne sont **pas archivés**, la montre les
  garde aussi — donc même si le spool devait être purgé sous contrainte, la donnée
  n'est pas perdue, elle est re-collectable. Politique en cas d'atteinte du plafond :
  **ne jamais purger un `acquired`-non-`delivered`** ; à la place, **cesser de
  downloader** (on laisse la montre porter le backlog, ce qu'elle sait faire jusqu'à
  saturation de *son* index) et signaler l'état dans l'app. C'est le retournement du
  pont : là-bas l'inbox locale et l'ingestion étant colocalisées, la pression ne
  montait jamais ; ici elle peut, et la réponse sûre est de ralentir la source, pas
  de jeter la seule copie.
- **Chiffrement au repos** : le spool contient de la donnée de santé. `.fit` écrits
  avec `NSFileProtectionComplete` (déchiffrés seulement appareil déverrouillé) ou au
  minimum `CompleteUnlessOpen` pour permettre l'écriture pendant un download
  arrière-plan sur appareil verrouillé. À arbitrer selon les besoins d'écriture en
  arrière-plan.

---

## 6. Protocole de bascule entre collecteurs

### 6.1 État existant côté Pulse

`SyncGateService` persiste une source active (`legacy` | `bridge`) dans
`settings.sync_source`, avec préséance sur `SYNC_SOURCE` de l'environnement.
`PUT /api/sync/source` change la source et **refuse (409) si une synchro est en
cours**. C'est le point d'extension.

### 6.2 Extension : ajouter la source `phone`

- Le type devient `'legacy' | 'bridge' | 'phone'`.
- En source `phone`, Pulse est **passif** : il ne déclenche ni `legacy`
  (fichier-signal) ni `bridge` (pull HTTP). Il **accepte les push** sur le nouvel
  endpoint d'ingestion (§2.1) et **rejette les push** quand la source active n'est
  pas `phone` (évite qu'un vieux téléphone continue d'injecter).
- `GET /api/sync/source` rend `phone` ; l'UI de Pulse (Paramètres > Synchronisation
  > Source) l'offre comme troisième choix.

### 6.3 Libérer le lien Linux — le travail transverse

C'est la vraie difficulté, et elle touche **garmin-bridge**, pas seulement Pulse.
Le pont Linux **tient le lien en permanence** (recyclé toutes les 2 h). Tant qu'il
le tient, la montre n'annonce pas et le téléphone ne peut pas connecter.

Il faut donc un **mode veille** sur garmin-bridge : un endpoint (p. ex.
`POST /standby` / `POST /resume`, ou un fichier-signal `control/standby.request` sur
le même modèle que `rebind`/`connparams`) qui fait **lâcher le lien et cesser de le
rétablir**. C'est un ajout ciblé : `WatchLink` sait déjà démonter et rouvrir un lien
(recyclage) ; la veille est « démonter et ne pas rouvrir tant que veille ».

Séquence de bascule **vers phone**, orchestrée par Pulse au `PUT /api/sync/source` :

```
1. Refuser si une synchro est en cours (déjà le cas, 409).
2. Mettre garmin-bridge en veille : POST /standby (ou signal control/).
3. Attendre confirmation que le lien est libéré : sonder GET /device jusqu'à
   connected=false, avec échéance. (Le champ existe déjà.)
4. Persister source = phone. À partir de là, Pulse accepte les push du téléphone.
5. Le téléphone, informé qu'il est source active (il sonde GET /api/sync/source),
   tente sa première connexion BLE.
```

Bascule **vers Linux** (retour au homelab) : symétrique. Pulse persiste
`source = bridge`, le téléphone (qui sonde la source) **passe en veille de lui-même**
(cesse de connecter, libère le lien), Pulse sort garmin-bridge de veille
(`POST /resume`).

### 6.4 Bascule alors que des fichiers sont en attente côté téléphone

C'est le cas que le brief demande de traiter, et **le design d'archivage différé le
rend sûr** :

- Un fichier spoolé sur le téléphone mais **non livré** à Pulse est **non archivé**
  sur la montre. Donc la montre le propose encore.
- Si on bascule vers Linux avec de tels fichiers en attente, **Linux les re-collecte
  depuis la montre** au sync suivant. Pulse dédup par hash : aucun double-ingest,
  aucune perte.
- Le seul « coût » est un re-download de ce que le téléphone tenait déjà — quelques
  secondes de BLE. Pas de perte de donnée, pas de blocage de la bascule.

Donc : **la bascule n'a pas à attendre que le spool du téléphone soit vide.** On
peut néanmoins offrir un « flush avant bascule » optionnel dans l'UI (« 3 fichiers
pas encore envoyés, les pousser d'abord ? ») par confort, mais ce n'est pas requis
pour la correction. Ce qui **est** requis, c'est que le téléphone, en repassant
source active plus tard, ne pousse pas des fichiers déjà ingérés via Linux — et le
hash de Pulse s'en charge, exactement comme pour le premier sync `bridge` qui
« remonte beaucoup de fichiers déjà connus, tous marqués comme doublons ».

### 6.5 Sécurité de la libération

Le point délicat : **s'assurer que le lien Linux est réellement libéré** avant que
le téléphone tente de connecter, sinon les deux se battent pour un périphérique qui
n'accepte qu'un companion. La confirmation vient de `GET /device` (`connected:false`)
côté pont, avec une échéance et un message clair si le pont ne confirme pas (« le
collecteur homelab n'a pas libéré la montre »). Tant que non confirmé, la bascule
reste en attente et le téléphone ne connecte pas.

### 6.6 Bascule suggérée sur détection de présence

Quand la source active est `phone` et que le téléphone est **stablement sur le
réseau local du homelab**, Pulse **propose** la bascule vers le collecteur fixe,
plutôt que de laisser l'utilisateur y penser. **Proposée, jamais automatique** —
la raison de fond est au 6.6.4.

#### 6.6.1 Le critère de présence

Le téléphone détecte **lui-même** s'il est à la maison, et le **signale à Pulse
dans un échange existant** — pas de canal supplémentaire. Il ride sur le sondage
qu'il fait déjà (`GET /api/sync/source`, §6.3) ou sur un heartbeat léger : la
présence doit remonter même quand il n'y a aucun fichier à pousser.

Deux signaux possibles, du plus simple au plus fiable :
- **Joignabilité de Pulse par son adresse locale** plutôt que par le relais
  Tailscale. C'est le meilleur critère « suis-je sur ce LAN » : on tente l'adresse
  locale de Pulse (ou un `/health` sur l'IP LAN), et le succès *est* la présence.
  Indépendant des permissions SSID.
- **SSID Wi-Fi** du réseau maison. Direct, mais lire le SSID sur iOS demande la
  permission Localisation (`CNCopyCurrentNetworkInfo` / `NEHotspotNetwork`) — friction
  et fragilité. À réserver en complément, pas en critère unique.

Recommandé : **joignabilité locale de Pulse** comme critère primaire.

#### 6.6.2 Le critère est imparfait, et on l'assume

Être sur le Wi-Fi maison **ne garantit pas d'être à portée BLE du dongle**. Un
appartement se couvre en Wi-Fi sur plusieurs pièces là où le lien Bluetooth exige
quelques mètres. C'est **exactement pourquoi la bascule est suggérée** : l'utilisateur
sait s'il est dans la bonne pièce, la machine ne le sait pas.

#### 6.6.3 Hystérésis, et ne pas insister

- **Ne rien proposer avant plusieurs minutes de présence stable** — de l'ordre de
  **10 minutes**, à affiner à l'usage — pour ne pas réagir à un passage (rentrer
  chercher quelque chose et repartir ne déclenche rien).
- **Symétriquement, ne pas retirer la suggestion à la première perte de réseau** :
  une coupure Wi-Fi brève n'est pas un départ. Fenêtre de tolérance côté descente
  également.
- **Une proposition par période de présence.** Si l'utilisateur ignore ou refuse,
  ne pas la représenter à chaque cycle : il a des raisons de rester sur le téléphone
  qu'on ne connaît pas. La suggestion ne réapparaît qu'après une **absence franche**
  suivie d'un **nouveau retour** stable.

#### 6.6.4 Le cas inverse, et pourquoi on ne peut pas faire mieux

Le cas inverse (source `bridge`, l'utilisateur s'éloigne) **ne se pose pas de la
même façon**. Le pont Linux constate que la montre est **hors de portée** et le
signale déjà — `linkError` porte le message. Proposer de basculer vers le téléphone
à ce moment serait utile, **mais** si le téléphone n'est pas à portée de la montre
non plus, la bascule n'améliore rien. Le déclencheur pertinent n'est donc pas « lien
homelab perdu » seul, mais **« absence prolongée du téléphone du réseau local » +
« lien homelab perdu »** — ce qui suppose que le téléphone, parti avec l'utilisateur,
est le collecteur qui a une chance de voir la montre.

**Pourquoi on ne peut pas faire mieux, sur les deux sens.** Le critère idéal serait
le **RSSI vu par le collecteur fixe** — une mesure directe de ce qui compte. Mais
pour le mesurer, le pont doit **prendre le lien**, que le téléphone tient peut-être
encore ; et un **scan passif ne verrait rien**, puisque la montre **n'annonce pas
quand elle est liée**. Il n'existe aucun moyen de mesurer la portée sans basculer.
C'est la raison de fond pour laquelle **la décision revient à l'utilisateur** — la
présence réseau est le seul proxy disponible, et c'est un proxy imparfait qu'on
présente comme une suggestion, pas comme un fait.

#### 6.6.5 Ce que ça ajoute à l'incrément 9

- Côté **téléphone** : détection de joignabilité locale de Pulse, et remontée de
  l'état de présence dans l'échange existant.
- Côté **Pulse** : mémoriser la présence dans le temps (hystérésis montée/descente),
  décider quand une suggestion est due, et l'exposer à l'UI **sans agir** — l'action
  reste le `PUT /api/sync/source` déclenché par l'utilisateur (§6.3). Mémoriser aussi
  « déjà proposé pour cette période de présence » pour ne pas réinsister.
- **Aucune action automatique n'est introduite** : la bascule elle-même reste le
  protocole du §6.3, avec sa confirmation de libération du lien (§6.5).

---

## 7. Découpage du protocole — l'effort de portage Swift

Rappel structurant : garmin-bridge **n'a pas réinventé le protocole**, il a **copié
verbatim** ~140 fichiers Java de Gadgetbridge (AGPL) et posé un shim de 4 primitives.
**Sur iOS, il n'y a pas de réutilisation verbatim** : Swift impose une
**ré-implémentation**. C'est la différence de coût majeure avec le pont, et la
principale source de risque (le code vendoré était éprouvé ; du Swift neuf ne l'est
pas). La contre-mesure : porter **le sous-ensemble minimal réellement exercé**, et
le couvrir de tests dérivés des captures et des tests existants du pont.

### 7.1 Ce qui est mécanique (traduction directe, testable en isolation)

Sans montre, vérifiable par vecteurs de test — idéalement **les mêmes vecteurs que
les tests du pont** (`src/test/.../GfdiFrames.java`, `CobsCoDec`, etc.) :

- **COBS** (encodage/décodage) — pur, quelques dizaines de lignes.
- **CRC16** — pur, une table.
- **Framing GFDI** : structures de messages, longueurs, types. Traduction champ à
  champ des `messages/` vendorés dont on a besoin (voir 7.3), pas des 48.
- **Réassemblage de fragments + acquittements** au niveau transport.
- **Réponses protobuf codées à la main.** Découverte importante :
  `ProtobufAck.java` **ne porte aucun `.proto`** — il code en dur 4 réponses de 6-7
  octets (`CALENDAR_OK_EMPTY`, `CORE_GET_LOCATION_NONE`, `CORE_LOCATION_UPDATED_OK`,
  `SMS_CANNED_LIST_SUCCESS`) et un ensemble de « services connus » pour choisir
  KEPT vs DISCARDED. **On copie ces octets tels quels en Swift. Pas de dépendance
  swift-protobuf sur le chemin collecteur.** C'est ~200 lignes, pas 17 `.proto` +
  génération.
- **Époque Garmin** : offset `631065600` (epoch Garmin = Unix − 631065600) pour la
  réponse à `CURRENT_TIME_REQUEST`. Une constante.

### 7.2 Ce qui demande du jugement (état, orchestration, corrélation)

- **Sélection V1/V2** par sondage des caractéristiques GATT à la connexion (la Venu
  2 est V2, multi-link).
- **Gestion d'état du lien** : le modèle *keeper* du pont, mais rendu à iOS pour la
  reconnexion (§3). Ce qui reste à nous : détecter la chute, décider reprise à la
  génération, ne pas rejouer `acquired`.
- **Orchestration des transferts** : file séquentielle (un download à la fois),
  listing → filtrage contre le journal → download → publication au spool. Parcours
  **du plus récent au plus ancien** (pour rapporter les mesures du jour d'abord
  quand le lien est court — leçon `3a2eae8`).
- **Corrélation protobuf** : un ack **KEPT** doit être suivi d'un
  **PROTOBUF_RESPONSE (type 5044)** corrélé par **requestId** pour les services
  qu'on prétend traiter ; **DISCARDED/UNKNOWN_REQUEST_ID** pour les autres. Omettre
  le followup = **retransmissions toutes les 5 s** (documenté, `fddbad6`/`6bd39b0`).
  C'est de l'état corrélé, pas de la traduction.
- **Poignée de main GFDI** : séquence `AuthNegotiation` (flags à zéro, pas de
  credentials) → `SupportedFileTypes` → réglage de l'heure → `SystemEvent(SYNC_READY)`,
  fin sur `CapabilitiesDeviceEvent`.
- **Archivage différé** (§2.2) : la logique propre à bridge-connect, absente du pont.

### 7.3 Sous-ensemble de messages à porter (pas les 48)

Strictement ce que le chemin collecteur exerce :
`DownloadRequest` / file transfer (listing index 0, entrées 16 octets, réassemblage),
`SetFileFlagsMessage` (ARCHIVE), `SetDeviceSettingsMessage` (AUTO_UPLOAD_ENABLED),
la réponse `CURRENT_TIME_REQUEST`, `ProtobufMessage` + `ProtobufStatusMessage`,
`DeviceInformationMessage` (firmware/serial, pour le « on parle à la montre »),
`BatteryStatusMessage` (utile pour juger le coût radio), et l'auth.

**Explicitement hors périmètre** : le parsing FIT (Pulse le fait), les services
`REALTIME_*` GFDI, `GdiSettingsService` (champ 42 — acquitté au transport mais **ne
répond jamais applicativement sur la Venu 2 fw 19.05**, inutile à porter — confirmé
côté pont), l'upload de séances (phase 5 du pont, pas un besoin du collecteur
distant). L'écriture du profil utilisateur (FIT SETTINGS / USER_PROFILE, poids)
est **optionnelle**, repoussée après le chemin critique.

### 7.4 Ordre de grandeur du code

Estimation : **~2500–4000 lignes de Swift** (transport + sous-ensemble messages +
session + spool + livraison), hors UI/WebView. À comparer aux 1445 lignes de
transport + le sous-ensemble de messages côté pont, majoré par l'absence de
réutilisation verbatim et par le fait qu'il faut réécrire les tests.

---

## 8. Incréments livrables

Chacun livre quelque chose de vérifiable et **dérisque avant d'investir**. L'ordre
est choisi pour que le risque rédhibitoire (§1) tombe à l'incrément 1. Estimations
en jours-dev pour un développeur seul à l'aise avec le domaine ; la barre d'erreur
est large sur tout ce qui touche le matériel.

| # | Livré | Vérification | Effort |
|---|---|---|---|
| **0** | Projet iOS, entitlements `bluetooth-central`, WKWebView vers Pulse via Tailscale, squelette de spool | L'app se lance, la WebView charge Pulse | 1–2 j |
| **1** | **Lien BLE + une caractéristique + mesure arrière-plan.** Scan/connect à la Venu 2, découverte services/caractéristiques, abonnement à une notif (p. ex. HR 180D, sans GFDI), State Restoration | Les 5 métriques du §3.3, montre en poche. **Go/No-Go du projet.** | 3–5 j (+ jours de mesure) |
| **2** | **Transport GFDI (mécanique)** : COBS, CRC16, framing, fragments, acks, sélection V1/V2 | Vecteurs de test = ceux du pont, verts sans montre | 4–7 j |
| **3** | **Poignée de main GFDI** : auth flags-zéro, supported file types, réponse heure (epoch Garmin), SYNC_READY | Log « Watch initialised » + `DeviceInformationMessage` (fw 19.05, serial) sur matériel | 3–5 j |
| **4** | **Canal protobuf** : ack KEPT/DISCARDED + PROTOBUF_RESPONSE 5044 corrélé, réponses codées en dur | Capture : les `PROTOBUF_REQUEST` **cessent** de se répéter toutes les 5 s | 3–5 j |
| **5** | **Listing + download** : listing index 0, entrées 16 o, file séquentielle, parcours récent→ancien, journal `acquired` | Un `.fit` réel arrive dans le spool ; `pendingFiles` décroît | 4–6 j |
| **6** | **Livraison à Pulse** : nouvel endpoint `POST /api/ingest`, upload URLSession background, ack 2xx | Un `.fit` collecté apparaît dans Pulse (activité ou santé) ; dédup par hash vérifiée | 3–5 j (dont côté Pulse) |
| **7** | **Archivage différé** : `SetFileFlagsMessage(ARCHIVE)` après ack, opportuniste sur fenêtre BLE | La montre continue d'exposer ses nouveaux fichiers sur la durée (pas de saturation d'index) | 2–4 j |
| **8** | **Tenue en arrière-plan** : keeper via State Restoration, reprise à la génération, spool/rétention/saturation | Collecte sur plusieurs jours, montre en usage normal, sans ouvrir l'app | 4–8 j (+ observation) |
| **9** | **Bascule** : source `phone` dans SyncGate, veille/reprise de garmin-bridge, orchestration de libération du lien, **+ suggestion sur détection de présence** (§6.6) | Basculer Linux↔phone sans que les deux se battent pour la montre ; pas de perte avec fichiers en attente ; suggestion proposée après ~10 min de présence locale stable, jamais automatique, non réinsistante | 4–6 j (transverse) |

**Total indicatif : ~30–50 jours-dev**, très dépendant du résultat de l'incrément 1
et du nombre d'allers-retours matériel sur 3, 5, 8. Les incréments 2 et 4 sont les
plus « mécaniques donc estimables » ; 1, 8 et 9 portent l'essentiel de l'incertitude.

---

## 9. WebView et App Store

Distribution **privée** actée. Donc :

- **Règle 4.2 (habillage web)** : **sans objet.** Elle ne s'applique qu'à la
  soumission App Store. En dev signing / TestFlight, non évaluée. Écartée.
- **Bluetooth arrière-plan « essentiel à la fonction »** : pour App Store, Apple
  exige de le justifier. Ici le BLE **est** la fonction (c'est un collecteur), donc
  même en cas de soumission future la justification serait solide — mais la question
  ne se pose pas en distribution privée.

Note technique indépendante de la distribution : `WKWebView` doit joindre Pulse via
son nom Tailscale (`https://…ts.net`). Prévoir le certificat TLS (Tailscale
`serve`/`cert`) et l'auth de session de Pulse dans la WebView (cookies).

---

## 10. Licence

garmin-bridge est **AGPL-3.0**, travail dérivé de Gadgetbridge. bridge-connect qui
porte le même protocole (même s'il ré-implémente en Swift au lieu de copier) est
**vraisemblablement un dérivé** et hérite de l'AGPL. Conséquences :

- **Publication du source** : l'AGPL impose de rendre le source disponible aux
  utilisateurs du logiciel, y compris en usage réseau. En mono-utilisateur perso,
  l'« utilisateur » c'est vous ; l'obligation est légère en pratique, mais **publier
  le dépôt (comme garmin-bridge et son `NOTICE`) est la voie propre** et sans
  friction.
- **App Store ↔ AGPL** : réputés incompatibles (les conditions de distribution
  Apple entrent en conflit avec l'AGPL). **Sans objet ici** : distribution privée,
  pas d'App Store. Si une distribution App Store était un jour visée, ce point
  **bloquerait** et demanderait soit une relicence (impossible unilatéralement sur
  du dérivé Gadgetbridge), soit une réécriture *clean-room* du protocole (coûteuse
  et risquée). À garder en tête comme **porte fermée**, pas comme problème actuel.
- **Pratique** : reprendre le modèle `NOTICE` de garmin-bridge — tracer ce qui vient
  de l'upstream, dans quelle version, ce qui a été porté. Même en ré-implémentant,
  documenter la filiation protège et clarifie.

---

## 11. Risques et ce qui les lève

| Risque | Gravité | Ce qui le lève |
|---|---|---|
| **BLE arrière-plan iOS insuffisant** (pas de contrôle connparams, fenêtres courtes) | **Rédhibitoire possible** | **Incrément 1**, sur matériel. Repli : mode premier-plan uniquement. |
| **Appairage iPhone évince le bond BlueZ** (réappairage au retour homelab) | Moyenne | Test empirique §4.2 avant tout le reste. Au pire : réappairer au retour, gênant mais pas bloquant. |
| **App Garmin officielle tient le lien** | Faible | Consigne d'usage + diagnostic clair dans l'app. |
| **Ré-implémentation Swift neuve vs code vendoré éprouvé** (bugs de transport) | Moyenne | Réutiliser les vecteurs de test du pont ; incréments 2/4 testés sans montre. |
| **Saturation index montre si archivage raté** | **Élevée** (panne de plusieurs jours vécue) | Archivage différé fiabilisé (incrément 7) ; ne jamais purger un `acquired` non `delivered`. |
| **Deux collecteurs se battent pour la montre** | Moyenne | Protocole de bascule avec confirmation de libération (§6.5). |
| **Perte de données en spool (téléphone perdu/reset avant livraison)** | Moyenne | Fichiers non livrés = non archivés = re-collectables depuis la montre. Chiffrement au repos. Fenêtre de perte = ce qui n'est ni livré ni encore sur la montre (rien, sauf si la montre a aussi tourné). |
| **Débit BLE faible (MTU non négocié)** | Faible | iOS négocie un MTU correct par défaut (souvent 185+), meilleur que le défaut prudent de BlueZ. À mesurer. |

---

## 12. Décisions restantes et informations manquantes

**Vérifications empiriques (ne se tranchent que sur matériel) :**

1. **La question rédhibitoire** : combien de fichiers passent par fenêtre de
   connexion arrière-plan, à portée réaliste. → Incrément 1.
2. **Bond multiple sur la Venu 2** : appairer l'iPhone évince-t-il le bond BlueZ ?
   Dans quel ordre la montre évince-t-elle ? → Test §4.2.
3. **Reprise de transfert après suspension** : iOS reprend-il, ou faut-il
   recommencer ? (La conception n'en dépend pas — reprise à la génération — mais la
   réponse informe l'optimisation.)
4. **Supervision timeout effectif négocié par iOS** avec cette montre.
5. **MTU négocié par iOS** avec cette montre.

**Décisions de conception — actées le 2026-09-18 :**

6. **Dépôt iOS** : ✅ **acté** — l'app vit ici (`Projects/all`), scaffold Xcode par
   défaut déjà en place (target `all`, bundle id `CleanYourRoom.all` à renommer avant
   TestFlight, iOS 18.2, Swift 5.0). Capabilities BLE/background à ajouter aux
   incréments.
7. **Endpoint d'ingestion push de Pulse** : ✅ **acté** — `POST /api/ingest`,
   **auth par token dédié au téléphone** (Bearer statique en config, un secret par
   appareil, révocable ; l'upload URLSession background ne porte pas commodément la
   session web). Le **2xx est l'ack**. Réutilise `IngestService.ingestBuffer`.
8. **Mécanisme de veille de garmin-bridge** : ✅ **acté** — **endpoint HTTP
   `POST /standby` / `POST /resume`** (plus simple à orchestrer depuis Pulse :
   appel direct + sonde `GET /device` jusqu'à `connected=false`). Ajout ciblé sur
   `WatchLink` (qui sait déjà démonter/rouvrir un lien).
9. **Protection des fichiers au repos** : ✅ **acté** — **`CompleteUnlessOpen`**
   (`NSFileProtectionCompleteUnlessOpen`) : permet d'écrire un download en cours
   même appareil verrouillé, requis pour la collecte arrière-plan qui est l'objet
   du projet.
10. **Écriture du profil utilisateur (poids)** : ✅ **acté** — **repoussée**, hors
    chemin critique du collecteur distant.
11. **Détection de présence (§6.6)** : ✅ **acté** — critère primaire =
    **joignabilité locale de Pulse** (`/health` sur IP LAN ; indépendant de la
    permission Localisation) ; SSID Wi-Fi écarté. Hystérésis de départ : **montée
    ~10 min** de présence stable, **descente** tolérante à une coupure Wi-Fi brève —
    valeurs à affiner à l'usage. Remontée de présence portée par l'échange existant
    (`GET /api/sync/source` enrichi ou heartbeat léger — à préciser à l'incrément 9).

**Information à récupérer avant l'incrément 6 :**

12. Confirmer que `IngestService.ingestBuffer` accepte un `.fit` arbitraire par un
    nouvel endpoint sans régression sur le watcher d'inbox et la dédup.

---

## Annexe — invariants hérités du pont, à ne pas réapprendre

- **Archiver après téléchargement, sinon l'index sature et la montre cesse d'exposer
  ses nouveaux fichiers** (`30a6b5c`). Ici : archiver après *livraison*.
- **Le point de reprise vient d'un journal (`acquired`), pas du listing** : le
  listing n'a pas de curseur et la montre le réordonne entre sessions (`3a2eae8`).
- **Reprise à la génération de lien, pas au fragment** : le tampon meurt avec le
  lien.
- **Parcours récent → ancien** : rapporte les mesures du jour d'abord sur un lien
  court.
- **Ack protobuf KEPT + PROTOBUF_RESPONSE 5044 corrélé par requestId**, sinon
  retransmissions toutes les 5 s (`fddbad6`, `6bd39b0`).
- **Répondre à `CURRENT_TIME_REQUEST`** en secondes epoch Garmin (Unix − 631065600).
- **Redémarrer la montre** quand le lien s'établit mais la poignée de main n'aboutit
  pas : symptôme côté serveur, cause dans la pile BLE de la montre.
- **Ne pas parser le FIT sur le collecteur** : Pulse le fait, dédup par hash.
- **`GdiSettingsService` (champ 42) ne répond jamais applicativement sur Venu 2 fw
  19.05** : ne pas le porter.
```
