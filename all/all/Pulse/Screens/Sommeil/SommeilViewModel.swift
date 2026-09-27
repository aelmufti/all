//
//  SommeilViewModel.swift
//  all (bridge-connect)
//
//  État de l'onglet **Sommeil** : navigation par NUIT (comme l'écran Santé) +
//  analyse poussée de la nuit sélectionnée + reco d'heure de coucher. Charge le
//  détail par jour (`api/wellness/day/{date}`, qui porte l'hypnogramme, la SpO2
//  et le stress de la nuit) et réutilise les helpers de formatage statiques de
//  `HealthViewModel` (dates/heures) pour ne pas les redupliquer. Découplé de
//  `HealthViewModel` (qui, lui, charge aussi intensité/poids/onglets métrique
//  sans rapport ici) pour ne rien casser côté Santé.
//

import Foundation
import Observation

@MainActor
@Observable
final class SommeilViewModel {

    private(set) var isLoading = false
    private(set) var errorMessage: String?

    private(set) var date: String = HealthViewModel.todayKey()
    private(set) var days30: [WellnessDayRow] = []
    private(set) var day: WellnessDayDetail?
    private(set) var recommendation: DashboardSleepRecommendation?

    private let client: PulseAPIClient

    init(client: PulseAPIClient = .shared) {
        self.client = client
    }

    // MARK: - Chargement

