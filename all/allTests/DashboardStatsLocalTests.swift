//
//  DashboardStatsLocalTests.swift
//  allTests
//
//  Valide l'incrément L4 (`docs/stockage-local.md`) : les six routes
//  `GET api/stats/*` servies par `RealLocalPulseBackend`/`DashboardStatsBackend`
//  (`Local/DashboardStats.swift`, portage de `stats.controller.ts`) + la
//  septième route déjà servie depuis L1 (`GET api/wellness/days`), toutes les
//  sept requises par `DashboardViewModel.load()`.
//
//  Un seul type `DashboardStatsLocalTests` (comme `WeightLocalTests.swift`,
//  `NutritionLocalTests.swift`…) pour que
//  `-only-testing:allTests/DashboardStatsLocalTests` (filtre EXACT par nom de
//  suite, pas par fichier) sélectionne bien tout ce qui suit.
//
//  Portée testée ici :
//    - FIDÈLE (`tab-health`, `sleep-debt`, `sleep-insights`,
//      `sleep-regularity`, `tab-nutrition`) : décodage RÉEL
//      (`PulseAPIClient.decoder` dans les modèles réels de
//      `DashboardModels.swift`) + cohérence interne des valeurs sur les
//      échantillons `.fit` d'exemple déjà utilisés par L1/L2/L3
//      (`custom-connect/samples`). AUCUN de ces échantillons ne contient de
//      nuit de sommeil (déjà noté en L2, `LocalDayDetailTests.swift`) : les
//      routes de sommeil ne sont donc exercées ici QUE sur leur branche
//      "aucune nuit" — comportement réel et testé, mais pas la branche à
//      données non vides. La PARITÉ EXACTE avec le serveur TS n'est PAS
//      recoupée (pas d'environnement Node/serveur disponible ici) : ces tests
//      vérifient que le portage est structurellement cohérent et décodable,
//      pas qu'il produit bit-à-bit la même sortie que `stats.controller.ts`.
//    - PARTIEL (`tab-training`) : `zones` toujours vide (non porté, cf.
//      en-tête de `DashboardStats.swift`) — vérifié explicitement.
//

import Testing
import Foundation
@testable import all

private enum StatsSample {
    static let root = "/Users/alielmufti/Documents/Projects/custom-connect/samples"
    static let wellness1 = "\(root)/user@example.com_263438980021.fit"
    static let running = "\(root)/user@example.com_306863786909.fit"
}

struct DashboardStatsLocalTests {
    private func makeDb() throws -> LocalDb {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("dashboard-stats-tests-\(UUID().uuidString).sqlite").path
        return try LocalDb(path: path)
    }

    private func ingestWellness(_ path: String, fileName: String, into db: LocalDb) throws {
        let url = URL(fileURLWithPath: path)
        let hash = try PulseUploader.sha256Hex(ofFileAt: url)
        let result = LocalIngestor.ingest(fileURL: url, hash: hash, fileName: fileName, into: db)
        #expect(result.kind == .wellness)
    }

    private func ingestActivity(_ path: String, fileName: String, into db: LocalDb) throws {
        let url = URL(fileURLWithPath: path)
        let hash = try PulseUploader.sha256Hex(ofFileAt: url)
        let result = LocalIngestor.ingest(fileURL: url, hash: hash, fileName: fileName, into: db)
        #expect(result.kind == .activity)
    }

    // MARK: - `tab-health` (FIDÈLE)

    /// Fenêtre large (3660 j) pour couvrir les échantillons d'exemple
    /// (2024/2026) depuis "maintenant" — `tabHealth` ancre sa fenêtre sur
    /// l'horloge réelle, pas sur la dernière donnée connue (cf.
    /// `DashboardStatsTime.sinceDateNow`).
    @Test func tabHealthDecodesAndReflectsRestingHrFromWellnessSample() async throws {
        let db = try makeDb()
        try ingestWellness(StatsSample.wellness1, fileName: "w1.fit", into: db)
        let backend = RealLocalPulseBackend(db: db)

        let data = try await backend.handle(method: "GET", path: "api/stats/tab-health", query: ["days": "3660"], body: nil)
        let tab = try PulseAPIClient.decoder.decode(DashboardHealthTab.self, from: data)

        #expect(tab.days == 3660)
        // `restingHr` connu (L1/L2) : 48 pour les deux dates de l'échantillon
        // → moyenne == 48.
        #expect(tab.restingHr == 48)
        #expect(tab.restingSeries.count == 2)
        #expect(tab.restingSeries.allSatisfy { $0.value == 48 })
        // Aucune nuit dans cet échantillon (cf. en-tête) : dérivés "nuit" vides.
        #expect(tab.respirationSeries.isEmpty)
        #expect(tab.spo2Nights == 0)
        #expect(tab.sleepHours == nil)
        #expect(tab.weightKg == nil)
        #expect(tab.weightSeries.isEmpty)
        // 3 corrélations toujours présentes (même sans données), `r: nil`.
        #expect(tab.correlations.count == 3)
    }

