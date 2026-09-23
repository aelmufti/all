//
//  DashboardViewModel.swift
//  all (bridge-connect)
//
//  Charge et détient les données de l'écran Dashboard — portage de
//  `refreshAll()` côté Angular, mais réduit aux 7 requêtes dont le template a
//  réellement besoin (cf. l'en-tête de `DashboardModels.swift`). Un seul état
//  d'erreur global : si une requête échoue, tout l'écran bascule en erreur
//  (comme le ferait un `Promise.all` sans le rattrapage par tâche individuelle
//  de `PageLoad` côté Angular — simplification volontaire, cohérente avec le
//  contrat "3 états" du socle natif).
//

import Foundation

@MainActor
@Observable
final class DashboardViewModel {
    enum LoadState: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    private(set) var state: LoadState = .loading

    private(set) var period: DashboardPeriod = .oneMonth
    private(set) var tab: DashboardTab = .sleep
    private(set) var subView: DashboardSubView = .trend

    private(set) var training: DashboardTrainingTab?
    private(set) var health: DashboardHealthTab?
    private(set) var nutrition: DashboardNutritionTab?
    private(set) var sleepDebt: DashboardSleepDebt?
    private(set) var sleepInsights: DashboardSleepInsights?
    private(set) var sleepRegularity: DashboardSleepRegularity?
    private(set) var wellnessDays: [DashboardWellnessDayRow] = []

    private let client: PulseAPIClient
    private var hasStartedLoad = false

    init(client: PulseAPIClient = .shared) {
        self.client = client
    }

    /// Vrai tant qu'aucune donnée n'a jamais été reçue — sert à distinguer,
    /// côté vue, le premier chargement (plein écran `LoadingView`/`ErrorView`)
    /// d'un rafraîchissement (`retry()`/pull-to-refresh) qui doit garder
    /// l'affichage précédent visible pendant la requête.
    var hasAnyData: Bool {
        training != nil || health != nil || nutrition != nil || sleepDebt != nil
    }

    /// Appelé depuis `.task` — ne déclenche le chargement qu'une fois par
    /// instance de vue-modèle (SwiftUI peut ré-exécuter `.task` à chaque
    /// apparition de la vue).
    func loadIfNeeded() async {
        guard !hasStartedLoad else { return }
        hasStartedLoad = true
        await load()
    }

    func retry() {
        Task { await load() }
    }

    func selectPeriod(_ period: DashboardPeriod) {
        guard period != self.period else { return }
        self.period = period
        Task { await load() }
    }

    func selectTab(_ tab: DashboardTab) {
        guard tab != self.tab else { return }
        self.tab = tab
        subView = dashboardSubViews(for: tab).first ?? subView
    }

    func selectSubView(_ subView: DashboardSubView) {
        self.subView = subView
    }

    func load() async {
        state = .loading
        let days = String(period.days)
        let daysQuery = ["days": days]
        do {
            async let trainingResult: DashboardTrainingTab = client.get("api/stats/tab-training", query: daysQuery)
            async let healthResult: DashboardHealthTab = client.get("api/stats/tab-health", query: daysQuery)
            async let nutritionResult: DashboardNutritionTab = client.get("api/stats/tab-nutrition", query: daysQuery)
            async let sleepDebtResult: DashboardSleepDebt = client.get("api/stats/sleep-debt", query: daysQuery)
            async let sleepInsightsResult: DashboardSleepInsights = client.get("api/stats/sleep-insights", query: daysQuery)
            async let sleepRegularityResult: DashboardSleepRegularity = client.get("api/stats/sleep-regularity", query: daysQuery)
            async let wellnessDaysResult: [DashboardWellnessDayRow] = client.get(
                "api/wellness/days",
                query: ["limit": days, "days": days, "bodyBattery": "0"]
            )

            let (t, h, n, sd, si, sr, wd) = try await (
                trainingResult, healthResult, nutritionResult,
                sleepDebtResult, sleepInsightsResult, sleepRegularityResult, wellnessDaysResult
            )
            training = t
            health = h
            nutrition = n
            sleepDebt = sd
            sleepInsights = si
            sleepRegularity = sr
            wellnessDays = wd
            state = .loaded
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    // MARK: - Dérivés onglet Sommeil (`dayRows`/`sleepHours()`/`debtDetail`…)

    /// Sommeil en heures par nuit, dans l'ordre chronologique renvoyé par
    /// `/api/wellness/days` (ancien → récent) — `nil` si pas de nuit ce jour.
    var wellnessSleepHours: [Double?] {
        wellnessDays.map { row in
            row.sleepDurationS.map { Double($0) / 3600 }
        }
    }

    var wellnessDates: [Date?] {
        wellnessDays.map { dashboardDate(from: $0.date) }
    }

    var sleepNightsCount: Int {
        wellnessSleepHours.compactMap { $0 }.count
    }

    /// `debtDetail` côté Angular : le détail le plus récent en premier.
    var debtDetail: [DashboardSleepDebtNight] {
        Array((sleepDebt?.detail ?? []).reversed())
    }

    var worstNight: DashboardSleepDebtNight? {
        debtDetail.min(by: { $0.sleepS < $1.sleepS })
    }

    var bestNight: DashboardSleepDebtNight? {
        debtDetail.max(by: { $0.sleepS < $1.sleepS })
    }

    /// `weekDelta()` côté Angular : somme des écarts des 7 nuits les plus
    /// récentes, en heures.
    var weekDeltaHours: Double {
        let rows = debtDetail.prefix(7)
        guard !rows.isEmpty else { return 0 }
        let sumSeconds = rows.reduce(0) { $0 + $1.deltaS }
        return (Double(sumSeconds) / 3600 * 10).rounded() / 10
    }

    /// `missingNights()` côté Angular.
    var missingNights: Int {
        max(period.days - (sleepDebt?.nights ?? 0), 0)
    }

    var debtLevel: String {
        dashboardDebtLevel(debtHours: sleepDebt?.debtHours ?? 0)
    }

    /// `compositionRows` côté Angular.
    var compositionRows: [(label: String, pct: Double, lo: Double, hi: Double, out: Bool)] {
        guard let composition = sleepInsights?.composition else { return [] }
        let rows: [(String, Double, DashboardRange)] = [
            ("Profond", composition.deep, composition.ref.deep),
            ("Léger", composition.light, composition.ref.light),
            ("Paradoxal", composition.rem, composition.ref.rem),
        ]
        return rows.map { label, pct, range in
            (label: label, pct: pct, lo: range.lo, hi: range.hi, out: pct < range.lo || pct > range.hi)
        }
    }

    // MARK: - `emptyTab` côté Angular

    /// Vrai quand l'onglet courant n'a rien à montrer sur la période — les
    /// vues affichent alors un état "rien sur cette période" plutôt que des
    /// graphes vides.
    var isCurrentTabEmpty: Bool {
        switch tab {
        case .sleep:
            return sleepDebt != nil && sleepNightsCount < 2
        case .training:
            return training?.count == 0
        case .health:
            guard let health else { return false }
            return health.restingSeries.isEmpty && health.respirationSeries.isEmpty && health.spo2Nights == 0
        case .nutrition:
            return nutrition?.daysLogged == 0
        case .map:
            return false
        }
    }
}
