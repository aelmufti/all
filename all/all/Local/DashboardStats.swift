//
//  DashboardStats.swift
//  all (bridge-connect)
//
//  Portage du calcul de `custom-connect/server/src/stats/stats.controller.ts`
//  (incrément L4, `docs/stockage-local.md`) — appelle les requêtes de
//  `LocalDb` (section « Dashboard / Stats »), agrège/corrèle en Swift, encode
//  le même JSON que le serveur (mêmes clés que `DashboardModels.swift`).
//  Câblé depuis `RealLocalPulseBackend.handle`.
//
//  Portée FIDÈLE (calculée sur des données locales réelles, mêmes requêtes
//  SQL — même moteur SQLite réel, donc même comportement `strftime`/affinité
//  qu'attendu par le TS) :
//    - `GET api/stats/tab-health`
//    - `GET api/stats/sleep-debt`
//    - `GET api/stats/sleep-insights`
//    - `GET api/stats/sleep-regularity`
//    - `GET api/stats/tab-nutrition` — porté INTÉGRALEMENT : contrairement à
//      `nutrition/day` (dont `targets`/`remaining` dépendent de `target.ts`,
//      non porté en L5-Nutrition), `tab-nutrition` ne lit qu'un réglage brut
//      (`settings.nutritionKcal`) pour son seuil "journée complète" — jamais
//      écrit localement ici, donc toujours `nil`/repli 1200 kcal, EXACTEMENT
//      le même repli que le serveur sans cible configurée. Aucun moteur
//      "programme"/"cible" à porter pour cet endpoint précis.
//
//  Portée PARTIELLE (`tab-training`) : tout est calculé depuis les données
//  LOCALES réelles (`activities`/`wellness_counters` — pas de "moteur
//  Programme" à porter pour cet endpoint, il n'y en a pas côté serveur non
//  plus), SAUF `zones` — qui nécessiterait de reparser CHAQUE `.fit`
//  d'activité de la période pour en extraire les zones de FC (miroir de
//  `zoneTotals`/`activity_zones`, TS) : non fait ici (coût et risque de
//  performance non justifiés à ce stade), `zones` reste `[]`. L'écran rend
//  ça honnêtement (`DashboardZonesCard` : « Pas de zone d'effort calculée sur
//  la période. », un message d'ABSENCE DE CALCUL, pas un zéro trompeur).
//
//    - `GET api/stats/sleep-recommendation` — porté (`docs/duree-ideale-sommeil.md`) :
//      lever/coucher/latence/paliers restent le portage de
//      `sleep-recommendation.ts` (`Local/SleepRecommendationLocal.swift`),
//      mais `targetHours`/`basis`/l'intervalle viennent désormais du NOUVEL
//      optimum bayésien (`Local/SleepOptimum.swift`), ajusté sur une fenêtre
//      SÉPARÉE de 180 nuits (indépendante du `days` de l'endpoint).
//

import Foundation

// MARK: - Aides pures (miroir `mean`/`pearson`/`stdev`, `sleep-recommendation.ts`)

enum DashboardStatsMath {
    static func mean(_ nums: [Double]) -> Double {
        nums.isEmpty ? 0 : nums.reduce(0, +) / Double(nums.count)
    }

    static func stdev(_ nums: [Double]) -> Double {
        guard nums.count >= 2 else { return 0 }
        let m = mean(nums)
        return mean(nums.map { ($0 - m) * ($0 - m) }).squareRoot()
    }

    static func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double { min(hi, max(lo, v)) }

    struct PearsonFit { let r: Double; let t: Double }

    /// Miroir de `pearson` (TS) — `nil` sous 10 paires ou variance nulle.
    static func pearson(_ pairs: [(Double, Double)]) -> PearsonFit? {
        let n = pairs.count
        guard n >= 10 else { return nil }
        let mx = mean(pairs.map { $0.0 })
        let my = mean(pairs.map { $0.1 })
        var sxy = 0.0, sxx = 0.0, syy = 0.0
        for (x, y) in pairs {
            sxy += (x - mx) * (y - my)
            sxx += (x - mx) * (x - mx)
            syy += (y - my) * (y - my)
        }
        guard sxx != 0, syy != 0 else { return nil }
        let r = sxy / (sxx * syy).squareRoot()
        let t = r * (Double(n - 2) / max(1 - r * r, 1e-9)).squareRoot()
        return PearsonFit(r: r, t: t)
    }
}

// MARK: - Aides temps (fenêtres/formatage — mêmes divergences fuseau déjà
// actées ailleurs dans `LocalDb` : un seul fuseau pertinent ici,
// `TimeZone.current`, pas `DISPLAY_TZ`)

enum DashboardStatsTime {
    /// Miroir de `rangeDays` (TS) — `parseInt(...) || 30` : `0`/non numérique
    /// retombent sur 30, borné [7, 3660].
    static func rangeDays(_ raw: String?) -> Int {
        let parsed = raw.flatMap(Int.init)
        let value = (parsed != nil && parsed != 0) ? parsed! : 30
        return min(max(value, 7), 3660)
    }

    private static let isoDateOnlyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Minuit UTC du jour calendaire `date`, en secondes epoch.
    static func dayStartUnixUTC(_ date: String) -> Double {
        isoDateOnlyFormatter.date(from: date)?.timeIntervalSince1970 ?? 0
    }

    static func dateFromISODate(_ date: String) -> Date {
        isoDateOnlyFormatter.date(from: date) ?? Date(timeIntervalSince1970: 0)
    }

    /// Miroir de `sinceDate(days, anchor)` (TS) — ancré sur `anchor` (ex.
    /// dernière nuit connue) si fourni, sinon sur "maintenant" ; fenêtre
    /// `days - 1` jours en arrière.
    static func sinceDateAnchored(days: Int, anchor: String?) -> String {
        let base = anchor.map(dayStartUnixUTC) ?? Date().timeIntervalSince1970
        return FitWellnessExtractor.isoDate(base - Double(days - 1) * 86400)
    }

    /// Miroir du `sinceDate` inline de `tabHealth`/`tabTraining`/
    /// `tabNutrition` (TS) — toujours ancré sur "maintenant", fenêtre `days`
    /// jours PLEINS (pas `days - 1`, divergence assumée du serveur lui-même
    /// entre ses deux formules).
    static func sinceDateNow(days: Int) -> String {
        FitWellnessExtractor.isoDate(Date().timeIntervalSince1970 - Double(days) * 86400)
    }

