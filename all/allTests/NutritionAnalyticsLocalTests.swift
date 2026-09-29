//
//  NutritionAnalyticsLocalTests.swift
//  allTests
//
//  Valide l'incrément L5-Nutrition-analytics (`docs/stockage-local.md`) : le
//  moteur de cible nutritionnelle (`Local/NutritionTarget.swift`, port de
//  `custom-connect/server/src/nutrition/target.ts`) et son câblage dans
//  `RealLocalPulseBackend` (`GET api/nutrition/targets`, `.../weekly`,
//  `.../timing/:date`, `.../suggestions/:date`, et les champs
//  `targets`/`remaining`/`targetRanges` de `.../day/:date`), qui remplacent
//  les STUBS neutres de l'incrément L5-Nutrition précédent.
//
//  Deux familles de tests :
//    - MOTEUR PUR (`NutritionTargetEngine`, aucune base) — valeurs
//      HAND-CHECKED à la main depuis les constantes de `target.ts` (calcul
//      détaillé en commentaire sur chaque test), donc la meilleure preuve
//      dont on dispose que le portage reproduit la formule. AUCUN
//      environnement Node/serveur n'est disponible ici : la parité EXACTE
//      avec `target.ts` n'est donc PAS recoupée bit-à-bit contre une
//      exécution réelle du TS — ces valeurs sont recalculées à la main à
//      partir du code source lu, pas rejouées.
//    - INTÉGRATION (`RealLocalPulseBackend`/`LocalDb`) — mêmes scénarios
//      rejoués à travers les routes HTTP réelles, décodés avec les modèles
//      RÉELS de l'écran (`PulseAPIClient.decoder`,
//      `Pulse/Screens/Nutrition/NutritionModels.swift`), pour vérifier le
//      câblage (lecture profil/montre/settings/food_log → JSON) en plus de
//      la formule elle-même. Le profil est seedé directement via
//      `LocalDb.setSetting`/`storeWellness` (mêmes clés que L6/L1), jamais
//      via un vrai `.fit`.
//

import Testing
import Foundation
@testable import all

// MARK: - Moteur pur (`NutritionTargetEngine`) — aucune base, aucun fuseau

