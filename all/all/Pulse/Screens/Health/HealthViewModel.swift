//
//  HealthViewModel.swift
//  all (bridge-connect)
//
//  État + logique réseau de l'écran Santé. Miroir de `HealthComponent`
//  (Angular) mais adapté au style vue-modèle iOS : un seul point d'entrée
//  `load()` (chargement initial), navigation de jour (`shiftDay`/`selectDate`)
//  qui recharge le détail du jour + l'intensité. Le poids vit dans l'écran
//  Nutrition (`NutritionWeightCard.swift`).
//

import Foundation
import Observation

@MainActor
@Observable
final class HealthViewModel {

    /// Correspond aux onglets `tabs` du composant Angular (`cardio`, `stress`,
    /// `energie`, `spo2`, `respiration`, `calories`).
    enum MetricTab: String, CaseIterable, Identifiable, Hashable {
        case cardio, stress, energie, spo2, respiration, calories

        var id: String { rawValue }

        var label: String {
            switch self {
            case .cardio: return "Cardio"
            case .stress: return "Stress"
            case .energie: return "Énergie"
            case .spo2: return "SpO2"
            case .respiration: return "Resp."
            case .calories: return "Calories"
            }
        }
    }

    // MARK: - État exposé

    private(set) var isLoading = false
    private(set) var errorMessage: String?
    /// Vrai dès que le premier chargement a abouti : le contenu reste alors
    /// TOUJOURS visible (un rechargement le remplace à l'arrivée de la réponse,
    /// un échec ne le vide pas — bandeau d'erreur discret). Avant : plein écran
    /// de chargement/erreur.
    private(set) var hasContent = false
    /// Vrai pendant que le détail d'une AUTRE date charge : `day` est alors
    /// `nil` (jamais les données de l'ancienne date), la vue garde la structure
    /// de la page avec des emplacements réservés.
    private(set) var isDayLoading = false

    private(set) var date: String = HealthViewModel.todayKey()
    private(set) var maxDate: String = HealthViewModel.todayKey()
    private(set) var days30: [WellnessDayRow] = []
    private(set) var day: WellnessDayDetail?
    private(set) var intensity: IntensityDayDetail?
    /// Distingue « pas encore chargée » de « a échoué » pour `IntensityCard`
    /// (miroir de `failed`/`detail` dans `IntensityDayCardComponent`) — les
    /// deux cas laissent `intensity` à `nil`.
    private(set) var intensityFailed = false

    var selectedTab: MetricTab = .cardio

    private let client: PulseAPIClient
    /// Fusionne les rechargements complets (retour au premier plan, synchro,
    /// changement de source) — cf. `ReloadGate`.
    private let gate = ReloadGate()
    /// Invalide la réponse « jour » d'une date quittée entre-temps.
    private var dayGeneration = 0

    init(client: PulseAPIClient = .shared) {
        self.client = client
    }

    // MARK: - Chargement initial

    /// Rechargement complet fusionné : un déclencheur pendant un rechargement
    /// en cours le rejoint au lieu de relancer toutes les requêtes. `trailing` :
    /// la donnée vient de changer (synchro, changement de source) — un seul
    /// rechargement est rejoué après le courant.
    func reload(trailing: Bool = false) async {
        await gate.run(trailing: trailing) { [self] in await self.load() }
    }

