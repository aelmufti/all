# Live-2 — métriques temps réel GFDI au-delà de la FC : conception

Document de conception pour l'incrément **Live-2** (pas, stress, SpO2, VFC, body
battery, respiration, calories, intensité — au-delà de la fréquence cardiaque déjà
livrée par Live-1a/1b via le profil BLE standard 0x2A37). Tranche le mécanisme,
liste ce qui est démontrable en test vs matériel uniquement, et pose le plan de
câblage. **Aucun code de ce document n'est branché** : les décodeurs vivent dans
`all/all/GFDI/RealtimeDecoders.swift`, appelés uniquement par
`all/allTests/RealtimeDecodersTests.swift`. `CommunicatorV2.swift` n'enregistre
toujours qu'un seul service ML (`GFDI`, code 1) ; rien n'est activé par défaut.

> **Rappel des règles immuables du dépôt.** Toute mise en œuvre effective (activer
> un service `REALTIME_*` contre la montre, observer une vraie mesure de FC/pas/
> SpO2/etc.) est une action qui lit de la donnée de santé personnelle et exige une
> autorisation explicite préalable — ce document ne fait que spécifier et ne fait
> tourner aucun flux.

---

## 1. Question centrale : quel mécanisme la Venu 2 utilise-t-elle ?

Deux candidats étaient sur la table. Réponse : **mécanisme 1 (services ML
`REALTIME_*`)**, avec preuves directes. Le mécanisme 2 (protobuf `GdiSmartProto`/
`GdiSettingsService`, capacité `REALTIME_SETTINGS`) est **sans rapport** — une
collision de vocabulaire, pas une alternative concurrente.

### 1.1 Mécanisme 1 (retenu) — services ML enregistrés par handle

Preuve directe et non ambiguë : **gadgetbridge upstream (non strippé) a des
décodeurs complets, fonctionnels, pour six des dix services `REALTIME_*`**,
enregistrés exactement comme le service GFDI l'est déjà dans ce projet
(`REGISTER_ML_REQ`/`REGISTER_ML_RESP` sur le canal de contrôle, handle 0, puis
messages applicatifs préfixés du handle attribué).

- `/Users/alielmufti/Documents/Projects/gadgetbridge/app/src/main/java/nodomain/freeyourgadget/gadgetbridge/service/devices/garmin/communicator/v2/CommunicatorV2.java` —
  enum `Service` (lignes 706–725) avec les dix codes `REALTIME_*`, et six classes
  internes de décodage complètes et actives : `RealtimeHeartRateCallback` (461),
  `RealtimeStepsCallback` (485), `RealtimeAccelerometerCallback` (516, javadoc
  détaillée sur le format), `RealtimeSpo2Callback` (570), `RealtimeRespirationCallback`
  (595), `RealtimeHrvCallback` (604). Elles sont branchées dans le `switch` de
  `processHandleManagement` (337–351) exactement comme `GfdiCallback` (le seul
  callback déjà porté dans ce dépôt).