struct NutritionTargetEngineTests {
    /// Exemple calculé À LA MAIN depuis `target.ts` : profil complet
    /// (36 ans, homme, 80 kg, 180 cm), repos MONTRE (`bmr_kcal` = 1800),
    /// dépense active montre 300 kcal, AUCUNE séance, réglages par défaut.
    ///
    /// Déroulé (cf. commentaires de `NutritionTarget.swift` pour les noms de
    /// constantes) :
    ///   - `fromWatch` vrai (1800 > 0) → `resting = restingBasis = 1800`.
    ///   - séances vides → `sessionActive = 0`, `active = max(300, 0) = 300`,
    ///     `source = "watch"` (300 ≥ 0).
    ///   - `adjustedActive = 300`, `expenditure = 1800 + 300 = 2100`.
    ///   - `dailyDeficitFor` : `weeklyKcal = 80 × 0.007 × 7700 = 4312`,
    ///     `deficit.kcal = round(4312 / 7) = 616` (exact).
    ///   - `fatFreeMassKg` : `bmi = 80 / 1.8² = 24.6913…`,
    ///     `bodyFatPct = clamp(1.2×24.6913 + 0.23×36 − 10.8 − 5.4, 5, 60)
    ///     = 21.7096…`, `ffmKg = round2(80 × (1 − 0.217096…)) = 62.63`.
    ///   - `availabilityFloor = 62.63 × 25 + 300 = 1865.75`.
    ///   - `target = expenditure − deficit.kcal = 2100 − 616 = 1484` < floor
    ///     (1865.75) → `target = 1865.75`, `guard = "availability"` ; ni
    ///     `< floorKcal(1500)` ni `> expenditure` ensuite.
    ///   - `targetKcal = round(1865.75) = 1866`, `expenditureKcal = 2100`,
    ///     `deficitKcal = 234`.
    ///   - Macros (`computeMacros`) : bonus déficit
    ///     `round2(0.3 × clamp((234/2100)/0.25, 0,1)) = 0.13` → `asked = 2.03`,
    ///     `lifted = max(2.03, 2.2) = 2.2` (`inDeficit`), `wanted = 2.2`,
    ///     `proteinCap = floor(1866×0.45/4) = 209`, `proteinG =
    ///     min(round(80×2.2)=176, 209) = 176`.
    ///     `fatFloorG=64`, `fatShareG=round(1866×0.27/9)=56`,
    ///     `fatMaxG=min(floor(1866×0.3/9)=62, floor(80))=62`,
    ///     `fatG=min(max(64,56),62)=62`. `carbsFloorG=160`,
    ///     `remaining()=(1866−704−558)/4=151 < 160` et `fatG(62) >
    ///     fatHardFloorG(40)` → `spare=ceil((160−151)×4/9)=4`,
    ///     `fatG=max(62−4,40)=58` ; `carbsG=remaining()` recalculé avec
    ///     `fatG=58` → `(1866−704−522)/4=160`.
    ///     `fiberG=round(clamp(1866/1000×14,20,50))=round(26.124)=26`.
    ///     `proteinPerKg = round2(wanted) = 2.2` (`proteinCapped` faux).
    @Test func computeDayTargetMatchesHandCalculatedExample() {
        let profile = NutritionEngineProfile(birthYear: 1990, sex: "male", weightKg: 80, heightCm: 180)
        let watch = NutritionEngineWatchDay(restingKcal: 1800, activeKcal: 300)
        let result = NutritionTargetEngine.computeDayTarget(
            date: "2026-09-23", profile: profile, watch: watch, sessions: [], settings: .defaults)

        #expect(result.status == "ok")
        #expect(result.source == "watch")
        #expect(result.guardStatus == "availability")
        #expect(result.targetKcal == 1866)
        #expect(result.expenditureKcal == 2100)
        #expect(result.deficitKcal == 234)
        #expect(result.plannedDeficitKcal == 616)
        #expect(result.fatFreeMassKg == 62.63)
        #expect(result.macros.proteinG == 176)
        #expect(result.macros.fatG == 58)
        #expect(result.macros.carbsG == 160)
        #expect(result.macros.fiberG == 26)
        #expect(result.macros.proteinPerKg == 2.2)
    }

    /// Profil totalement vide + aucune donnée montre : `computeDayTarget`
    /// retombe HONNÊTEMENT sur `unavailable()` — miroir de la branche
    /// `!fromWatch && formulaBmr == null` (TS). Aucune valeur fabriquée
    /// (toutes les cibles `nil`, `macros` neutre).
    @Test func computeDayTargetIsUnavailableWithoutProfileOrWatch() {
        let profile = NutritionEngineProfile(birthYear: nil, sex: nil, weightKg: nil, heightCm: nil)
        let watch = NutritionEngineWatchDay(restingKcal: nil, activeKcal: nil)
        let result = NutritionTargetEngine.computeDayTarget(
            date: "2026-09-23", profile: profile, watch: watch, sessions: [], settings: .defaults)

        #expect(result.status == "unavailable")
        #expect(Set(result.missing) == Set(["birthYear", "sex", "weightKg", "heightCm"]))
        #expect(result.targetKcal == nil)
        #expect(result.macros.proteinG == nil)
        #expect(result.macros.fiberG == nil) // `unavailable()` n'appelle PAS `computeMacros` : fiberG jamais calculé.
        #expect(result.guardStatus == "none")
    }