    private static let isoDateTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        return f
    }()

    /// Même format que `activities.start_time` (`FitActivityExtractor.isoDateTime`,
    /// mêmes réglages de formatteur) — nécessaire pour comparer/parser cette
    /// colonne telle quelle (`new Date(...).toISOString()` côté TS).
    static func isoDateTime(_ unixSeconds: Double) -> String {
        isoDateTimeFormatter.string(from: Date(timeIntervalSince1970: unixSeconds))
    }

    static func activityDate(_ isoDateTimeString: String) -> Date? {
        isoDateTimeFormatter.date(from: isoDateTimeString)
    }

    /// Miroir de `clockOf` (TS) — divergence fuseau assumée : appareil, pas
    /// `DISPLAY_TZ` (même principe que `LocalDb.localOffsetSeconds`).
    static func clockOf(_ ts: Double) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.timeZone = TimeZone.current
        f.dateFormat = "HH:mm"
        return f.string(from: Date(timeIntervalSince1970: ts))
    }

    /// Miroir de `minToClock` (TS).
    static func minToClock(_ minutes: Double) -> String {
        let m = (minutes.rounded().truncatingRemainder(dividingBy: 1440) + 1440).truncatingRemainder(dividingBy: 1440)
        let h = Int(m / 60)
        let mm = Int(m.truncatingRemainder(dividingBy: 60))
        return String(format: "%02d:%02d", h, mm)
    }

    private static let isoWeekCalendar: Calendar = {
        var cal = Calendar(identifier: .iso8601)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }()

    /// Miroir de `weekKey` (TS) — lundi (UTC) de la semaine ISO contenant
    /// `date`, via `Calendar(identifier: .iso8601)` (mêmes règles ISO-8601 :
    /// semaine du lundi, semaine 1 contient le premier jeudi de l'année).
    static func isoWeekMonday(_ date: Date) -> String {
        let start = isoWeekCalendar.dateInterval(of: .weekOfYear, for: date)?.start ?? date
        return FitWellnessExtractor.isoDate(start.timeIntervalSince1970)
    }

    /// Miroir de `isoWeek` (TS).
    static func isoWeekNumber(_ date: Date) -> Int {
        isoWeekCalendar.component(.weekOfYear, from: date)
    }
}

// MARK: - Décodage des phases de sommeil (JSON `wellness_sleep.phases`)
//
// Duplique volontairement `LocalDb`'s `decodePhases` (`private`, donc
// inaccessible depuis ce fichier) — même forme JSON, même logique, quelques
// lignes.

private struct DashboardPhaseSpan { let from: Double; let to: Double; let stage: String }

private func decodeSleepPhasesJSON(_ json: String) -> [DashboardPhaseSpan] {
    guard let data = json.data(using: .utf8),
          let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
    else { return [] }
    return array.compactMap { dict in
        guard let from = dict["from"] as? Double, let to = dict["to"] as? Double,
              let stage = dict["stage"] as? String else { return nil }
        return DashboardPhaseSpan(from: from, to: to, stage: stage)
    }
}

// MARK: - DTO d'encodage JSON — mêmes clés que `Pulse/Screens/Dashboard/DashboardModels.swift`

private struct StatsHealthPointDTO: Encodable { let date: String; let value: Double }
private struct StatsRangeDTO: Encodable { let lo: Double; let hi: Double }
private struct StatsSpo2BucketDTO: Encodable { let label: String; let nights: Int }
private struct StatsWeightPointDTO: Encodable { let date: String; let kg: Double }
private struct StatsCorrelationDTO: Encodable { let label: String; let r: Double?; let strength: String; let pairs: Int }

private struct StatsHealthTabDTO: Encodable {
    let days: Int
    let restingHr: Double?
    let respiration: Double?
    let spo2Night: Double?
    let stress: Int?
    let weightKg: Double?
    let sleepHours: Double?
    let restingSeries: [StatsHealthPointDTO]
    let restingDelta: Double?
    let respirationSeries: [StatsHealthPointDTO]
    let respirationBand: StatsRangeDTO?
    let spo2Buckets: [StatsSpo2BucketDTO]
    let spo2Nights: Int
    let weightSeries: [StatsWeightPointDTO]
    let weightDelta: Double?
    let correlations: [StatsCorrelationDTO]
}

private struct StatsSleepDebtNightDTO: Encodable {
    let date: String
    let sleepS: Int
    let inBedS: Int
    let awakeS: Int
    let deltaS: Int
    let cumulativeS: Int
    let score: Int?
    let bedtime: String?
}

private struct StatsSleepDebtDTO: Encodable {
    let nights: Int
    let targetHours: Int
    let debtHours: Double
    let avgHours: Double
    let deficitNights: Int
    let avgInBedHours: Double
    let avgAwakeMin: Int
    let detail: [StatsSleepDebtNightDTO]
}

private struct StatsStressBucketDTO: Encodable { let label: String; let nights: Int; let avgStress: Double? }
private struct StatsStressImpactDTO: Encodable { let nights: Int; let r: Double?; let significant: Bool; let buckets: [StatsStressBucketDTO] }
private struct StatsFragmentationPointDTO: Encodable { let date: String; let arousals: Int; let awakeMin: Int; let longestMin: Int }
private struct StatsFragmentationDTO: Encodable {
    let nights: Int; let avgArousals: Double; let avgAwakeMin: Int; let avgLongestMin: Int
    let series: [StatsFragmentationPointDTO]
}
private struct StatsCompositionRefDTO: Encodable { let deep: StatsRangeDTO; let light: StatsRangeDTO; let rem: StatsRangeDTO }
private struct StatsCompositionDTO: Encodable {
    let nights: Int; let deep: Double; let light: Double; let rem: Double; let wasoPct: Double
    let ref: StatsCompositionRefDTO
}
private struct StatsSpo2ArousalDTO: Encodable {
    let nights: Int; let desatTotal: Int; let desatNearPct: Double; let controlPct: Double
    let medianArousalMin: Int; let microArousals: Int; let totalArousals: Int
}
private struct StatsSleepInsightsDTO: Encodable {
    let stressImpact: StatsStressImpactDTO
    let fragmentation: StatsFragmentationDTO
    let composition: StatsCompositionDTO
    let spo2Arousal: StatsSpo2ArousalDTO?
}

private struct StatsSleepRecommendationDTO: Encodable {
    var nights: Int
    var status: String
    var basis: String? = nil
    var targetHours: Double? = nil
    var avgSleepHours: Double? = nil
    var waketime: String? = nil
    var currentBedtime: String? = nil
    var recommendedBedtime: String? = nil
    var targetBedtime: String? = nil
    var stepped: Bool? = nil
    var stepMin: Int? = nil
    var latencyMin: Int? = nil
    var shiftMin: Int? = nil
    var avgAwakeMin: Int? = nil
    var debtHours: Double? = nil
    var debtBonusMin: Int? = nil
    var idealHours: Double? = nil
    var idealLowHours: Double? = nil
    var idealHighHours: Double? = nil
    var belowFloor: Bool? = nil
    var modelNights: Int? = nil
    var trial: Bool? = nil
    // Ajouts v1.2 (couche contextuelle, `docs/duree-ideale-sommeil.md` §10) —
    // tous optionnels : absents du JSON quand `nil` (`JSONEncoder` omet `nil`),
    // donc contrat inchangé pour un client qui les ignore.
    var waketimeWorkday: String? = nil
    var waketimeFreeDay: String? = nil
    var nightDate: String? = nil
    var nightIdealHours: Double? = nil

    static func insufficient(nights: Int) -> StatsSleepRecommendationDTO {
        StatsSleepRecommendationDTO(nights: nights, status: "insufficient")
    }

