# Audit de robustesse — reprise de fragment, CRC invalide, interleaving ARCHIVE

Audit des trois chemins « corrects en théorie mais peu éprouvés » du collecteur
GFDI (`all/all/GFDI/GarminSession.swift`, `all/all/GFDI/FileTransferReassembler.swift`),
confrontés à la spec de référence `garmin-bridge/src/main/java/net/garminbridge/session/GarminSession.java`
(AGPL-3.0, méthodes `answeredAFragmentOutOfStep`/`trackWhereTheTransferIs`/`archiveOnWatch`/
`processDownloadQueue`/`nextStillWanted`) et au pont vendoré (Gadgetbridge)
`FileTransferHandler.java`/`FileTransferDataStatusMessage.java` pour les points où
le pont Linux lui-même ne fait pas référence (CRC).

Portée : mécanique de transfert uniquement — le contenu FIT n'est jamais parsé
ici (règle CLAUDE.md), seul le déroulé protocolaire est en jeu.

## Seam de test ajouté (avant l'audit proprement dit)

`GarminSession` était construite directement sur `CommunicatorV2` (classe
concrète, `init?` exige un `CBPeripheral` réel) — impossible à piloter en test
sans CoreBluetooth réel. Introduit un protocole étroit `GfdiCommunicating`
(`CommunicatorV2.swift`) portant les 4 points d'entrée que `GarminSession`
utilise réellement (`onGfdiFrame`, `onGfdiChannelReady`, `start()`,
`sendGfdiMessage(_:taskName:)`) ; `GarminSession.init` prend maintenant ce
protocole plutôt que la classe concrète. `CommunicatorV2` reste l'unique
conformance de production (`BLEManager` continue de lui passer une vraie
instance, aucun appelant existant modifié). C'est un seam de test pur, même
famille que `SpoolUploading`/`PulseUploadTransport` déjà dans le repo — **aucun
comportement de production n'est modifié** (build + tous les tests existants
verts avant/après, cf. § Résultat).

Ce seam est ce qui permet aux nouveaux tests (`TransferResilienceTests.swift`)
de piloter `GarminSession` de bout en bout avec un communicator factice
(`FakeGfdiCommunicator`) — jamais de vrai BLE, jamais de donnée de santé réelle.

## 1) Reprise de fragment interrompu

**Fidèle.** Le port suit `answeredAFragmentOutOfStep`/`trackWhereTheTransferIs`
quasiment trame pour trame, PAS le `FileTransferHandler.FileFragment.append`
vendoré (qui lève une exception sur tout fragment hors séquence — le bug
d'origine que le pont corrige avec ces deux méthodes, et que ce port évite
structurellement en extrayant `FileTransferReassembler` en type pur).

| Cas | Pont (`GarminSession.java`) | Port (`FileTransferReassembler`/`GarminSession.swift`) |
|---|---|---|
| Offset attendu (`==`) | Passe aux handlers, `sendAck` avec `dataOffset+message.length` (`FileTransferDataMessage.statusMessage`) | `.appended(ackOffset: buffer.count, complete:)`, identique |
| En retard (`<`, doublon) | `sendOutgoingMessage(... FileTransferDataStatusMessage(..., OK, expected))`, pas de `markTransferActivity()` (délibéré — « le cas que le stall timeout existe pour attraper ») | `.reAck(offset: expected)`, sans réappliquer — même trame |
| En avance (`>`, perte) | Même trame `(..., OK, expected)`, mais CETTE branche appelle `markTransferActivity()` | `.reAck(offset: expected)` — même trame ; pas d'équivalent `markTransferActivity`/stall-timeout côté port (cf. Hardware-only) |
| Traînard (après fin) | `!isDownloading() \|\| expectedDataOffset==NOTHING_TO_APPEND_TO` → `sendAck` sur la trame elle-même, dont l'ack par défaut vaut `dataOffset+message.length` (« son propre offset ») | `currentDownload == nil` → `sendFileTransferAck(offset: dataOffset + chunk.count)` — même valeur, même rationale |

Jamais `TransferStatus.RESEND` dans le pont ni dans le port : les deux
n'utilisent que `OK`, la reprise se fait en répétant l'offset voulu, jamais un
statut dédié. Confirmé aussi par `FileTransferDataStatusMessage.TransferStatus`
(protocole GFDI réel) qui liste `RESEND`/`ABORT`/`CRC_MISMATCH`/
`OFFSET_MISMATCH`/`SYNC_PAUSED` en plus de `OK` — ni le pont ni le port ne les
émettent jamais : c'est un choix délibéré et partagé, pas un oubli du port.