    /// Une séance de renforcement (`sport: "training"`) ajoute le bonus
    /// protéines `"strength"` (+0,2 g/kg) — miroir de
    /// `sessions.some(isResistanceSession)` (TS). Vérifie la présence du
    /// bonus (`macros.bonuses`), pas tout le recalcul en aval (déjà couvert
    /// par le test hand-calculated ci-dessus pour le cas sans séance).
    @Test func computeMacrosAddsStrengthBonusForResistanceSession() {
        let session = NutritionEngineSession(sport: "training", subSport: nil, durationS: 1800, calories: 200)
        let withSession = NutritionTargetEngine.computeMacros(
            targetKcal: 1866, deficitKcal: 234, expenditureKcal: 2100, weightKg: 80, ageYears: 36,
            sessions: [session], settings: .defaults)
        let withoutSession = NutritionTargetEngine.computeMacros(
            targetKcal: 1866, deficitKcal: 234, expenditureKcal: 2100, weightKg: 80, ageYears: 36,
            sessions: [], settings: .defaults)

        #expect(withSession.bonuses.contains { $0.key == "strength" && $0.perKg == 0.2 })
        #expect(!withoutSession.bonuses.contains { $0.key == "strength" })
    }

    /// `computeWeekly` — 4 jours "complets" (intake ≥ 60 % de la cible,
    /// `isCompleteDay`) à 1600 kcal vs dépense 2100, 3 jours vides.
    /// `avgIntakeKcal = 1600`, `avgExpenditureKcal = 2100`,
    /// `avgDeficitKcal = 500` (< `weeklyAlertKcal` par défaut = 600 → pas
    /// d'alerte).
    @Test func computeWeeklyMatchesHandCalculatedAggregate() {
        var days: [NutritionEngineWeeklyDay] = []
        for i in 0..<3 {
            days.append(.init(date: "day-empty-\(i)", intakeKcal: nil, expenditureKcal: 2100, targetKcal: 1866, balanceKcal: nil))
        }
        for i in 0..<4 {
            days.append(.init(date: "day-complete-\(i)", intakeKcal: 1600, expenditureKcal: 2100, targetKcal: 1866, balanceKcal: -500))
        }
        let result = NutritionTargetEngine.computeWeekly(days, settings: .defaults)

        #expect(result.loggedDays == 4)
        #expect(result.partialDays == 0)
        #expect(result.emptyDays == 3)
        #expect(result.avgIntakeKcal == 1600)
        #expect(result.avgExpenditureKcal == 2100)
        #expect(result.avgDeficitKcal == 500)
        #expect(result.alert == false)
        #expect(result.thresholdKcal == 600)
    }

    /// `clampSetting` — bornes exactes de `target.ts` (`weeklyAlertKcal` ∈
    /// [100, 2000]) ; hors bornes → `nil`, jamais une valeur tronquée
    /// silencieusement à la borne.
    @Test func clampSettingRejectsOutOfRangeValues() {
        #expect(NutritionTargetEngine.clampSetting(.weeklyAlertKcal, 50) == nil)
        #expect(NutritionTargetEngine.clampSetting(.weeklyAlertKcal, 700) == 700)
        #expect(NutritionTargetEngine.clampSetting(.proteinPerKg, 2.567) == 2.57) // arrondi 0,01.
    }
}

// MARK: - Intégration (`RealLocalPulseBackend`/`LocalDb`)

struct NutritionAnalyticsLocalTests {
    private func makeDb() throws -> LocalDb {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("nutrition-analytics-tests-\(UUID().uuidString).sqlite").path
        return try LocalDb(path: path)
    }

    /// Profil complet identique à l'exemple moteur ci-dessus (36 ans, homme,
    /// 80 kg, 180 cm) — `weightKg` posé directement en `settings` (pas de
    /// `weight_log`), miroir du repli `profileOn`/`weightOn` quand aucune
    /// pesée n'existe avant la date interrogée.
    private func seedCompleteProfile(_ db: LocalDb) throws {
        try db.setSetting(key: "birthYear", value: "1990")
        try db.setSetting(key: "sex", value: "male")
        try db.setSetting(key: "weightKg", value: "80")
        try db.setSetting(key: "heightCm", value: "180")
    }