    static func ok(
        _ ok: SleepRecommendationLocal.OK, nightDate: String? = nil, nightIdealHours: Double? = nil
    ) -> StatsSleepRecommendationDTO {
        StatsSleepRecommendationDTO(
            nights: ok.nights, status: "ok", basis: ok.basis, targetHours: ok.targetHours,
            avgSleepHours: ok.avgSleepHours, waketime: ok.waketime, currentBedtime: ok.currentBedtime,
            recommendedBedtime: ok.recommendedBedtime, targetBedtime: ok.targetBedtime, stepped: ok.stepped,
            stepMin: ok.stepMin, latencyMin: ok.latencyMin, shiftMin: ok.shiftMin, avgAwakeMin: ok.avgAwakeMin,
            debtHours: ok.debtHours, debtBonusMin: ok.debtBonusMin, idealHours: ok.idealHours,
            idealLowHours: ok.idealLowHours, idealHighHours: ok.idealHighHours, belowFloor: ok.belowFloor,
            modelNights: ok.modelNights, trial: ok.trial,
            waketimeWorkday: ok.waketimeWorkday, waketimeFreeDay: ok.waketimeFreeDay,
            nightDate: nightDate, nightIdealHours: nightIdealHours)
    }
}

private struct StatsSleepRegularityDTO: Encodable {
    let nights: Int
    let score: Int?
    let bedtime: String?
    let waketime: String?
    let bedStdMin: Int?
    let wakeStdMin: Int?
}

private struct StatsTrainingWeekDTO: Encodable {
    let week: String; let label: String; let load: Int; let durationS: Double
    let sessions: Int; let avg4: Int?; let overload: Bool
}
private struct StatsSportShareDTO: Encodable { let sport: String; let durationS: Double; let pct: Int }
private struct StatsStreakDTO: Encodable { let best: Int; let current: Int }
private struct StatsZoneDTO: Encodable { let zone: Int; let seconds: Double }
private struct StatsPeriodRecordDTO: Encodable { let value: Double; let date: String?; let label: String? }
private struct StatsTrainingRecordsDTO: Encodable {
    let longestSession: StatsPeriodRecordDTO?
    let longestDistance: StatsPeriodRecordDTO?
    let bestPace: StatsPeriodRecordDTO?
    let heaviestWeek: StatsPeriodRecordDTO?
    let maxHr: StatsPeriodRecordDTO?
}
private struct StatsTrainingTabDTO: Encodable {
    let days: Int; let count: Int; let totalS: Double; let perWeek: Double
    let avgHr: Int?; let activeKcal: Int; let deltaPct: Int?
    let weeks: [StatsTrainingWeekDTO]; let shares: [StatsSportShareDTO]
    let streak: StatsStreakDTO; let zones: [StatsZoneDTO]; let records: StatsTrainingRecordsDTO
}

private struct StatsNutritionDayDTO: Encodable { let date: String; let kcal: Int?; let expenditure: Int?; let state: String }
private struct StatsMacroDTO: Encodable { let key: String; let label: String; let grams: Int?; let pct: Int }
private struct StatsTopFoodDTO: Encodable { let name: String; let uses: Int; let kcal: Int; let protein: Int; let pct: Int }
private struct StatsNutritionTabDTO: Encodable {
    let days: Int; let kcalPerDay: Int?; let expenditurePerDay: Int?; let balance: Int?; let proteinPerDay: Int?
    let daysLogged: Int; let completeDays: Int; let entriesPerDay: Double
    let series: [StatsNutritionDayDTO]; let macros: [StatsMacroDTO]; let topFoods: [StatsTopFoodDTO]; let totalEntries: Int
}

// MARK: - Assemblage des endpoints (appelé depuis `RealLocalPulseBackend.handle`)

enum DashboardStatsBackend {

    // MARK: sleep-debt

    static func sleepDebt(db: LocalDb, query: [String: String]) throws -> Data {
        let nightLimit = DashboardStatsTime.rangeDays(query["days"])
        let targetHours = 7
        let targetS = Double(targetHours) * 3600
        let latest = try db.latestSleepNightDate()
        let since = DashboardStatsTime.sinceDateAnchored(days: nightLimit, anchor: latest)
        var rows = try db.statsSleepDebtRows(since: since, limit: nightLimit)
        rows.reverse() // DESC -> ASC (le plus ancien d'abord), comme `rows.reverse()` côté TS.

        guard !rows.isEmpty else {
            let dto = StatsSleepDebtDTO(
                nights: 0, targetHours: targetHours, debtHours: 0, avgHours: 0,
                deficitNights: 0, avgInBedHours: 0, avgAwakeMin: 0, detail: [])
            return try JSONEncoder().encode(dto)
        }

        func round1(_ v: Double) -> Double { (v * 10).rounded() / 10 }
        var cumulativeS = 0.0
        var detail: [StatsSleepDebtNightDTO] = []
        for r in rows {
            let sleepS = r.deepS + r.lightS + r.remS
            let deltaS = sleepS - targetS
            cumulativeS += targetS - sleepS
            detail.append(StatsSleepDebtNightDTO(
                date: r.date, sleepS: Int(sleepS.rounded()), inBedS: Int((sleepS + r.awakeS).rounded()),
                awakeS: Int(r.awakeS.rounded()), deltaS: Int(deltaS.rounded()), cumulativeS: Int(cumulativeS.rounded()),
                score: r.score.map { Int($0.rounded()) }, bedtime: r.startTs.map(DashboardStatsTime.clockOf)))
        }
        let totalSleepS = detail.reduce(0.0) { $0 + Double($1.sleepS) }
        let totalInBedS = detail.reduce(0.0) { $0 + Double($1.inBedS) }
        let totalAwakeS = detail.reduce(0.0) { $0 + Double($1.awakeS) }
        let dto = StatsSleepDebtDTO(
            nights: rows.count, targetHours: targetHours,
            debtHours: round1(cumulativeS / 3600), avgHours: round1(totalSleepS / Double(rows.count) / 3600),
            deficitNights: detail.filter { $0.deltaS < 0 }.count,
            avgInBedHours: round1(totalInBedS / Double(rows.count) / 3600),
            avgAwakeMin: Int((totalAwakeS / Double(rows.count) / 60).rounded()),
            detail: detail)
        return try JSONEncoder().encode(dto)
    }

    // MARK: sleep-insights

    private static let sleepBucketDefs: [(label: String, min: Double, max: Double)] = [
        ("moins de 5 h", 0, 5), ("5 à 6 h", 5, 6), ("6 à 7 h", 6, 7), ("plus de 7 h", 7, 99),
    ]

    static func sleepInsights(db: LocalDb, query: [String: String]) throws -> Data {
        let window = DashboardStatsTime.rangeDays(query["days"])
        let since = DashboardStatsTime.sinceDateAnchored(days: window, anchor: nil)
        var rows = try db.statsSleepInsightRows(since: since, limit: window)
        rows.reverse()

        let dto = StatsSleepInsightsDTO(
            stressImpact: stressImpact(rows),
            fragmentation: fragmentation(rows),
            composition: composition(rows),
            spo2Arousal: try spo2Arousal(db: db, rows: rows))
        return try JSONEncoder().encode(dto)
    }

