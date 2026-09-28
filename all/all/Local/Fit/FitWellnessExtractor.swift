//
//  FitWellnessExtractor.swift
//  all (bridge-connect)
//
//  Portage Swift de `FitParserService.extractWellness`/`extractSleep`
//  (`custom-connect/server/src/ingest/fit-parser.service.ts`) — même logique
//  de bucketing par date/fuseau, mêmes règles de validité par métrique.
//  Opère sur la sortie générique de `FitDecoder` ([FitMessage]), pas sur les
//  octets bruts.
//
//  Divergence assumée vs le serveur : le serveur lit le fuseau d'affichage
//  dans `DISPLAY_TZ` (variable d'env, un seul serveur pour tout le monde) ;
//  ici, il n'y a qu'un fuseau pertinent — celui du téléphone
//  (`TimeZone.current`), utilisé UNIQUEMENT en repli quand `monitoring_info`
//  n'a pas de paire timestamp/localTimestamp exploitable.
//

import Foundation

// MARK: - Modèles de sortie (miroir des interfaces TS `WellnessData`/`SleepSummary`)

struct FitWellnessDay {
    let date: String
    var restingHr: Double?
    var bmrKcal: Double?
}

struct FitWellnessCounter {
    let date: String
    let activityType: String
    var steps: Double?
    var activeCalories: Double?
    var distanceM: Double?
    var activeTimeS: Double?
}

struct FitWellnessCounterSample {
    let ts: Double
    let activityType: String
    let steps: Double?
    let activeCalories: Double?
}

/// `metric` ∈ {"hr", "stress", "spo2", "respiration"} — même convention que
/// `wellness_samples.metric` côté Pulse.
struct FitWellnessSample {
    let metric: String
    let ts: Double
    let value: Double
}

struct FitWellnessData {
    let days: [FitWellnessDay]
    let counters: [FitWellnessCounter]
    let counterSamples: [FitWellnessCounterSample]
    let samples: [FitWellnessSample]
}

struct FitSleepPhase {
    let from: Double
    let to: Double
    /// "deep" | "light" | "rem" | "awake"
    let stage: String
}

struct FitSleepSummary {
    let date: String
    let startTs: Double
    let endTs: Double
    let durationS: Double
    let score: Double?
    let deepS: Double
    let lightS: Double
    let remS: Double
    let awakeS: Double
    let awakenings: Double?
    let phases: [FitSleepPhase]
}

enum FitWellnessExtractor {
    /// Écart Unix ↔ époque FIT, en secondes — CLAUDE.md, « Répondre à
    /// CURRENT_TIME_REQUEST en secondes epoch Garmin (Unix − 631065600) » :
    /// même constante, `FIT_EPOCH_S` côté TS.
    static let fitEpochS: Double = 631_065_600

    private static let stepActivityTypes = FitProfile.stepActivityTypeValues

    // MARK: - `extractWellness` (fichiers `monitoringB`)