    /// Repos/dépense montre pour une date — même exemple que le test moteur
    /// (`bmr_kcal` = 1800, `active_calories` = 300), via `FitWellnessData`
    /// directement (pas de vrai `.fit`) : `wellness_days`/`wellness_counters`
    /// sont indexées par la CHAÎNE `date`, jamais par un timestamp — aucune
    /// sensibilité au fuseau de la machine de test ici (contrairement à
    /// `activities.start_time`, non exercé par ces tests).
    private func seedWatchDay(_ db: LocalDb, date: String, bmrKcal: Double, activeCalories: Double) throws {
        let data = FitWellnessData(
            days: [FitWellnessDay(date: date, restingHr: nil, bmrKcal: bmrKcal)],
            counters: [FitWellnessCounter(date: date, activityType: "walking", steps: nil, activeCalories: activeCalories, distanceM: nil, activeTimeS: nil)],
            counterSamples: [], samples: [])
        try db.storeWellness(data, hash: "watch-\(date)", fileName: "watch-\(date).fit")
    }

    private func targets(_ backend: RealLocalPulseBackend, date: String) async throws -> NutritionTargetInfo {
        let data = try await backend.handle(method: "GET", path: "api/nutrition/targets", query: ["date": date], body: nil)
        return try PulseAPIClient.decoder.decode(NutritionTargetInfo.self, from: data)
    }

    private func day(_ backend: RealLocalPulseBackend, date: String) async throws -> NutritionDay {
        let data = try await backend.handle(method: "GET", path: "api/nutrition/day/\(date)", query: [:], body: nil)
        return try PulseAPIClient.decoder.decode(NutritionDay.self, from: data)
    }

    // MARK: - `GET api/nutrition/targets`

    /// Base vierge (profil incomplet) : comportement HONNÊTE du serveur —
    /// `status: "unavailable"`, `missing` liste les 4 champs, aucune cible
    /// fabriquée. Miroir de `computeDayTargetIsUnavailableWithoutProfileOrWatch`
    /// (moteur pur), à travers la route HTTP réelle cette fois.
    @Test func targetsRouteIsUnavailableWithIncompleteProfile() async throws {
        let backend = RealLocalPulseBackend(db: try makeDb())
        let info = try await targets(backend, date: "2026-09-23")

        #expect(info.auto.status == "unavailable")
        #expect(Set(info.auto.missing) == Set(["birthYear", "sex", "weightKg", "heightCm"]))
        #expect(info.auto.targetKcal == nil)
        #expect(info.targets.kcal == nil)
        #expect(info.mode == "auto") // défaut sans `settings.nutritionMode`.
        #expect(info.source == "manual") // `useAuto` faux (status != "ok") → repli manuel (vide ici).
    }

    /// Profil complet + montre seedée : la route reflète EXACTEMENT l'exemple
    /// calculé à la main (cf. `computeDayTargetMatchesHandCalculatedExample`)
    /// — vérifie le câblage lecture-profil/montre → JSON en plus de la
    /// formule.
    @Test func targetsRouteReflectsComputedValuesWithCompleteProfile() async throws {
        let db = try makeDb()
        try seedCompleteProfile(db)
        try seedWatchDay(db, date: "2026-09-23", bmrKcal: 1800, activeCalories: 300)
        let backend = RealLocalPulseBackend(db: db)

        let info = try await targets(backend, date: "2026-09-23")
        #expect(info.mode == "auto")
        #expect(info.source == "auto")
        #expect(info.auto.status == "ok")
        #expect(info.auto.source == "watch")
        #expect(info.auto.guardStatus == "availability")
        #expect(info.auto.targetKcal == 1866)
        #expect(info.auto.expenditureKcal == 2100)
        #expect(info.auto.deficitKcal == 234)
        #expect(info.auto.macros.proteinG == 176)
        #expect(info.auto.macros.fatG == 58)
        #expect(info.auto.macros.carbsG == 160)
        #expect(info.auto.macros.fiberG == 26)
        #expect(info.auto.macros.proteinPerKg == 2.2)
        #expect(info.auto.macros.programme == nil) // moteur programme non porté.
        #expect(info.targets.kcal == 1866)
        #expect(info.targets.protein == 176)
    }