    private static func stressImpact(_ rows: [LocalDb.StatsSleepInsightRow]) -> StatsStressImpactDTO {
        let usable = rows.filter { $0.avgStress != nil }
        let buckets = sleepBucketDefs.map { b -> StatsStressBucketDTO in
            let inBucket = usable.filter { $0.sleepS / 3600 >= b.min && $0.sleepS / 3600 < b.max }
            let avg: Double? = inBucket.isEmpty
                ? nil : (DashboardStatsMath.mean(inBucket.map { $0.avgStress! }) * 10).rounded() / 10
            return StatsStressBucketDTO(label: b.label, nights: inBucket.count, avgStress: avg)
        }
        let fit = DashboardStatsMath.pearson(usable.map { ($0.sleepS / 3600, $0.avgStress!) })
        return StatsStressImpactDTO(
            nights: usable.count, r: fit.map { ($0.r * 100).rounded() / 100 },
            significant: fit.map { abs($0.t) > 2 } ?? false, buckets: buckets)
    }

    private static func fragmentation(_ rows: [LocalDb.StatsSleepInsightRow]) -> StatsFragmentationDTO {
        struct S { let date: String; let arousals: Int; let awakeMin: Int; let longestMin: Int }
        let series: [S] = rows.map { r in
            let phases = decodeSleepPhasesJSON(r.phases)
            var arousals = 0
            var longest = 0.0
            for i in phases.indices {
                guard phases[i].stage == "awake" else { continue }
                if i == 0 || phases[i - 1].stage != "awake" { arousals += 1 }
                longest = max(longest, phases[i].to - phases[i].from)
            }
            return S(date: r.date, arousals: arousals, awakeMin: Int((r.awakeS / 60).rounded()), longestMin: Int((longest / 60).rounded()))
        }
        guard !series.isEmpty else {
            return StatsFragmentationDTO(nights: 0, avgArousals: 0, avgAwakeMin: 0, avgLongestMin: 0, series: [])
        }
        let dtoSeries = series.map { StatsFragmentationPointDTO(date: $0.date, arousals: $0.arousals, awakeMin: $0.awakeMin, longestMin: $0.longestMin) }
        return StatsFragmentationDTO(
            nights: series.count,
            avgArousals: (DashboardStatsMath.mean(series.map { Double($0.arousals) }) * 10).rounded() / 10,
            avgAwakeMin: Int(DashboardStatsMath.mean(series.map { Double($0.awakeMin) }).rounded()),
            avgLongestMin: Int(DashboardStatsMath.mean(series.map { Double($0.longestMin) }).rounded()),
            series: dtoSeries)
    }

    private static let compositionRef = StatsCompositionRefDTO(
        deep: StatsRangeDTO(lo: 13, hi: 23), light: StatsRangeDTO(lo: 44, hi: 55), rem: StatsRangeDTO(lo: 20, hi: 25))

    private static func composition(_ rows: [LocalDb.StatsSleepInsightRow]) -> StatsCompositionDTO {
        let recent = rows.filter { $0.deepS + $0.lightS + $0.remS > 0 }
        guard !recent.isEmpty else {
            return StatsCompositionDTO(nights: 0, deep: 0, light: 0, rem: 0, wasoPct: 0, ref: compositionRef)
        }
        func pct(_ pick: (LocalDb.StatsSleepInsightRow) -> Double) -> Double {
            (DashboardStatsMath.mean(recent.map { pick($0) / ($0.deepS + $0.lightS + $0.remS) * 100 }) * 10).rounded() / 10
        }
        let wasoPct = (DashboardStatsMath.mean(recent.map {
            $0.awakeS / ($0.deepS + $0.lightS + $0.remS + $0.awakeS) * 100
        }) * 10).rounded() / 10
        return StatsCompositionDTO(
            nights: recent.count, deep: pct { $0.deepS }, light: pct { $0.lightS }, rem: pct { $0.remS },
            wasoPct: wasoPct, ref: compositionRef)
    }

    private static func spo2Arousal(db: LocalDb, rows: [LocalDb.StatsSleepInsightRow]) throws -> StatsSpo2ArousalDTO? {
        var nights = 0
        var desatTotal = 0, desatNear = 0, ctrlTotal = 0, ctrlNear = 0
        var arousalLens: [Double] = []

        for row in rows {
            let samples = try db.statsRawSamplesBetween(metric: "spo2", from: row.startTs, to: row.endTs)
            guard samples.count >= 30 else { continue }
            nights += 1
            let phases = decodeSleepPhasesJSON(row.phases)
            var onsets: [Double] = []
            for i in phases.indices {
                guard phases[i].stage == "awake" else { continue }
                if i == 0 || phases[i - 1].stage != "awake" { onsets.append(phases[i].from) }
                arousalLens.append(phases[i].to - phases[i].from)
            }
            guard !onsets.isEmpty else { continue }

            let sortedValues = samples.map { $0.value }.sorted()
            let median = sortedValues[sortedValues.count / 2]
            func near(_ ts: Double) -> Bool { onsets.contains { $0 >= ts - 180 && $0 <= ts + 180 } }

            var inDesat = false
            for s in samples {
                let isDesat = s.value <= median - 3
                if isDesat && !inDesat {
                    desatTotal += 1
                    if near(s.ts) { desatNear += 1 }
                    let shifted: Double?
                    if s.ts + 1800 < row.endTs { shifted = s.ts + 1800 }
                    else if s.ts - 1800 > row.startTs { shifted = s.ts - 1800 }
                    else { shifted = nil }
                    if let shifted {
                        ctrlTotal += 1
                        if near(shifted) { ctrlNear += 1 }
                    }
                }
                inDesat = isDesat
            }
        }

        guard nights > 0 else { return nil }
        let sortedLens = arousalLens.sorted()
        return StatsSpo2ArousalDTO(
            nights: nights, desatTotal: desatTotal,
            desatNearPct: desatTotal > 0 ? ((Double(desatNear) / Double(desatTotal)) * 1000).rounded() / 10 : 0,
            controlPct: ctrlTotal > 0 ? ((Double(ctrlNear) / Double(ctrlTotal)) * 1000).rounded() / 10 : 0,
            medianArousalMin: sortedLens.isEmpty ? 0 : Int((sortedLens[sortedLens.count / 2] / 60).rounded()),
            microArousals: arousalLens.filter { $0 < 300 }.count,
            totalArousals: arousalLens.count)
    }

    // MARK: sleep-regularity

