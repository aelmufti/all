//
//  SleepRecommendationLocal.swift
//  all (bridge-connect)
//
//  Portage Swift de `custom-connect/server/src/stats/sleep-recommendation.ts` :
//  `wakeStressByNight` (intégral) + la mécanique lever/coucher/latence/paliers
//  de `computeSleepRecommendation` — SA section stress-corrélée (`basis:
//  'stress'|'objectif'`, `pearson`/`SLEEP_BUCKETS`) est RETIRÉE, remplacée par
//  le NOUVEL optimum (`Local/SleepOptimum.swift`, `docs/duree-ideale-sommeil.md`
//  §7) qui fixe désormais `targetHours`/`basis`/`debtHours`/`debtBonusMin`.
//
//  Tout ce fichier est PUR (aucun accès `LocalDb`) : `buildModelNights` prend
//  des échantillons déjà requêtés et produit les nuits agrégées du modèle
//  (`SleepOptimumNightInput`, spec §2-4) ; `computeSleepRecommendation` prend
//  la fenêtre de l'endpoint + un `SleepOptimumModel.Fit` déjà calculé. Les
//  requêtes `LocalDb` qui alimentent ces deux fonctions vivent dans
//  `Local/DashboardStats.swift` (`DashboardStatsBackend.sleepRecommendation`).
//

import Foundation

enum SleepRecommendationLocal {
    // MARK: - `wakeStressByNight` (port intégral)

    struct NightWindow { let startTs: Double; let endTs: Double }
    struct StressSample { let ts: Double; let value: Double }

    /// Stress de la journée de veille qui suit chaque nuit — fenêtre bornée
    /// par le coucher de la nuit SUIVANTE (16 h max sans nuit suivante, nil si
    /// cette journée n'est pas encore terminée). `nights`/`samples` dans
    /// n'importe quel ordre ; résultat aligné sur l'ordre d'entrée de `nights`.
    static func wakeStressByNight(nights: [NightWindow], samples: [StressSample], nowS: Double) -> [Double?] {
        let maxDayS: Double = 16 * 3600
        let minSamples = 60

        let order = nights.enumerated()
            .map { (i, n) in (startTs: n.startTs, endTs: n.endTs, i: i) }
            .sorted { $0.startTs < $1.startTs }
        let sortedSamples = samples.sorted { $0.ts < $1.ts }

        var result = [Double?](repeating: nil, count: nights.count)
        var ptr = 0
        for idx in order.indices {
            let n = order[idx]
            let next = idx + 1 < order.count ? order[idx + 1] : nil
            let maxDayEnd = n.endTs + maxDayS
            let dayEnd = next.map { min($0.startTs, maxDayEnd) } ?? maxDayEnd

            if next == nil && dayEnd > nowS {
                result[n.i] = nil
                continue
            }

            while ptr < sortedSamples.count && sortedSamples[ptr].ts < n.endTs { ptr += 1 }
            var sum = 0.0
            var count = 0
            var p = ptr
            while p < sortedSamples.count && sortedSamples[p].ts < dayEnd {
                sum += sortedSamples[p].value
                count += 1
                p += 1
            }
            result[n.i] = count >= minSamples ? sum / Double(count) : nil
            ptr = p
        }
        return result
    }

    // MARK: - Construction des nuits du MODÈLE (spec §2-4) — fonction PURE,
    // prend des échantillons déjà requêtés par `DashboardStatsBackend`.

    struct ModelRawNight {
        let date: String
        let startTs: Double
        let endTs: Double
        /// `(deep+light+rem)/3600`, déjà filtrée dans `[3, 12]` h par l'appelant.
        let S: Double
        /// Décalage fuseau LOCAL de cette nuit (`LocalDb.localOffsetSeconds`) —
        /// nécessaire pour `onsetShift`/`workdayNext`, en heure locale
        /// d'affichage (même convention que `sleep-recommendation.ts`).
        let offsetS: Double
    }

    struct Sample { let ts: Double; let value: Double }
    struct ActivityWindow { let startTs: Double; let durationMin: Double }