    /// Mode MANUEL (`settings.nutritionMode = "manual"`) : `source ==
    /// "manual"` même si l'auto est calculable, `targets.kcal` = la valeur
    /// manuelle configurée — miroir de `useAuto = mode === 'auto' && ...`.
    @Test func targetsRouteUsesManualModeWhenConfigured() async throws {
        let db = try makeDb()
        try seedCompleteProfile(db)
        try seedWatchDay(db, date: "2026-09-23", bmrKcal: 1800, activeCalories: 300)
        try db.setSetting(key: "nutritionMode", value: "manual")
        try db.setSetting(key: "nutritionKcal", value: "2200")
        let backend = RealLocalPulseBackend(db: db)

        let info = try await targets(backend, date: "2026-09-23")
        #expect(info.mode == "manual")
        #expect(info.source == "manual")
        #expect(info.targets.kcal == 2200)
        // `auto` reste calculé/exposé indépendamment du mode (même que le serveur).
        #expect(info.auto.status == "ok")
        #expect(info.auto.targetKcal == 1866)
    }

    // MARK: - `GET api/nutrition/day/:date`

    /// `day/:date` porte désormais les VRAIES cibles/reliquat (plus le
    /// neutre `null` de l'incrément précédent) : profil complet + montre +
    /// une entrée journalisée → `remaining` = cible − totaux réels.
    @Test func dayRouteCarriesRealTargetsAndRemaining() async throws {
        let db = try makeDb()
        try seedCompleteProfile(db)
        try seedWatchDay(db, date: "2026-09-23", bmrKcal: 1800, activeCalories: 300)
        _ = try db.insertLog(
            date: "2026-09-23", foodId: nil, name: "Repas test", grams: 300, kcal: 500, protein: 50,
            carbs: 40, fiber: 5, fat: 10, unitLabel: nil, unitQty: nil, ts: 1_758_610_000)
        let backend = RealLocalPulseBackend(db: db)

        let d = try await day(backend, date: "2026-09-23")
        #expect(d.targets.kcal == 1866)
        #expect(d.targets.protein == 176)
        #expect(d.remaining.kcal == 1366) // 1866 - 500
        #expect(d.remaining.protein == 126) // 176 - 50
        #expect(d.remaining.carbs == 120) // 160 - 40
        #expect(d.remaining.fiber == 21) // 26 - 5
        #expect(d.targetRanges == nil) // aucune cible manuelle min/max configurée.
        #expect(d.programme == nil) // moteur programme non porté.
    }

    /// `targetRanges` reflète les cibles MANUELLES min/max
    /// (`settings.nutritionKcalMin`/`Max`) — `manualRanges()`, indépendant du
    /// mode auto/manuel (le serveur les calcule dans tous les cas).
    @Test func dayRouteTargetRangesReflectManualMinMaxSettings() async throws {
        let db = try makeDb()
        try db.setSetting(key: "nutritionKcalMin", value: "1800")
        try db.setSetting(key: "nutritionKcalMax", value: "2200")
        let backend = RealLocalPulseBackend(db: db)

        let d = try await day(backend, date: "2026-09-23")
        let ranges = try #require(d.targetRanges)
        #expect(ranges["kcal"]?.min == 1800)
        #expect(ranges["kcal"]?.max == 2200)
        #expect(ranges["protein"] == nil) // aucune borne protéine configurée.
    }

    // MARK: - `GET api/nutrition/weekly`

