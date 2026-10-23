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
    private(set) var sleepRecommendation: DashboardSleepRecommendation?
    private(set) var wellnessDays: [DashboardWellnessDayRow] = []

    private let client: PulseAPIClient
    private var hasStartedLoad = false
    /// Fusionne les rechargements (synchro, changement de source, pull-to-refresh,
    /// réessai) — cf. `ReloadGate`. Le changement de période, lui, ne passe pas
    /// par la garde : il doit remplacer le chargement en cours.
    private let gate = ReloadGate()
    /// Numéro du dernier `load()` lancé : la réponse d'un chargement dépassé (autre
    /// période demandée entre-temps) ne remplace pas une plus récente.
    private var loadGeneration = 0
    /// Source de données du contenu RÉELLEMENT affiché : posée seulement après un
    /// chargement réussi et toujours d'actualité (cf. `reco` non bloquante, et
    /// l'échec d'un chargement après changement de source).
    private var loadedMode: StorageMode?
    /// Mode de stockage courant — injectable pour les tests (relu à chaque
    /// chargement, jamais capturé).
    private let modeProvider: @Sendable () -> StorageMode

    init(
        client: PulseAPIClient = .shared,
        modeProvider: @escaping @Sendable () -> StorageMode = { StorageModeStore.current }
    ) {
        self.client = client
        self.modeProvider = modeProvider
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
        await reload()
    }

    /// Rechargement fusionné : un déclencheur pendant un rechargement en cours
    /// le rejoint au lieu de relancer les 8 requêtes. `trailing` : la donnée
    /// vient de changer (synchro, changement de source) — un seul rechargement
    /// est rejoué après le courant.
    func reload(trailing: Bool = false) async {
        await gate.run(trailing: trailing) { [self] in await self.load() }
    }

    func retry() {
        Task { await reload() }
    }

    func selectPeriod(_ period: DashboardPeriod) {
        guard period != self.period else { return }
        self.period = period
        Task { await load() }
    }

    /// Fixe le domaine actif et réinitialise sa sous-vue par défaut — appelé
    /// à l'apparition de `DashboardDomainDetailView` (poussé depuis l'aperçu).
    /// Toujours réinitialiser `subView`, y compris quand `tab` ne change pas
    /// en apparence (retour sur le même domaine) : sans ça, une `subView`
    /// laissée par un AUTRE domaine resterait sélectionnée alors qu'elle ne
    /// correspond à aucune sous-vue valide de celui-ci (l'ancien early-return
    /// `guard tab != self.tab` ne protégeait que le cas où `tab` changeait).
    func selectTab(_ tab: DashboardTab) {
        self.tab = tab
        subView = dashboardSubViews(for: tab).first ?? subView
    }

    func selectSubView(_ subView: DashboardSubView) {
        self.subView = subView
    }

    /// Sections de l'aperçu : chacune se remplit dès que SES données sont
    /// arrivées (réussies ou non) ; tant qu'elle n'est pas « réglée » la carte
    /// affiche son squelette.
    enum Part: Hashable { case training, health, nutrition, sleep }
    private(set) var settled: Set<Part> = []

    func isLoading(_ part: Part) -> Bool { !settled.contains(part) }

    func load() async {
        loadGeneration += 1
        let generation = loadGeneration
        let mode = modeProvider()
        // Contenu d'un autre backend : retiré d'emblée, la nouvelle source se
        // présente en squelette puis se remplit.
        if loadedMode != nil && loadedMode != mode {
            training = nil
            health = nil
            nutrition = nil
            sleepDebt = nil
            sleepInsights = nil
            sleepRegularity = nil
            sleepRecommendation = nil
            wellnessDays = []
            settled = []
        }
        loadedMode = mode
        state = .loading
        let days = String(period.days)
        let daysQuery = ["days": days]
        let c = client
        await prefillFromCache(days: days, query: daysQuery, generation: generation)

        async let trainingResult = fetch(.training, generation) { [self] in
            let v: DashboardTrainingTab = try await c.getCached("api/stats/tab-training", query: daysQuery)
            guard generation == loadGeneration else { return false }
            training = v
            return true
        }
        async let healthResult = fetch(.health, generation) { [self] in
            let v: DashboardHealthTab = try await c.getCached("api/stats/tab-health", query: daysQuery)
            guard generation == loadGeneration else { return false }
            health = v
            return true
        }
        async let nutritionResult = fetch(.nutrition, generation) { [self] in
            let v: DashboardNutritionTab = try await c.getCached("api/stats/tab-nutrition", query: daysQuery)
            guard generation == loadGeneration else { return false }
            nutrition = v
            return true
        }
        // Sommeil : quatre sources, la carte se remplit quand toutes ont répondu
        // (chacune pose sa donnée à l'arrivée).
        async let sleepDebtResult = fetch(nil, generation) { [self] in
            let v: DashboardSleepDebt = try await c.getCached("api/stats/sleep-debt", query: daysQuery)
            guard generation == loadGeneration else { return false }
            sleepDebt = v
            return true
        }
        async let sleepInsightsResult = fetch(nil, generation) { [self] in
            let v: DashboardSleepInsights = try await c.getCached("api/stats/sleep-insights", query: daysQuery)
            guard generation == loadGeneration else { return false }
            sleepInsights = v
            return true
        }
        async let sleepRegularityResult = fetch(nil, generation) { [self] in
            let v: DashboardSleepRegularity = try await c.getCached("api/stats/sleep-regularity", query: daysQuery)
            guard generation == loadGeneration else { return false }
            sleepRegularity = v
            return true
        }
        async let wellnessDaysResult = fetch(nil, generation) { [self] in
            let v: [DashboardWellnessDayRow] = try await c.getCached(
                "api/wellness/days",
                query: ["limit": days, "days": days, "bodyBattery": "0"]
            )
            guard generation == loadGeneration else { return false }
            wellnessDays = v
            return true
        }
        // Reco d'heure de coucher : fetch **non bloquant** — c'est un ajout
        // récent, un serveur Pulse pas encore à jour renvoie 404 ; on laisse
        // alors la carte disparaître plutôt que de faire tomber tout l'écran.
        async let recoResult: DashboardSleepRecommendation? =
            try? await c.getCached("api/stats/sleep-recommendation", query: daysQuery)

        let results = await [
            trainingResult, healthResult, nutritionResult,
            sleepDebtResult, sleepInsightsResult, sleepRegularityResult, wellnessDaysResult,
        ]
        let reco = await recoResult
        guard generation == loadGeneration else { return }
        settled.insert(.sleep)
        // Un échec ponctuel garde la reco déjà affichée.
        if let reco { sleepRecommendation = reco }
        if let firstError = results.compactMap({ $0 }).first {
            state = .failed(firstError.localizedDescription)
        } else {
            state = .loaded
        }
    }

    /// Premier affichage : dernières valeurs connues (cache) de chaque carte encore
    /// vide, pendant que les lectures fraîches partent.
    private func prefillFromCache(days: String, query: [String: String], generation: Int) async {
        let c = client
        if training == nil, let v: DashboardTrainingTab = await c.cachedValue("api/stats/tab-training", query: query),
           generation == loadGeneration, training == nil {
            training = v
            settled.insert(.training)
        }
        if health == nil, let v: DashboardHealthTab = await c.cachedValue("api/stats/tab-health", query: query),
           generation == loadGeneration, health == nil {
            health = v
            settled.insert(.health)
        }
        if nutrition == nil, let v: DashboardNutritionTab = await c.cachedValue("api/stats/tab-nutrition", query: query),
           generation == loadGeneration, nutrition == nil {
            nutrition = v
            settled.insert(.nutrition)
        }
        guard sleepDebt == nil,
              let debt: DashboardSleepDebt = await c.cachedValue("api/stats/sleep-debt", query: query),
              let insights: DashboardSleepInsights = await c.cachedValue("api/stats/sleep-insights", query: query),
              let regularity: DashboardSleepRegularity = await c.cachedValue("api/stats/sleep-regularity", query: query),
              let wellness: [DashboardWellnessDayRow] = await c.cachedValue(
                "api/wellness/days", query: ["limit": days, "days": days, "bodyBattery": "0"]),
              generation == loadGeneration, sleepDebt == nil
        else { return }
        sleepDebt = debt
        sleepInsights = insights
        sleepRegularity = regularity
        wellnessDays = wellness
        settled.insert(.sleep)
    }

    /// Exécute le chargement d'une section ; la section est « réglée » même en
    /// cas d'échec. Renvoie l'erreur éventuelle.
    private func fetch(_ part: Part?, _ generation: Int, _ body: @MainActor () async throws -> Bool) async -> Error? {
        do {
            let applied = try await body()
            if applied, let part { settled.insert(part) }
            return nil
        } catch {
            if generation == loadGeneration, let part { settled.insert(part) }
            return generation == loadGeneration ? error : nil
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