    /// Agrège les covariables brutes (§4) + `bbMorning`/`bbEvening` (§3) pour
    /// chaque nuit du modèle. `wakeStress` (3e issue) est calculé à part par
    /// l'appelant via `wakeStressByNight` puis fusionné ici (même ordre que
    /// `nights`).
    static func buildModelNights(
        nights: [ModelRawNight],
        bbSamples: [Sample],
        stressSamples: [Sample],
        activities: [ActivityWindow],
        wakeStresses: [Double?]
    ) -> [SleepOptimumNightInput] {
        guard nights.count == wakeStresses.count else { return [] }
        let sortedBB = bbSamples.sorted { $0.ts < $1.ts }
        let sortedStress = stressSamples.sorted { $0.ts < $1.ts }
        let ascByStart = nights.enumerated().sorted { $0.element.startTs < $1.element.startTs }

        // §4.6 : médiane des endormissements LOCAUX recentrés autour de midi —
        // même repli que `sleep-recommendation.ts` (pas de médiane circulaire
        // à cheval sur minuit).
        func recenteredOnsetMin(_ n: ModelRawNight) -> Double {
            let onsetMin = mod(n.startTs + n.offsetS, 86400) / 60
            return mod(onsetMin - 720, 1440)
        }
        let recenteredOnsets = nights.map(recenteredOnsetMin)
        let medianRecenteredOnset = median(recenteredOnsets)

        // §4.7 : S par date, pour `priorSleep` (demi-vie 1 nuit, d-1...d-7).
        var sByDate: [String: Double] = [:]
        for n in nights { sByDate[n.date] = n.S }

        var utcCal = Calendar(identifier: .gregorian)
        utcCal.timeZone = TimeZone(identifier: "UTC")!

        var out: [SleepOptimumNightInput] = []
        out.reserveCapacity(nights.count)
        for (i, night) in nights.enumerated() {
            let on = night.startTs
            let wk = night.endTs

            // §3 bbMorning : max bb dans [wk, wk+2h].
            let bbMorning = sortedBB
                .filter { $0.ts >= wk && $0.ts <= wk + 2 * 3600 }
                .map(\.value).max()

            // §3 bbEvening : bb le plus proche de wk+10h (±30 min) ; nil si la
            // nuit principale SUIVANTE commence avant wk+10h.
            let bbEvening: Double?
            if let nextEntry = ascByStart.first(where: { $0.element.startTs > on }),
               nextEntry.element.startTs < wk + 10 * 3600 {
                bbEvening = nil
            } else {
                let target = wk + 10 * 3600
                bbEvening = sortedBB
                    .filter { abs($0.ts - target) <= 1800 }
                    .min { abs($0.ts - target) < abs($1.ts - target) }?.value
            }

            // §4.1 bbBed : dernier bb dans [on-60min, on].
            let bbBed = sortedBB
                .filter { $0.ts >= on - 3600 && $0.ts <= on }
                .max { $0.ts < $1.ts }?.value

            // §4.2 stressPrevDay : moyenne du stress dans [on-14h, on-30min],
            // nil si < 60 échantillons.
            let stressWindow = sortedStress.filter { $0.ts >= on - 14 * 3600 && $0.ts <= on - 1800 }
            let stressPrevDay = stressWindow.count >= 60 ? DashboardStatsMath.mean(stressWindow.map(\.value)) : nil

            // §4.3/4.4 sportPrev/sportNext : minutes d'activité dont le DÉBUT
            // est dans la fenêtre (0 si aucune, jamais `nil`).
            let sportPrev = activities
                .filter { $0.startTs >= on - 24 * 3600 && $0.startTs <= on }
                .reduce(0) { $0 + $1.durationMin }
            let sportNext = activities
                .filter { $0.startTs >= wk && $0.startTs <= wk + 12 * 3600 }
                .reduce(0) { $0 + $1.durationMin }

            // §4.5 workdayNext : jour LOCAL du réveil, lun.-ven. (Foundation
            // Calendar : 1=dim....7=sam., donc 2...6=lun....ven.).
            let localWakeDate = Date(timeIntervalSince1970: wk + night.offsetS)
            let weekday = utcCal.component(.weekday, from: localWakeDate)
            let workdayNext: Double = (2...6).contains(weekday) ? 1 : 0

            // §4.6 onsetShift : écart (en heures) à la médiane des
            // endormissements RECENTRÉS — le recentrage s'annule dans la
            // différence, pas de `mod` à réappliquer après coup.
            let onsetShift = (recenteredOnsets[i] - medianRecenteredOnset) / 60

            // §4.7 priorSleep : moyenne pondérée des S des nuits d-1...d-7
            // présentes dans le modèle, poids 0.5^(k-1) (demi-vie 1 nuit).
            let priorSleep = SleepOptimumContext.priorSleep(date: night.date, sleepByDate: sByDate)

            out.append(SleepOptimumNightInput(
                date: night.date, S: night.S, bbMorning: bbMorning, bbEvening: bbEvening,
                wakeStress: wakeStresses[i], bbBed: bbBed, stressPrevDay: stressPrevDay,
                sportPrev: sportPrev, sportNext: sportNext, workdayNext: workdayNext,
                onsetShift: onsetShift, priorSleep: priorSleep))
        }
        return out
    }