    @Test func tabHealthEmptyDbProducesNeutralButDecodableTab() async throws {
        let backend = RealLocalPulseBackend(db: try makeDb())
        let data = try await backend.handle(method: "GET", path: "api/stats/tab-health", query: ["days": "30"], body: nil)
        let tab = try PulseAPIClient.decoder.decode(DashboardHealthTab.self, from: data)
        #expect(tab.restingHr == nil)
        #expect(tab.restingSeries.isEmpty)
        #expect(tab.correlations.allSatisfy { $0.r == nil && $0.strength == "trop peu de données" })
    }

    // MARK: - `sleep-debt`/`sleep-insights`/`sleep-regularity` (FIDÈLE — branche "aucune nuit")

    @Test func sleepDebtWithoutSleepDataReturnsZeroBranch() async throws {
        let db = try makeDb()
        try ingestWellness(StatsSample.wellness1, fileName: "w1.fit", into: db)
        let backend = RealLocalPulseBackend(db: db)

        let data = try await backend.handle(method: "GET", path: "api/stats/sleep-debt", query: ["days": "3660"], body: nil)
        let debt = try PulseAPIClient.decoder.decode(DashboardSleepDebt.self, from: data)

        #expect(debt.nights == 0)
        #expect(debt.targetHours == 7)
        #expect(debt.debtHours == 0)
        #expect(debt.avgHours == 0)
        #expect(debt.deficitNights == 0)
        #expect(debt.detail.isEmpty)
    }

    @Test func sleepInsightsWithoutSleepDataReturnsZeroNights() async throws {
        let backend = RealLocalPulseBackend(db: try makeDb())
        let data = try await backend.handle(method: "GET", path: "api/stats/sleep-insights", query: ["days": "30"], body: nil)
        let insights = try PulseAPIClient.decoder.decode(DashboardSleepInsights.self, from: data)

        #expect(insights.stressImpact.nights == 0)
        #expect(insights.stressImpact.r == nil)
        #expect(insights.stressImpact.significant == false)
        #expect(insights.stressImpact.buckets.count == 4)
        #expect(insights.fragmentation.nights == 0)
        #expect(insights.composition.nights == 0)
        // Référence de composition toujours présente (constantes, pas un calcul).
        #expect(insights.composition.ref.deep.lo == 13)
        #expect(insights.composition.ref.deep.hi == 23)
        #expect(insights.spo2Arousal == nil)
    }

    @Test func sleepRegularityUnderThreeNightsReturnsInsufficientBranch() async throws {
        let backend = RealLocalPulseBackend(db: try makeDb())
        let data = try await backend.handle(method: "GET", path: "api/stats/sleep-regularity", query: ["days": "30"], body: nil)
        let regularity = try PulseAPIClient.decoder.decode(DashboardSleepRegularity.self, from: data)

        #expect(regularity.nights == 0)
        #expect(regularity.score == nil)
        #expect(regularity.bedtime == nil)
        #expect(regularity.waketime == nil)
    }

