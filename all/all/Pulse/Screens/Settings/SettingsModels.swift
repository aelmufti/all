//
//  SettingsModels.swift
//  all (bridge-connect)
//
//  Modèles `Decodable`/`Encodable` de l'écran Paramètres — miroir des formes
//  JSON exposées par NestJS (`custom-connect/server/src/sync/sync.controller.ts`,
//  `sync/sync.types.ts`, `profile/profile.controller.ts`) et consommées par la
//  page Angular `/parametres` (`custom-connect/web/src/app/pages/settings/
//  settings.component.ts`, section « Synchronisation > Source » notamment).
//
//  Convention socle (cf. `PulseAPIClient.decoder`, pas de stratégie de date) :
//  les champs epoch/compteurs restent `Int`, les chaînes calendaires/horodatages
//  ISO restent `String`. Comme dans les autres écrans (cf. `HealthModels.swift`,
//  `NutritionModels.swift`), les valeurs de statut/source qui sont des libellés
//  de provenance plutôt que des branches de logique figées restent `String`
//  (pas d'enum de décodage) — un enum d'affichage séparé (`SettingsSyncSourceKind`
//  ci-dessous) sert uniquement à peupler le sélecteur, pas au décodage.
//

import Foundation

// MARK: - `GET /api/sync/source`, `PUT /api/sync/source`, `POST /api/sync/ingest-token/regenerate`

/// Miroir de `SyncSource` (`sync.types.ts`). `source`/`configured` valent
/// `"legacy"` (le téléphone historique tire par adb), `"bridge"` (garmin-bridge
/// en Bluetooth depuis le serveur) ou `"phone"` (nouvelle chaîne bridge-connect :
/// le téléphone pousse en HTTP). `ingestToken` n'est présent (non-`nil`) que
/// quand `source == "phone"` (cf. commentaire `SyncController.describeSource`).
struct SettingsSyncSource: Decodable, Equatable {
    let source: String
    let configured: String
    let overridden: Bool
    let url: String
    let reachable: Bool?
    let detail: String?
    let ingestToken: String?
}

/// Corps de `PUT /api/sync/source` (`SyncController.setSource`) — seule valeur
/// attendue par le serveur, qui rejette tout ce qui n'est pas
/// `"legacy"`/`"bridge"`/`"phone"` (400).
struct SettingsSyncSourceUpdateRequest: Encodable {
    let source: String
}

/// Les trois valeurs possibles de `SettingsSyncSource.source`/`.configured`,
/// avec le libellé français utilisé par le sélecteur (miroir de `sources`
/// dans `SettingsComponent`, Angular). Ne sert qu'à l'affichage : le décodage
/// réseau reste en `String` brut (cf. en-tête de fichier).
enum SettingsSyncSourceKind: String, CaseIterable, Identifiable {
    case legacy
    case bridge
    case phone

    var id: String { rawValue }

    var label: String {
        switch self {
        case .legacy: return "Téléphone"
        case .bridge: return "garmin-bridge"
        case .phone: return "iPhone (BLE)"
        }
    }
}

// MARK: - `GET /api/sync/status`

/// Miroir de `SyncProgress` (`sync.types.ts`) — présent uniquement en cours de
/// synchronisation bridge, `nil` sinon.
struct SettingsSyncProgress: Decodable, Equatable {
    let startedAt: String?
    let watchFiles: Int?
    let remainingOnWatch: Int?
}

/// Miroir de `DataFreshness` (`sync.types.ts`) — âge de la donnée la plus
/// récente en base, calculé côté serveur (indépendant de la source active).
struct SettingsSyncFreshness: Decodable, Equatable {
    let at: String?
    let ageSec: Int?
}

/// Miroir de `SyncStatusView` (`sync.types.ts`, `SyncController.status`).
/// `state` vaut `"idle"` / `"running"` / `"ok"` / `"error"`.
struct SettingsSyncStatus: Decodable, Equatable {
    let state: String
    let at: String?
    let lastSuccess: String?
    let message: String?
    let progress: SettingsSyncProgress?
    let freshness: SettingsSyncFreshness
}

// MARK: - `GET /api/sync/inventory`

/// Miroir de la forme renvoyée par `SyncController.inventory()` — objet
/// littéral (pas de type nommé côté Nest). Purement informatif dans cet
/// écran : chargé en best-effort, une panne ne bloque pas le reste de la
/// page (cf. `SettingsViewModel.loadInventory`).
struct SettingsSyncInventory: Decodable, Equatable {
    let onDisk: Int
    let activities: Int
    let sleepFiles: Int
    let wellnessFiles: Int
    let unaccounted: Int
    let nights: Int
    let days: Int
}

// MARK: - `GET /api/profile`, `PUT /api/profile`

/// Miroir de `Profile` (`profile.controller.ts`). `sex` vaut `"male"` /
/// `"female"` / `nil` (jamais renseigné). `weightKg` est en lecture seule ici
/// — la saisie du poids se fait jour par jour sur la page Santé (note
/// affichée par `SettingsComponent`, `<app-sheet title="Profil">`), cet écran
/// ne l'édite pas.
struct SettingsProfile: Decodable, Equatable {
    let birthYear: Int?
    let sex: String?
    let weightKg: Double?
    let heightCm: Double?
}

/// Corps de `PUT /api/profile` — mêmes trois champs que
/// `SettingsComponent.saveProfile()` (Angular) envoie (`birthYear`, `sex`,
/// `heightCm` si renseignée) ; jamais `weightKg` depuis cet écran. Les
/// propriétés `Optional` sont omises du JSON par l'encodage synthétisé
/// (`encodeIfPresent`, cf. `NutritionLogRequest` et ses tests) plutôt
/// qu'envoyées en `null`.
struct SettingsProfileUpdateRequest: Encodable {
    var birthYear: Int?
    var sex: String?
    var heightCm: Double?
}
