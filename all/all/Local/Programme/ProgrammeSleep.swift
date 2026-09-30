//
//  ProgrammeSleep.swift
//  all (bridge-connect)
//
//  Portage Swift de `custom-connect/server/src/programme/sleep.ts`
//  (incrément L7a, cf. `docs/stockage-local.md`) : analyse de régularité du
//  sommeil (moyenne/écart-type circulaires de l'heure de coucher/réveil,
//  décalage social, rattrapage, indice de régularité SRI) sur la fenêtre des
//  14 dernières nuits (`windowNights`). Câblé depuis `RealLocalPulseBackend`
//  pour le domaine `sleep` de `GET api/programme` (`ProgrammeCatalogue.sleepRegularity`).
//
//  `offsetOf` (décalage fuseau par date) est injecté par l'appelant —
//  `RealLocalPulseBackend` passe `LocalDb.localOffsetSeconds(forDate:)`, la
//  MÊME formule que `dayDetail`/`days`, plutôt que d'en dupliquer une copie
//  ici (accès relâché à `internal` sur `LocalDb.localOffsetSeconds`, cf.
//  commentaire dédié dans `LocalDb.swift`).
//

import Foundation

// MARK: - Types d'entrée/sortie (miroir `SleepNightRow`/`NightPoint`/
// `SleepMetricProgress`/`SleepAxis`/`SleepReport`)

struct ProgrammeEngineSleepNightRow {
    let date: String
    let startTs: Double
    let endTs: Double
    let sleepS: Double
    let phases: String?
}

struct ProgrammeEngineNightPoint {
    let date: String
    let weekday: Int
    let workDay: Bool
    let onset: Double
    let wake: Double
    let sleepMin: Double
}

struct ProgrammeEngineSleepMetricProgress {
    let key: String
    let label: String
    let detail: String
    let evidence: String
    let unit: ProgrammeEngineSleepUnit
    let informative: Bool
    let value: Double?
    let rangeMin: Double?
    let rangeMax: Double?
    let scaleMin: Double
    let scaleMax: Double
    let status: ProgrammeEngineStatus
    let band: ProgrammeEngineSleepBand?
    let note: String?
}

struct ProgrammeEngineSleepAxis {
    let onsetMean: Double
    let onsetSd: Double
    let wakeMean: Double
    let wakeSd: Double
}

struct ProgrammeEngineSleepReport {
    let from: String?
    let to: String?
    let nights: Int
    let spanDays: Int
    let staleDays: Int
    let workNights: Int
    let freeNights: Int
    let pairs: Int
    let axis: ProgrammeEngineSleepAxis?
    let strip: [ProgrammeEngineNightPoint]
    let metrics: [ProgrammeEngineSleepMetricProgress]
    let hits: Int
    let total: Int
}

enum ProgrammeSleepEngine {
    /// Miroir de `SLEEP_WINDOW_NIGHTS` (TS).
    static let windowNights = 14

    private static let axisOrigin = 720.0
    private static let minutesPerDay = 1440.0
    private static let minNights = 7
    private static let minGroupNights = 2
    private static let minPairs = 4
    private static let shortNightMin = 420.0

    private struct Spread {
        let mean: Double
        let sd: Double
    }

    private static let dateOfMinuteFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    /// Miroir de `localMinuteOfDay` (TS).
    static func localMinuteOfDay(ts: Double, offsetS: Double) -> Double {
        let local = ((ts + offsetS) / 60).rounded(.down)
        return (local.truncatingRemainder(dividingBy: minutesPerDay) + minutesPerDay).truncatingRemainder(dividingBy: minutesPerDay)
    }

    /// Miroir de `axisMinute` (TS).
    static func axisMinute(ts: Double, offsetS: Double) -> Double {
        (localMinuteOfDay(ts: ts, offsetS: offsetS) + axisOrigin).truncatingRemainder(dividingBy: minutesPerDay)
    }

