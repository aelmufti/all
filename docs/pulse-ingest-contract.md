# Contrat d'ingestion push — `bridge-connect` → Pulse

Spécification du seul point de contact réseau entre l'app iOS **bridge-connect** et
**Pulse** (`custom-connect`) : l'endpoint vers lequel le téléphone **pousse** les
`.fit` récupérés en BLE de la montre. Document de conception, revu par un humain ;
il cadre l'incrément 6 (« Livraison à Pulse », CADRAGE §8) et prépare l'incrément 9
(source `phone` dans `SyncGateService`). Aucun code ici.

Décisions déjà actées, non rediscutées (CADRAGE §12 pts 7, 9 ; CLAUDE.md
« Contrats ») : `POST /api/ingest`, **auth par token dédié au téléphone**, **le 2xx
est l'accusé**, réutilise `IngestService.ingestBuffer`, **archivage montre différé
jusqu'à l'accusé**. Ce doc les précise et tranche ce qui restait ouvert.

> **Rappel des règles immuables du dépôt** : cet endpoint transporte de la donnée de
> santé. Toute mise en œuvre effective (tester en émettant une vraie requête,
> déployer le token, pousser un `.fit`) est une action réseau **et** personnelle et
> exige une autorisation explicite préalable. Le présent document ne fait que
> spécifier ; il n'émet rien.

---

## 1. Vue d'ensemble

Le téléphone iOS ne peut pas être un serveur joignable en arrière-plan (une app
suspendue ne reçoit pas de connexion entrante). On **inverse** le sens du mode
`bridge` (où Pulse tire) : **le téléphone pousse**, via `URLSession` en
configuration **background upload**, qui survit à la suspension et à la terminaison
de l'app et rejoue tout seul quand le réseau revient.

Chaîne de livraison (CADRAGE §2.2) :

```
download (BLE) → spool local (acquired) → upload background → 2xx de Pulse (= ack)
   → marquer delivered → à la prochaine fenêtre BLE : SetFileFlags(ARCHIVE) → archived
```

Propriétés que le contrat doit garantir :

- **Un `.fit` brut par requête.** Pas de batch (voir §8, question ouverte).
- **Le 2xx est l'unique accusé.** Rien n'est archivé sur la montre ni purgé du
  téléphone avant lui (§7).
- **Idempotence obligatoire.** Le background upload iOS peut **rejouer** une requête
  (retransmission système, relance après terminaison). Le même fichier peut donc
  arriver plusieurs fois ; il doit toujours produire un 2xx, jamais une erreur (§4).
- **Pulse ne fait pas confiance au téléphone pour la dédup** : il déduplique par
  **hash des octets qu'il reçoit**, comme aujourd'hui. Le téléphone ne parse pas le
  FIT (CLAUDE.md, invariant).

---

## 2. Endpoint

| | |
|---|---|
| **Méthode / chemin** | `POST /api/ingest` |
| **Content-Type** | `application/octet-stream` |
| **Corps** | Le `.fit` **brut**, tel quel, non enveloppé, non compressé |
| **Réponse** | JSON (voir §6) ; **c'est le code HTTP qui fait foi**, le corps est informatif |

**Pourquoi octet-stream brut et pas multipart.** La contrainte dure vient de la
seule API iOS viable en arrière-plan : `URLSession` **background upload task**
n'accepte qu'un **corps = un fichier sur disque** (`uploadTask(with:fromFile:)`) avec
des **en-têtes simples** ; elle ne construit pas de corps multipart et ne peut pas
streamer un `HTTPBody` composé. Le `.fit` du spool est déjà un fichier sur disque :
le pointer directement en corps est le chemin le plus court et le plus robuste. Le
multipart existant côté UI (`FilesInterceptor`, `activities.controller.ts`) sert un
autre besoin (upload navigateur multi-fichiers) et n'est pas réutilisable ici.

