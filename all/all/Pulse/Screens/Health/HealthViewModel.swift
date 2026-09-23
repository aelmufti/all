//
//  HealthViewModel.swift
//  all (bridge-connect)
//
//  État + logique réseau de l'écran Santé. Miroir de `HealthComponent`
//  (Angular) mais adapté au style vue-modèle iOS : un seul point d'entrée
//  `load()` (chargement initial), navigation de jour (`shiftDay`/`selectDate`)
//  qui recharge le détail du jour + l'intensité, poids séparé (fenêtre 90 j,
//  indépendante de la date affichée — comme côté Angular).
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

    private(set) var date: String = HealthViewModel.todayKey()
    private(set) var maxDate: String = HealthViewModel.todayKey()
    private(set) var days30: [WellnessDayRow] = []
    private(set) var day: WellnessDayDetail?
    private(set) var intensity: IntensityDayDetail?
    /// Distingue « pas encore chargée » de « a échoué » pour `IntensityCard`
    /// (miroir de `failed`/`detail` dans `IntensityDayCardComponent`) — les
    /// deux cas laissent `intensity` à `nil`.
    private(set) var intensityFailed = false
    private(set) var weight: WeightData?

    var selectedTab: MetricTab = .cardio

    var weightInputText: String = ""
    private(set) var weightMessage: String?
    private(set) var isSavingWeight = false

    private let client: PulseAPIClient

    init(client: PulseAPIClient = .shared) {
        self.client = client
    }

    // MARK: - Chargement initial

    func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let days: [WellnessDayRow] = try await client.get(
                "api/wellness/days",
                query: ["limit": "30", "days": "30"]
            )
            let dates: [String] = try await client.get("api/wellness/dates")
            days30 = days
            let latest = days.last?.date ?? dates.last
            if let latest {
                date = latest
                maxDate = latest
            }
            await loadDayDetails()
            await loadWeight()
        } catch {
            errorMessage = Self.message(for: error)
        }
    }

    func retry() async {
        await load()
    }

    // MARK: - Navigation de jour

    var isLastDay: Bool {
        guard let last = days30.last?.date else { return false }
        return date >= last
    }

    func shiftDay(by delta: Int) async {
        guard let current = Self.parseDate(date) else { return }
        let next = current.addingTimeInterval(TimeInterval(delta) * 86_400)
        await selectDate(Self.formatDate(next))
    }

    func selectDate(_ newDate: String) async {
        guard newDate != date else { return }
        date = newDate
        weightMessage = nil
        weightInputText = Self.formatKg(shownWeight)
        await loadDayDetails()
    }

    private func loadDayDetails() async {
        day = nil
        intensity = nil
        intensityFailed = false
        errorMessage = nil
        do {
            let detail: WellnessDayDetail = try await client.get("api/wellness/day/\(date)")
            day = detail
        } catch {
            errorMessage = Self.message(for: error)
            return
        }
        // Intensité : au mieux, comme `IntensityDayCardComponent` côté Angular
        // (attrape ses propres erreurs sans affecter le reste de l'écran).
        do {
            intensity = try await client.get("api/wellness/intensity/day/\(date)")
        } catch {
            intensityFailed = true
        }
    }

    // MARK: - Poids

    private func loadWeight() async {
        do {
            let data: WeightData = try await client.get("api/weight", query: ["days": "90"])
            weight = data
            weightInputText = Self.formatKg(shownWeight)
        } catch {
            // Le poids est secondaire à l'écran Santé — une panne ici ne doit
            // pas empêcher d'afficher le reste (FC, sommeil, etc.), donc pas
            // de propagation vers `errorMessage`.
        }
    }

    /// Poids du jour affiché s'il existe, sinon le dernier connu — miroir de
    /// `dayWeight`/`shownWeight` (Angular).
    var dayWeight: Double? {
        weight?.series.first { $0.date == date }?.kg
    }

    var shownWeight: Double? {
        dayWeight ?? weight?.current
    }

    var weightDelta: Double? { weight?.deltaKg }

    var weighLabel: String {
        guard let weight, weight.entries > 0 else { return "aucune pesée" }
        if dayWeight != nil { return "pesée du jour" }
        guard let currentDate = weight.currentDate else { return "aucune pesée" }
        return "dernière : \(Self.shortDateLabel(currentDate))"
    }

    var watchNote: String? {
        guard let push = weight?.push, push.status != "idle" else { return nil }
        guard let pushKg = push.kg, let current = weight?.current else { return nil }
        guard abs(pushKg - current) < 0.05 else { return nil }
        switch push.status {
        case "sent": return "poids transmis à la montre"
        case "pending": return "poids en attente de la montre"
        default: return "poids non transmis à la montre"
        }
    }

    func saveWeight() async {
        guard let kg = Double(weightInputText.replacingOccurrences(of: ",", with: ".")) else { return }
        isSavingWeight = true
        weightMessage = nil
        defer { isSavingWeight = false }
        do {
            let _: WeightSaveResult = try await client.post(
                "api/weight",
                body: WeightSaveRequest(date: date, kg: kg)
            )
            await loadWeight()
            weightMessage = "Pesée enregistrée pour le \(Self.shortDateLabel(date))."
        } catch {
            weightMessage = "Poids refusé : vérifie la valeur (entre 25 et 300 kg)."
        }
    }

    func removeWeight() async {
        weightMessage = nil
        do {
            try await client.delete("api/weight/\(date)")
            await loadWeight()
            weightMessage = "Pesée effacée."
        } catch {
            weightMessage = "Suppression impossible."
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
        let inside = spo2.filter { $0.ts >= main.from && $0.ts <= main.to }.map(\.value)
        guard !inside.isEmpty else { return nil }
        let mean = inside.reduce(0, +) / Double(inside.count)
        return NightSpo2(
            mean: Int(mean.rounded()),
            min: Int((inside.min() ?? 0).rounded()),
            max: Int((inside.max() ?? 0).rounded())
        )
    }

    // MARK: - Formatage / dates (calendaire UTC, comme le serveur — jamais `Date` dans les modèles)

    static func todayKey() -> String {
        formatDate(Date())
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

    private static func formatKg(_ value: Double?) -> String {
        guard let value else { return "" }
        return String(format: "%.1f", value)
    }

    private static func message(for error: Error) -> String {
        (error as? PulseAPIError)?.errorDescription ?? "Erreur inattendue."
    }
}