    /// 7 jours se terminant le 2026-09-23, montre identique chaque jour
    /// (→ `targetKcal`/`expenditureKcal` = 1866/2100 tous les jours, cf.
    /// exemple moteur), 4 jours journalisés à 1600 kcal (≥ 60 % de 1866 →
    /// "complets"), 3 jours vides — miroir exact de
    /// `computeWeeklyMatchesHandCalculatedAggregate` mais à travers la route
    /// réelle (câblage `dayTarget`/`foodLogKcalByDate` sur 7 dates).
    @Test func weeklyRouteMatchesHandCalculatedAggregate() async throws {
        let db = try makeDb()
        try seedCompleteProfile(db)
        let dates = ["2026-09-17", "2026-09-18", "2026-09-19", "2026-09-20", "2026-09-21", "2026-09-22", "2026-09-23"]
        let watchData = FitWellnessData(
            days: dates.map { FitWellnessDay(date: $0, restingHr: nil, bmrKcal: 1800) },
            counters: dates.map { FitWellnessCounter(date: $0, activityType: "walking", steps: nil, activeCalories: 300, distanceM: nil, activeTimeS: nil) },
            counterSamples: [], samples: [])
        try db.storeWellness(watchData, hash: "weekly-watch", fileName: "weekly-watch.fit")
        // 4 derniers jours journalisés à 1600 kcal chacun (une seule entrée par jour).
        for date in dates.suffix(4) {
            _ = try db.insertLog(
                date: date, foodId: nil, name: "Repas", grams: 400, kcal: 1600, protein: nil,
                carbs: nil, fiber: nil, fat: nil, unitLabel: nil, unitQty: nil, ts: 0)
        }
        let backend = RealLocalPulseBackend(db: db)

        let data = try await backend.handle(method: "GET", path: "api/nutrition/weekly", query: ["date": "2026-09-23"], body: nil)
        let weekly = try PulseAPIClient.decoder.decode(NutritionWeekly.self, from: data)

        #expect(weekly.loggedDays == 4)
        #expect(weekly.partialDays == 0)
        #expect(weekly.emptyDays == 3)
        #expect(weekly.avgDeficitKcal == 500)
        #expect(weekly.alert == false)
        #expect(weekly.thresholdKcal == 600)
    }

    // MARK: - `GET api/nutrition/timing/:date`

    /// Dernier repas à `ts = T` (800 kcal, 30 g de lipides), deux échantillons
    /// de stress dans la fenêtre `[T, T+5400)` (20 et 40 → moyenne 30) —
    /// calcul à la main : `baseH = clamp(1.5 + 800/400 + 30/30, 1.5, 5) =
    /// 4.5`, `stressFactor = clamp(1 + (30−30)/100, 0.75, 1.6) = 1`,
    /// `windowH = 4.5`, `digestionEndTs = T + 4.5×3600 = T + 16200`.
    @Test func timingRouteComputesDigestionWindowFromHandCalculatedExample() async throws {
        let db = try makeDb()
        let t = 1_758_610_000
        _ = try db.insertLog(
            date: "2026-09-23", foodId: nil, name: "Dîner", grams: 300, kcal: 800, protein: 40,
            carbs: 60, fiber: 5, fat: 30, unitLabel: nil, unitQty: nil, ts: t)
        let stressData = FitWellnessData(
            days: [], counters: [], counterSamples: [],
            samples: [
                FitWellnessSample(metric: "stress", ts: Double(t) + 1000, value: 20),
                FitWellnessSample(metric: "stress", ts: Double(t) + 2000, value: 40),
            ])
        try db.storeWellness(stressData, hash: "stress-sample", fileName: "stress.fit")
        let backend = RealLocalPulseBackend(db: db)

        let data = try await backend.handle(method: "GET", path: "api/nutrition/timing/2026-09-23", query: [:], body: nil)
        let timing = try PulseAPIClient.decoder.decode(NutritionTimingResponse.self, from: data)
        let meal = try #require(timing.meal)

        #expect(meal.lastMealTs == t)
        #expect(meal.digestionEndTs == t + 16200)
        #expect(meal.nextMealTs == t + 16200)
        #expect(meal.avgStress == 30)
        #expect(meal.windowH == 4.5)
    }