**Écart vs l'existant, assumé.** Aucune route de Pulse ne lit aujourd'hui un corps
`application/octet-stream` brut : il faudra câbler un body-parser brut (`express.raw`)
**limité à cette route**, avec un plafond de taille (proposé : **8 Mo**, très large
devant des `.fit` de monitoring/activité de l'ordre de la dizaine à la centaine de
Ko ; l'UI plafonne déjà à 25 Mo par fichier). Le corps est passé tel quel à
`ingestBuffer(buffer, originalName)` — **aucune régression** sur le watcher d'inbox
ni sur `bridge-sync`, qui appellent la même fonction (CADRAGE §12 pt 12 à confirmer).

---

## 3. Authentification

- **Bearer token dédié au téléphone**, en en-tête : `Authorization: Bearer <token>`.
  Raison (CADRAGE §12 pt 7) : le background upload iOS **ne porte pas commodément la
  session web** (cookies) ; un token statique en en-tête, lui, voyage trivialement.
- **TLS obligatoire, pas de fallback clair.** L'endpoint n'est joint que via le nom
  Tailscale de Pulse en `https://…ts.net` (TLS terminé en amont, cf. README « TLS
  terminé en amont »). L'**ATS** d'iOS bloque le HTTP clair : il n'y a pas de mode
  dégradé à prévoir, et il ne faut pas en ajouter.
- **Où vit le token, côté Pulse.** Nouvelle variable d'environnement, p. ex.
  `INGEST_TOKENS` — **une liste** de tokens (un par appareil), pas un secret unique.
  Lue dans `config.ts` à côté de `authUsername`/`sessionSecret`. Comparaison à temps
  constant. **Aucun secret en dur** dans le code ni dans ce doc ; génération type
  `openssl rand -hex 32`, comme `SESSION_SECRET`.
- **Révocation** : retirer le token de la liste et redéployer (ou recharger la
  config) invalide l'appareil immédiatement. Une liste permet d'ajouter/retirer un
  téléphone sans toucher aux autres.
- **Intégration au guard existant.** L'`AuthGuard` global (`APP_GUARD`) valide un
  **cookie de session** et rejette tout le reste ; il faut donc soit marquer la route
  `@Public()` (comme `/api/health`) et lui appliquer un **guard de token dédié**,
  soit étendre l'`AuthGuard` pour accepter *ou* le cookie *ou* un Bearer d'ingestion.
  **Recommandé** : un `IngestTokenGuard` distinct sur la seule route `/api/ingest`,
  pour ne pas élargir la surface du guard de session.

---

## 4. Idempotence & déduplication

**Clé de dédup = SHA-256 des octets du fichier, calculé par Pulse.** C'est
exactement ce que fait déjà `IngestService.ingestBuffer` :
`createHash('sha256').update(buffer)` → recherche dans `activities.file_hash` puis
`imported_files.hash` → si présent, retourne `status: 'duplicate'`. **On ne change
rien** : le contrat s'aligne sur la dédup en place plutôt que d'en inventer une.

Conséquence centrale, **non négociable** : **un fichier déjà connu vaut accusé.** Un
doublon renvoie **2xx**, jamais une erreur — sinon le téléphone, qui a rejoué un
upload ou re-téléchargé un fichier non encore archivé, ne pourrait **jamais**
l'archiver et resterait bloqué dessus. `'imported'`, `'wellness'`, `'duplicate'` et
`'skipped'` (type FIT non géré, cf. `fit-parser` `kind: 'other'`) **valent tous
accusé** (§6).

**Distinguer nouveau vs déjà connu** est utile (télémétrie, UI « X envoyés / Y
doublons »), mais purement informatif : le corps de réponse porte `outcome`, le code
reste 2xx dans les deux cas.

**Hash côté téléphone — optionnel, non autoritatif.** Le téléphone *peut* joindre le
SHA-256 qu'il a calculé (en-tête `X-Content-SHA256`, §5) pour deux gains : (a) un
**contrôle d'intégrité** (Pulse rejette en 400 si le hash reçu ≠ hash des octets — un
corps tronqué en transit) ; (b) un **court-circuit d'idempotence** (Pulse répond
`duplicate` sans reparser si le hash est déjà connu). Mais **l'autorité reste le hash
que Pulse calcule sur les octets reçus** : le champ du téléphone n'est qu'un
indice/garde-fou, jamais la source de vérité de la dédup.

---

## 5. Métadonnées

Le corps étant le `.fit` brut, les métadonnées voyagent en **en-têtes HTTP**. Pulse
re-dérive tout le reste du FIT lui-même ; on n'envoie que le strict utile.

| En-tête | Obligatoire | Rôle |
|---|---|---|
| `Authorization: Bearer <token>` | oui | Auth (§3) |
| `Content-Type: application/octet-stream` | oui | Corps brut (§2) |
| `X-Watch-Filename` | oui | Nom Garmin du fichier = **identité** `type + date + index` (`DirectoryEntry.getFileName()`, CADRAGE §5.2). Passé comme `originalName` à `ingestBuffer` → stocké dans `activities.file_name` / `imported_files.file_name`, sert au diagnostic et à corréler avec le spool du téléphone. |
| `X-Content-SHA256` | recommandé | Hash des octets calculé par le téléphone : intégrité + court-circuit d'idempotence (§4). Non autoritatif. |
| `Content-Length` | oui | Fourni par `URLSession` ; permet le rejet précoce au-delà du plafond (§2). |