    /// `sleep-recommendation` n'est PAS servi par le backend local (best-effort
    /// côté `DashboardViewModel`, `try?`) — retombe sur `LocalPulseUnavailableError`.
    @Test func sleepRecommendationIsNotServedLocally() async throws {
        let backend = RealLocalPulseBackend(db: try makeDb())
        await #expect(throws: LocalPulseUnavailableError.self) {
            _ = try await backend.handle(method: "GET", path: "api/stats/sleep-recommendation", query: ["days": "30"], body: nil)
        }
    }

    // MARK: - `tab-training` (PARTIEL — `zones` toujours vide)

    @Test func tabTrainingEmptyDbProducesNeutralDecodableTab() async throws {
        let backend = RealLocalPulseBackend(db: try makeDb())
        let data = try await backend.handle(method: "GET", path: "api/stats/tab-training", query: ["days": "30"], body: nil)
        let tab = try PulseAPIClient.decoder.decode(DashboardTrainingTab.self, from: data)

        #expect(tab.count == 0)
        #expect(tab.totalS == 0)
        #expect(tab.avgHr == nil)
        #expect(tab.activeKcal == 0)
        #expect(tab.deltaPct == nil)
        #expect(tab.weeks.isEmpty)
        #expect(tab.shares.isEmpty)
        #expect(tab.streak.best == 0 && tab.streak.current == 0)
        #expect(tab.zones.isEmpty) // jamais calculé (cf. en-tête de `DashboardStats.swift`)
        #expect(tab.records.longestSession == nil)
    }

    /// Ingestion réelle (`running.fit`, déjà validé en L3 — `durationS ==
    /// 1960.173`, `avgHr == 154`, `sport == "running"`) — vérifie que
    /// `tab-training` reflète une VRAIE activité locale (pas un stub muet),
    /// hors `zones`.
    @Test func tabTrainingWithOneRunningActivityReflectsRealData() async throws {
        let db = try makeDb()
        try ingestActivity(StatsSample.running, fileName: "running.fit", into: db)
        let backend = RealLocalPulseBackend(db: db)

        let data = try await backend.handle(method: "GET", path: "api/stats/tab-training", query: ["days": "3660"], body: nil)
        let tab = try PulseAPIClient.decoder.decode(DashboardTrainingTab.self, from: data)

        #expect(tab.count == 1)
        #expect(tab.totalS == 1960.173)
        #expect(tab.avgHr == 154) // une seule séance avec HR → moyenne pondérée == sa propre valeur.
        #expect(tab.shares.count == 1)
        #expect(tab.shares[0].sport == "running")
        #expect(tab.shares[0].pct == 100)
        #expect(tab.weeks.count == 1)
        #expect(tab.weeks[0].sessions == 1)
        #expect(tab.records.longestSession?.value == 1960.173)
        #expect(tab.records.longestDistance?.value == 4636.4)
        #expect(tab.records.maxHr?.value == 175)
        // Distance (4636.4 m) >= seuil de 4000 m → une allure "record" EST calculable.
        #expect(tab.records.bestPace != nil)
        #expect(tab.zones.isEmpty) // toujours vide, cf. en-tête.
    }

    // MARK: - `tab-nutrition` (FIDÈLE, portage intégral)

    @Test func tabNutritionEmptyDbProducesEmptyCardBranch() async throws {
        let backend = RealLocalPulseBackend(db: try makeDb())
        let data = try await backend.handle(method: "GET", path: "api/stats/tab-nutrition", query: ["days": "30"], body: nil)
        let tab = try PulseAPIClient.decoder.decode(DashboardNutritionTab.self, from: data)

        #expect(tab.daysLogged == 0)
        #expect(tab.completeDays == 0) // `DashboardNutritionEmptyCard` s'affiche sur ce cas.
        #expect(tab.kcalPerDay == nil)
        #expect(tab.series.count == 30) // une entrée par jour de la fenêtre, même vide.
        #expect(tab.series.allSatisfy { $0.state == "none" })
    }

    /// Un repas aujourd'hui (assez calorique pour dépasser le seuil "journée
    /// complète" par défaut, 1200 kcal — aucune cible `settings.nutritionKcal`
    /// n'est écrite localement ici, cf. en-tête de `DashboardStats.swift`) —
    /// vérifie que `tab-nutrition` calcule de VRAIES moyennes depuis
    /// `food_log`, pas un stub.
    @Test func tabNutritionWithOneCompleteLoggedDayReflectsRealTotals() async throws {
        let db = try makeDb()
        let today = FitWellnessExtractor.isoDate(Date().timeIntervalSince1970)
        _ = try db.insertLog(
            date: today, foodId: nil, name: "Repas test", grams: 500,
            kcal: 1500, protein: 100, carbs: 150, fiber: 10, fat: 50,
            unitLabel: nil, unitQty: nil, ts: Int(Date().timeIntervalSince1970))

        let backend = RealLocalPulseBackend(db: db)
        let data = try await backend.handle(method: "GET", path: "api/stats/tab-nutrition", query: ["days": "30"], body: nil)
        let tab = try PulseAPIClient.decoder.decode(DashboardNutritionTab.self, from: data)

        #expect(tab.daysLogged == 1)
        #expect(tab.completeDays == 1)
        #expect(tab.kcalPerDay == 1500)
        #expect(tab.proteinPerDay == 100)
        #expect(tab.totalEntries == 1)
        #expect(tab.topFoods.count == 1)
        #expect(tab.topFoods[0].name == "Repas test")
        #expect(tab.topFoods[0].kcal == 1500)
        #expect(tab.topFoods[0].pct == 100)
        let todayEntry = try #require(tab.series.first { $0.date == today })
        #expect(todayEntry.state == "complete")
        #expect(todayEntry.kcal == 1500)
        // Pas de dépense estimée (aucune donnée `wellness_days`/`wellness_counters`
        // ce jour-là dans ce test) : `expenditurePerDay`/`balance` restent `nil`,
        // pas un `0` fabriqué.
        #expect(tab.expenditurePerDay == nil)
        #expect(tab.balance == nil)
        // Macros réelles (pas neutres) : 3 clés toujours présentes.
        #expect(tab.macros.count == 3)
        let protein = try #require(tab.macros.first { $0.key == "protein" })
        #expect(protein.grams == 100)
    }

    // MARK: - Les SEPT endpoints requis par `DashboardViewModel.load()` sont tous décodables

    /// Rejoue exactement les requêtes de `DashboardViewModel.load()` (mêmes
    /// routes, mêmes paramètres `days`/`limit`/`bodyBattery`) sur une base
    /// peuplée d'un échantillon wellness + une activité — si UNE seule de ces
    /// sept routes échouait à décoder, `DashboardViewModel.load()` ferait
    /// tomber tout l'écran Dashboard en mode Téléphone (`try await` sur le
    /// tuple des sept, cf. `DashboardViewModel.swift`).
    @Test func allSevenDashboardEndpointsDecodeWithRealModels() async throws {
        let db = try makeDb()
        try ingestWellness(StatsSample.wellness1, fileName: "w1.fit", into: db)
        try ingestActivity(StatsSample.running, fileName: "running.fit", into: db)
        let backend = RealLocalPulseBackend(db: db)
        let days = "3660"
        let daysQuery = ["days": days]

        let trainingData = try await backend.handle(method: "GET", path: "api/stats/tab-training", query: daysQuery, body: nil)
        _ = try PulseAPIClient.decoder.decode(DashboardTrainingTab.self, from: trainingData)

        let healthData = try await backend.handle(method: "GET", path: "api/stats/tab-health", query: daysQuery, body: nil)
        _ = try PulseAPIClient.decoder.decode(DashboardHealthTab.self, from: healthData)

        let nutritionData = try await backend.handle(method: "GET", path: "api/stats/tab-nutrition", query: daysQuery, body: nil)
        _ = try PulseAPIClient.decoder.decode(DashboardNutritionTab.self, from: nutritionData)

        let sleepDebtData = try await backend.handle(method: "GET", path: "api/stats/sleep-debt", query: daysQuery, body: nil)
        _ = try PulseAPIClient.decoder.decode(DashboardSleepDebt.self, from: sleepDebtData)

        let sleepInsightsData = try await backend.handle(method: "GET", path: "api/stats/sleep-insights", query: daysQuery, body: nil)
        _ = try PulseAPIClient.decoder.decode(DashboardSleepInsights.self, from: sleepInsightsData)

        let sleepRegularityData = try await backend.handle(method: "GET", path: "api/stats/sleep-regularity", query: daysQuery, body: nil)
        _ = try PulseAPIClient.decoder.decode(DashboardSleepRegularity.self, from: sleepRegularityData)

        let wellnessDaysData = try await backend.handle(
            method: "GET", path: "api/wellness/days", query: ["limit": days, "days": days, "bodyBattery": "0"], body: nil)
        let wellnessDays = try PulseAPIClient.decoder.decode([DashboardWellnessDayRow].self, from: wellnessDaysData)
        #expect(!wellnessDays.isEmpty)
    }
}
