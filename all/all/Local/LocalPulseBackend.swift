//
//  LocalPulseBackend.swift
//  all (bridge-connect)
//
//  Portage réel du backend local « Pulse embarqué » (incrément L1, cf.
//  `docs/stockage-local.md`) — remplace `StubLocalPulseBackend` (L0) pour les
//  routes qu'il sait vraiment servir depuis `LocalDb`. Toute autre route
//  continue de lever `LocalPulseUnavailableError` (`Pulse/Core/PulseAPIClient.swift`),
//  à faire pour L2/L3 (`day/:date`, `intensity`, sommeil détaillé, activités…).
//
//  Portée L1 : `GET api/wellness/days`, `GET api/wellness/dates`. `day/:date`
//  est DIFFÉRÉ à L2 (cf. rapport d'incrément) : sa forme JSON reproduit aussi
//  `bodyBatteryPivot` (simulateur physiologique complet,
//  `WellnessController.pivotSeries`/`body-battery.ts`) et les activités —
//  aucun des deux n'entre dans le périmètre bien-être minimal de L1.
//

import Foundation
import os

/// Construit le backend local par défaut de `PulseAPIClient.shared` :
/// `RealLocalPulseBackend` si `LocalDb` s'ouvre (cas normal), sinon
/// `StubLocalPulseBackend` en repli (ex. `Application Support` inaccessible)
/// — jamais un crash au lancement pour une base locale qui ne sert qu'au
/// mode Téléphone/Les deux (`StorageModeStore`), potentiellement jamais
/// activé par l'utilisateur.
enum LocalPulseBackendFactory {
    private static let log = Logger(subsystem: "CleanYourRoom.all", category: "local-backend")

    static func make() -> LocalPulseBackend {
        do {
            return try RealLocalPulseBackend()
        } catch {
            log.error("LocalDb indisponible, repli sur StubLocalPulseBackend : \(error.localizedDescription, privacy: .public)")
            return StubLocalPulseBackend()
        }
    }
}

final class RealLocalPulseBackend: LocalPulseBackend {
    private let db: LocalDb

    init() throws {
        db = try LocalDb()
    }

    /// Init testable : base déjà construite (fichier temporaire en test).
    init(db: LocalDb) {
        self.db = db
    }

    func handle(method: String, path: String, query: [String: String], body: Data?) throws -> Data {
        let route = path.hasPrefix("api/") ? String(path.dropFirst(4)) : path

        switch (method, route) {
        case ("GET", "wellness/dates"):
            return try JSONEncoder().encode(db.dates())

        case ("GET", "wellness/days"):
            // Même bornage que `WellnessController.days` (`limit`, 1...3660,
            // défaut 30) — `days` (fenêtre glissante en jours) n'est PAS
            // reproduit ici : en L1 l'historique local est de toute façon
            // borné à ce que le spool contient, `limit` suffit à cadrer
            // l'affichage (cf. rapport d'incrément).
            let requested = query["limit"].flatMap(Int.init) ?? 30
            let limit = min(max(requested, 1), 3660)
            let rows = try db.days(limit: limit)
            return try JSONEncoder().encode(rows.map(LocalWellnessDayRowDTO.init))

        default:
            throw LocalPulseUnavailableError()
        }
    }
}

/// DTO d'encodage JSON — mêmes clés que `WellnessDayRow`
/// (`Pulse/Screens/Health/HealthModels.swift`) et son sous-ensemble
/// `DashboardWellnessDayRow` (`Pulse/Screens/Dashboard/DashboardModels.swift`),
/// pour que `PulseAPIClient.decoder` décode ce JSON exactement comme une
/// réponse serveur — les écrans ne savent jamais que la réponse vient d'ici.
/// `bodyBatteryHigh`/`bodyBatteryLow`/`sportCalories` : toujours absents
/// (`nil`, encodés comme `null`) — non implémentés en L1 (cf. rapport :
/// nécessitent respectivement le simulateur "pivot" et les activités,
/// `wellness/body-battery.ts`, `activities` table — L3+/L4). Les deux
/// modèles côté écran les typent `Optional`, `null` décode donc sans erreur.
private struct LocalWellnessDayRowDTO: Encodable {
    let date: String
    let restingHr: Double?
    let bmrKcal: Double?
    let steps: Double?
    let activeCalories: Double?
    let distanceM: Double?
    let minHr: Double?
    let maxHr: Double?
    let avgStress: Double?
    let bodyBatteryHigh: Double?
    let bodyBatteryLow: Double?
    let sleepDurationS: Double?
    let sleepScore: Double?
    let sportCalories: Double?

    init(_ row: LocalDb.DayRow) {
        date = row.date
        restingHr = row.restingHr
        bmrKcal = row.bmrKcal
        steps = row.steps
        activeCalories = row.activeCalories
        distanceM = row.distanceM
        minHr = row.minHr
        maxHr = row.maxHr
        avgStress = row.avgStress
        bodyBatteryHigh = nil
        bodyBatteryLow = nil
        sleepDurationS = row.sleepDurationS
        sleepScore = row.sleepScore
        sportCalories = nil
    }
}
