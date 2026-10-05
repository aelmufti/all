//
//  SommeilViewModel.swift
//  all (bridge-connect)
//
//  État de l'onglet **Sommeil** : navigation par NUIT (comme l'écran Santé,
//  bornée à aujourd'hui) + analyse poussée de la nuit sélectionnée + reco
//  d'heure de coucher : carte fixe « Ce soir » (nuit à venir, requête propre,
//  indépendante de la date affichée) et carte par nuit. Charge le
//  détail par jour (`api/wellness/day/{date}`, qui porte l'hypnogramme, la SpO2
//  et le stress de la nuit) et réutilise les helpers de formatage statiques de
//  `HealthViewModel` (dates/heures) pour ne pas les redupliquer. Découplé de
//  `HealthViewModel` (qui, lui, charge aussi intensité/poids/onglets métrique
//  sans rapport ici) pour ne rien casser côté Santé.
//

import Foundation
import Observation

extension SommeilViewModel.RecoState {
    var reco: DashboardSleepRecommendation? {
        if case .ready(let reco) = self { return reco }
        return nil
    }
}

@MainActor
@Observable
final class SommeilViewModel {

    private(set) var isLoading = false
    private(set) var errorMessage: String?

    private(set) var date: String
    private(set) var days30: [WellnessDayRow] = []
    private(set) var day: WellnessDayDetail?
    /// Première date disponible (`api/wellness/dates`) — borne basse du
    /// sélecteur de date.
    private(set) var firstDate: String?

    /// État de la reco de la date AFFICHÉE (carte par nuit). Jamais de valeur
    /// d'une autre date : pendant le chargement la carte montre un emplacement
    /// réservé, pas l'heure de la date précédente.
    enum RecoState: Equatable {
        case loading
        case ready(DashboardSleepRecommendation)
        case failed
    }
    private(set) var nightReco: RecoState = .loading

    /// Carte par nuit : ce que la vue doit montrer.
    enum NightCard: Equatable {
        /// Rien : date = nuit à venir (doublon avec « Ce soir »), ou aucune
        /// donnée exploitable.
        case hidden
        /// Reco de cette date en cours de chargement (emplacement réservé).
        case placeholder
        case plan(SleepBedtimePlan.Result)
    }

    /// Carte fixe « Ce soir ».
    enum TonightCard: Equatable {
        case placeholder
        /// Pas de reco exploitable (échec sans repli, historique insuffisant).
        case unavailable
        case plan(SleepBedtimePlan.Result)
    }

    /// Nuit à venir (jour de réveil) visée par la carte « Ce soir » — `nil`
    /// avant le premier chargement.
    private(set) var tonightDate: String?
    private(set) var tonightReco: RecoState = .loading
    /// Dernière reco chargée avec succès (n'importe quelle date) : repli de
    /// l'idéal GLOBAL quand la requête d'une date échoue.
    private var lastGoodReco: DashboardSleepRecommendation?

    private let client: PulseAPIClient
    private let now: () -> Date
    private let calendar: () -> Calendar
    /// Alarmes par jour de semaine (1 = dimanche … 7 = samedi).
    private let alarms: @MainActor () -> [Int: Int]
    /// Rechargement de la reco lors d'un changement de date (annulé si une
    /// nouvelle date arrive avant la réponse).
    private var recoTask: Task<Void, Never>?
    /// Invalide les réponses « Ce soir » en vol quand une requête plus récente
    /// part (date de nuit changée, rafraîchissement).
    private var tonightGeneration = 0
    /// Aujourd'hui tel que vu au dernier chargement (détecte le changement de
    /// jour dans `reloadForNewDay`).
    private var lastKnownToday: String

    init(
        client: PulseAPIClient = .shared,
        now: @escaping () -> Date = Date.init,
        calendar: @escaping () -> Calendar = { .current },
        alarms: @escaping @MainActor () -> [Int: Int] = { WakeScheduleStore.shared.minutesByWeekday }
    ) {
        self.client = client
        self.now = now
        self.calendar = calendar
        self.alarms = alarms
        let today = SommeilDatePicking.key(forPickerDate: now(), calendar: calendar())
        self.date = today
        self.lastKnownToday = today
    }