    static func sleepRegularity(db: LocalDb, query: [String: String]) throws -> Data {
        let days = DashboardStatsTime.rangeDays(query["days"])
        let since = DashboardStatsTime.sinceDateAnchored(days: days, anchor: nil)
        let rows = try db.statsSleepStartEndRows(since: since, limit: days)
        guard rows.count >= 3 else {
            let dto = StatsSleepRegularityDTO(nights: rows.count, score: nil, bedtime: nil, waketime: nil, bedStdMin: nil, wakeStdMin: nil)
            return try JSONEncoder().encode(dto)
        }
        let offset = Double(TimeZone.current.secondsFromGMT(for: Date()))
        var bed: [Double] = []
        var wake: [Double] = []
        for r in rows {
            let bMin = ((r.startTs + offset).truncatingRemainder(dividingBy: 86400) + 86400)
                .truncatingRemainder(dividingBy: 86400) / 60
            let wMin = ((r.endTs + offset).truncatingRemainder(dividingBy: 86400) + 86400)
                .truncatingRemainder(dividingBy: 86400) / 60
            bed.append(((bMin - 720).truncatingRemainder(dividingBy: 1440) + 1440).truncatingRemainder(dividingBy: 1440))
            wake.append(wMin)
        }
        let bedStd = DashboardStatsMath.stdev(bed)
        let wakeStd = DashboardStatsMath.stdev(wake)
        let score = Int(DashboardStatsMath.clamp(100 - ((bedStd + wakeStd) / 2) * (100.0 / 180.0), 0, 100).rounded())
        let dto = StatsSleepRegularityDTO(
            nights: rows.count, score: score,
            bedtime: DashboardStatsTime.minToClock(DashboardStatsMath.mean(bed) + 720),
            waketime: DashboardStatsTime.minToClock(DashboardStatsMath.mean(wake)),
            bedStdMin: Int(bedStd.rounded()), wakeStdMin: Int(wakeStd.rounded()))
        return try JSONEncoder().encode(dto)
    }

    // MARK: sleep-recommendation (§7, `docs/duree-ideale-sommeil.md`)
    //
    // Deux fenêtres DISTINCTES : `windowRows` (fenêtre de l'ENDPOINT, `days`
    // query — lever/coucher/latence/paliers + dette, miroir exact de l'ancien
    // comportement) et `modelRows` (180 dernières nuits FIXES, spec §2 — le
    // modèle bayésien de durée idéale). `targetHours`/`basis`/l'intervalle
    // viennent du modèle ; tout le reste (lever/coucher/paliers) de la fenêtre
    // de l'endpoint.

    static func sleepRecommendation(
        db: LocalDb, query: [String: String], cache: SleepModelCache = SleepModelCache()
    ) throws -> Data {
        let window = DashboardStatsTime.rangeDays(query["days"])
        let since = DashboardStatsTime.sinceDateAnchored(days: window, anchor: nil)
        let windowRows = try db.sleepRecommendationWindowNights(since: since, limit: window)

        guard windowRows.count >= 3 else {
            return try JSONEncoder().encode(StatsSleepRecommendationDTO.insufficient(nights: windowRows.count))
        }

        let nowS = Date().timeIntervalSince1970
        let bundle = try cache.bundle(db: db, nowS: nowS)

        let recoNights = windowRows.map { row in
            SleepRecommendationLocal.RecoNight(
                date: row.date, startTs: row.startTs, endTs: row.endTs,
                deepS: row.deepS, lightS: row.lightS, remS: row.remS, awakeS: row.awakeS,
                offsetS: LocalDb.localOffsetSeconds(forDate: row.date))
        }
        let todayKey = FitWellnessExtractor.isoDate(nowS)
        let result = SleepRecommendationLocal.computeSleepRecommendation(
            nights: recoNights, fit: bundle.fit, todayKey: todayKey)

        switch result {
        case .insufficient(let n):
            return try JSONEncoder().encode(StatsSleepRecommendationDTO.insufficient(nights: n))
        case .ok(let ok):
            // Durée idéale de LA nuit demandée (`date`, jour de RÉVEIL) — optionnel.
            var nightDate: String?
            var nightIdeal: Double?
            if let date = query["date"], isDateKey(date) {
                nightDate = date
                nightIdeal = try nightIdealHours(db: db, bundle: bundle, date: date, nowS: nowS)
            }
            return try JSONEncoder().encode(
                StatsSleepRecommendationDTO.ok(ok, nightDate: nightDate, nightIdealHours: nightIdeal))
        }
    }

    /// `YYYY-MM-DD` valide (aller-retour par le formateur UTC : rejette
    /// `2026-13-45`, `abc`, etc.).
    static func isDateKey(_ s: String) -> Bool {
        s.count == 10 && FitWellnessExtractor.isoDate(DashboardStatsTime.dayStartUnixUTC(s)) == s
    }

    /// Durée idéale contextuelle de la nuit de réveil `date`. Nuit mesurée du
    /// modèle → ses covariables brutes ; sinon (à venir / pas encore
    /// synchronisée) → covariables calculées avec un endormissement de
    /// référence (`SleepOptimumContext.onsetReference`), les petites fenêtres
    /// d'échantillons (≤ 24 h avant l'endormissement) étant relues dans la base
    /// À CHAQUE appel — elles évoluent à chaque synchro, contrairement aux deux
    /// ajustements du bundle, mis en cache.
    private static func nightIdealHours(db: LocalDb, bundle: SleepModelBundle, date: String, nowS: Double) throws -> Double {
        guard let model = bundle.context else { return bundle.fit.idealHours }
        let covariates: SleepOptimumContext.Covariates
        if let night = bundle.nightInputs.first(where: { $0.date == date }) {
            covariates = SleepOptimumContext.Covariates(night: night)
        } else {
            let eve = FitWellnessExtractor.isoDate(DashboardStatsTime.dayStartUnixUTC(date) - 86400)
            let onsetRef = SleepOptimumContext.onsetReference(
                date: date, nowS: nowS, habitualOnsetMin: bundle.habitualOnsetMin,
                offsetS: LocalDb.localOffsetSeconds(forDate: eve))
            let bb = try db.statsRawSamplesBetween(metric: "bb", from: onsetRef - 3600, to: onsetRef + 1)
            let stress = try db.statsRawSamplesBetween(
                metric: "stress", from: onsetRef - 14 * 3600, to: onsetRef - 1800 + 1)
            let activityRows = try db.statsActivitiesSince(DashboardStatsTime.isoDateTime(onsetRef - 24 * 3600))
            let activities: [SleepRecommendationLocal.ActivityWindow] = activityRows.compactMap { row in
                guard let d = DashboardStatsTime.activityDate(row.startTime) else { return nil }
                return SleepRecommendationLocal.ActivityWindow(
                    startTs: d.timeIntervalSince1970, durationMin: (row.durationS ?? 0) / 60)
            }
            covariates = SleepOptimumContext.upcomingNightCovariates(
                date: date, onsetRef: onsetRef,
                bbSamples: bb.map { SleepRecommendationLocal.Sample(ts: $0.ts, value: $0.value) },
                stressSamples: stress.map { SleepRecommendationLocal.Sample(ts: $0.ts, value: $0.value) },
                activities: activities, sleepByDate: bundle.sleepByDate)
        }
        return SleepOptimumContext.nightIdealHours(model: model, covariates: covariates)
    }

    /// Les deux ajustements (global p = 21, contextuel p = 25) + les données
    /// nécessaires au calcul PAR DATE (nuits agrégées, S par date,
    /// endormissement habituel) — ce que `SleepModelCache` conserve.
    struct SleepModelBundle {
        let fit: SleepOptimumModel.Fit
        /// `nil` sans nuit retenue (rien à ajuster).
        let context: SleepOptimumContext.Model?
        let nightInputs: [SleepOptimumNightInput]
        let sleepByDate: [String: Double]
        let habitualOnsetMin: Double?
    }