    static func extractWellness(messages: [FitMessage]) -> FitWellnessData {
        let info = messages.first { $0.globalMessageNumber == FitProfile.mesgMonitoringInfo }
        let infoTs = info?.double(253)
        let localTs = info?.double(0)
        let offset: Double
        if let infoTs, let localTs {
            offset = localTs - infoTs
        } else if let infoTs {
            offset = deviceTzOffsetSeconds(atUnix: infoTs + fitEpochS)
        } else {
            offset = 0
        }

        func toLocalUnix(_ fitTs: Double) -> Double { fitTs + offset + fitEpochS }
        func toUtcUnix(_ fitTs: Double) -> Double { fitTs + fitEpochS }
        func toDate(_ fitTs: Double) -> String { isoDate(toLocalUnix(fitTs)) }
        func toCounterDate(_ fitTs: Double) -> String {
            let localUnix = toLocalUnix(fitTs)
            let intoDay = (localUnix.truncatingRemainder(dividingBy: 86400) + 86400)
                .truncatingRemainder(dividingBy: 86400)
            let adjusted = intoDay < 90 ? localUnix - 86400 : localUnix
            return isoDate(adjusted)
        }

        var samples: [FitWellnessSample] = []
        var counters: [String: FitWellnessCounter] = [:] // clé "date|activityType"
        var counterOrder: [String] = []
        var counterSamples: [FitWellnessCounterSample] = []
        var days: [String: FitWellnessDay] = [:]
        var dayOrder: [String] = []

        func dayEntry(_ date: String) -> FitWellnessDay {
            if let existing = days[date] { return existing }
            let fresh = FitWellnessDay(date: date, restingHr: nil, bmrKcal: nil)
            days[date] = fresh
            dayOrder.append(date)
            return fresh
        }

        if let infoTs {
            if let bmr = info?.double(5) {
                var entry = dayEntry(toDate(infoTs))
                entry.bmrKcal = bmr
                days[entry.date] = entry
            }
        }

        for hrData in messages where hrData.globalMessageNumber == FitProfile.mesgMonitoringHrData {
            guard let ts = hrData.double(253) else { continue }
            let resting = hrData.double(1) ?? hrData.double(0) // currentDayRestingHeartRate ?? restingHeartRate
            if let resting, resting > 0 {
                var entry = dayEntry(toDate(ts))
                entry.restingHr = resting
                days[entry.date] = entry
            }
        }

        var lastFullTs: Double?
        for m in messages where m.globalMessageNumber == FitProfile.mesgMonitoring {
            var ts: Double?
            if let full = m.double(253) {
                ts = full
                lastFullTs = full
            } else if let ts16 = m.double(26), let lastFull = lastFullTs {
                let lastU32 = UInt32(lastFull)
                let low16 = UInt16(truncatingIfNeeded: lastU32)
                let ts16U = UInt16(ts16)
                let diff = ts16U &- low16 // enroulement mod 65536, comme `(ts16 - low16) & 0xffff` en TS
                let newTs = lastU32 &+ UInt32(diff)
                ts = Double(newTs)
                lastFullTs = ts
            }
            guard let ts else { continue }

            if let hr = m.double(27), hr > 0 {
                samples.append(FitWellnessSample(metric: "hr", ts: toUtcUnix(ts), value: hr))
            }

            let activityTypeValue = m.double(5).map(Int.init)
            let activityType = activityTypeValue.flatMap { FitProfile.activityTypeNames[$0] }
            let cycles = m.double(3)
            let steps: Double? = {
                if let activityTypeValue, stepActivityTypes.contains(activityTypeValue), let cycles {
                    return cycles * 2
                }
                return nil
            }()
            let activeCalories = m.double(19)
            let distanceM = m.double(2)
            let activeTimeS = m.double(4)

            if let activityType, steps != nil || activeCalories != nil {
                counterSamples.append(
                    FitWellnessCounterSample(ts: toUtcUnix(ts), activityType: activityType, steps: steps, activeCalories: activeCalories))
            }
            if let activityType, steps != nil || activeCalories != nil || distanceM != nil || activeTimeS != nil {
                let date = toCounterDate(ts)
                let key = "\(date)|\(activityType)"
                var existing = counters[key] ?? {
                    counterOrder.append(key)
                    return FitWellnessCounter(date: date, activityType: activityType, steps: nil, activeCalories: nil, distanceM: nil, activeTimeS: nil)
                }()
                existing.steps = maxOrNil(existing.steps, steps)
                existing.activeCalories = maxOrNil(existing.activeCalories, activeCalories)
                existing.distanceM = maxOrNil(existing.distanceM, distanceM)
                existing.activeTimeS = maxOrNil(existing.activeTimeS, activeTimeS)
                counters[key] = existing
            }
        }

        for stress in messages where stress.globalMessageNumber == FitProfile.mesgStressLevel {
            guard let ts = stress.double(1), let value = stress.double(0), value >= 0 else { continue }
            samples.append(FitWellnessSample(metric: "stress", ts: toUtcUnix(ts), value: value))
        }

        for spo2 in messages where spo2.globalMessageNumber == FitProfile.mesgSpo2Data {
            guard let ts = spo2.double(253), let value = spo2.double(0), value > 0, value <= 100 else { continue }
            samples.append(FitWellnessSample(metric: "spo2", ts: toUtcUnix(ts), value: value))
        }

        for resp in messages where resp.globalMessageNumber == FitProfile.mesgRespirationRate {
            guard let ts = resp.double(253), let value = resp.double(0), value > 0 else { continue }
            samples.append(FitWellnessSample(metric: "respiration", ts: toUtcUnix(ts), value: value))
        }

        return FitWellnessData(
            days: dayOrder.compactMap { days[$0] },
            counters: counterOrder.compactMap { counters[$0] },
            counterSamples: counterSamples,
            samples: samples)
    }