**Écart mineur, non bloquant, documenté ici plutôt que fixé** : le pont
distingue la branche `>` (perte) de la branche `<` (doublon) uniquement pour
décider d'appeler `markTransferActivity()` (nourrit un timeout de stall
30 s, `SyncService.STALL_TIMEOUT`, qui vit dans `SyncService`/`SyncCompletion`
— une couche d'orchestration multi-liens qui n'existe pas encore côté iOS,
cf. Hardware-only ci-dessous). Le port ne fait pas cette distinction (les deux
branches produisent la même `.reAck`) parce qu'il n'y a rien côté iOS
aujourd'hui qui consomme un tel signal d'activité. Ce n'est pas un bug : c'est
de la fonctionnalité non portée parce que sa consommatrice n'existe pas encore.
Si un futur incrément ajoute un timeout de session côté iOS, il faudra alors
réintroduire cette distinction — noté pour ne pas le redécouvrir.

**Tests ajoutés** (`TransferResilienceTests.swift`, `GarminSessionFragmentResumeTests`) :
`inOrderFragmentsAckEachOffsetAndCompleteTheFile`,
`fragmentAheadOfExpectedIsNotAppliedAndReAsksForCurrentOffset`,
`duplicateFragmentIsReAckedWithoutBeingReapplied`,
`stragglerFragmentAfterCompletionIsAckedButHasNoEffect` — ce dernier cas
n'existe qu'au niveau `GarminSession` (`currentDownload == nil`), invisible à
`FileTransferReassemblerTests` (GarminProtocolTests.swift) qui ne voit que le
type pur. Complètent (ne dupliquent pas) les vecteurs déjà pinnés côté type pur.