    /// Ajuste le modèle bayésien de durée idéale (spec §2-6) sur les 180
    /// dernières nuits (`S ∈ [3, 12]` h), indépendamment de `days`, puis le
    /// modèle contextuel par-dessus. Charge les échantillons `bb`/`stress`/
    /// activités sur UNE plage englobant toutes les fenêtres par-nuit
    /// nécessaires (§3-4), puis délègue l'agrégation (PURE) à
    /// `SleepRecommendationLocal.buildModelNights`.
    static func buildSleepModelBundle(db: LocalDb, modelRows: [LocalDb.SleepOptimumNightRow], nowS: Double) throws -> SleepModelBundle {
        guard !modelRows.isEmpty else {
            return SleepModelBundle(
                fit: SleepOptimumModel.fit(X: [], y: []), context: nil, nightInputs: [],
                sleepByDate: [:], habitualOnsetMin: nil)
        }

        let modelNights: [SleepRecommendationLocal.ModelRawNight] = modelRows.map { row in
            SleepRecommendationLocal.ModelRawNight(
                date: row.date, startTs: row.startTs, endTs: row.endTs,
                S: (row.deepS + row.lightS + row.remS) / 3600,
                offsetS: LocalDb.localOffsetSeconds(forDate: row.date))
        }

        let minStartTs = modelNights.map(\.startTs).min()!
        let maxEndTs = modelNights.map(\.endTs).max()!

        // Plage englobant §3 (bbMorning [wk,wk+2h], bbEvening ~wk+10h±30min,
        // wakeStress jusqu'à +16h) et §4 (bbBed [on-60min,on], stressPrevDay
        // [on-14h,on-30min], sportPrev [on-24h,on], sportNext [wk,wk+12h]).
        let stressRaw = try db.statsRawSamplesBetween(
            metric: "stress", from: minStartTs - 14 * 3600, to: maxEndTs + 16 * 3600 + 1)
        let bbRaw = try db.statsRawSamplesBetween(
            metric: "bb", from: minStartTs - 3600, to: maxEndTs + 11 * 3600)
        let activityRows = try db.statsActivitiesSince(
            DashboardStatsTime.isoDateTime(minStartTs - 24 * 3600))

        let windows = modelNights.map { SleepRecommendationLocal.NightWindow(startTs: $0.startTs, endTs: $0.endTs) }
        let stressForWake = stressRaw.map { SleepRecommendationLocal.StressSample(ts: $0.ts, value: $0.value) }
        let wakeStresses = SleepRecommendationLocal.wakeStressByNight(nights: windows, samples: stressForWake, nowS: nowS)

        let bbSamples = bbRaw.map { SleepRecommendationLocal.Sample(ts: $0.ts, value: $0.value) }
        let stressSamples = stressRaw.map { SleepRecommendationLocal.Sample(ts: $0.ts, value: $0.value) }
        let activities: [SleepRecommendationLocal.ActivityWindow] = activityRows.compactMap { row in
            guard let date = DashboardStatsTime.activityDate(row.startTime) else { return nil }
            return SleepRecommendationLocal.ActivityWindow(
                startTs: date.timeIntervalSince1970, durationMin: (row.durationS ?? 0) / 60)
        }

        let nightInputs = SleepRecommendationLocal.buildModelNights(
            nights: modelNights, bbSamples: bbSamples, stressSamples: stressSamples,
            activities: activities, wakeStresses: wakeStresses)
        let built = SleepOptimumFeatures.build(nights: nightInputs)
        let fit = SleepOptimumModel.fit(X: built.X, y: built.y)
        let context = SleepOptimumContext.fit(built: built, globalFit: fit)
        var sByDate: [String: Double] = [:]
        for n in modelNights { sByDate[n.date] = n.S }
        return SleepModelBundle(
            fit: fit, context: context, nightInputs: nightInputs, sleepByDate: sByDate,
            habitualOnsetMin: SleepOptimumContext.habitualOnsetMin(nights: modelNights))
    }

    // MARK: tab-health

    static func tabHealth(db: LocalDb, query: [String: String]) throws -> Data {
        let days = DashboardStatsTime.rangeDays(query["days"])
        let sinceDate = DashboardStatsTime.sinceDateNow(days: days)

        let restingRows = try db.statsRestingHrSince(sinceDate)
        let restingSeries = restingRows.map { StatsHealthPointDTO(date: $0.date, value: $0.value) }
        let nights = try db.statsNightsSince(sinceDate)

        var respirationSeries: [StatsHealthPointDTO] = []
        var spo2Nights: [Double] = []
        var spo2ByDate: [String: Double] = [:]
        for n in nights {
            if let resp = try db.statsNightAvg(metric: "respiration", from: n.startTs, to: n.endTs) {
                respirationSeries.append(StatsHealthPointDTO(date: n.date, value: (resp * 10).rounded() / 10))
            }
            if let spo2 = try db.statsNightAvg(metric: "spo2", from: n.startTs, to: n.endTs) {
                spo2Nights.append(spo2)
                spo2ByDate[n.date] = spo2
            }
        }

        let bucketDefs: [(label: String, min: Double, max: Double)] = [
            ("<90", 0, 90), ("91", 90, 91.5), ("92", 91.5, 92.5), ("93", 92.5, 93.5), ("94", 93.5, 94.5), ("95+", 94.5, 101),
        ]
        let buckets = bucketDefs.map { b in
            StatsSpo2BucketDTO(label: b.label, nights: spo2Nights.filter { $0 >= b.min && $0 < b.max }.count)
        }

        let stressAvg = try db.statsAvgStressSince(tsFrom: DashboardStatsTime.dayStartUnixUTC(sinceDate))
        let weights = try db.statsWeightsSince(sinceDate)
        let weightSeries = weights.map { StatsWeightPointDTO(date: $0.date, kg: $0.kg) }

        let respValues = respirationSeries.map { $0.value }
        let respMean = DashboardStatsMath.mean(respValues)
        let respStd = DashboardStatsMath.stdev(respValues)

        let stressByDate = try db.statsStressAvgByDate()
        let stepsByDate = try db.statsStepsSumByDate()
        let restingByDate = Dictionary(uniqueKeysWithValues: restingSeries.map { ($0.date, $0.value) })
        let loadByDate = try db.statsLoadByDate()

        func nextDay(_ date: String) -> String {
            FitWellnessExtractor.isoDate(DashboardStatsTime.dayStartUnixUTC(date) + 86400)
        }

        var pairsSleepStress: [(Double, Double)] = []
        for n in nights {
            if let stress = stressByDate[nextDay(n.date)] { pairsSleepStress.append((n.sleepS / 3600, stress)) }
        }
        var pairsLoadResting: [(Double, Double)] = []
        for (date, load) in loadByDate {
            if let resting = restingByDate[nextDay(date)] { pairsLoadResting.append((load, resting)) }
        }
        var pairsStepsSpo2: [(Double, Double)] = []
        for (date, steps) in stepsByDate {
            if let spo2 = spo2ByDate[nextDay(date)] { pairsStepsSpo2.append((steps, spo2)) }
        }

        func correlation(_ label: String, _ pairs: [(Double, Double)]) -> StatsCorrelationDTO {
            guard let fit = DashboardStatsMath.pearson(pairs) else {
                return StatsCorrelationDTO(label: label, r: nil, strength: "trop peu de données", pairs: pairs.count)
            }
            let absR = abs(fit.r)
            let strength = absR >= 0.5 ? "fort" : (absR >= 0.3 ? "moyen" : "faible")
            return StatsCorrelationDTO(label: label, r: (fit.r * 100).rounded() / 100, strength: strength, pairs: pairs.count)
        }

        func avgOrNil(_ list: [Double]) -> Double? { list.isEmpty ? nil : (DashboardStatsMath.mean(list) * 10).rounded() / 10 }

        let dto = StatsHealthTabDTO(
            days: days,
            restingHr: avgOrNil(restingSeries.map { $0.value }),
            respiration: avgOrNil(respValues),
            spo2Night: avgOrNil(spo2Nights),
            stress: stressAvg.map { Int($0.rounded()) },
            weightKg: weights.last?.kg,
            sleepHours: avgOrNil(nights.map { $0.sleepS / 3600 }),
            restingSeries: restingSeries,
            restingDelta: restingSeries.count > 4
                ? (DashboardStatsMath.mean(restingSeries.suffix(7).map { $0.value })
                    - DashboardStatsMath.mean(restingSeries.prefix(7).map { $0.value })).rounded()
                : nil,
            respirationSeries: respirationSeries,
            respirationBand: respValues.count > 4
                ? StatsRangeDTO(lo: ((respMean - respStd) * 10).rounded() / 10, hi: ((respMean + respStd) * 10).rounded() / 10)
                : nil,
            spo2Buckets: buckets,
            spo2Nights: spo2Nights.count,
            weightSeries: weightSeries,
            weightDelta: weights.count > 1 ? ((weights.last!.kg - weights.first!.kg) * 10).rounded() / 10 : nil,
            correlations: [
                correlation("Sommeil ↔ stress du lendemain", pairsSleepStress),
                correlation("Charge ↔ FC repos", pairsLoadResting),
                correlation("Pas ↔ SpO2", pairsStepsSpo2),
            ])
        return try JSONEncoder().encode(dto)
    }