    func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let days: [WellnessDayRow] = try await client.get(
                "api/wellness/days", query: ["limit": "30", "days": "30"]
            )
            let dates: [String] = try await client.get("api/wellness/dates")
            days30 = days
            // Par défaut, la nuit la plus récente RÉELLEMENT dormie (le tout
            // dernier jour peut être aujourd'hui, sans nuit encore mesurée).
            let latest = days.last(where: { $0.sleepDurationS != nil })?.date
                ?? days.last?.date ?? dates.last
            if let latest { date = latest }
            await loadDay()
            // Reco non bloquante (endpoint récent : un Pulse pas à jour renvoie 404).
            recommendation = try? await client.get(
                "api/stats/sleep-recommendation", query: ["days": "30"]
            )
        } catch {
            errorMessage = Self.message(for: error)
        }
    }

    func retry() async { await load() }

    // MARK: - Navigation de jour (miroir du sous-ensemble de HealthViewModel)

    var isLastDay: Bool {
        guard let last = days30.last?.date else { return false }
        return date >= last
    }

    func shiftDay(by delta: Int) async {
        guard let current = HealthViewModel.parseDate(date) else { return }
        let next = current.addingTimeInterval(TimeInterval(delta) * 86_400)
        await selectDate(HealthViewModel.formatDate(next))
    }

    func selectDate(_ newDate: String) async {
        guard newDate != date else { return }
        date = newDate
        await loadDay()
    }

    private func loadDay() async {
        day = nil
        errorMessage = nil
        do {
            day = try await client.get("api/wellness/day/\(date)")
        } catch {
            errorMessage = Self.message(for: error)
        }
    }

    func reloadForNewDay() async {
        if isLastDay { await load() }
    }

    // MARK: - Analyse de la nuit sélectionnée

    /// Répartition par phase (s), miroir de `HealthViewModel.stageBreakdown` —
    /// recalculé ici pour rester découplé de l'écran Santé.
    var stageBreakdown: HealthViewModel.StageBreakdown? {
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
        let b = HealthViewModel.StageBreakdown(deep: deep, light: light, rem: rem, awake: awake)
        return b.total > 0 ? b : nil
    }

    var nightSpo2: HealthViewModel.NightSpo2? {
        guard let main = day?.sleep.main, let spo2 = day?.spo2, !spo2.isEmpty else { return nil }
        let inside = spo2.filter { $0.ts >= Double(main.from) && $0.ts <= Double(main.to) }.map(\.value)
        guard !inside.isEmpty else { return nil }
        let mean = inside.reduce(0, +) / Double(inside.count)
        return HealthViewModel.NightSpo2(
            mean: Int(mean.rounded()),
            min: Int((inside.min() ?? 0).rounded()),
            max: Int((inside.max() ?? 0).rounded())
        )
    }

    /// Fragmentation + efficacité + stress de la nuit — l'« analyse poussée ».
    struct NightStats {
        let sleepS: Int          // profond + léger + paradoxal
        let awakeS: Int          // éveil intra-nuit (WASO)
        let inBedS: Int          // sommeil + éveil (fenêtre)
        let efficiencyPct: Int   // sleepS / inBedS
        let arousals: Int        // nombre de segments d'éveil
        let longestAwakeS: Int   // plus long éveil
        let avgNightStress: Int? // stress moyen pendant la fenêtre de nuit
    }

    var nightStats: NightStats? {
        guard let stages = day?.sleep.stages, !stages.isEmpty,
              let breakdown = stageBreakdown else { return nil }
        let sleepS = breakdown.deep + breakdown.light + breakdown.rem
        let awakeS = breakdown.awake
        let inBedS = sleepS + awakeS
        var arousals = 0
        var longest = 0
        for (index, stage) in stages.enumerated() where stage.stage == .awake {
            // Un « éveil » = entrée dans une phase awake (pas deux awake d'affilée).
            if index == 0 || stages[index - 1].stage != .awake { arousals += 1 }
            longest = max(longest, stage.to - stage.from)
        }
        var avgStress: Int?
        if let main = day?.sleep.main, let stress = day?.stress {
            let inside = stress
                .filter { $0.ts >= Double(main.from) && $0.ts <= Double(main.to) && $0.value >= 0 }
                .map(\.value)
            if !inside.isEmpty {
                avgStress = Int((inside.reduce(0, +) / Double(inside.count)).rounded())
            }
        }
        return NightStats(
            sleepS: sleepS,
            awakeS: awakeS,
            inBedS: inBedS,
            efficiencyPct: inBedS > 0 ? Int((Double(sleepS) / Double(inBedS) * 100).rounded()) : 0,
            arousals: arousals,
            longestAwakeS: longest,
            avgNightStress: avgStress
        )
    }

    /// Composition (% du sommeil réel) de la nuit vs fourchettes de référence
    /// (mêmes bornes que `sleep-insights` côté serveur).
    struct CompositionRow: Identifiable {
        let id = UUID()
        let label: String
        let pct: Int
        let lo: Int
        let hi: Int
        var out: Bool { pct < lo || pct > hi }
    }

    var compositionRows: [CompositionRow] {
        guard let b = stageBreakdown else { return [] }
        let sleep = Double(b.deep + b.light + b.rem)
        guard sleep > 0 else { return [] }
        func pct(_ v: Int) -> Int { Int((Double(v) / sleep * 100).rounded()) }
        return [
            CompositionRow(label: "Profond", pct: pct(b.deep), lo: 13, hi: 23),
            CompositionRow(label: "Léger", pct: pct(b.light), lo: 44, hi: 55),
            CompositionRow(label: "Paradoxal", pct: pct(b.rem), lo: 20, hi: 25),
        ]
    }

    /// Moyenne de durée sur les nuits mesurées de la fenêtre (30 j) — pour situer
    /// la nuit affichée par rapport à l'habitude.
    var avgDurationS: Double? {
        let durations = days30.compactMap(\.sleepDurationS)
        guard !durations.isEmpty else { return nil }
        return durations.reduce(0, +) / Double(durations.count)
    }

    /// Écart de la nuit affichée à cette moyenne, en secondes (nil si pas de nuit).
    var deltaToAvgS: Double? {
        guard let main = day?.sleep.main, let avg = avgDurationS else { return nil }
        return main.durationS - avg
    }

    // MARK: - Libellés

    var dateLabel: String {
        guard let parsed = HealthViewModel.parseDate(date) else { return date }
        return HealthViewModel.dateLabelFormatter
            .string(from: parsed)
            .capitalized(with: Locale(identifier: "fr_FR"))
    }

    var shortLabel: String {
        date == HealthViewModel.todayKey()
            ? "aujourd'hui"
            : HealthViewModel.shortDateLabel(date)
    }

    private static func message(for error: Error) -> String {
        (error as? PulseAPIError)?.errorDescription ?? "Erreur inattendue."
    }
}