**Hardware-only** : le comportement réel de la Venu 2 face à une VRAIE perte de
fragment (latence de retransmission, tolérance à combien de re-acks avant
d'abandonner le lien) — non observable sans matériel. Le timeout de stall
30 s de session (`SyncService`) n'a pas d'équivalent côté iOS actuellement
(un seul lien à la fois, pas de daemon d'orchestration) ; à réévaluer si un
futur incrément l'introduit.

## 2) Ré-accusé sur CRC invalide

**Divergence assumée du pont — probablement une amélioration, pas un bug.**
C'était l'hypothèse non vérifiée signalée dans le code (`FileTransferReassembler`,
commentaire HYPOTHÈSE) ; l'audit confirme qu'elle diverge bien du pont, mais
dans un sens défendable :

- **Pont** : `GarminSession.java` (la classe de session, celle que ce port
  suit) NE gère PAS spécifiquement le CRC — `answeredAFragmentOutOfStep` ne
  regarde que l'offset. Un fragment à l'offset attendu mais au CRC invalide
  tombe dans le pipeline de handlers normal, où le `FileTransferHandler`
  **vendoré** (`FileFragment.append`, `FileTransferHandler.java:444-446`)
  compare le CRC et **lève `IllegalStateException("Received message with
  invalid CRC")` AVANT toute mutation d'état** (position/CRC courant
  inchangés — confirmé en lisant `append()` : le `throw` précède
  `dataHolder.put`/`setRunningCrc`). Cette exception remonte jusqu'à
  `onNotification` (`GarminSession.java:339-341`), qui l'attrape et se
  contente de logger — **aucun accusé n'est renvoyé pour ce fragment**. La
  montre ne reçoit donc aucune réponse et retransmet le même fragment de son
  propre chef, sur son timer de retransmission (silence = NACK implicite).
- **Port** : `FileTransferReassembler.receive` traite un CRC invalide à
  l'offset attendu exactement comme le cas « perte de fragment » : aucune
  mutation (même garantie que le pont — buffer/CRC courant inchangés), MAIS
  envoie activement `sendFileTransferAck(offset: expected)` — la **même
  trame** que celle utilisée pour la reprise après perte de fragment
  (`Status.ACK`, `TransferStatus.OK`, offset inchangé).

**Pourquoi ce n'est probablement pas un problème** : côté fil, ces deux trames
sont identiques bit pour bit à ce que le pont envoie déjà pour la branche
« perte de fragment » (`fragment.getDataOffset() > expected`). Rien dans le
protocole ne permet à la montre de distinguer « vous avez perdu un fragment »
de « le fragment que vous venez d'envoyer est corrompu, réessayez » — les deux
se traduisent par le même accusé nommant le même offset non avancé. Le port
est donc **cohérent avec un mécanisme de reprise que le pont utilise déjà
ailleurs dans le même fichier**, juste appliqué à un troisième déclencheur
(CRC) que le pont laisse au hasard d'un timeout. Le port est plus réactif
(pas d'attente du timer de retransmission de la montre) sans introduire de
nouvelle sémantique de trame.

**Décision : pas de durcissement.** Aligner le port sur le pont signifierait
revenir à un comportement strictement pire (silence + attente d'un timeout non
documenté côté montre) sans bénéfice de fidélité réel, puisque le pont
lui-même ne fait ici qu'hériter d'un accident du handler vendoré plutôt que
d'un choix délibéré de `GarminSession.java`. Gardé tel quel, avec ce constat
documenté ici (remplace l'hypothèse non vérifiée par une confrontation
explicite au pont).

**Test ajouté** (en plus de `FileTransferReassemblerTests.invalidCrcAtExpectedOffsetIsNotAppliedAndReAsksTheSameOffset`,
qui ne couvre que l'`Action` pure) :
`GarminSessionFragmentResumeTests.invalidCrcAtExpectedOffsetIsNotAppliedAndReAsksTheSameOffset`
— vérifie l'accusé RÉELLEMENT émis sur le fil (RESPONSE/5000 avec offset=0,
TransferStatus.OK) et que rien n'est écrit dans le spool tant que le bon
fragment n'arrive pas.

**Hardware-only** : le point non tranchable sans matériel reste de savoir si
la Venu 2 accepte bien de re-servir le même fragment sur ce type d'accusé
« actif » aussi rapidement qu'attendu, ou si elle a un comportement différent
(ex. incrémente un compteur d'échecs, referme le lien) après plusieurs CRC
invalides consécutifs au même offset — jamais observé, un vrai CRC invalide
sur BLE fiable étant rarissime en usage normal.

## 3) Interleaving ARCHIVE / téléchargement suivant

**Fidèle, et le garde de slot est un renforcement délibéré et documenté (pas un
écart caché).**

- **Émission de l'archive elle-même** : `archiveFileOnWatch`
  (`GarminSession.swift`) envoie `SET_FILE_FLAG(ARCHIVE)` (5008) en **trame
  directe**, sans jamais toucher `downloadTarget`/`currentDownload` — exactement
  comme `archiveOnWatch` côté pont (`GarminSession.java:878-889`), qui appelle
  `sendOutgoingMessage` sans passer par le `FileTransferHandler`/slot non plus.
  Le pont interleave même explicitement DÉJÀ l'archive avec le démarrage d'un
  téléchargement suivant : `nextStillWanted` (ligne 929-938) appelle
  `archiveOnWatch(next)` pour chaque entrée déjà tenue **dans la même passe**
  que celle qui va ensuite déclencher `sendOutgoingMessage("download file ...")`
  pour la suivante réellement due — confirmant que archive et download ne sont
  **jamais mutuellement exclusifs** dans la référence non plus.
- **Différence de déclenchement, déjà actée et documentée (CLAUDE.md,
  `GarminSession.swift` en-tête)** : le pont archive dès que les octets sont
  localement tenus (`onFileDownloaded`, synchrone avec la réception BLE) ; le
  port diffère l'archive jusqu'à l'accusé Pulse (`archivePendingDeliveries`,
  appelée depuis `handleUploadOutcome` sur un callback réseau asynchrone qui
  peut donc atterrir à *n'importe quel* moment, y compris pendant qu'un tout
  autre fichier occupe déjà le slot). C'est *exactement* le scénario
  d'interleaving visé par cet audit, et le mécanisme qui le rend sûr — l'archive
  ne touchant jamais le slot — est le même des deux côtés.
- **Garde anti-course sur le slot lui-même** (`pendingDirectoryRelisting`,
  `requestDirectoryListing`, `advanceDownloadQueue`) : porte un problème
  DIFFÉRENT (une re-list de manifeste demandée par la montre pendant qu'un
  téléchargement de contenu est en vol), que le pont résout autrement
  (`wouldRestartATransferAlreadyRunning`, ligne 742-748 : **abandonne**
  silencieusement le message FILTER plutôt que de le rejouer). Le port choisit
  de **différer puis rejouer** plutôt que d'abandonner — divergence déjà
  explicitement justifiée dans le commentaire de `requestDirectoryListing`
  (écraser le slot faisait refuser la montre en `downloadStatus=3`) et
  cohérente avec le modèle simplifié « un manifeste par appel de
  `syncNewFiles()` » du port (cf. en-tête de fichier). Pas un bug : un choix de
  conception différent pour un problème que le pont, avec son modèle de
  listing en flux continu, n'a pas besoin de résoudre de la même façon.

**Aucun vrai écart/bug trouvé** sur ce chemin — la lecture ligne à ligne
confirme que `archiveFileOnWatch`/`archivePendingDeliveries` ne lisent ni
n'écrivent jamais `downloadTarget`/`currentDownload`/`downloadQueue`/`syncState`,
et que `GarminSession` tourne entièrement sur le thread principal
(`CBCentralManager(delegate:queue: nil)` → callbacks CoreBluetooth sur main ;
`handleUploadOutcome` explicitement `DispatchQueue.main.async`) : pas de race
de données possible entre le callback d'upload Pulse et le traitement d'un
fragment BLE entrant, les deux sont sérialisés sur la même file.

**Tests ajoutés** (`GarminSessionSlotInterleavingTests`) :
- `archivingAPriorFileDoesNotDisturbAFileCurrentlyDownloading` — archive un
  fichier A (délivré) PENDANT qu'un fichier B est mi-téléchargé (un fragment
  déjà appliqué, le second en vol) ; vérifie que l'archive part bien (trame
  5008 correcte, `A` marqué `archived` dans le spool) SANS perturber la suite
  du téléchargement de B (accusé final correct, contenu de B intact, `B` bien
  acquis).
