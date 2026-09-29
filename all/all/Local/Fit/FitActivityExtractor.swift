//
//  FitActivityExtractor.swift
//  all (bridge-connect)
//
//  Portage Swift de `FitParserService.extractSummary`/`parseDetail`
//  (`custom-connect/server/src/ingest/fit-parser.service.ts`) — incrément L3,
//  cf. `docs/stockage-local.md`. Opère sur la sortie générique de
//  `FitDecoder` ([FitMessage]), comme `FitWellnessExtractor`.
//
//  Divergence assumée vs le serveur : le `track` (parcours GPS) n'est PAS
//  extrait — `positionLat`/`positionLong` ne sont même pas dans le profil
//  (`FitProfile`, cf. son en-tête). Décision actée de la tâche d'incrément :
//  `ActivityDetail.track` reste toujours `[]` en mode Téléphone (pas de
//  road-snapping/carte type `activity_tracks`/`activity_edges`, hors
//  périmètre). Conséquence à connaître : `ActivityDetailView` masque alors la
//  carte (`detail.track.count > 1`) ET l'onglet de courbe « Altitude »
//  (`!detail.track.isEmpty` fait aussi partie de sa garde), même si le flux
//  `streams.altitude` ci-dessous est, lui, bien peuplé — cf. rapport
//  d'incrément.
//
//  Pas de mécanisme de "composants" FIT (dérivation bits d'un champ vers un
//  autre) — cf. commentaire de `FitProfile.table[mesgRecord]` : les 3
//  échantillons d'activité disponibles montrent que la Venu 2 n'émet que les
//  champs `enhanced*`, donc les décoder séparément avec repli
//  (`enhanced* ?? legacy`) suffit à reproduire le comportement observé du SDK.
//

import Foundation

enum FitActivityExtractor {
    // MARK: - Modèles de sortie (miroir des interfaces TS `ActivitySummary`/`ActivityDetail`)

    struct Summary {
        let sport: String?
        let subSport: String?
        /// ISO 8601 complet (`new Date(...).toISOString()` côté TS) — jamais
        /// un `Date` (règle du socle, cf. commentaire de `PulseAPIClient.decoder`).
        let startTime: String?
        let durationS: Double?
        let distanceM: Double?
        let calories: Double?
        let avgHr: Double?
        let maxHr: Double?
    }

    struct Streams {
        let time: [Double?]
        let hr: [Double?]
        let speed: [Double?]
        let altitude: [Double?]
        let distance: [Double?]
    }

    struct Lap {
        let index: Int
        let durationS: Double?
        let distanceM: Double?
        let avgHr: Double?
        let maxHr: Double?
    }

    struct SetRow {
        let index: Int
        let durationS: Double?
        let category: String?
        let repetitions: Double?
    }

    struct Split {
        let index: Int
        let type: String?
        let durationS: Double?
        let ascentM: Double?
        let descentM: Double?
        let calories: Double?
        let avgVertSpeedMs: Double?
    }

    struct HrZoneRow {
        let zone: Int
        let seconds: Double
        let fromBpm: Double?
        let toBpm: Double?
    }

    struct Detail {
        let streams: Streams
        let laps: [Lap]
        let sets: [SetRow]
        let splits: [Split]
        let hrZones: [HrZoneRow]
    }

    /// Nombre max de points de flux — miroir de `MAX_POINTS` (TS). Aucun des
    /// 3 échantillons d'activité (jusqu'à 1726 `recordMesgs`) ne dépasse ce
    /// seuil, mais le downsample reste porté pour les activités plus longues.
    private static let maxStreamPoints = 2000

    // MARK: - `extractSummary` (miroir `FitParserService.extractSummary`)

    static func extractSummary(messages: [FitMessage]) -> Summary {
        if let session = messages.first(where: { $0.globalMessageNumber == FitProfile.mesgSession }) {
            return Summary(
                sport: session.double(5).map(FitProfile.sportName),
                subSport: session.double(6).map(FitProfile.subSportName),
                startTime: session.double(2).map(isoDateTime),
                durationS: session.double(8) ?? session.double(7), // totalTimerTime ?? totalElapsedTime
                distanceM: session.double(9),
                calories: session.double(11),
                avgHr: session.double(16),
                maxHr: session.double(17))
        }
        // Repli sans session — miroir de la branche TS correspondante
        // (aucun de nos 3 échantillons ne l'emprunte, mais un fichier
        // d'activité sans `sessionMesgs` reste possible en théorie).
        let firstRecord = messages.first { $0.globalMessageNumber == FitProfile.mesgRecord }
        let activity = messages.first { $0.globalMessageNumber == FitProfile.mesgActivity }
        let sport = messages.first { $0.globalMessageNumber == FitProfile.mesgSport }
        let startFit = firstRecord?.double(253) ?? activity?.double(253)
        return Summary(
            sport: sport?.double(0).map(FitProfile.sportName),
            subSport: sport?.double(1).map(FitProfile.subSportName),
            startTime: startFit.map(isoDateTime),
            durationS: activity?.double(0),
            distanceM: nil,
            calories: nil,
            avgHr: nil,
            maxHr: nil)
    }

    // MARK: - `parseDetail` (streams/laps/sets/splits/hrZones — PAS le `track`, cf. en-tête)