    // MARK: tab-training (miroir partiel — `zones` toujours vide, cf. en-tête de fichier)

    static func tabTraining(db: LocalDb, query: [String: String]) throws -> Data {
        let days = DashboardStatsTime.rangeDays(query["days"])
        let nowS = Date().timeIntervalSince1970
        let sinceFull = DashboardStatsTime.isoDateTime(nowS - Double(days) * 86400)
        let previousSinceFull = DashboardStatsTime.isoDateTime(nowS - Double(2 * days) * 86400)
        let sinceDateOnly = String(sinceFull.prefix(10))

        let rows = try db.statsActivitiesSince(sinceFull)
        let previousTotal = try db.statsActivityDurationSum(from: previousSinceFull, until: sinceFull)

        let totalS = rows.reduce(0.0) { $0 + ($1.durationS ?? 0) }
        let hrRows = rows.filter { $0.avgHr != nil && ($0.durationS ?? 0) != 0 }
        let avgHr: Int? = hrRows.isEmpty ? nil : Int((
            hrRows.reduce(0.0) { $0 + $1.avgHr! * ($1.durationS ?? 0) } /
            hrRows.reduce(0.0) { $0 + ($1.durationS ?? 0) }
        ).rounded())
        let activeKcal = try db.statsActiveCaloriesSince(sinceDateOnly)
        let wornDays = try db.statsWornDaysSince(sinceDateOnly)

        // Regroupement par semaine ISO (charge/durée/sessions), miroir de `weekMap`/`weeks` (TS).
        struct WeekAgg { var load = 0.0; var durationS = 0.0; var count = 0 }
        var weekMap: [String: WeekAgg] = [:]
        for r in rows {
            guard let date = DashboardStatsTime.activityDate(r.startTime) else { continue }
            let key = DashboardStatsTime.isoWeekMonday(date)
            var entry = weekMap[key] ?? WeekAgg()
            entry.load += ((r.durationS ?? 0) / 60) * ((r.avgHr ?? 100) / 100)
            entry.durationS += r.durationS ?? 0
            entry.count += 1
            weekMap[key] = entry
        }
        let weekKeys = weekMap.keys.sorted()
        var weeks: [StatsTrainingWeekDTO] = []
        for (i, key) in weekKeys.enumerated() {
            let entry = weekMap[key]!
            let windowKeys = weekKeys[max(0, i - 4)..<i]
            let windowLoads = windowKeys.map { weekMap[$0]!.load }
            let avg4: Double? = windowLoads.isEmpty ? nil : DashboardStatsMath.mean(windowLoads)
            weeks.append(StatsTrainingWeekDTO(
                week: key, label: "S\(DashboardStatsTime.isoWeekNumber(DashboardStatsTime.dateFromISODate(key)))",
                load: Int(entry.load.rounded()), durationS: entry.durationS, sessions: entry.count,
                avg4: avg4.map { Int($0.rounded()) },
                overload: avg4 != nil && avg4! > 0 && entry.load > avg4! * 1.3))
        }

        var sportMap: [String: Double] = [:]
        for r in rows { sportMap[r.sport ?? "inconnu", default: 0] += r.durationS ?? 0 }
        let shares = sportMap.map { sport, durationS in
            StatsSportShareDTO(sport: sport, durationS: durationS, pct: totalS > 0 ? Int(((durationS / totalS) * 100).rounded()) : 0)
        }.sorted { $0.durationS > $1.durationS }

        let allWeeks = try db.statsAllWeeksActivityCounts()
        var best = 0, current = 0
        for w in allWeeks {
            if w.n >= 3 { current += 1; best = max(best, current) } else { current = 0 }
        }

        func pick(_ list: [LocalDb.StatsActivityRow], _ key: (LocalDb.StatsActivityRow) -> Double?) -> StatsPeriodRecordDTO? {
            var bestRow: LocalDb.StatsActivityRow?
            var bestValue = -Double.infinity
            for r in list {
                if let v = key(r), v > bestValue { bestValue = v; bestRow = r }
            }
            guard bestRow != nil else { return nil }
            return StatsPeriodRecordDTO(value: bestValue, date: bestRow!.startTime, label: nil)
        }
        let walks = rows.filter { $0.sport == "walking" || $0.sport == "running" }
        let paced = rows.filter { ($0.distanceM ?? 0) >= 4000 && ($0.durationS ?? 0) > 0 }
        var bestPace: StatsPeriodRecordDTO?
        for r in paced {
            let pace = r.durationS! / (r.distanceM! / 1000)
            if bestPace == nil || pace < bestPace!.value {
                bestPace = StatsPeriodRecordDTO(value: pace, date: r.startTime, label: nil)
            }
        }
        let heaviestWeek = weeks.max { $0.durationS < $1.durationS }

        let dto = StatsTrainingTabDTO(
            days: days, count: rows.count, totalS: totalS,
            perWeek: wornDays > 0 ? ((Double(rows.count) / Double(wornDays)) * 7 * 10).rounded() / 10 : 0,
            avgHr: avgHr, activeKcal: Int(activeKcal.rounded()),
            deltaPct: previousTotal > 0 ? Int((((totalS - previousTotal) / previousTotal) * 100).rounded()) : nil,
            weeks: weeks, shares: shares, streak: StatsStreakDTO(best: best, current: current),
            zones: [], // non calculé — cf. en-tête de fichier (pas de reparse `.fit` par activité).
            records: StatsTrainingRecordsDTO(
                longestSession: pick(rows) { $0.durationS },
                longestDistance: pick(walks) { $0.distanceM },
                bestPace: bestPace,
                heaviestWeek: heaviestWeek.map { StatsPeriodRecordDTO(value: $0.durationS, date: nil, label: $0.label) },
                maxHr: pick(rows) { $0.maxHr }))
        return try JSONEncoder().encode(dto)
    }