- `directoryRelistRequestedMidDownloadIsDeferredThenReplayedOnceTheSlotFrees`
  — pilote un manifeste réel d'une entrée (traversée automatique
  `syncNewFiles`), déclenche une re-list en plein milieu du téléchargement du
  seul fichier dû (rien n'est envoyé tout de suite), puis vérifie qu'elle est
  rejouée automatiquement — une nouvelle trame DOWNLOAD_REQUEST(index=0) —
  une fois la traversée épuisée.

**Hardware-only** : le comportement réel de la montre si elle reçoit
effectivement un SET_FILE_FLAG et un DOWNLOAD_REQUEST/FILE_TRANSFER_DATA
imbriqués sur le fil BLE (latence, ordonnancement GATT côté firmware Venu 2)
— non observable sans matériel. Le test valide la logique côté téléphone
(qu'on n'envoie jamais rien qui casse l'état local), pas la réaction de la
montre à recevoir ces trames entrelacées.

## Résultat build + tests

```
xcodebuild test -project all/all.xcodeproj -scheme all \
  -destination 'platform=iOS Simulator,id=255FC575-0DB9-4132-AE9C-87152158B4DE' \
  -only-testing:allTests
```

**Build : succès. Tous les tests verts**, y compris les 7 nouveaux
(`GarminSessionFragmentResumeTests` × 5, `GarminSessionSlotInterleavingTests` × 2)
et l'intégralité de la suite pré-existante. Une exécution isolée a montré
`PulseLiveHrPusherTests.pushesThroughTheTransportWhenConfigured()` échouer une
fois puis repasser au vert sans aucun changement de code — flakiness
pré-existante et déjà documentée dans le fichier lui-même
(`LiveHeartRatePushTests.swift`, commentaire sur `@Suite(.serialized)` :
course sur l'état Keychain partagé de `PulseConfig` entre suites, pas
sérialisée globalement). Confirmé sans rapport avec cette tâche : ce chemin ne
touche ni `PulseConfig` ni le Keychain, et une ré-exécution complète est
repassée verte sans modification.

## Durcissement appliqué

Aucun — aucun vrai écart comportemental trouvé vs le pont sur les trois
chemins. Seul changement de production : le seam de test `GfdiCommunicating`
(§ en tête de ce document), qui ne modifie aucun comportement observable
(`CommunicatorV2` reste l'unique conformance réelle, mêmes appels, mêmes
trames).