    /// Miroir de `clockSpread` (TS) — moyenne/écart-type circulaires (heure
    /// d'horloge, on ne peut pas moyenner naïvement autour de minuit).
    private static func clockSpread(_ values: [Double]) -> Spread? {
        guard values.count >= 2 else { return nil }
        let turn = Double.pi * 2
        var sinSum = 0.0, cosSum = 0.0
        for value in values {
            let angle = (value / minutesPerDay) * turn
            sinSum += sin(angle)
            cosSum += cos(angle)
        }
        let meanAngle = atan2(sinSum / Double(values.count), cosSum / Double(values.count))
        let mean = (((meanAngle / turn) * minutesPerDay).truncatingRemainder(dividingBy: minutesPerDay) + minutesPerDay)
            .truncatingRemainder(dividingBy: minutesPerDay)
        var squares = 0.0
        for value in values {
            var gap = value - mean
            while gap > minutesPerDay / 2 { gap -= minutesPerDay }
            while gap <= -minutesPerDay / 2 { gap += minutesPerDay }
            squares += gap * gap
        }
        return Spread(mean: mean, sd: (squares / Double(values.count - 1)).squareRoot())
    }

    /// Miroir de `linearSpread` (TS).
    private static func linearSpread(_ values: [Double]) -> Spread? {
        guard values.count >= 2 else { return nil }
        let mean = values.reduce(0, +) / Double(values.count)
        let squares = values.reduce(0.0) { $0 + pow($1 - mean, 2) }
        return Spread(mean: mean, sd: (squares / Double(values.count - 1)).squareRoot())
    }