    // MARK: tab-nutrition (miroir intégral, cf. en-tête de fichier)

    static func tabNutrition(db: LocalDb, query: [String: String]) throws -> Data {
        let days = DashboardStatsTime.rangeDays(query["days"])
        let sinceDate = DashboardStatsTime.sinceDateNow(days: days)
        let nowS = Date().timeIntervalSince1970

        let logged = try db.statsFoodLogDailyTotals(since: sinceDate)
        let loggedMap = Dictionary(uniqueKeysWithValues: logged.map { ($0.date, $0) })
        let expenditureByDate = try db.statsExpenditureByDate(since: sinceDate)

        let targetRaw = try db.settingValue(key: "nutritionKcal")
        let targetKcal = targetRaw.flatMap(Double.init)
        let completeThreshold = targetKcal.map { $0 * 0.6 } ?? 1200

        var series: [StatsNutritionDayDTO] = []
        for i in stride(from: days - 1, through: 0, by: -1) {
            let date = FitWellnessExtractor.isoDate(nowS - Double(i) * 86400)
            let row = loggedMap[date]
            let kcal = row?.kcal
            let state: String
            if kcal == nil { state = "none" } else if kcal! >= completeThreshold { state = "complete" } else { state = "partial" }
            series.append(StatsNutritionDayDTO(
                date: date, kcal: kcal.map { Int($0.rounded()) },
                expenditure: expenditureByDate[date].map { Int($0) }, state: state))
        }

        let completeDays = series.filter { $0.state == "complete" }
        func avgOf(_ pick: (LocalDb.StatsFoodLogDailyRow) -> Double?) -> Int? {
            let values = completeDays.compactMap { loggedMap[$0.date] }.compactMap(pick)
            return values.isEmpty ? nil : Int(DashboardStatsMath.mean(values).rounded())
        }
        let kcalPerDay = avgOf { $0.kcal }
        let proteinPerDay = avgOf { $0.protein }
        let carbsPerDay = avgOf { $0.carbs }
        let fatPerDay = avgOf { $0.fat }
        let expenditureValues = completeDays.compactMap { $0.expenditure }
        let expenditurePerDay = expenditureValues.isEmpty
            ? nil : Int(DashboardStatsMath.mean(expenditureValues.map(Double.init)).rounded())

        let macroKcal = Double(proteinPerDay ?? 0) * 4 + Double(carbsPerDay ?? 0) * 4 + Double(fatPerDay ?? 0) * 9
        func macroPct(_ kcal: Double) -> Int { macroKcal > 0 ? Int(((kcal / macroKcal) * 100).rounded()) : 0 }
        let macros = [
            StatsMacroDTO(key: "protein", label: "Protéines", grams: proteinPerDay, pct: macroPct(Double(proteinPerDay ?? 0) * 4)),
            StatsMacroDTO(key: "carbs", label: "Glucides", grams: carbsPerDay, pct: macroPct(Double(carbsPerDay ?? 0) * 4)),
            StatsMacroDTO(key: "fat", label: "Lipides", grams: fatPerDay, pct: macroPct(Double(fatPerDay ?? 0) * 9)),
        ]

        let totalEntries = logged.reduce(0) { $0 + $1.entries }
        let totalKcal = logged.reduce(0.0) { $0 + ($1.kcal ?? 0) }
        let topFoodsRaw = try db.statsTopFoods(since: sinceDate, limit: 5)
        let topFoods = topFoodsRaw.map { f -> StatsTopFoodDTO in
            let kcal = f.kcal ?? 0
            return StatsTopFoodDTO(
                name: f.name, uses: f.uses, kcal: Int(kcal.rounded()), protein: Int((f.protein ?? 0).rounded()),
                pct: totalKcal > 0 ? Int(((kcal / totalKcal) * 100).rounded()) : 0)
        }

        let dto = StatsNutritionTabDTO(
            days: days, kcalPerDay: kcalPerDay, expenditurePerDay: expenditurePerDay,
            balance: (kcalPerDay != nil && expenditurePerDay != nil) ? kcalPerDay! - expenditurePerDay! : nil,
            proteinPerDay: proteinPerDay, daysLogged: logged.count, completeDays: completeDays.count,
            entriesPerDay: logged.isEmpty ? 0 : ((Double(totalEntries) / Double(logged.count)) * 10).rounded() / 10,
            series: series, macros: macros, topFoods: topFoods, totalEntries: totalEntries)
        return try JSONEncoder().encode(dto)
    }
}

// MARK: - Cache mémoire des ajustements `sleep-recommendation`

/// Garde en mémoire, PAR backend (donc par base : pas de collision entre deux
/// bases de test), le résultat des deux ajustements bayésiens et les données du
/// calcul par date — le recalcul complet relit jusqu'à 180 nuits
/// d'échantillons, trop lourd à refaire à chaque changement de date de l'écran
/// Sommeil. Clé : nombre de nuits retenues + date et fin de la dernière nuit +
/// jour courant (local) ; elle change dès qu'une nuit s'ajoute / est resynchronisée
/// ou que le jour tourne (`wakeStress` dépend de « maintenant »). Une nuit
/// ancienne modifiée sans changer ces quatre valeurs n'invalide PAS le cache
/// (accepté : l'idéal bouge à peine et le jour suivant le renouvelle).
final class SleepModelCache {
    struct Key: Equatable {
        let nights: Int
        let lastDate: String?
        let lastEndTs: Double?
        let day: String
    }

    private let lock = NSLock()
    private var key: Key?
    private var cached: DashboardStatsBackend.SleepModelBundle?
    /// Nombre de recalculs complets effectués (diagnostic / tests).
    private(set) var computeCount = 0

    func bundle(db: LocalDb, nowS: Double) throws -> DashboardStatsBackend.SleepModelBundle {
        let rows = try db.sleepOptimumModelNights(limit: 180).filter { row in
            let s = (row.deepS + row.lightS + row.remS) / 3600
            return s >= 3 && s <= 12
        }
        let latest = rows.max { $0.date < $1.date }
        let newKey = Key(
            nights: rows.count, lastDate: latest?.date, lastEndTs: latest?.endTs, day: Self.localDayKey(nowS))
        lock.lock()
        defer { lock.unlock() }
        if let cached, key == newKey { return cached }
        let fresh = try DashboardStatsBackend.buildSleepModelBundle(db: db, modelRows: rows, nowS: nowS)
        cached = fresh
        key = newKey
        computeCount += 1
        return fresh
    }

    static func localDayKey(_ nowS: Double) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: Date(timeIntervalSince1970: nowS))
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}