- **garmin-bridge (ce pont, dans l'écosystème du projet) a explicitement retiré
  ces six callbacks** en gardant les codes de service : voir
  `/Users/alielmufti/Documents/Projects/garmin-bridge/patches/CommunicatorV2-strip-realtime.patch`
  (diff complet des ~230 lignes retirées) et le commentaire laissé dans le fichier
  strippé lui-même,
  `/Users/alielmufti/Documents/Projects/garmin-bridge/src/main/java/.../communicator/v2/CommunicatorV2.java:223-229` :
  > *« The realtime measurement services below are deliberately not implemented.
  > Upstream streams live HR / steps / accelerometer / SpO2 / HRV straight into
  > GreenDAO and Sleep-as-Android; that is the only reason CommunicatorV2 depends
  > on the Gadgetbridge persistence layer. garmin-bridge syncs recorded files, so
  > the streams are dead weight. »*

  Autrement dit : **le pont ne les a pas retirés parce qu'ils ne marchent pas —
  il les a retirés parce qu'il n'en a pas besoin** (il synchronise des fichiers
  enregistrés, pas des flux temps réel). C'est un choix de périmètre, pas une
  preuve d'échec du mécanisme. Le code retiré reste la meilleure preuve
  disponible que ce mécanisme fonctionne contre du matériel Garmin réel (gadgetbridge
  compte des dizaines de milliers d'utilisateurs actifs, cette fonctionnalité
  existe depuis des années dans l'app Android).

- `CommunicatorV2.swift` (ce projet) le confirme lui-même en en-tête (lignes
  9-15) : *« Les services FILE_TRANSFER_*/REALTIME_* du pont ne sont PAS portés :
  rien dans ce projet ne les utilise… »* — écrit avant que Live-2 ne soit cadré,
  ça montre que l'infrastructure d'enregistrement de service (handle management)
  déjà portée est **directement réutilisable** : même canal de contrôle
  (`processHandleManagement`), même `REGISTER_ML_REQ`/`RESP`, juste un code de
  service différent de `GFDI(1)`.

### 1.2 Mécanisme 2 (écarté) — `GdiSmartProto`/`GdiSettingsService`, capacité `REALTIME_SETTINGS`

Fausse piste par collision de nom. Preuve :

- `GarminSupport.java:448-461` — la capacité `REALTIME_SETTINGS` (annoncée par la
  montre dans `CapabilitiesDeviceEvent`) ne déclenche qu'un seul appel :
  `sendProtobufRequest("init realtime settings", GdiSmartProto.Smart.newBuilder().setSettingsService(GdiSettingsService.SettingsService.newBuilder().setInitRequest(...language/region...)))`.
- `gdi_settings_service.proto` (`SettingsService`, `ScreenDefinition`,
  `ScreenEntry`, `Label`, `Target`…) décrit des **écrans de préférences** (menus
  de réglages de la montre, avec titres, options, sous-écrans) — rien qui
  ressemble à un flux biométrique.
- `GarminRealtimeSettingsActivity.java`/`GarminRealtimeSettingsFragment.java`
  confirment l'usage : une UI de **navigation dans les réglages de la montre
  depuis le téléphone** (`screenId`, fragments de préférences Android). Le mot
  « Realtime » désigne ici « lire l'état courant d'un réglage en direct », pas
  « recevoir un flux de mesures physiologiques ».
- C'est très exactement le **`GdiSettingsService` du champ 42** que `CLAUDE.md` et
  `CADRAGE.md` (§7.3, ligne 522) documentent déjà comme **hors périmètre** et
  **mort sur cette Venu 2 fw 19.05** (« acquitté au transport mais ne répond
  jamais applicativement »). Rien de nouveau à apprendre ici : même s'il était
  pertinent pour Live-2 (il ne l'est pas), il est déjà connu non fonctionnel sur
  ce matériel précis.

**Conclusion : aucune décision protobuf à prendre pour Live-2.** La règle du
dépôt (pas de `swift-protobuf`, acks codés en dur façon `ProtobufAck.java`)
n'est **pas mise sous tension** par ce chantier — les services `REALTIME_*` sont
un mécanisme binaire simple (identique à `GFDI`), aucun message protobuf
n'intervient dans le flux de données lui-même.

---

## 2. Métriques : ce qui est réaliste sur la Venu 2, et leur format

### 2.1 Décodées et testées ici (format connu, preuve upstream directe)

| Métrique | Service ML (code) | Taille payload | Format |
|---|---|---|---|
| Fréquence cardiaque | `REALTIME_HR` (6) | ≥ 3 o | `type:u8, hr:u8, resting:u8` |
| Pas | `REALTIME_STEPS` (7) | 8 o | `steps:u32LE, goal:u32LE` |
| VFC / RR | `REALTIME_HRV` (12) | ≥ 6 o | `rr:u16LE, unk:u32LE` |
| Accéléromètre | `REALTIME_ACCELEROMETER` (16) | 16 o exactement | en-tête 16 bits (horodatage 13 bits + nb d'échantillons 3 bits) + 9 valeurs signées 12 bits empaquetées en nibbles (3 échantillons x,y,z) |
| SpO2 | `REALTIME_SPO2` (19) | ≥ 5 o | `spo2:i8, ts:u32LE` (epoch Garmin) |
| Respiration | `REALTIME_RESPIRATION` (21) | ≥ 1 o | `bpm:i8` (peut être négatif = pas de valeur, sentinelle non confirmée) |

Chaque format ci-dessus vient d'un décodeur **actif et non ambigu** côté
gadgetbridge upstream (pas d'une déduction). Portés dans
`RealtimeDecoders.swift`, testés dans `RealtimeDecodersTests.swift` avec des
vecteurs construits à la main (entiers) ou dérivés d'un port Python fidèle de
l'algorithme d'empaquetage (accéléromètre, cf. commentaire en tête du fichier de
test).

Zones d'incertitude assumées et documentées dans le code (non résolues, pas
vérifiables sans matériel) :
- FC réaltime : le premier octet (`type`) a un sens incertain même côté pont
  (commentaire d'origine : « 0/2/3? 3 == realtime? »).
- VFC : les deux champs sont nommés `rr`/`unk` côté pont **sans unité
  confirmée** — probablement des millisecondes pour `rr`, non vérifié.
- Respiration : la sentinelle « valeur inconnue » n'est **pas** un `-2` figé
  dans le code amont, juste un commentaire (« usually -2 ») — le décodeur ici
  expose la valeur brute sans interprétation.
- Accéléromètre : convention de signe **Android** reproduite telle quelle
  (z = -1g montre à plat écran vers le haut) ; aucune garantie qu'elle
  corresponde à la convention CoreMotion/iOS si jamais on rapproche les deux.

### 2.2 Hors de portée du décodage — matériel uniquement

| Métrique | Service ML (code) | Statut |
|---|---|---|
| Calories | `REALTIME_CALORIES` (8) | Code de service confirmé (enum upstream), **aucun décodeur nulle part** dans gadgetbridge ni garmin-bridge |
| Intensité | `REALTIME_INTENSITY` (10) | idem |
| Stress | `REALTIME_STRESS` (13) | idem |
| Body battery | `REALTIME_BODY_BATTERY` (20) | idem |

Recherche exhaustive faite (`grep` sur l'intégralité de
`gadgetbridge/app/src/main/java`) : ces quatre codes de service **existent** dans
l'enum (même famille numérique que les six ci-dessus, cf. §1.1), ce qui laisse
penser que la Venu 2 les expose bel et bien au même titre — mais **personne dans
l'écosystème gadgetbridge n'a jamais écrit ni documenté leur décodeur**. Rien à
porter avant d'avoir une **capture réelle** (enregistrer le service, journaliser
les octets bruts reçus, procéder par inspection — exactement la méthode qui a
produit les six formats connus, à en juger par les commentaires « unk »/
incertitudes laissés dans le code amont lui-même).

**Conséquence pratique pour Live-2** : sur les huit métriques demandées dans le
cadrage de cette tâche (pas, stress, SpO2, VFC, body battery, respiration,
calories, intensité), **quatre sont décodables dès aujourd'hui** (pas, SpO2, VFC,
respiration) et **quatre exigent une session de capture matérielle avant tout
code** (stress, body battery, calories, intensité). Pas de raccourci honnête
possible ici — inventer un format serait pire que ne rien livrer.

---

## 3. Plan de câblage (non activé)

Grandes lignes de ce qu'il faudrait faire pour rendre Live-2 réel, **sans le
faire** :

1. **Extension de `CommunicatorV2.swift`** : élargir l'enum privé `MlService`
   (aujourd'hui `case gfdi = 1` seul) avec les codes de `RealtimeMlService` dont
   `hasKnownDecoder == true`, et un point d'enregistrement explicite et **gardé**
   (ex. `func enableRealtimeService(_:)`, appelé nulle part par défaut — jamais
   dans `start()`). Réutiliser telle quelle l'infrastructure `REGISTER_ML_REQ`/
   `RESP`/`CLOSE_HANDLE_*` déjà écrite pour `GFDI` : c'est très exactement le même
   protocole de canal de contrôle, juste un `service.rawValue` différent.
2. **Décodage** : au retour de `handleIncoming`, un handle inconnu de `.gfdi`
   mais connu de `RealtimeMlService` route vers `RealtimeDecoders.swift` (déjà
   écrit, déjà testé) au lieu de tomber dans le `default`/`log.warning` actuel.
3. **État côté appelant** : `RealtimeSteps` n'inclut pas le delta pas-à-pas que
   calcule le pont (`steps - previousSteps`) — c'est un calcul **stateful** par
   nature (dépend du message précédent), volontairement laissé hors d'un
   décodeur pur. À faire dans la couche qui détient l'état de session (analogue
   à `GarminSession.swift`), pas dans `RealtimeDecoders.swift`.
4. **Remontée UI** : suivre le patron déjà validé par Live-1a (mesure native
   affichée dans l'app, hors WebView Pulse) — un `@Published`/`AsyncStream` côté
   SwiftUI par métrique, alimenté par les callbacks `CommunicatorV2`. Live-1b a
   ensuite ajouté un push réseau vers Pulse **découplé** de l'affichage (piloté
   par le premier plan) ; le même découplage s'appliquerait à Live-2 si on
   veut pousser ces métriques à Pulse — **nouvelle action réseau, nouvelle
   autorisation à demander le moment venu**, pas dans ce document.
5. **Activation/désactivation** : côté pont, `onEnableRealtime*(enable: Bool)`
   ouvre/ferme le handle à la demande (pas une écoute permanente). Le
   câblage devrait suivre le même patron — un toggle explicite par métrique,
   jamais un abonnement automatique au démarrage de la session GFDI.

Aucune de ces étapes n'est faite dans cet incrément : `RealtimeDecoders.swift`
est un module **isolé**, sans import de `CommunicatorV2`/`GarminSession`, sans
appelant de production.

---

## 4. Ce que Live-2 remonte à l'utilisateur

- **Pas de décision protobuf à trancher** (cf. §1.2) — bonne nouvelle, la règle
  « pas de swift-protobuf » n'est jamais mise sous tension par ce chantier.
- **Quatre métriques sur huit demandées restent hardware-only** (stress, body
  battery, calories, intensité) : aucun format documenté nulle part dans
  l'écosystème. Avant d'écrire le moindre décodeur pour elles, il faut une
  session de capture contre la Venu 2 réelle (enregistrer le service ML
  correspondant, journaliser les octets bruts d'au moins quelques messages,
  déduire le format par inspection). C'est un incrément matériel à part, pas un
  travail de code pur.
- **L'accéléromètre reproduit une convention de signe Android non vérifiée** —
  à confronter au matériel si jamais on l'active.
- Le prochain choix réel, si on va plus loin : **quelles métriques activer en
  premier** (suggestion : SpO2 et pas, formats les plus simples et les moins
  ambigus) et **où les afficher** (écran natif comme Live-1a, ou remontée Pulse
  comme Live-1b) — décision produit, pas une question technique tranchée ici.
