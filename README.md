# bridge-connect

Collecteur iOS pour montre **Garmin Venu 2**, en Bluetooth Low Energy (protocole
GFDI). L'app récupère les fichiers `.fit` de la montre et permet de les consulter
de deux façons, au choix (réglage **Stockage**) :

- **Téléphone** — tout reste sur l'iPhone (base locale, aucun serveur, aucun
  réseau sauf le scan nutrition, voir *Confidentialité*).
- **Pulse** — les fichiers sont poussés vers un serveur [custom-connect
  « Pulse »](https://github.com/) personnel (source de vérité).
- **Les deux** — envoi à Pulse + copie locale ; lecture depuis Pulse avec repli
  local s'il est injoignable.

> **Statut : travail en cours.** Fonctionne sur matériel réel. Le Bluetooth
> arrière-plan a été abandonné au profit d'une collecte au premier plan.

## Licence

**GNU Affero General Public License v3.0 (AGPL-3.0)** — voir [`LICENSE`](LICENSE).

Ce projet est une **œuvre dérivée de [Gadgetbridge](https://codeberg.org/Freeyourgadget/Gadgetbridge)**
(AGPL-3.0) : le protocole Garmin a été rétro-conçu par Gadgetbridge et est ici
**porté en Swift**. Détails de filiation et composants tiers dans [`NOTICE`](NOTICE).

En conséquence, si vous **distribuez** cette app (même à un seul testeur, même
gratuitement), vous devez :
- la licencier en AGPL-3.0,
- **fournir le code source complet** à chaque destinataire (le plus simple :
  publier ce dépôt et en donner le lien),
- conserver les mentions de licence et de filiation (`LICENSE`, `NOTICE`).

## Non affilié à Garmin

Projet indépendant, **non affilié, ni autorisé, ni approuvé par Garmin Ltd.**
« Garmin » et « Venu » sont des marques de leurs détenteurs respectifs, citées
uniquement pour décrire l'interopérabilité.

## Confidentialité

- Les données de santé de la montre restent **sur l'iPhone** (mode Téléphone) ou
  ne vont que vers **votre** serveur Pulse (modes Pulse / Les deux). Aucune
  télémétrie, aucun envoi vers un tiers.
- **Seul appel réseau externe** : le scan / la recherche d'aliments interroge
  **Open Food Facts** (`openfoodfacts.org`), et uniquement quand vous le
  déclenchez. Données Open Food Facts sous licence ODbL.
- En diffusant l'app, vous devenez responsable des données de vos testeurs :
  informez-les de ce qui est collecté et obtenez leur accord.

## Prérequis & build

- **Xcode** (cible iOS **17.5+**), Swift. Bundle id `CleanYourRoom.all`.
- Le lien BLE et la mesure ne se testent **que sur un iPhone physique** avec une
  Venu 2 — pas au simulateur.

```sh
# Tests unitaires (simulateur)
xcodebuild test -project all/all.xcodeproj -scheme all \
  -destination 'platform=iOS Simulator,name=iPhone 15 Pro' -only-testing:allTests

# Build sur appareil (signature automatique)
xcodebuild -project all/all.xcodeproj -scheme all \
  -destination 'id=<UDID>' -allowProvisioningUpdates build
```

Avec un compte Apple **gratuit**, la signature de développement expire tous les
7 jours : il faut alors réinstaller l'app et **faire confiance au profil**
(Réglages → Général → VPN et gestion de l'appareil).

## Composants tiers

- [Gadgetbridge](https://codeberg.org/Freeyourgadget/Gadgetbridge) — AGPL-3.0
  (origine du protocole).
- [swift-protobuf](https://github.com/apple/swift-protobuf) — Apache-2.0.
- [Open Food Facts](https://world.openfoodfacts.org) — données sous ODbL.