    /// Garde tout ce qui est affiché jusqu'à l'arrivée de la réponse.
    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let days: [WellnessDayRow] = try await client.get(
                "api/wellness/days",
                query: ["limit": "30", "days": "30"]
            )
            days30 = days
            // Toujours le jour du calendrier, même vide : après minuit le
            // nouveau jour n'existe côté Pulse qu'à l'ingestion du premier
            // `.fit` qui le couvre — l'écran se remplit alors. Un jour passé
            // consulté est conservé (un rechargement ne ramène pas à aujourd'hui).
            let today = Self.todayKey()
            let followsToday = !hasContent || isLastDay
            maxDate = today
            if followsToday && date != today {
                date = today
                day = nil
                intensity = nil
                intensityFailed = false
                isDayLoading = true
            }
            await loadDayDetails()
            hasContent = true
        } catch {
            errorMessage = Self.message(for: error)
        }
    }

    func retry() async {
        await reload()
    }

    // MARK: - Navigation de jour

    var isLastDay: Bool {
        date >= maxDate
    }

    func shiftDay(by delta: Int) async {
        guard let current = Self.parseDate(date) else { return }
        let next = current.addingTimeInterval(TimeInterval(delta) * 86_400)
        await selectDate(Self.formatDate(next))
    }

    func selectDate(_ newDate: String) async {
        guard newDate != date else { return }
        date = newDate
        // Seul cas où l'on ne montre pas les données d'avant : une AUTRE date.
        day = nil
        intensity = nil
        intensityFailed = false
        isDayLoading = true
        await loadDayDetails()
    }

    /// Détail + intensité de la date courante. Garde `day`/`intensity` tant que
    /// la réponse n'est pas arrivée (rechargement de la même date) ; une réponse
    /// d'une date quittée entre-temps est ignorée.
    private func loadDayDetails() async {
        dayGeneration += 1
        let generation = dayGeneration
        let requested = date
        defer { if generation == dayGeneration { isDayLoading = false } }
        do {
            let detail: WellnessDayDetail = try await client.get("api/wellness/day/\(requested)")
            guard generation == dayGeneration else { return }
            day = detail
            errorMessage = nil
        } catch {
            guard generation == dayGeneration else { return }
            errorMessage = Self.message(for: error)
            return
        }
        // Intensité : au mieux, comme `IntensityDayCardComponent` côté Angular
        // (attrape ses propres erreurs sans affecter le reste de l'écran).
        do {
            let loaded: IntensityDayDetail = try await client.get("api/wellness/intensity/day/\(requested)")
            guard generation == dayGeneration else { return }
            intensity = loaded
            intensityFailed = false
        } catch {
            guard generation == dayGeneration else { return }
            // Un échec de rechargement garde l'intensité déjà affichée.
            if intensity == nil { intensityFailed = true }
        }
    }

    // MARK: - En-tête du graphique par onglet (moyenne / plage — miroir de `chartHead`)

    struct MetricHeadline {
        let value: String
        let unit: String
        let range: String
    }

    var metricHeadline: MetricHeadline {
        switch selectedTab {
        case .stress:
            return Self.averageRangeHeadline(day?.stress ?? [], unit: "de stress en moyenne")
        case .energie:
            let bb = day?.bodyBatteryPivot ?? []
            guard !bb.isEmpty else { return MetricHeadline(value: "—", unit: "au plus haut", range: "") }
            let high = Int(bb.map(\.value).max() ?? 0)
            let low = Int(bb.map(\.value).min() ?? 0)
            return MetricHeadline(value: "\(high)", unit: "au plus haut", range: "\(low) – \(high)")
        case .spo2:
            return Self.averageRangeHeadline(day?.spo2 ?? [], unit: "% en moyenne", suffix: " %")
        case .respiration:
            return Self.averageRangeHeadline(
                day?.respiration ?? [], unit: "/min en moyenne", decimals: 1
            )
        case .calories:
            guard let total = totalCalories else {
                return MetricHeadline(value: "—", unit: "kcal dépensées", range: "")
            }
            return MetricHeadline(value: Self.formatInt(total), unit: "kcal dépensées", range: "")
        case .cardio:
            return Self.averageRangeHeadline(day?.hr ?? [], unit: "bpm en moyenne")
        }
    }

    private static func averageRangeHeadline(
        _ samples: [WellnessSample], unit: String, decimals: Int = 0, suffix: String = ""
    ) -> MetricHeadline {
        guard !samples.isEmpty else { return MetricHeadline(value: "—", unit: unit, range: "") }
        let values = samples.map(\.value)
        let avg = values.reduce(0, +) / Double(values.count)
        let format: (Double) -> String = decimals == 0
            ? { String(Int($0.rounded())) }
            : { String(format: "%.\(decimals)f", $0) }
        let range = "\(format(values.min() ?? 0)) – \(format(values.max() ?? 0))\(suffix)"
        return MetricHeadline(value: format(avg), unit: unit, range: range)
    }

    // MARK: - Calories (miroir simplifié de `passiveCalories`/`activeCalories`/`totalCalories`)

    var passiveCalories: Double? {
        guard let bmr = day?.summary.bmrKcal else { return nil }
        return bmr * dayFraction
    }

    var activeCalories: Double? {
        guard let summary = day?.summary else { return nil }
        let sport = summary.sportCalories ?? 0
        if let active = summary.activeCalories { return max(active, sport) }
        return summary.sportCalories
    }

    var totalCalories: Double? {
        guard activeCalories != nil || passiveCalories != nil else { return nil }
        return (activeCalories ?? 0) + (passiveCalories ?? 0)
    }

    // MARK: Calories horaires (miroir `hourlyBase`/`hourlySport`/`hourlyActive`)
    //
    // Le graphe calories du web est un histogramme 24 h empilé : base (BMR
    // réparti, teinte calorie translucide) + actif (sport réparti par
    // recouvrement d'activité, plus les calories actives non-sport pondérées
    // par la FC au-dessus du repos, teinte calorie pleine).

    /// BMR réparti heure par heure, borné à la fraction de journée écoulée.
    var hourlyBaseCalories: [Double] {
        guard let bmr = day?.summary.bmrKcal else { return Array(repeating: 0, count: 24) }
        let perHour = bmr / 24
        let elapsed = dayFraction * 24
        return (0..<24).map { h in
            let hd = Double(h)
            if hd + 1 <= elapsed { return perHour }
            if hd < elapsed { return perHour * (elapsed - hd) }
            return 0
        }
    }

    /// Calories de sport réparties par recouvrement de chaque activité sur les
    /// tranches horaires (miroir de `hourlySport`).
    private var hourlySportCalories: [Double] {
        guard let day else { return Array(repeating: 0, count: 24) }
        // 00 h du jour affiché dans le même repère « fake-UTC » que les ts
        // (déjà décalés au fuseau d'affichage côté serveur), comme `dayStart`.
        let dayStart = Self.parseDate(day.date)?.timeIntervalSince1970 ?? 0
        var out = Array(repeating: 0.0, count: 24)
        for activity in day.activities {
            guard let cal = activity.calories, let dur = activity.durationS, dur > 0 else { continue }
            let aStart = Double(activity.startTs)
            let aEnd = Double(activity.startTs) + dur
            for h in 0..<24 {
                let hs = dayStart + Double(h) * 3600
                let overlap = min(aEnd, hs + 3600) - max(aStart, hs)
                if overlap > 0 { out[h] += cal * (overlap / dur) }
            }
        }
        return out
    }

    /// Sport + non-sport réparti par le poids FC (au-dessus du repos) de chaque
    /// heure (miroir de `hourlyActive`).
    var hourlyActiveCalories: [Double] {
        guard let day else { return hourlySportCalories }
        let sport = hourlySportCalories
        let active = activeCalories ?? 0
        let nonSport = max(active - (day.summary.sportCalories ?? 0), 0)
        if nonSport <= 0 { return sport }
        let resting = day.summary.restingHr ?? 50
        var weights = Array(repeating: 0.0, count: 24)
        for sample in day.hr {
            let h = Self.utcCalendar.component(.hour, from: Date(timeIntervalSince1970: sample.ts))
            if h >= 0, h < 24 { weights[h] += max(sample.value - resting, 0) }
        }
        let wSum = weights.reduce(0, +)
        return sport.enumerated().map { index, sp in
            sp + (wSum > 0 ? nonSport * (weights[index] / wSum) : nonSport / 24)
        }
    }

    /// Fraction de la journée écoulée (1 pour un jour passé) — sert de base
    /// au calcul du BMR partiel, comme `dayFraction` côté Angular.
    private var dayFraction: Double {
        let today = Self.todayKey()
        guard date == today else { return 1 }
        let now = Date()
        let calendar = Calendar(identifier: .gregorian)
        let midnight = calendar.startOfDay(for: now)
        let elapsed = now.timeIntervalSince(midnight)
        return min(max(elapsed / 86_400, 0), 1)
    }

    // MARK: - Sommeil (miroir de `stageBreakdown`)

    struct StageBreakdown {
        let deep: Int
        let light: Int
        let rem: Int
        let awake: Int

        var total: Int { deep + light + rem + awake }

        func percent(_ part: Int) -> Int {
            total > 0 ? Int((Double(part) / Double(total) * 100).rounded()) : 0
        }
    }

    var stageBreakdown: StageBreakdown? {
        guard let stages = day?.sleep.stages, !stages.isEmpty else { return nil }
        var deep = 0, light = 0, rem = 0, awake = 0
        for stage in stages {
            let duration = stage.to - stage.from
            switch stage.stage {
            case .deep: deep += duration
            case .light: light += duration
            case .rem: rem += duration
            case .awake: awake += duration
            }
        }
        let breakdown = StageBreakdown(deep: deep, light: light, rem: rem, awake: awake)
        return breakdown.total > 0 ? breakdown : nil
    }

    /// SpO2 pendant la nuit principale — miroir de `nightSpo2`.
    struct NightSpo2 {
        let mean: Int
        let min: Int
        let max: Int
    }

    var nightSpo2: NightSpo2? {
        guard let main = day?.sleep.main, let spo2 = day?.spo2, !spo2.isEmpty else { return nil }
        let inside = spo2.filter { $0.ts >= Double(main.from) && $0.ts <= Double(main.to) }.map(\.value)
        guard !inside.isEmpty else { return nil }
        let mean = inside.reduce(0, +) / Double(inside.count)
        return NightSpo2(
            mean: Int(mean.rounded()),
            min: Int((inside.min() ?? 0).rounded()),
            max: Int((inside.max() ?? 0).rounded())
        )
    }

    // MARK: - Formatage / dates (calendaire UTC, comme le serveur — jamais `Date` dans les modèles)

    /// « Aujourd'hui » en calendrier **local** (pas UTC) — cale sur la bascule
    /// de jour du serveur (jour local du process Nest, même fuseau que le
    /// téléphone). L'UTC retardait d'1-2 h → le jour ne changeait pas à minuit.
    static func todayKey() -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// Déclenché au changement de jour local (`refreshesAtDayChange`) : si
    /// l'utilisateur est sur le dernier jour, recharge — `load()` re-cale la
    /// date sur aujourd'hui (même encore vide).
    func reloadForNewDay(trailing: Bool = false) async {
        if isLastDay { await reload(trailing: trailing) }
    }

    private static var utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private static let keyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static func parseDate(_ key: String) -> Date? {
        keyFormatter.date(from: key)
    }

    static func formatDate(_ date: Date) -> String {
        keyFormatter.string(from: date)
    }

    static let dateLabelFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "fr_FR")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "EEEE d MMMM yyyy"
        return formatter
    }()

    var dateLabel: String {
        guard let parsed = Self.parseDate(date) else { return date }
        return Self.dateLabelFormatter.string(from: parsed).capitalized(with: Locale(identifier: "fr_FR"))
    }

    static func shortDateLabel(_ key: String) -> String {
        guard let parsed = parseDate(key) else { return key }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "fr_FR")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "d MMMM"
        return formatter.string(from: parsed)
    }

    static func clock(_ ts: Int) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(ts))
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    static func sleepShort(_ seconds: Double) -> String {
        let h = Int(seconds) / 3600
        let m = Int((seconds.truncatingRemainder(dividingBy: 3600)) / 60)
        return "\(h) h \(String(format: "%02d", m))"
    }

    private static func formatInt(_ value: Double) -> String {
        String(Int(value.rounded()))
    }

    private static func message(for error: Error) -> String {
        (error as? PulseAPIError)?.errorDescription ?? "Erreur inattendue."
    }
}