    // MARK: - `extractSleep` (fichiers "sleep")

    static func extractSleep(messages: [FitMessage]) -> FitSleepSummary? {
        let events = messages.filter { $0.globalMessageNumber == FitProfile.mesgEvent }
        let startEvent = events.first { $0.double(1) == FitProfile.eventTypeStart }
        let stopEvent = events.first { $0.double(1) == FitProfile.eventTypeStop }

        let levels = messages
            .filter { $0.globalMessageNumber == FitProfile.mesgSleepLevel }
            .compactMap { m -> (ts: Double, level: Double?)? in
                guard let ts = m.double(253) else { return nil }
                return (ts, m.double(0))
            }
            .sorted { $0.ts < $1.ts }
        guard !levels.isEmpty else { return nil }

        let startFit = startEvent?.double(253) ?? levels[0].ts
        let endFit = stopEvent?.double(253) ?? levels[levels.count - 1].ts
        guard endFit > startFit else { return nil }

        // `data` (champ 3) — repli sur `data16` (champ 2) si le SDK a
        // transmis la variante 16 bits sur le fil (cf. `FitProfile`, aucun
        // fichier sommeil dans les échantillons pour trancher définitivement).
        let startData = startEvent?.double(3) ?? startEvent?.double(2)
        let offset: Double
        if let startData, let startTimestamp = startEvent?.double(253) {
            offset = startData - startTimestamp
        } else {
            offset = deviceTzOffsetSeconds(atUnix: startFit + fitEpochS)
        }

        func mapStage(_ level: Double?) -> String {
            if level == FitProfile.sleepLevelDeep { return "deep" }
            if level == FitProfile.sleepLevelRem { return "rem" }
            if level == FitProfile.sleepLevelLight { return "light" }
            return "awake"
        }

        var phases: [FitSleepPhase] = []
        var deepS: Double = 0
        var lightS: Double = 0
        var remS: Double = 0
        var awakeS: Double = 0
        var prevFit = startFit
        for level in levels {
            let toFit = level.ts
            guard toFit > prevFit else { continue }
            let stage = mapStage(level.level)
            let seconds = toFit - prevFit
            switch stage {
            case "deep": deepS += seconds
            case "light": lightS += seconds
            case "rem": remS += seconds
            default: awakeS += seconds
            }
            phases.append(FitSleepPhase(from: prevFit + fitEpochS, to: toFit + fitEpochS, stage: stage))
            prevFit = toFit
        }
        guard !phases.isEmpty else { return nil }

        let assessment = messages.first { $0.globalMessageNumber == FitProfile.mesgSleepAssessment }
        let startTs = startFit + fitEpochS
        let endTs = endFit + fitEpochS

        return FitSleepSummary(
            date: isoDate(endTs + offset),
            startTs: startTs,
            endTs: endTs,
            durationS: deepS + lightS + remS + awakeS,
            score: assessment?.double(6),
            deepS: deepS,
            lightS: lightS,
            remS: remS,
            awakeS: awakeS,
            awakenings: assessment?.double(11),
            phases: phases)
    }

    // MARK: - Utilitaires

    private static func maxOrNil(_ a: Double?, _ b: Double?) -> Double? {
        guard let a else { return b }
        guard let b else { return a }
        return max(a, b)
    }

    /// Décalage fuseau du téléphone à l'instant Unix donné — repli quand
    /// `monitoring_info`/l'événement `start` ne donnent pas d'offset direct
    /// (cf. en-tête de fichier).
    private static func deviceTzOffsetSeconds(atUnix unix: Double) -> Double {
        Double(TimeZone.current.secondsFromGMT(for: Date(timeIntervalSince1970: unix)))
    }

    private static let isoDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    /// `new Date(unixSeconds * 1000).toISOString().slice(0, 10)` — toujours en
    /// UTC (cf. en-tête : les secondes passées ici sont déjà "l'heure locale
    /// déguisée en UTC", même convention que le serveur).
    static func isoDate(_ unixSeconds: Double) -> String {
        isoDateFormatter.string(from: Date(timeIntervalSince1970: unixSeconds))
    }
}