    private static func average(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    /// Miroir de `parsePhases` (TS) — même idiome que `LocalDb`'s
    /// `decodePhases` (JSON array `{from,to,stage}`), dupliqué ici plutôt que
    /// partagé (fichier différent, fonction privée côté `LocalDb`).
    private static func parsePhases(_ raw: String?) -> [(from: Double, to: Double, stage: String)] {
        guard let raw, let data = raw.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
        return array.compactMap { dict in
            guard let from = dict["from"] as? Double, let to = dict["to"] as? Double, let stage = dict["stage"] as? String
            else { return nil }
            return (from, to, stage)
        }
    }

    /// Miroir de `dateOfMinute` (TS) — `minute` = minutes entières depuis
    /// l'epoch Unix (PAS minute du jour).
    private static func dateOfMinute(_ minute: Int) -> String {
        dateOfMinuteFormatter.string(from: Date(timeIntervalSince1970: Double(minute) * 60))
    }

    /// Miroir de `sleepRegularityIndex` (TS) — compare minute par minute
    /// l'état veille/sommeil d'un jour et du suivant, sur toutes les paires de
    /// jours consécutifs couverts par `nights`.
    static func sleepRegularityIndex(
        nights: [ProgrammeEngineSleepNightRow], offsetOf: (String) -> Double
    ) -> (value: Double?, pairs: Int) {
        var asleep: [String: [UInt8]] = [:]
        let recorded = Set(nights.map { $0.date })
        let minutesPerDayInt = Int(minutesPerDay)

        for night in nights {
            let offset = offsetOf(night.date)
            for phase in parsePhases(night.phases) where phase.stage != "awake" {
                let from = Int(((phase.from + offset) / 60).rounded(.down))
                let to = Int(((phase.to + offset) / 60).rounded(.up))
                guard to > from else { continue }
                for minute in from..<to {
                    let date = dateOfMinute(minute)
                    var mask = asleep[date] ?? [UInt8](repeating: 0, count: minutesPerDayInt)
                    let idx = ((minute % minutesPerDayInt) + minutesPerDayInt) % minutesPerDayInt
                    mask[idx] = 1
                    asleep[date] = mask
                }
            }
        }

        func covered(_ date: String) -> Bool {
            recorded.contains(date) && recorded.contains(ProgrammeProgressEngine.addDays(date, 1))
        }

        var pairs = 0
        var matches = 0
        for night in nights {
            let day = night.date
            let next = ProgrammeProgressEngine.addDays(day, 1)
            guard covered(day), covered(next), let left = asleep[day], let right = asleep[next] else { continue }
            pairs += 1
            for minute in 0..<minutesPerDayInt where left[minute] == right[minute] { matches += 1 }
        }
        guard pairs >= minPairs else { return (nil, pairs) }
        return (-100 + (200 / (Double(pairs) * minutesPerDay)) * Double(matches), pairs)
    }

    private static func bandFor(_ value: Double?, _ bands: [ProgrammeEngineSleepBand]) -> ProgrammeEngineSleepBand? {
        guard let value, !bands.isEmpty else { return nil }
        return bands.first { $0.upTo == nil || value <= $0.upTo! }
    }

    private static func statusFor(_ value: Double?, _ min: Double?, _ max: Double?) -> ProgrammeEngineStatus {
        guard let value else { return .unknown }
        if min == nil && max == nil { return .unknown }
        if let min, value < min { return .under }
        if let max, value > max { return .over }
        return .hit
    }

    private static func shortNights(_ count: Int) -> String { "\(count) nuit\(count > 1 ? "s" : "")" }
    private static func asMinutes(_ minutes: Double) -> String { "\(Int(minutes.rounded())) min" }

    private static func asDuration(_ minutes: Double) -> String {
        let rounded = Int(abs(minutes).rounded())
        let hours = rounded / 60
        let rest = rounded % 60
        if hours == 0 { return "\(rest) min" }
        return rest != 0 ? "\(hours) h \(String(format: "%02d", rest))" : "\(hours) h"
    }

    /// Miroir de `asClock` (TS).
    static func asClock(_ axisMinutes: Double) -> String {
        let wrapped = (axisMinutes.truncatingRemainder(dividingBy: minutesPerDay) + minutesPerDay).truncatingRemainder(dividingBy: minutesPerDay)
        let minuteOfDay = ((wrapped + axisOrigin).truncatingRemainder(dividingBy: minutesPerDay)).rounded()
        let hours = Int(minuteOfDay / 60) % 24
        let mins = Int(minuteOfDay) % 60
        return "\(hours) h \(String(format: "%02d", mins))"
    }

    private static func daysBetween(_ from: String, _ to: String) -> Int {
        guard let f = ProgrammeProgressEngine.utcDate(from)?.timeIntervalSince1970,
              let t = ProgrammeProgressEngine.utcDate(to)?.timeIntervalSince1970
        else { return 0 }
        return Int((t - f) / 86400)
    }

    private struct MetricInputs {
        let enough: Bool
        let missing: String?
        let noGroups: String?
        let groupsReady: Bool
        let onsets: Spread?
        let durations: Spread?
        let workDuration: Double?
        let freeDuration: Double?
        let workMid: Double?
        let freeMid: Double?
        let index: (value: Double?, pairs: Int)
    }

    /// Miroir de `buildMetric` (TS, privée).
    private static func buildMetric(_ rule: ProgrammeEngineSleepRule, _ input: MetricInputs) -> ProgrammeEngineSleepMetricProgress {
        var raw: Double?
        var note: String?
        var min = rule.min
        var max = rule.max

        switch rule.metric {
        case .onsetSd:
            raw = input.enough ? input.onsets?.sd : nil
            note = (raw != nil && input.onsets != nil)
                ? "Coucher moyen à \(asClock(input.onsets!.mean)) ; chaque nuit s’en écarte de \(asMinutes(raw!)) en moyenne."
                : input.missing
        case .durationSd:
            raw = input.enough ? input.durations?.sd : nil
            note = (raw != nil && input.durations != nil)
                ? "Nuits de \(asDuration(input.durations!.mean)) en moyenne ; chacune s’en écarte de \(asMinutes(raw!))."
                : input.missing
        case .meanDuration:
            raw = input.enough ? input.durations?.mean : nil
            note = input.missing
        case .socialJetlag:
            if input.enough, input.groupsReady, let workMid = input.workMid, let freeMid = input.freeMid {
                raw = abs(freeMid - workMid)
                note = "Milieu de nuit à \(asClock(workMid)) avant un jour travaillé, \(asClock(freeMid)) avant un jour libre : la nuit glisse de \(asMinutes(raw!))."
            } else {
                raw = nil
                note = input.missing ?? input.noGroups
            }
        case .catchUp:
            let ready = input.enough && input.groupsReady && input.workDuration != nil && input.freeDuration != nil
            if ready, let workDuration = input.workDuration, let freeDuration = input.freeDuration {
                raw = freeDuration - workDuration
                let owed = shortNightMin - workDuration
                if owed <= 0 {
                    min = nil
                    max = 120
                    note = "Les nuits avant un jour travaillé font déjà \(asDuration(workDuration)) : le papier ne recommande d’allonger que si la semaine est courte."
                } else {
                    min = 60
                    max = 120
                    note = "Les nuits avant un jour travaillé font \(asDuration(workDuration)), soit \(asDuration(owed)) sous les 7 h."
                }
            } else {
                raw = nil
                note = input.missing ?? input.noGroups
            }
        case .sri:
            raw = input.index.value
            note = input.index.value == nil
                ? "Il faut au moins \(minPairs) paires de jours consécutifs complets, \(input.index.pairs) disponible\(input.index.pairs > 1 ? "s" : "")."
                : nil
        }

        let value = raw.map { $0.rounded() }
        return ProgrammeEngineSleepMetricProgress(
            key: rule.key, label: rule.label, detail: rule.detail, evidence: rule.evidence, unit: rule.unit,
            informative: rule.informative, value: value, rangeMin: min, rangeMax: max,
            scaleMin: rule.scaleMin, scaleMax: rule.scaleMax,
            status: rule.informative ? .unknown : statusFor(value, min, max),
            band: bandFor(value, rule.bands), note: note)
    }

    /// Miroir de `analyseSleep` (TS).
    static func analyseSleep(
        programme: ProgrammeEngineProgramme, rows: [ProgrammeEngineSleepNightRow], workDays: [Int],
        today: String, offsetOf: (String) -> Double
    ) -> ProgrammeEngineSleepReport {
        let nights = rows.sorted { $0.date < $1.date }
        let work = Set(workDays)
        let strip: [ProgrammeEngineNightPoint] = nights.map { night in
            let offset = offsetOf(night.date)
            let onset = axisMinute(ts: night.startTs, offsetS: offset)
            var wake = axisMinute(ts: night.endTs, offsetS: offset)
            if wake <= onset { wake += minutesPerDay }
            let weekday = ProgrammeProgressEngine.weekdayOf(night.date)
            return ProgrammeEngineNightPoint(
                date: night.date, weekday: weekday, workDay: work.contains(weekday),
                onset: onset, wake: wake, sleepMin: night.sleepS / 60)
        }

        let enough = strip.count >= minNights
        let onsets = clockSpread(strip.map { $0.onset })
        let wakes = clockSpread(strip.map { $0.wake.truncatingRemainder(dividingBy: minutesPerDay) })
        let durations = linearSpread(strip.map { $0.sleepMin })
        let workNights = strip.filter { $0.workDay }
        let freeNights = strip.filter { !$0.workDay }
        let groupsReady = workNights.count >= minGroupNights && freeNights.count >= minGroupNights
        let workDuration = average(workNights.map { $0.sleepMin })
        let freeDuration = average(freeNights.map { $0.sleepMin })
        let workMid = average(workNights.map { ($0.onset + $0.wake) / 2 })
        let freeMid = average(freeNights.map { ($0.onset + $0.wake) / 2 })
        let index = sleepRegularityIndex(nights: nights, offsetOf: offsetOf)

        let missing: String? = enough
            ? nil
            : "Il faut au moins \(minNights) nuits dans la fenêtre, \(shortNights(strip.count)) relevée\(strip.count > 1 ? "s" : "")."
        let noGroups: String? = groupsReady
            ? nil
            : "Il faut au moins deux nuits de chaque côté : deux avant un jour travaillé, deux avant un jour libre."

        let input = MetricInputs(
            enough: enough, missing: missing, noGroups: noGroups, groupsReady: groupsReady,
            onsets: onsets, durations: durations, workDuration: workDuration, freeDuration: freeDuration,
            workMid: workMid, freeMid: freeMid, index: index)
        let metrics = programme.sleepRules.map { buildMetric($0, input) }

        let scored = metrics.filter { !$0.informative }
        let from = nights.first?.date
        let to = nights.last?.date

        return ProgrammeEngineSleepReport(
            from: from, to: to, nights: strip.count,
            spanDays: (from != nil && to != nil) ? daysBetween(from!, to!) + 1 : 0,
            staleDays: to != nil ? daysBetween(to!, today) : 0,
            workNights: workNights.count, freeNights: freeNights.count, pairs: index.pairs,
            axis: (onsets != nil && wakes != nil)
                ? ProgrammeEngineSleepAxis(onsetMean: onsets!.mean, onsetSd: onsets!.sd, wakeMean: wakes!.mean, wakeSd: wakes!.sd)
                : nil,
            strip: strip, metrics: metrics,
            hits: scored.filter { $0.status == .hit }.count, total: scored.count)
    }
}