    // MARK: - Mécanique lever/coucher/latence/paliers (port de
    // `computeSleepRecommendation`, section stress-corrélée retirée — spec
    // §7.4 « le reste est inchangé »)

    static let sleepLatencyMin = 15
    static let bedtimeStepMin = 15
    private static let debtWindowNights = 7

    struct RecoNight {
        let date: String
        let startTs: Double
        let endTs: Double
        let deepS: Double
        let lightS: Double
        let remS: Double
        let awakeS: Double
        let offsetS: Double
    }

    enum Result {
        case insufficient(nights: Int)
        case ok(OK)
    }

    struct OK {
        let nights: Int
        let basis: String
        let targetHours: Double
        let avgSleepHours: Double
        let waketime: String
        /// Lever habituel par type de jour (médiane des réveils locaux des nuits
        /// de la fenêtre dont le jour de réveil est lun.-ven. / sam.-dim.) ;
        /// `nil` sous 3 nuits de ce type (repli sur `waketime`).
        let waketimeWorkday: String?
        let waketimeFreeDay: String?
        let currentBedtime: String
        let recommendedBedtime: String
        let targetBedtime: String
        let stepped: Bool
        let stepMin: Int
        let latencyMin: Int
        let shiftMin: Int
        let avgAwakeMin: Int
        let debtHours: Double
        let debtBonusMin: Int
        let idealHours: Double?
        let idealLowHours: Double?
        let idealHighHours: Double?
        let belowFloor: Bool?
        let modelNights: Int?
        let trial: Bool?
    }

