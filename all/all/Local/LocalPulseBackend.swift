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
//  `LocalDb.pivotSeries`/`bodyBatteryStart`).
//
//  Portée L3 (cf. `docs/stockage-local.md`) : `GET api/activities` (liste
//  réelle, `activities`/`LocalDb.activities(limit:offset:)`) et
//  `GET api/activities/:id` (détail — résumé + flux/segments recalculés à la
//  volée depuis le `.fit` brut retrouvé dans le spool, cf.
//  `findSpoolFileURL`/`FitActivityExtractor`, miroir de
//  `ActivitiesController.detail`). `activities`/`sportCalories` dans
//  `day/:date` restent `[]`/`0` (pas dans le périmètre de `WellnessController.day`
//  ni côté serveur, cf. commentaire déjà présent sur `LocalWellnessDayDetailDTO`).
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
    /// Source des octets bruts `.fit` pour `GET api/activities/:id`
    /// (`findSpoolFileURL`) — `nil` si `SpoolStore` n'a pas pu s'ouvrir (même
    /// politique de repli que `LocalDb`, cf. `LocalPulseBackendFactory`) :
    /// le détail retombe alors systématiquement sur la branche « fichier
    /// absent » (résumé seul), jamais un crash.
    private let spool: SpoolStore?

    init() throws {
        db = try LocalDb()
        spool = try? SpoolStore()
    }

    /// Init testable : base (et spool, optionnel) déjà construits (fichiers
    /// temporaires en test).
    init(db: LocalDb, spool: SpoolStore? = nil) {
        self.db = db
        self.spool = spool
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
            return try encodeActivityList(query: query)

        case ("GET", let r) where r.hasPrefix("activities/"):
            return try encodeActivityDetail(idString: String(r.dropFirst("activities/".count)))

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

    // MARK: - Activités (incrément L3, miroir `ActivitiesController.list`/`detail`)

    /// Même bornage que `ActivitiesController.list` (`limit` 1...500, défaut
    /// 50 ; `offset` ≥ 0, défaut 0).
    private func encodeActivityList(query: [String: String]) throws -> Data {
        let requestedLimit = query["limit"].flatMap(Int.init) ?? 50
        let limit = min(max(requestedLimit, 1), 500)
        let requestedOffset = query["offset"].flatMap(Int.init) ?? 0
        let offset = max(requestedOffset, 0)

        let total = try db.activitiesCount()
        let items = try db.activities(limit: limit, offset: offset).map(LocalActivityListItemDTO.init)
        return try JSONEncoder().encode(LocalActivityListResponseDTO(total: total, items: items))
    }

    /// Miroir de `ActivitiesController.detail` : id inconnu → erreur propre
    /// (`LocalActivityNotFoundError`, équivalent du `NotFoundException`
    /// Nest) ; id connu mais `.fit` brut introuvable dans le spool → résumé
    /// seul avec flux/segments vides (`track: []`, `streams: null`), miroir
    /// EXACT de la branche `!fs.existsSync(filePath)` côté serveur.
    private func encodeActivityDetail(idString: String) throws -> Data {
        guard let id = Int(idString), let found = try db.activity(id: id) else {
            throw LocalActivityNotFoundError(idString: idString)
        }
        guard let fileURL = findSpoolFileURL(hash: found.fileHash) else {
            return try JSONEncoder().encode(LocalActivityDetailDTO(
                row: found.row, track: [], streams: nil, laps: [], sets: [], splits: [], hrZones: []))
        }
        // Pas de garde try/catch ici : un `.fit` illisible/corrompu doit
        // remonter une erreur exploitable à l'écran (`ActivityDetailViewModel`
        // l'affiche via `error.localizedDescription`, cf. `FitDecodeError`),
        // pas un détail silencieusement vide — même esprit que le serveur, où
        // un `parseDetail` en échec produirait une exception non rattrapée.
        let data = try Data(contentsOf: fileURL)
        let file = try FitDecoder.decode(data)
        let detail = FitActivityExtractor.extractDetail(messages: file.messages)
        return try JSONEncoder().encode(LocalActivityDetailDTO(row: found.row, detail: detail))
    }

    /// Retrouve les octets bruts d'une activité par son hash — le spool
    /// (`SpoolStore.entries`) est indexé par identité MONTRE
    /// (`WatchFileID`), pas par hash de contenu, donc pas de raccourci : on
    /// hache chaque entrée à la volée (`PulseUploader.sha256Hex`, même
    /// fonction que `LocalIngestor`) jusqu'à trouver la correspondance.
    /// Coût O(n) sur le nombre d'entrées du spool — acceptable à l'échelle
    /// d'un usage personnel (dizaines à quelques centaines de fichiers), pas
    /// d'index dédié en L3.
    private func findSpoolFileURL(hash: String) -> URL? {
        guard let spool else { return nil }
        for entry in spool.entries.values {
            let url = spool.fileURL(for: entry)
            guard let entryHash = try? PulseUploader.sha256Hex(ofFileAt: url) else { continue }
            if entryHash == hash { return url }
        }
        return nil
    }
}