    static func extractDetail(messages: [FitMessage]) -> Detail {
        let records = messages.filter { $0.globalMessageNumber == FitProfile.mesgRecord }
        let sampled = downsample(records, max: maxStreamPoints)
        let startTs = records.first?.double(253)

        var time: [Double?] = []
        var hr: [Double?] = []
        var speed: [Double?] = []
        var altitude: [Double?] = []
        var distance: [Double?] = []
        time.reserveCapacity(sampled.count)
        hr.reserveCapacity(sampled.count)
        speed.reserveCapacity(sampled.count)
        altitude.reserveCapacity(sampled.count)
        distance.reserveCapacity(sampled.count)

        for record in sampled {
            let ts = record.double(253)
            time.append(ts != nil && startTs != nil ? ts! - startTs! : nil)
            hr.append(record.double(3))
            speed.append(record.double(73) ?? record.double(6)) // enhancedSpeed ?? speed
            altitude.append(record.double(78) ?? record.double(2)) // enhancedAltitude ?? altitude
            distance.append(record.double(5))
        }

        return Detail(
            streams: Streams(time: time, hr: hr, speed: speed, altitude: altitude, distance: distance),
            laps: extractLaps(messages),
            sets: extractSets(messages),
            splits: extractSplits(messages),
            hrZones: extractHrZones(messages))
    }

    // MARK: - Segments

    private static func extractLaps(_ messages: [FitMessage]) -> [Lap] {
        var out: [Lap] = []
        for lap in messages where lap.globalMessageNumber == FitProfile.mesgLap {
            out.append(Lap(
                index: out.count + 1,
                durationS: lap.double(8) ?? lap.double(7), // totalTimerTime ?? totalElapsedTime
                distanceM: lap.double(9),
                avgHr: lap.double(15),
                maxHr: lap.double(16)))
        }
        return out
    }

    /// Miroir `extractSets` (TS) — ne garde que les séries "actives" (jamais
    /// les paliers de repos, `setType == 0`), catégorie = premier élément
    /// nommé et différent d'« unknown » du tableau `category`.
    private static func extractSets(_ messages: [FitMessage]) -> [SetRow] {
        var out: [SetRow] = []
        for set in messages where set.globalMessageNumber == FitProfile.mesgSet {
            guard set.double(5) == FitProfile.setTypeActive else { continue }
            let named = set.numberList(7)
                .map(FitProfile.exerciseCategoryName)
                .first { $0 != "unknown" }
            out.append(SetRow(
                index: out.count + 1,
                durationS: set.double(0),
                category: named,
                repetitions: set.double(3)))
        }
        return out
    }

    private static func extractSplits(_ messages: [FitMessage]) -> [Split] {
        var out: [Split] = []
        for split in messages where split.globalMessageNumber == FitProfile.mesgSplit {
            out.append(Split(
                index: out.count + 1,
                type: split.double(0).map(FitProfile.splitTypeName),
                durationS: split.double(2) ?? split.double(1), // totalTimerTime ?? totalElapsedTime
                ascentM: split.double(13),
                descentM: split.double(14),
                calories: split.double(28),
                avgVertSpeedMs: split.double(26)))
        }
        return out
    }

    /// Miroir `extractHrZones` (TS) : `timeInZoneMesgs` de référence
    /// "session" en priorité, sinon "lap" — `referenceMesg` (champ 0) est le
    /// numéro de message global brut (18/19), pas un nom, donc comparaison
    /// directe aux constantes `FitProfile.mesgSession`/`mesgLap` (aucune
    /// table de noms nécessaire pour ce champ précis).
    private static func extractHrZones(_ messages: [FitMessage]) -> [HrZoneRow] {
        let all = messages.filter { $0.globalMessageNumber == FitProfile.mesgTimeInZone }
        let session = all.first { $0.double(0) == Double(FitProfile.mesgSession) }
            ?? all.first { $0.double(0) == Double(FitProfile.mesgLap) }
        guard let session else { return [] }

        let times = session.numberList(2) // timeInHrZone
        let bounds = session.numberList(6) // hrZoneHighBoundary
        guard times.count > 1 else { return [] }
        var out: [HrZoneRow] = []
        for i in 1..<times.count {
            out.append(HrZoneRow(
                zone: i,
                seconds: times[i],
                fromBpm: bounds.indices.contains(i - 1) ? bounds[i - 1] : nil,
                toBpm: bounds.indices.contains(i) ? bounds[i] : nil))
        }
        while let last = out.last, last.seconds == 0, last.toBpm == nil {
            out.removeLast()
        }
        return out
    }

    // MARK: - Utilitaires

    /// Miroir exact de `downsample` (TS, `fit-parser.service.ts`) : garde le
    /// dernier point tel quel après le rééchantillonnage régulier (jamais
    /// tronqué avant la fin réelle de l'activité).
    private static func downsample<T>(_ items: [T], max: Int) -> [T] {
        guard items.count > max else { return items }
        let step = Double(items.count) / Double(max)
        var result: [T] = []
        result.reserveCapacity(max)
        for i in 0..<max {
            result.append(items[Int((Double(i) * step).rounded(.down))])
        }
        result[result.count - 1] = items[items.count - 1]
        return result
    }

    private static let isoDateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        return formatter
    }()

    /// `new Date((FIT_EPOCH_S + value) * 1000).toISOString()` — réutilise
    /// `FitWellnessExtractor.fitEpochS`, même constante que le sommeil/bien-être.
    private static func isoDateTime(_ fitSeconds: Double) -> String {
        isoDateTimeFormatter.string(from: Date(timeIntervalSince1970: fitSeconds + FitWellnessExtractor.fitEpochS))
    }
}