    /// Aucune entrée journalisée avec `ts` pour la date : `{"meal": null}` —
    /// état réel valide du contrat (pas une dégradation), miroir de
    /// `if (!last) return { meal: null }` (TS).
    @Test func timingRouteReturnsNilMealWithoutTimestampedEntry() async throws {
        let backend = RealLocalPulseBackend(db: try makeDb())
        let data = try await backend.handle(method: "GET", path: "api/nutrition/timing/2026-09-23", query: [:], body: nil)
        let timing = try PulseAPIClient.decoder.decode(NutritionTimingResponse.self, from: data)
        #expect(timing.meal == nil)
    }

    // MARK: - `GET api/nutrition/suggestions/:date`

    /// Profil complet + montre seedée, AUCUN aliment journalisé : `remaining`
    /// == les cibles complètes (totaux nuls), miroir de l'exemple moteur —
    /// `items` non vide (bibliothèque `foods` semée au premier ouverture) et
    /// borné à 6. Cohérence interne vérifiée sur le premier item : ses
    /// quantités absolues sont bien `round(kcal_pour_100g × grams / 100)` —
    /// recalculé depuis la fiche `foods` retrouvée via `GET
    /// api/nutrition/foods`, pas une valeur fabriquée. La PARITÉ EXACTE avec
    /// le tri/score de `target.ts`/`NutritionController.suggestions` n'est
    /// PAS recoupée ici (dépend de l'ordre d'itération des ~95 aliments
    /// semés) — seule la cohérence interne du premier résultat est vérifiée.
    @Test func suggestionsRouteScoresAgainstFullRemainingTargets() async throws {
        let db = try makeDb()
        try seedCompleteProfile(db)
        try seedWatchDay(db, date: "2026-09-23", bmrKcal: 1800, activeCalories: 300)
        let backend = RealLocalPulseBackend(db: db)

        let data = try await backend.handle(method: "GET", path: "api/nutrition/suggestions/2026-09-23", query: [:], body: nil)
        let suggestions = try PulseAPIClient.decoder.decode(NutritionSuggestionsResponse.self, from: data)

        #expect(suggestions.remaining.kcal == 1866)
        #expect(suggestions.remaining.protein == 176)
        #expect(suggestions.reason == nil)
        #expect(!suggestions.items.isEmpty)
        #expect(suggestions.items.count <= 6)

        let top = try #require(suggestions.items.first)
        let foodsData = try await backend.handle(method: "GET", path: "api/nutrition/foods", query: ["q": top.name], body: nil)
        let foods = try PulseAPIClient.decoder.decode([NutritionFoodLite].self, from: foodsData)
        let sheet = try #require(foods.first { $0.name == top.name })
        let factor = top.grams / 100
        if let kcalPer100 = sheet.kcal {
            #expect(top.kcal == (kcalPer100 * factor).rounded())
        }
    }

    /// Profil incomplet : `remaining` neutre → `reason: "no-targets"`, ZÉRO
    /// requête à la bibliothèque `foods` (déjà couvert en détail par
    /// `NutritionLocalTests.suggestionsStubDecodesAsNoTargets`, revérifié ici
    /// dans le contexte du moteur réel pour confirmer que le chemin
    /// "incomplet" reste inchangé après le portage).
    @Test func suggestionsRouteReturnsNoTargetsReasonWithIncompleteProfile() async throws {
        let backend = RealLocalPulseBackend(db: try makeDb())
        let data = try await backend.handle(method: "GET", path: "api/nutrition/suggestions/2026-09-23", query: [:], body: nil)
        let suggestions = try PulseAPIClient.decoder.decode(NutritionSuggestionsResponse.self, from: data)
        #expect(suggestions.items.isEmpty)
        #expect(suggestions.reason == "no-targets")
    }
}