    /// `nights` = fenêtre de l'ENDPOINT (`days` query), PAS les 180 nuits du
    /// modèle. `fit` vient d'une fenêtre séparée (`SleepOptimumModel.fit`,
    /// toujours 180 nuits, cf. `DashboardStatsBackend.sleepRecommendation`) —
    /// c'est lui qui fixe `targetHours`/`basis`/l'idéal ; `nights` ne sert plus
    /// qu'au lever/coucher/latence/paliers + à la dette (7 dernières nuits DE
    /// CETTE fenêtre).
    static func computeSleepRecommendation(
        nights: [RecoNight], fit: SleepOptimumModel.Fit, todayKey: String
    ) -> Result {
        guard nights.count >= 3 else { return .insufficient(nights: nights.count) }
        func round1(_ v: Double) -> Double { (v * 10).rounded() / 10 }

        let asc = nights.sorted { $0.startTs < $1.startTs }
        let last7 = Array(asc.suffix(debtWindowNights))

        let wakeMinutes = asc.map { mod($0.endTs + $0.offsetS, 86400) / 60 }
        let wakeAnchorMin = median(wakeMinutes)
        let wakeByDayType = wakeMedianByDayType(asc)

        let bedRecentered = last7.map { n -> Double in
            let onsetMin = mod(n.startTs + n.offsetS, 86400) / 60
            return mod(onsetMin - 720, 1440)
        }
        let habitualOnsetMin = mod(median(bedRecentered) + 720, 1440)
        let habitualLightsOutMin = mod(habitualOnsetMin - Double(sleepLatencyMin), 1440)

        let avgAwakeMin = DashboardStatsMath.mean(asc.map(\.awakeS)) / 60
        let avgSleepHours = DashboardStatsMath.mean(asc.map { ($0.deepS + $0.lightS + $0.remS) / 3600 })
        let last7SleepHours = last7.map { ($0.deepS + $0.lightS + $0.remS) / 3600 }

        let reco = SleepOptimumModel.recommendation(fit: fit, todayKey: todayKey, last7SleepHours: last7SleepHours)

        let sleepOpportunityMin = reco.targetHours * 60 + avgAwakeMin
        let inBedMin = sleepOpportunityMin + Double(sleepLatencyMin)
        let targetBedMin = mod(wakeAnchorMin - inBedMin, 1440)

        let shiftMin = Int((mod(targetBedMin - habitualLightsOutMin + 720, 1440) - 720).rounded())
        let stepped = shiftMin < -bedtimeStepMin
        let tonightBedMin = stepped ? mod(habitualLightsOutMin - Double(bedtimeStepMin), 1440) : targetBedMin

        return .ok(OK(
            nights: nights.count, basis: fit.basis,
            targetHours: round1(reco.targetHours), avgSleepHours: round1(avgSleepHours),
            waketime: DashboardStatsTime.minToClock(wakeAnchorMin),
            waketimeWorkday: wakeByDayType.workday.map(DashboardStatsTime.minToClock),
            waketimeFreeDay: wakeByDayType.freeDay.map(DashboardStatsTime.minToClock),
            currentBedtime: DashboardStatsTime.minToClock(habitualLightsOutMin),
            recommendedBedtime: DashboardStatsTime.minToClock(tonightBedMin),
            targetBedtime: DashboardStatsTime.minToClock(targetBedMin),
            stepped: stepped, stepMin: bedtimeStepMin, latencyMin: sleepLatencyMin, shiftMin: shiftMin,
            avgAwakeMin: Int(avgAwakeMin.rounded()),
            debtHours: round1(reco.debtHours), debtBonusMin: reco.debtBonusMin,
            idealHours: fit.idealHours, idealLowHours: fit.idealLowHours, idealHighHours: fit.idealHighHours,
            belowFloor: fit.belowFloor, modelNights: fit.n, trial: reco.trial))
    }

    /// Nombre minimal de nuits d'un type de jour pour publier son lever habituel.
    static let minNightsPerDayType = 3

    /// Médiane des heures de réveil LOCALES (minutes depuis minuit) des nuits
    /// dont le jour local de réveil est lun.-ven. (`workday`) ou sam.-dim.
    /// (`freeDay`) ; `nil` sous `minNightsPerDayType` nuits de ce type.
    static func wakeMedianByDayType(_ nights: [RecoNight]) -> (workday: Double?, freeDay: Double?) {
        var utcCal = Calendar(identifier: .gregorian)
        utcCal.timeZone = TimeZone(identifier: "UTC")!
        var workday: [Double] = []
        var freeDay: [Double] = []
        for n in nights {
            let localWake = n.endTs + n.offsetS
            // Foundation : 1 = dim. … 7 = sam. → 2...6 = lun.-ven. (cf. `workdayNext`).
            let weekday = utcCal.component(.weekday, from: Date(timeIntervalSince1970: localWake))
            let minutes = mod(localWake, 86400) / 60
            if (2...6).contains(weekday) { workday.append(minutes) } else { freeDay.append(minutes) }
        }
        return (
            workday.count >= minNightsPerDayType ? median(workday) : nil,
            freeDay.count >= minNightsPerDayType ? median(freeDay) : nil)
    }

    // MARK: - Utilitaires (miroir `mod`/`median`, `sleep-recommendation.ts`)

    static func mod(_ v: Double, _ m: Double) -> Double {
        (v.truncatingRemainder(dividingBy: m) + m).truncatingRemainder(dividingBy: m)
    }

    static func median(_ nums: [Double]) -> Double {
        guard !nums.isEmpty else { return 0 }
        let sorted = nums.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2
    }
}