    // MARK: - Chargement

    func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        // « Ce soir » ne dépend ni des jours ni de la date affichée : requête
        // concurrente, un échec des jours ne l'empêche pas.
        async let tonight: Void = refreshTonight()
        lastKnownToday = todayKey
        do {
            let days: [WellnessDayRow] = try await client.get(
                "api/wellness/days", query: ["limit": "30", "days": "30"]
            )
            let dates: [String] = try await client.get("api/wellness/dates")
            days30 = days
            firstDate = dates.min()
            // Par défaut, la nuit la plus récente RÉELLEMENT dormie (le tout
            // dernier jour peut être aujourd'hui, sans nuit encore mesurée).
            let latest = days.last(where: { $0.sleepDurationS != nil })?.date
                ?? days.last?.date ?? dates.last
            let previousDate = date
            if let latest { date = latest }
            // Un simple rafraîchissement de la même date garde la valeur affichée.
            if date != previousDate { nightReco = .loading }
            await loadDay()
            // Reco non bloquante (endpoint récent : un Pulse pas à jour renvoie 404).
            recoTask?.cancel()
            await fetchRecommendation(for: date)
        } catch {
            errorMessage = Self.message(for: error)
        }
        await tonight
    }

    func retry() async { await load() }

    // MARK: - Navigation de jour (miroir du sous-ensemble de HealthViewModel)

    /// Aujourd'hui (clé locale, horloge injectable).
    private var todayKey: String { SommeilDatePicking.key(forPickerDate: now(), calendar: calendar()) }

    /// Dernière date NAVIGABLE : aujourd'hui. La nuit à venir n'a pas de page
    /// à elle : elle vit dans la carte fixe « Ce soir ».
    var maxReachableDate: String { todayKey }

    var isLastDay: Bool { date >= maxReachableDate }

    /// Bornes du sélecteur de date : première date disponible → aujourd'hui.
    /// Sans première date connue, on retombe sur la plus ancienne des 30 jours
    /// chargés, sinon sur la date affichée.
    var selectableRange: ClosedRange<String> {
        let upper = maxReachableDate
        let lower = firstDate ?? days30.first?.date ?? date
        return min(lower, upper)...upper
    }

    func shiftDay(by delta: Int) async {
        guard let current = HealthViewModel.parseDate(date) else { return }
        let next = current.addingTimeInterval(TimeInterval(delta) * 86_400)
        await selectDate(HealthViewModel.formatDate(next))
    }

    func selectDate(_ newDate: String) async {
        guard newDate != date, newDate <= maxReachableDate else { return }
        date = newDate
        // Plus de reco périmée : tant que la nouvelle date charge, la carte par
        // nuit montre un emplacement réservé (pas l'heure de la date d'avant).
        nightReco = .loading
        // La reco de la nouvelle date se charge en parallèle du détail de la
        // nuit : elle ne retarde pas son affichage, et son échec n'en fait pas
        // un échec d'écran.
        recoTask?.cancel()
        recoTask = Task { [weak self] in
            await self?.fetchRecommendation(for: newDate)
        }
        await loadDay()
    }

    /// Reco pour la date `requested` (`date` envoyée à l'endpoint → durée idéale
    /// de CETTE nuit). Échec non bloquant (`try?`, état `.failed`) ; réponse
    /// ignorée si l'écran a changé de date entre-temps.
    private func fetchRecommendation(for requested: String) async {
        let reco = await Self.fetchReco(client: client, date: requested)
        guard !Task.isCancelled, date == requested else { return }
        if let reco {
            lastGoodReco = reco
            nightReco = .ready(reco)
        } else {
            nightReco = .failed
        }
    }

    private static func fetchReco(client: PulseAPIClient, date: String) async -> DashboardSleepRecommendation? {
        try? await client.get("api/stats/sleep-recommendation", query: ["days": "30", "date": date])
    }

    // MARK: - « Ce soir » (nuit à venir)

    /// Nuit à venir selon l'heure, les alarmes et (si connue) la reco.
    private func upcomingNight(reco: DashboardSleepRecommendation?) -> String {
        SleepTonight.upcomingNightDate(
            now: now(), calendar: calendar(), alarms: alarms(), reco: reco)
    }

    /// (Re)charge la reco de la nuit à venir. `force: false` (minuteur, retour
    /// d'alarme) : ne fait rien tant que la nuit visée n'a pas changé. Un
    /// changement de nuit remet la carte en chargement (jamais l'heure de la
    /// nuit d'avant) ; un simple rafraîchissement garde l'ancienne valeur
    /// affichée jusqu'à la réponse.
    func refreshTonight(force: Bool = true) async {
        var wanted = upcomingNight(reco: tonightReco.reco ?? lastGoodReco)
        if !force, wanted == tonightDate { return }
        if wanted != tonightDate { tonightReco = .loading }
        tonightDate = wanted
        tonightGeneration += 1
        let generation = tonightGeneration

        // Les lever habituels ne dépendent pas de la date demandée : si la reco
        // reçue, une fois connue, désigne une AUTRE nuit (cas sans alarme),
        // on redemande pour la bonne date — une seule fois.
        for attempt in 0..<2 {
            let reco = await Self.fetchReco(client: client, date: wanted)
            guard generation == tonightGeneration, !Task.isCancelled else { return }
            guard let reco else {
                tonightReco = .failed
                return
            }
            lastGoodReco = reco
            let refined = upcomingNight(reco: reco)
            if refined == wanted || attempt == 1 {
                tonightReco = .ready(reco)
                return
            }
            wanted = refined
            tonightDate = refined
            tonightReco = .loading
        }
    }

    /// Réveil prévu pour la clé `date` : alarme du jour de semaine de cette date.
    private func plan(reco: DashboardSleepRecommendation, date: String) -> SleepBedtimePlan.Result? {
        guard let weekday = SleepBedtimePlan.weekday(ofDateKey: date) else { return nil }
        return SleepBedtimePlan.plan(reco: reco, date: date, alarmMinutes: alarms()[weekday])
    }

    var tonightCard: TonightCard {
        guard let tonightDate else { return .placeholder }
        switch tonightReco {
        case .loading:
            return .placeholder
        case .ready(let reco):
            return plan(reco: reco, date: tonightDate).map(TonightCard.plan) ?? .unavailable
        case .failed:
            // Repli : dernière reco connue (idéal global).
            guard let lastGoodReco, let result = plan(reco: lastGoodReco, date: tonightDate) else { return .unavailable }
            return .plan(result)
        }
    }

    var nightCard: NightCard {
        // Date affichée = nuit à venir (cas après minuit) : doublon de « Ce soir ».
        if date == tonightDate { return .hidden }
        switch nightReco {
        case .loading:
            return .placeholder
        case .ready(let reco):
            return plan(reco: reco, date: date).map(NightCard.plan) ?? .hidden
        case .failed:
            // Échec connu : on retombe sur l'idéal GLOBAL de la dernière reco.
            guard let lastGoodReco, let result = plan(reco: lastGoodReco, date: date) else { return .hidden }
            return .plan(result)
        }
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

    /// Changement de jour / retour au premier plan / données locales : recharge
    /// tout si l'utilisateur est sur aujourd'hui (ou sur « l'ancien aujourd'hui »
    /// après minuit) ; sinon la nuit à venir seule est réévaluée.
    func reloadForNewDay() async {
        if isLastDay || date == lastKnownToday {
            await load()
        } else {
            lastKnownToday = todayKey
            await refreshTonight(force: false)
        }
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
        date == todayKey
            ? "aujourd'hui"
            : HealthViewModel.shortDateLabel(date)
    }

    private static func message(for error: Error) -> String {
        (error as? PulseAPIError)?.errorDescription ?? "Erreur inattendue."
    }
}
