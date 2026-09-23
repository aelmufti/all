//
//  StatusModels.swift
//  all (bridge-connect)
//
//  Modèles `Decodable`/`Encodable` de l'écran Statut — miroir des formes JSON
//  exposées par NestJS (`custom-connect/server/src/sync/sync.controller.ts`,
//  `sync/sync.types.ts`, `health.controller.ts`) et consommées par la page
//  Angular `/statut` (`status.component.ts`, qui embarque aussi
//  `shared/sync-card.component.ts`).
//
//  Quatre lectures, trois formes de réponse :
//  - `GET api/sync/link` / `POST api/sync/link/connect` → `StatusLinkState`
//    (lien BLE bridge ↔ montre : joignabilité, RSSI, dernière vue, reprise
//    automatique, récupération contrôleur Bluetooth).
//  - `GET api/health/detail` → `StatusHealthDetail` (santé de la synchro
//    automatique : fichiers en attente, blocage, présence de la montre).
//  - `GET api/sync/status` → `StatusSyncStatusView` (état d'une synchro en
//    cours + fraîcheur des données, ce qu'affiche `<app-sync-card>`).
//  - `POST api/sync` → `StatusTriggerResult` (déclenchement manuel).
//
//  Convention socle (cf. `PulseAPIClient.decoder`, pas de stratégie de date) :
//  tous les champs "date" de ces contrôleurs sont des chaînes ISO 8601
//  complètes (`new Date().toISOString()` côté serveur, ex.
//  `bridge-sync.service.ts:347`), jamais des epoch ni des `YYYY-MM-DD`. Ils
//  restent typés `String?` ici ; `StatusDateFormatting` (dans
//  `StatusViewModel.swift`) fait la conversion locale en libellés relatifs
//  ("il y a 2 min"). Les compteurs (`pending`, `cycles`, `failures`,
//  `watchFiles`…) sont des entiers ; le RSSI et la cadence (`intervalMs`)
//  restent `Double` par prudence (valeurs numériques calculées côté serveur,
//  pas des colonnes SQLite entières garanties).
//

import Foundation

// MARK: - Lien BLE (`GET/POST api/sync/link*`)

/// Miroir de `ControllerRecovery` — le contrôleur Bluetooth du serveur peut
/// se bloquer indépendamment de la montre ; une récupération matérielle est
/// alors en cours côté bridge, rien à faire depuis l'app.
struct StatusControllerRecovery: Decodable {
    let inProgress: Bool
    let requestedAt: String?
    let outcome: String?
}

/// Miroir de `LinkHealth`.
struct StatusLinkHealth: Decodable {
    let connected: Bool?
    let lastSeenAt: String?
    let rssi: Double?
    let rssiAt: String?
    let failures: Int?
    let nextAttemptAt: String?
    let error: String?
    let recovery: StatusControllerRecovery?
}

/// Miroir de `LinkState` — réponse de `GET api/sync/link` et
/// `POST api/sync/link/connect`.
struct StatusLinkState: Decodable {
    let reachable: Bool
    let detail: String?
    let link: StatusLinkHealth
}

// MARK: - Santé de la synchro automatique (`GET api/health/detail`)

/// Miroir de `SyncSourceName` — source active pilotant l'ingestion.
enum StatusSyncSourceName: String, Decodable {
    case legacy
    case bridge
    case phone
}

/// Miroir de `DevicePresence`.
enum StatusDevicePresence: String, Decodable {
    case proche
    case absente
    case inconnue
}

/// Miroir de `AutoSyncHealth`.
struct StatusAutoSyncHealth: Decodable {
    let pending: Int
    let stalled: Bool
    let cycles: Int
    let source: StatusSyncSourceName
    let enabled: Bool
    let since: String?
    let reason: String?
    let presence: StatusDevicePresence
    let link: StatusLinkHealth
    let lastSuccess: String?
    let nextAttemptAt: String?
    let intervalMs: Double
}

/// Miroir de la réponse de `HealthController.detail` (`GET api/health/detail`)
/// — `{ status: "ok", sync: AutoSyncHealth }`.
struct StatusHealthDetail: Decodable {
    let status: String
    let sync: StatusAutoSyncHealth
}

// MARK: - État de synchronisation (`GET api/sync/status`, `POST api/sync`)

/// Miroir de `SyncProgress`.
struct StatusSyncProgress: Decodable {
    let startedAt: String?
    let watchFiles: Int?
    let remainingOnWatch: Int?
}

/// Miroir de `DataFreshness`.
struct StatusDataFreshness: Decodable {
    let at: String?
    let ageSec: Int?
}

/// Miroir de `SyncStatus['state']`.
enum StatusSyncState: String, Decodable {
    case idle
    case running
    case ok
    case error
}

/// Miroir de `SyncStatusView` — réponse de `GET api/sync/status`.
struct StatusSyncStatusView: Decodable {
    let state: StatusSyncState
    let at: String?
    let lastSuccess: String?
    let message: String?
    let progress: StatusSyncProgress?
    let freshness: StatusDataFreshness?
}

/// Miroir de `TriggerResult` — réponse de `POST api/sync` (union discriminée
/// côté TS par `status`). `already`/`retryInSec`/`message` ne coexistent
/// jamais tous ensemble en pratique, mais les trois restent `Optional` ici :
/// plus simple qu'un enum à cas associés pour un `Decodable` direct, et le
/// view-model ne lit que le champ pertinent selon `status`.
struct StatusTriggerResult: Decodable {
    enum Status: String, Decodable {
        case pending
        case throttled
        case unavailable
    }

    let status: Status
    let already: Bool?
    let retryInSec: Int?
    let message: String?
}