**Volontairement absents** : type de fichier montre, date, index en clair — Pulse les
lit dans le FIT (`fileIdMesgs`, etc.). Ne pas dupliquer une vérité que le fichier
porte déjà. `X-Watch-Filename` suffit comme étiquette opaque de corrélation.

---

## 6. Sémantique des réponses

Pour **chaque** classe, l'action du téléphone est fixée. Rappel : tout `.fit` non
`delivered` reste dans le spool et **n'est pas archivé** sur la montre — donc jamais
perdu, re-collectable (CADRAGE §5.3, §6.4).

| HTTP | Cas | `outcome` (corps) | Vaut accusé ? | Action du téléphone |
|---|---|---|---|---|
| **200** | Nouvellement ingéré | `imported` \| `wellness` | **oui** | `delivered` → archiver à la prochaine fenêtre BLE |
| **200** | Déjà connu (dédup hash) | `duplicate` | **oui** | idem — `delivered` → archiver |
| **200** | Type FIT non géré (`kind:'other'`) | `skipped` | **oui** | idem — Pulse n'en voudra jamais ; `delivered` → archiver |
| **401** | Token absent/invalide | — | non | **Garder** en spool, **ne pas archiver**. Cesser de rejouer, **remonter une erreur de configuration** dans l'UI (token à corriger). Pas de retry-spam. |
| **403** | Source active ≠ `phone` (§ gating) | — | non | **Garder**, **ne pas archiver**. Back-off et **retry différé** (la source peut redevenir `phone`). Informer l'utilisateur si ça persiste. |
| **400** | Corps vide / `X-Watch-Filename` manquant / `X-Content-SHA256` ≠ octets reçus | — | non | Rejouer n'aide pas (bug d'émission ou corruption en transit). **Recalculer/re-émettre une fois** ; si ça persiste, **quarantaine** locale + signalement. **Ne pas archiver.** |
| **413** | Corps au-delà du plafond (§2) | — | non | Anomalie (un `.fit` montre n'atteint pas 8 Mo). **Quarantaine** + signalement. Ne pas archiver. |
| **415** | `Content-Type` inattendu | — | non | Bug d'émission côté téléphone. Corriger l'en-tête et rejouer. Ne pas archiver. |
| **422** | FIT illisible — `ingestBuffer` a rendu `status:'error'` (parse échoué) | `error` | non | Rejouer **n'aidera jamais** (fichier corrompu/tronqué à la source). **Quarantaine** : cesser le retry auto, **garder les octets**, signaler à l'utilisateur. **Ne pas archiver** → la montre garde sa copie, re-collectable ultérieurement. |
| **5xx / timeout / réseau** | Pulse indisponible | — | non | **Garder** en spool. `URLSession` background **réessaie tout seul** quand le réseau/serveur revient. Backoff géré par l'OS + le spool. Ne pas archiver. |

Notes de mise en œuvre côté Pulse :
- `ingestBuffer` renvoie `status ∈ {imported, wellness, duplicate, skipped, error}`.
  Mapping : `error` → **422** ; tout le reste → **200** avec `outcome = status`.
- Sur `skipped`/`duplicate`, `ingestBuffer` n'écrit rien de neuf en base — c'est
  correct, l'accusé ne dépend pas d'une écriture, seulement du fait que Pulse
  **assume** le fichier (déjà là, ou sciemment ignoré).
- **Distinction 422 vs 400** : 422 = octets valides mais FIT non parsable (décision
  applicative de Pulse) ; 400 = requête mal formée (métadonnée/intégrité). Les deux
  mènent à la quarantaine côté téléphone, mais séparer aide le diagnostic.

---

## 7. Cycle de vie & garantie de livraison

Invariant du spool (CADRAGE §5.2), calqué sur `AcquiredFiles` du pont, à trois états :

| État | Signifie | Transition |
|---|---|---|
| `acquired` | octets sur le disque du téléphone | après download BLE réussi |
| `delivered` | **2xx** reçu de Pulse | après upload background |
| `archived` | flag ARCHIVE posé sur la montre | après `SetFileFlags`, à la prochaine fenêtre BLE |

Règles que ce contrat verrouille :

- **Rien n'est archivé sur la montre ni purgé du téléphone avant le 2xx.** L'archivage
  différé est la **seule divergence** de contrat vs le pont Linux (où `DELETE /files`
  *est* l'ack et l'archivage est immédiat car inbox et ingestion sont colocalisées).
  Ici les deux sont sur des machines distinctes reliées par un réseau faillible :
  « à nous » ≠ « livré » (CADRAGE §2.2).
- **Un `delivered` non encore `archived` est normal et sûr** : si le fichier
  réapparaît (re-listing, re-download avant archivage), un re-push renvoie `duplicate`
  en 2xx (§4). Pas de double-ingestion, pas de blocage.
- **Ne jamais purger un `acquired` non `delivered`** : c'est la seule copie hors
  montre tant que Pulse ne l'a pas. En cas de plafond de spool atteint, on **cesse de
  downloader** (la montre porte le backlog), on ne jette jamais cette copie
  (CADRAGE §5.3).
- **Pourquoi l'archivage reste non négociable** : sans lui, l'index de la montre
  sature et elle **cesse d'exposer ses nouveaux fichiers** (panne de plusieurs jours
  déjà vécue côté Linux). Différer est correct ; oublier est fatal (CADRAGE §2.2).

