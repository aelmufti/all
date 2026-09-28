//
//  LocalPulseBackend.swift
//  all (bridge-connect)
//
//  Portage réel du backend local « Pulse embarqué » (incréments L1+L2, cf.
//  `docs/stockage-local.md`) — remplace `StubLocalPulseBackend` (L0) pour les
//  routes qu'il sait vraiment servir depuis `LocalDb`. Toute autre route
//  continue de lever `LocalPulseUnavailableError` (`Pulse/Core/PulseAPIClient.swift`),
//  à faire pour L3+ (sommeil détaillé/export, SpO2 report, poids…).
//
//  Portée L1 : `GET api/wellness/days`, `GET api/wellness/dates`.
//
//  Portée L2 : `GET api/wellness/day/:date` (dont `bodyBatteryPivot`, portage
//  du simulateur `body-battery.ts` — cf. `Local/BodyBattery.swift` et
//  `LocalDb.pivotSeries`/`bodyBatteryStart`) ; `GET api/activities` en stub
//  minimal (`{total:0, items:[]}` — la table `activities`/GPS est L3, mais
//  `HomeViewModel.load()` attend cette route pour ne PAS échouer tout
//  l'écran Accueil, cf. rapport d'incrément L2).
//  `activities`/`sportCalories` dans `day/:date` restent aussi à `[]`/`0` pour
//  la même raison (pas de table `activities` locale encore).
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

        case ("GET", "activities"):
            // Stub minimal — cf. en-tête de fichier : sans cette route,
            // `HomeViewModel.load()` échoue tout l'écran Accueil (elle attend
            // `api/activities` dans le même bloc `try` que `wellness/day`, pas
            // en "best-effort"). Vraie implémentation = L3.
            return try JSONEncoder().encode(LocalActivityListDTO(total: 0, items: []))

        case ("GET", let r) where r.hasPrefix("wellness/day/"):
            let date = String(r.dropFirst("wellness/day/".count))
            return try encodeDayDetail(date: date)

        default:
            throw LocalPulseUnavailableError()
        }
    }

    private static let datePattern = try! NSRegularExpression(pattern: #"^\d{4}-\d{2}-\d{2}$"#)

    private func encodeDayDetail(date: String) throws -> Data {
        let range = NSRange(date.startIndex..<date.endIndex, in: date)
        guard Self.datePattern.firstMatch(in: date, range: range) != nil else {
            throw LocalPulseUnavailableError()
        }
        let detail = try db.dayDetail(date: date)
        return try JSONEncoder().encode(LocalWellnessDayDetailDTO(detail))
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

// MARK: - DTO d'encodage JSON — `GET wellness/day/:date` (incrément L2)
//
// Même forme que le corps renvoyé par `WellnessController.day` — mêmes clés
// que `WellnessDayDetail`/`WellnessDaySummary`/`WellnessDaySleep`/`WellnessSample`
// (`Pulse/Screens/Health/HealthModels.swift`), consommées aussi par le
// sous-ensemble `HomeDayDetail` de l'Accueil (`Pulse/Screens/Home/HomeModels.swift`
// — mêmes clés, moins `summary.bodyBattery*`/`sportCalories`, `bodyBatteryPivot`,
// `activities`, `counterSeries`, ignorées par `Decodable` si présentes).

private struct LocalSampleDTO: Encodable {
    let ts: Double
    let value: Double
}

private struct LocalCounterPointDTO: Encodable {
    let minute: Int
    let steps: Double
    let activeCalories: Double
}

private struct LocalSleepIntervalDTO: Encodable {
    let from: Double
    let to: Double
}

private struct LocalSleepStageDTO: Encodable {
    let from: Double
    let to: Double
    let stage: String
}

private struct LocalSleepMainDTO: Encodable {
    let from: Double
    let to: Double
    let durationS: Double
}

private struct LocalDaySleepDTO: Encodable {
    let segments: [LocalSleepIntervalDTO]
    let main: LocalSleepMainDTO?
    let stages: [LocalSleepStageDTO]
    let score: Double?
}

/// Toujours `[]` en L2 — pas de table `activities` locale (L3). Le type
/// existe (plutôt qu'un `[Int]` vide arbitraire) pour rester prêt côté forme
/// JSON le jour où L3 la peuple.
private struct LocalActivityDTO: Encodable {
    let id: Int
    let sport: String?
    let subSport: String?
    let startTs: Double
    let durationS: Double?
    let calories: Double?
}

private struct LocalActivityListDTO: Encodable {
    let total: Int
    let items: [LocalActivityDTO]
}

/// `bodyBatteryHigh`/`bodyBatteryLow` : toujours `nil` — miroir fidèle du
/// serveur, qui ne les calcule PAS dans `day()` (contrairement à `days()`) ;
/// la colonne `wellness_days.body_battery_high/low` d'où ils viendraient
/// sinon n'est écrite nulle part côté ingestion serveur non plus (vérifié :
/// aucun `INSERT`/`UPDATE` sur ces colonnes dans `custom-connect/server/src`).
private struct LocalWellnessDaySummaryDTO: Encodable {
    let restingHr: Double?
    let bmrKcal: Double?
    let bodyBatteryHigh: Double?
    let bodyBatteryLow: Double?
    let steps: Double?
    let activeCalories: Double?
    let distanceM: Double?
    let sportCalories: Double?
}

private struct LocalWellnessDayDetailDTO: Encodable {
    let date: String
    let summary: LocalWellnessDaySummaryDTO
    let counterSeries: [LocalCounterPointDTO]
    let hr: [LocalSampleDTO]
    let stress: [LocalSampleDTO]
    let spo2: [LocalSampleDTO]
    let respiration: [LocalSampleDTO]
    let bodyBatteryPivot: [LocalSampleDTO]
    let activities: [LocalActivityDTO]
    let sleep: LocalDaySleepDTO

    init(_ detail: LocalDb.DayDetail) {
        date = detail.date
        summary = LocalWellnessDaySummaryDTO(
            restingHr: detail.restingHr, bmrKcal: detail.bmrKcal,
            bodyBatteryHigh: nil, bodyBatteryLow: nil,
            steps: detail.steps, activeCalories: detail.activeCalories, distanceM: detail.distanceM,
            // Toujours 0 en L2 — miroir de `sportCalories` côté serveur
            // (`SUM(activities.calories)`), pas de table `activities` locale (L3).
            sportCalories: 0)
        counterSeries = detail.counterSeries.map {
            LocalCounterPointDTO(minute: $0.minute, steps: $0.steps, activeCalories: $0.activeCalories)
        }
        hr = detail.hr.map { LocalSampleDTO(ts: $0.ts, value: $0.value) }
        stress = detail.stress.map { LocalSampleDTO(ts: $0.ts, value: $0.value) }
        spo2 = detail.spo2.map { LocalSampleDTO(ts: $0.ts, value: $0.value) }
        respiration = detail.respiration.map { LocalSampleDTO(ts: $0.ts, value: $0.value) }
        bodyBatteryPivot = detail.bodyBatteryPivot.map { LocalSampleDTO(ts: $0.ts, value: $0.value) }
        activities = []
        sleep = LocalDaySleepDTO(
            segments: detail.sleepSegments.map { LocalSleepIntervalDTO(from: $0.from, to: $0.to) },
            main: detail.sleepMain.map { LocalSleepMainDTO(from: $0.from, to: $0.to, durationS: $0.durationS) },
            stages: detail.sleepStages.map { LocalSleepStageDTO(from: $0.from, to: $0.to, stage: $0.stage) },
            score: detail.sleepScore)
    }
}
