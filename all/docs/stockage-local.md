# Stockage local — mode Téléphone (« Pulse embarqué »)

Décisions utilisateur (2026-09-29) :

- **Réglage à 3 positions** : `Pulse` | `Téléphone` | `Les deux` (Paramètres).
- **Téléphone = app autonome** : les écrans lisent des données calculées sur l'iPhone,
  sans serveur. → **révise l'invariant « ne pas parser le FIT sur le collecteur »**
  (vrai en mode Pulse ; faux en mode Téléphone/Les deux).
- **Décodeur FIT maison** (Swift, sous-ensemble des messages utilisés par Pulse,
  zéro dépendance) ; base **SQLite système** (`libsqlite3`, pas de SPM).
- **Archivage montre** en mode Téléphone : **dès l'écriture locale** (le fichier du
  spool vaut livraison). En Pulse/Les deux : inchangé (après 2xx Pulse).
- **Les deux** : les écrans lisent **Pulse, repli local** si Pulse est injoignable
  — erreur de transport **ou** aucune adresse Pulse configurée (`.notConfigured` :
  « pas de Pulse → tout local », décision 2026-09-29). Jamais sur 4xx/401/5xx.
- **Historique** : la base locale est (ré)alimentée depuis le **spool** existant
  (tous les `.fit` depuis la 1re synchro de l'app). Pas de rapatriement depuis Pulse.
- **Hors montre** (Nutrition, Programme, Poids) : **masqués** en mode Téléphone,
  portés dans des incréments ultérieurs.

## Architecture

`PulseAPIClient` route chaque requête soit vers le serveur, soit vers un
**`LocalPulseBackend`** in-process qui répond aux **mêmes routes** avec le **même
JSON** (mêmes modèles `Decodable`). Les écrans ne changent pas. Le backend local
est un portage Swift du serveur `custom-connect/server/src` (parser FIT → tables
SQLite calquées sur celles de Pulse → contrôleurs).

## Incréments

| # | Contenu | Test |
|---|---|---|
| **L0 ✅** | Réglage de mode ; livraison locale (archivage) en Téléphone ; routage `PulseAPIClient` + backend local stub ; login contourné et écrans hors montre masqués en Téléphone ; pas de push live HR en Téléphone | device : mode Téléphone → synchro → archivage sans réseau |
| **L1 ✅** | Décodeur FIT maison (`all/Local/Fit/`) + base SQLite système (`all/Local/Db/`) + ingestion (`LocalIngestor`, dédup hash) ; backend local sert `wellness/dates` + `wellness/days` | 13 tests vs sortie `@garmin/fitsdk` sur les `.fit` d'exemple |
| **L2 ✅** | `wellness/day/:date` (+ `bodyBatteryPivot` porté & recoupé vs TS) ; ingestion câblée (lancement + fin de traversée BLE) ; Maintenant + Santé lisibles en Téléphone. **Reportés** : `intensity` local + live HR local (dégradent proprement) ; `api/activities` = stub vide | 16 tests + build device |
| **L3 ✅** | Activités : extracteur (résumé/streams/laps/sets/splits/hrZones), tables `activities`/`activity_zones`, `api/activities` + `:id` (détail reparsé depuis le spool). Sommeil : écran déjà servi par L1/L2 (vérifié). GPS porté (`track` peuplé → carte + Altitude). Fix décodeur : échelle appliquée aux champs tableau | 12 tests + build device |
| L4 | Stats / Dashboard | |
| L5+ | Nutrition, Programme, Poids | |