**Raccord à `SyncGateService` / source `phone` (côté Pulse).** Aujourd'hui
`SyncSourceName = 'legacy' | 'bridge'` (`sync.types.ts`), persisté dans
`settings.sync_source` (`sync-gate.service.ts`). Le contrat suppose l'extension
**`… | 'phone'`** (CADRAGE §6.2) :

- En source `phone`, Pulse est **passif** : il ne déclenche ni `legacy` ni `bridge`,
  il **accepte les push** sur `/api/ingest`.
- **Gating** : quand la source active **n'est pas** `phone`, `/api/ingest` **rejette
  en 403** (évite qu'un ancien téléphone continue d'injecter — CADRAGE §6.2). C'est
  la ligne « 403 » du §6.
- Le changement de source reste gouverné par `PUT /api/sync/source` (409 si une
  synchro est en cours) ; la bascule et la libération du lien Linux sont hors de ce
  contrat (CADRAGE §6.3–6.5).

---

## 8. Questions ouvertes — à trancher avec l'utilisateur

Franches, courtes ; aucune ne bloque le cadrage, toutes affinent la mise en œuvre.

1. **Schéma exact du token.** Retenu : `INGEST_TOKENS` = liste de secrets, en-tête
   `Authorization: Bearer`, révocation par retrait + redéploiement. À confirmer :
   nom de la variable, rotation (deux tokens en parallèle le temps d'un basculement ?),
   et si un identifiant d'appareil lisible (préfixe non secret) est souhaité pour les
   logs.
2. **`X-Content-SHA256` : obligatoire ou recommandé ?** Le rendre **obligatoire**
   offre un contrôle d'intégrité systématique (rejet 400 des corps tronqués) au prix
   d'un hash calculé sur le téléphone. Proposé : **recommandé** au départ, promu
   obligatoire si des corruptions de transit apparaissent.
3. **Endpoint de santé/statut pour le téléphone.** Le téléphone a besoin de sonder
   « suis-je la source active ? » (`GET /api/sync/source`, déjà présent) et sa
   **joignabilité locale** pour la détection de présence (CADRAGE §6.6). Faut-il un
   `GET /api/ingest/health` dédié (auth par token) distinct du `/api/health` public,
   pour que le téléphone valide **son** token sans pousser de fichier ? Proposé :
   oui, léger, réutilise le `IngestTokenGuard`.
4. **Batch vs un-par-un.** Retenu : **un `.fit` par requête** (simple, idempotent,
   compatible `uploadTask(with:fromFile:)`). Un mode batch (tar/zip multi-fichiers)
   réduirait le nombre de réveils réseau mais complique l'idempotence partielle (2xx
   partiel ?) et le body-parser. À reconsidérer **seulement** si le volume de réveils
   background devient un problème mesuré.
5. **Plafond de taille exact** (`8 Mo` proposé) et **plafond de spool** (`~200 Mo`
   proposé, CADRAGE §5.3) — valeurs à confirmer à l'usage.
6. **Concurrence.** Un téléphone poussant en série (un upload à la fois) rend la
   course improbable, mais `URLSession` peut relancer un upload pendant qu'un autre
   est en vol. `ingestBuffer` n'est pas explicitement sérialisé côté Pulse ; vérifier
   qu'un double-push simultané du **même** fichier ne crée pas deux lignes (la dédup
   par hash devrait l'absorber, mais la fenêtre entre « parse » et « insert » n'est
   pas verrouillée). À confirmer avant l'incrément 6 (rejoint CADRAGE §12 pt 12).