/// `GET api/activities/:id` sur un id inconnu (absent de `activities`, ou
/// segment non numérique) — miroir de `NotFoundException()` côté Nest
/// (`ActivitiesController.detail`). Message stable, affiché tel quel par
/// `ActivityDetailViewModel` (`error.localizedDescription`).
struct LocalActivityNotFoundError: Error, LocalizedError {
    let idString: String
    var errorDescription: String? { "Activité introuvable (\(idString))." }
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

/// Toujours `[]`, MÊME après L3 : `WellnessController.day` peuple ce champ
/// via `activityIntervals` (une requête par plage horaire sur `activities`,
/// distincte de `ActivitiesController.list`/`detail`) — non porté ici, hors
/// périmètre explicite de la tâche d'incrément L3 (qui ne couvre QUE
/// `api/activities`/`api/activities/:id`, cf. rapport). Lacune connue,
/// assumée : le bloc « activités du jour » de `wellness/day/:date` reste
/// vide en mode Téléphone tant qu'un futur incrément ne porte pas
/// `activityIntervals`. Le type existe (plutôt qu'un `[Int]` vide arbitraire)
/// pour rester prêt côté forme JSON ce jour-là.
private struct LocalActivityDTO: Encodable {
    let id: Int
    let sport: String?
    let subSport: String?
    let startTs: Double
    let durationS: Double?
    let calories: Double?
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
            // Toujours 0, MÊME après L3 : même lacune assumée que le champ
            // `activities` ci-dessus (`sportCalories` serveur vient de
            // `activityIntervals`/la même requête bornée par plage horaire,
            // non portée ici) — cf. commentaire de `LocalActivityDTO`.
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

// MARK: - DTO d'encodage JSON — `GET api/activities`/`GET api/activities/:id` (incrément L3)
//
// Mêmes clés que `Activity`/`ActivityListResponse`/`ActivityStreams`/
// `ActivityLap`/`ActivitySet`/`ActivitySplit`/`HrZone`/`ActivityDetail`
// (`Pulse/Screens/Activities/ActivityModels.swift`) — et, pour la LISTE
// (`id`/`startTime`/`durationS`, sous-ensemble), du `HomeActivity` de
// l'Accueil (`Pulse/Screens/Home/HomeModels.swift`), qui tape la MÊME route.

private struct LocalActivityListItemDTO: Encodable {
    let id: Int
    let fileName: String
    let sport: String?
    let subSport: String?
    let startTime: String?
    let durationS: Double?
    let distanceM: Double?
    let calories: Double?
    let avgHr: Double?
    let maxHr: Double?

    init(_ row: LocalDb.ActivityRow) {
        id = row.id
        fileName = row.fileName
        sport = row.sport
        subSport = row.subSport
        startTime = row.startTime
        durationS = row.durationS
        distanceM = row.distanceM
        calories = row.calories
        avgHr = row.avgHr
        maxHr = row.maxHr
    }
}

private struct LocalActivityListResponseDTO: Encodable {
    let total: Int
    let items: [LocalActivityListItemDTO]
}

private struct LocalActivityStreamsDTO: Encodable {
    let time: [Double?]
    let hr: [Double?]
    let speed: [Double?]
    let altitude: [Double?]
    let distance: [Double?]

    init(_ streams: FitActivityExtractor.Streams) {
        time = streams.time
        hr = streams.hr
        speed = streams.speed
        altitude = streams.altitude
        distance = streams.distance
    }
}

private struct LocalActivityLapDTO: Encodable {
    let index: Int
    let durationS: Double?
    let distanceM: Double?
    let avgHr: Double?
    let maxHr: Double?

    init(_ lap: FitActivityExtractor.Lap) {
        index = lap.index
        durationS = lap.durationS
        distanceM = lap.distanceM
        avgHr = lap.avgHr
        maxHr = lap.maxHr
    }
}

private struct LocalActivitySetDTO: Encodable {
    let index: Int
    let durationS: Double?
    let category: String?
    let repetitions: Double?

    init(_ set: FitActivityExtractor.SetRow) {
        index = set.index
        durationS = set.durationS
        category = set.category
        repetitions = set.repetitions
    }
}

private struct LocalActivitySplitDTO: Encodable {
    let index: Int
    let type: String?
    let durationS: Double?
    let ascentM: Double?
    let descentM: Double?
    let calories: Double?
    let avgVertSpeedMs: Double?

    init(_ split: FitActivityExtractor.Split) {
        index = split.index
        type = split.type
        durationS = split.durationS
        ascentM = split.ascentM
        descentM = split.descentM
        calories = split.calories
        avgVertSpeedMs = split.avgVertSpeedMs
    }
}

private struct LocalHrZoneDTO: Encodable {
    let zone: Int
    let seconds: Double
    let fromBpm: Double?
    let toBpm: Double?

    init(_ zone: FitActivityExtractor.HrZoneRow) {
        self.zone = zone.zone
        seconds = zone.seconds
        fromBpm = zone.fromBpm
        toBpm = zone.toBpm
    }
}

/// `GET api/activities/:id` — résumé (`row`) + flux/segments. `track` reste
/// TOUJOURS `[]` (décision actée de l'incrément L3, cf. en-tête de
/// `FitActivityExtractor.swift`) ; `streams` est `nil` uniquement quand le
/// `.fit` brut n'a pas été retrouvé dans le spool (miroir de la branche
/// `!fs.existsSync` côté serveur), jamais dans le cas contraire.
private struct LocalActivityDetailDTO: Encodable {
    let id: Int
    let fileName: String
    let sport: String?
    let subSport: String?
    let startTime: String?
    let durationS: Double?
    let distanceM: Double?
    let calories: Double?
    let avgHr: Double?
    let maxHr: Double?
    let track: [[Double]]
    let streams: LocalActivityStreamsDTO?
    let laps: [LocalActivityLapDTO]
    let sets: [LocalActivitySetDTO]
    let splits: [LocalActivitySplitDTO]
    let hrZones: [LocalHrZoneDTO]

    /// Fichier brut introuvable dans le spool — résumé seul, tout le reste vide/`nil`.
    init(row: LocalDb.ActivityRow, track: [[Double]], streams: LocalActivityStreamsDTO?,
         laps: [LocalActivityLapDTO], sets: [LocalActivitySetDTO], splits: [LocalActivitySplitDTO],
         hrZones: [LocalHrZoneDTO]) {
        id = row.id
        fileName = row.fileName
        sport = row.sport
        subSport = row.subSport
        startTime = row.startTime
        durationS = row.durationS
        distanceM = row.distanceM
        calories = row.calories
        avgHr = row.avgHr
        maxHr = row.maxHr
        self.track = track
        self.streams = streams
        self.laps = laps
        self.sets = sets
        self.splits = splits
        self.hrZones = hrZones
    }

    /// Fichier brut retrouvé et reparsé — `detail` vient de
    /// `FitActivityExtractor.extractDetail`.
    init(row: LocalDb.ActivityRow, detail: FitActivityExtractor.Detail) {
        self.init(
            row: row, track: detail.track,
            streams: LocalActivityStreamsDTO(detail.streams),
            laps: detail.laps.map(LocalActivityLapDTO.init),
            sets: detail.sets.map(LocalActivitySetDTO.init),
            splits: detail.splits.map(LocalActivitySplitDTO.init),
            hrZones: detail.hrZones.map(LocalHrZoneDTO.init))
    }
}
