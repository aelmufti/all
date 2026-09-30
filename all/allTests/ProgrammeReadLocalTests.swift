//
//  ProgrammeReadLocalTests.swift
//  allTests
//
//  Valide l'incrément L7a-Programme (lecture) — `docs/stockage-local.md` :
//  `GET api/programme` servi par `RealLocalPulseBackend`/`LocalDb`
//  (`programme_state`/`programme_plan`/`programme_done`, ajoutées cet
//  incrément), câblé sur le moteur portagé sous `Local/Programme/`
//  (`ProgrammeCatalogue`/`ProgrammeProgressEngine`/`ProgrammeSleepEngine`).
//
//  Deux familles de tests, même esprit que `NutritionAnalyticsLocalTests` :
//    - MOTEUR PUR (`ProgrammeCatalogueEngineTests`) — aucune base, catalogue
//      et fonctions pures (`sessionsPerWeek`/`ruleCount`/`checkDay`/`weekOf`).
//    - INTÉGRATION (`ProgrammeReadLocalTests`) — `RealLocalPulseBackend`
//      réel + `LocalDb` temporaire, décodé avec le modèle RÉEL de l'écran
//      (`PulseAPIClient.decoder`, `ProgrammeCurrent`,
//      `Pulse/Screens/Programme/ProgrammeModels.swift`). Un programme actif
//      est seedé DIRECTEMENT dans `programme_state`/`programme_plan`/
//      `programme_done` via les méthodes `debug*` de `LocalDb` (AUCUNE route
//      d'activation locale n'existe encore, cf. `RealLocalPulseBackend`).
//
//  AUCUN environnement Node/serveur n'est disponible ici : la parité EXACTE
//  avec `programme.controller.ts`/`catalogue.ts`/`progress.ts`/`sleep.ts`
//  n'est donc PAS recoupée bit-à-bit contre une exécution réelle du TS — les
//  valeurs attendues ci-dessous sont recalculées À LA MAIN à partir du code
//  source lu (détail du calcul en commentaire sur chaque test), pas rejouées.
//
//  Le domaine sommeil dépend du fuseau de l'appareil (`LocalDb.localOffsetSeconds`,
//  identique à `dayDetail`) : les nuits de test utilisent la MÊME heure
//  d'horloge chaque nuit sur une fenêtre sans changement d'heure (8 jours de
//  septembre) — le décalage fuseau est donc CONSTANT sur toute la fenêtre, ce
//  qui rend les écarts-types attendus (0) indépendants du fuseau réel du
//  simulateur qui exécute le test (cf. `activatedSleepProgrammeReflectsRegularNights`).
//

import Testing
import Foundation
@testable import all

// MARK: - Moteur pur (catalogue + progression) — aucune base

struct ProgrammeCatalogueEngineTests {
    /// Catalogue statique — dénombrements hand-checked depuis `catalogue.ts`
    /// (cf. `ProgrammeCatalogue.swift`) : `seche-escalade-nutrients-2021`
    /// (CLIMB_BLOCK) a 4 semaines de 3 séances identiques (`CLIMB_SESSIONS`),
    /// `rules: []` (kind `training`) → `ruleCount` retombe sur `rules.count`
    /// (0), `sessionsPerWeek` = max séances/semaine = 3.
    @Test func climbBlockCounts() {
        let programme = ProgrammeCatalogue.programme(byId: "seche-escalade-nutrients-2021")!
        #expect(programme.weeks.count == 4)
        #expect(ProgrammeCatalogue.ruleCount(programme) == 0)
        #expect(ProgrammeProgressEngine.sessionsPerWeek(programme) == 3)
    }

    /// `seche-nutrients-2021` (FAT_LOSS) : kind `nutrition`, `weeks: []`,
    /// 4 règles (protein/carbs/fat/fiber) → `ruleCount` = 4 (PAS `sleepRules`,
    /// kind ≠ sleep), `sessionsPerWeek` = 0 (aucune semaine).
    @Test func fatLossCounts() {
        let programme = ProgrammeCatalogue.programme(byId: "seche-nutrients-2021")!
        #expect(programme.kind == .nutrition)
        #expect(ProgrammeCatalogue.ruleCount(programme) == 4)
        #expect(ProgrammeProgressEngine.sessionsPerWeek(programme) == 0)
    }

    /// `sommeil-regularite-nsf-2023` : kind `sleep`, 6 `sleepRules` →
    /// `ruleCount` retombe sur `sleepRules.count` (PAS `rules`, vide ici).
    @Test func sleepRegularityCounts() {
        let programme = ProgrammeCatalogue.programme(byId: "sommeil-regularite-nsf-2023")!
        #expect(programme.kind == .sleep)
        #expect(ProgrammeCatalogue.ruleCount(programme) == 6)
    }

    /// `debug-course-pipeline` (DEBUG_RUN) : 2 semaines de 2 séances chacune
    /// → `sessionsPerWeek` = 2.
    @Test func debugRunCounts() {
        let programme = ProgrammeCatalogue.programme(byId: "debug-course-pipeline")!
        #expect(programme.weeks.count == 2)
        #expect(ProgrammeProgressEngine.sessionsPerWeek(programme) == 2)
    }

    /// `weekOf` (TS) : semaine 1 le jour du démarrage, incrémente tous les
    /// 7 jours calendaires (UTC).
    @Test func weekOfMatchesHandCalculation() {
        #expect(ProgrammeProgressEngine.weekOf(startedOn: "2026-09-14", date: "2026-09-14") == 1)
        #expect(ProgrammeProgressEngine.weekOf(startedOn: "2026-09-14", date: "2026-09-20") == 1)
        #expect(ProgrammeProgressEngine.weekOf(startedOn: "2026-09-14", date: "2026-09-21") == 2)
        // Avant le démarrage : 0 (miroir de `day < start` → 0).
        #expect(ProgrammeProgressEngine.weekOf(startedOn: "2026-09-14", date: "2026-09-01") == 0)
    }

    /// `checkDay` (`progress.ts`) — règle protéines de FAT_LOSS (2,2 à 3,0
    /// g/kg), poids 80 kg : bornes `[176, 240]`. 200 g → `hit` ; 150 g →
    /// `under` ; 250 g → `over` ; sans apport (`intake: nil`) → `unknown`,
    /// `logged: false`.
    @Test func checkDayAppliesPerKgRuleScaling() {
        let programme = ProgrammeCatalogue.programme(byId: "seche-nutrients-2021")!
        func intake(protein: Double) -> ProgrammeEngineDayIntake {
            ProgrammeEngineDayIntake(date: "2026-09-30", protein: protein, carbs: 0, fat: 0, fiber: 0, kcal: 0)
        }
        let hit = ProgrammeProgressEngine.checkDay(programme: programme, intake: intake(protein: 200), weightKg: 80, date: "2026-09-30")
        let proteinRuleHit = hit.rules.first { $0.rule.key == "protein" }!
        #expect(proteinRuleHit.targetMin == 176)
        #expect(proteinRuleHit.targetMax == 240)
        #expect(proteinRuleHit.status == .hit)

        let under = ProgrammeProgressEngine.checkDay(programme: programme, intake: intake(protein: 150), weightKg: 80, date: "2026-09-30")
        #expect(under.rules.first { $0.rule.key == "protein" }!.status == .under)

        let over = ProgrammeProgressEngine.checkDay(programme: programme, intake: intake(protein: 250), weightKg: 80, date: "2026-09-30")
        #expect(over.rules.first { $0.rule.key == "protein" }!.status == .over)

        let empty = ProgrammeProgressEngine.checkDay(programme: programme, intake: nil, weightKg: 80, date: "2026-09-30")
        #expect(empty.logged == false)
        #expect(empty.rules.allSatisfy { $0.status == .unknown && $0.value == nil })
    }
}

// MARK: - Intégration (`RealLocalPulseBackend` + `LocalDb` temporaire)

// `.serialized` : ces tests passent isolément mais échouaient en exécution
// parallèle (état global partagé sous concurrence, même cause que la suite
// `PulseSocleTests`). La sérialisation supprime la course.
@Suite(.serialized)
struct ProgrammeReadLocalTests {
    private func makeDb() throws -> LocalDb {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("programme-read-local-tests-\(UUID().uuidString).sqlite").path
        return try LocalDb(path: path)
    }

    private func getProgramme(_ backend: RealLocalPulseBackend, date: String? = nil) async throws -> ProgrammeCurrent {
        let query = date.map { ["date": $0] } ?? [:]
        let data = try await backend.handle(method: "GET", path: "api/programme", query: query, body: nil)
        return try PulseAPIClient.decoder.decode(ProgrammeCurrent.self, from: data)
    }

    private func domain(_ current: ProgrammeCurrent, _ kind: ProgrammeKind) -> ProgrammeDomainView {
        current.domains.first { $0.kind == kind }!
    }

    private static let utc: TimeZone = TimeZone(identifier: "UTC")!

    /// Construit un epoch Unix (secondes) depuis une date/heure UTC littérale
    /// — évite toute dépendance à `ISO8601DateFormatter` (comportement de
    /// parsing parfois surprenant sur les fractions/fuseaux) pour un besoin
    /// aussi simple.
    private func epoch(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int) -> Double {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Self.utc
        let components = DateComponents(year: y, month: m, day: d, hour: h, minute: min)
        return calendar.date(from: components)!.timeIntervalSince1970
    }

    // MARK: - Base vierge (aucun programme activé)

    /// Décode dans le modèle réel de l'écran ; les trois domaines sont
    /// présents, DANS L'ORDRE `DOMAINS` (training, nutrition, sleep) ; aucun
    /// n'a de programme actif (base vierge, `programme_state` vide) — miroir
    /// HONNÊTE du serveur avec une base vide, rien de fabriqué.
    @Test func emptyDbHasThreeDomainsAllInactive() async throws {
        let backend = RealLocalPulseBackend(db: try makeDb())
        let current = try await getProgramme(backend)

        #expect(current.domains.map(\.kind) == [.training, .nutrition, .sleep])
        for d in current.domains {
            #expect(d.active == nil)
            #expect(d.detail == nil)
        }
        // `date` par défaut = aujourd'hui (calendaire local, `todayDateKey`).
        #expect(current.date.count == 10)
        #expect(current.date.filter { $0 == "-" }.count == 2)
    }

    /// Catalogue statique visible dans `choices` MÊME sans activation —
    /// dénombrements hand-checked (cf. `ProgrammeCatalogueEngineTests`).
    @Test func choicesReflectStaticCatalogueRegardlessOfActivation() async throws {
        let backend = RealLocalPulseBackend(db: try makeDb())
        let current = try await getProgramme(backend)

        let training = domain(current, .training)
        #expect(Set(training.choices.map(\.id)) == Set(["seche-escalade-nutrients-2021", "debug-course-pipeline"]))
        let climb = training.choices.first { $0.id == "seche-escalade-nutrients-2021" }!
        #expect(climb.weeks == 4)
        #expect(climb.rules == 0)
        #expect(climb.perWeek == 3)

        let nutrition = domain(current, .nutrition)
        #expect(nutrition.choices.count == 1)
        #expect(nutrition.choices[0].id == "seche-nutrients-2021")
        #expect(nutrition.choices[0].rules == 4)

        let sleep = domain(current, .sleep)
        #expect(sleep.choices.count == 1)
        #expect(sleep.choices[0].id == "sommeil-regularite-nsf-2023")
        #expect(sleep.choices[0].rules == 6)
    }

    /// `?date=` valide reflété tel quel ; invalide → repli sur aujourd'hui
    /// (miroir de `DATE_RE.test(dateParam) ? dateParam : today`).
    @Test func dateQueryParamIsValidatedOrFallsBackToToday() async throws {
        let backend = RealLocalPulseBackend(db: try makeDb())
        let withDate = try await getProgramme(backend, date: "2026-01-01")
        #expect(withDate.date == "2026-01-01")

        let withInvalidDate = try await getProgramme(backend, date: "not-a-date")
        #expect(withInvalidDate.date != "not-a-date")
        #expect(withInvalidDate.date.count == 10)
    }

    // MARK: - Écritures différées

    /// `activate`/`stop`/`session`/`push`/`export` restent `LocalPulseUnavailableError`
    /// — aucune route d'écriture locale pour Programme dans cet incrément
    /// (déclenchées par une action utilisateur, pas au chargement de l'écran).
    @Test func writeRoutesStayDeferred() async throws {
        let backend = RealLocalPulseBackend(db: try makeDb())
        await #expect(throws: LocalPulseUnavailableError.self) {
            _ = try await backend.handle(method: "POST", path: "api/programme/activate", query: [:], body: Data("{}".utf8))
        }
        await #expect(throws: LocalPulseUnavailableError.self) {
            _ = try await backend.handle(method: "POST", path: "api/programme/stop", query: [:], body: Data("{}".utf8))
        }
        await #expect(throws: LocalPulseUnavailableError.self) {
            _ = try await backend.handle(method: "POST", path: "api/programme/session", query: [:], body: Data("{}".utf8))
        }
        await #expect(throws: LocalPulseUnavailableError.self) {
            _ = try await backend.handle(method: "GET", path: "api/programme/push", query: [:], body: nil)
        }
        await #expect(throws: LocalPulseUnavailableError.self) {
            _ = try await backend.handle(method: "GET", path: "api/programme/export", query: [:], body: nil)
        }
    }

    // MARK: - Domaine entraînement, programme activé

    /// Programme escalade (`seche-escalade-nutrients-2021`) activé au
    /// 2026-09-14 (lundi), une séance planifiée (`programme_plan`,
    /// semaine 1/`escalade-intensite`, le 2026-09-15) rapprochée d'une
    /// activité importée le même jour (rockClimbing/indoorClimbing, 50 min ≥
    /// les 45 min requis) → `matchSessions` la marque `done`, `manual: false`.
    ///
    /// Interrogé au 2026-09-30 : `week = weekOf("2026-09-14","2026-09-30")`
    /// = `floor(16/7) + 1 = 3` (hand-calc, cf. `weekOfMatchesHandCalculation`).
    /// Les 11 autres séances (aucun `programme_plan`) retombent sur
    /// `plannedOn: nil` → `status: "upcoming"` (JAMAIS `"missed"`, miroir de
    /// `statusFor` : `plannedOn == null` court-circuite avant la comparaison
    /// à `today`) → `missed == 0` quelle que soit la date interrogée.
    /// Le domaine `nutrition` (non activé) reste `nil` — la lecture est bien
    /// scoppée par `kind`.
    @Test func activatedTrainingProgrammeReflectsMatchedSession() async throws {
        let db = try makeDb()
        try db.debugActivateProgramme(
            programmeId: "seche-escalade-nutrients-2021", kind: "training", startedOn: "2026-09-14", days: nil)
        try db.debugInsertProgrammePlan(
            programmeId: "seche-escalade-nutrients-2021", week: 1, session: "escalade-intensite", date: "2026-09-15")
        let activityId = try db.storeActivity(
            FitActivityExtractor.Summary(
                sport: "rockClimbing", subSport: "indoorClimbing", startTime: "2026-09-15T09:00:00Z",
                durationS: 3000, distanceM: nil, calories: 400, avgHr: 140, maxHr: 160),
            hash: "activity-climb-1", fileName: "climb1.fit")
        // Pointage manuel (`programme_done`, sans activité) — miroir de la
        // branche `forced` de `matchSessions` : `manual: true`, prioritaire
        // sur tout rapprochement automatique pour cette clé.
        try db.debugInsertProgrammeDone(
            programmeId: "seche-escalade-nutrients-2021", week: 1, session: "renfo", date: "2026-09-16", activityId: nil)

        let backend = RealLocalPulseBackend(db: db)
        let current = try await getProgramme(backend, date: "2026-09-30")

        let training = domain(current, .training)
        let active = try #require(training.active)
        #expect(active.programmeId == "seche-escalade-nutrients-2021")
        #expect(active.week == 3)
        #expect(active.weeks == 4)
        #expect(active.perWeek == 3)
        #expect(active.days == [])

        guard case .training(let detail) = try #require(training.detail) else {
            Issue.record("Détail attendu de type training")
            return
        }
        #expect(detail.total == 12) // 4 semaines × 3 séances.
        #expect(detail.done == 2) // escalade-intensite (auto) + renfo (manuel).
        #expect(detail.missed == 0)

        let matched = try #require(detail.sessions.first { $0.week == 1 && $0.session.key == "escalade-intensite" })
        #expect(matched.done == true)
        #expect(matched.status == .done)
        #expect(matched.manual == false)
        #expect(matched.activityId == activityId)
        #expect(matched.date == "2026-09-15")
        #expect(matched.plannedOn == "2026-09-15")

        let manual = try #require(detail.sessions.first { $0.week == 1 && $0.session.key == "renfo" })
        #expect(manual.done == true)
        #expect(manual.status == .done)
        #expect(manual.manual == true)
        #expect(manual.activityId == nil)
        #expect(manual.date == "2026-09-16")

        // Domaine nutrition non activé — reste honnêtement vide.
        #expect(domain(current, .nutrition).active == nil)
    }

    // MARK: - Domaine alimentation, programme activé

    /// Programme sèche (`seche-nutrients-2021`) activé, poids 80 kg
    /// (`weight_log`, seedé au 2026-09-25 — `weightOn(date:)` le retrouve
    /// pour toute date ≥ à celle-ci), un repas loggé au 2026-09-30 (protéines
    /// 200 g, glucides 100 g, lipides 40 g, fibres 10 g).
    ///
    /// Bornes hand-checked (`progress.ts checkDay`, `min(Round(rule.min×80))`) :
    ///   - protéines `[176, 240]` (2,2–3,0 g/kg) → 200 g → `hit`.
    ///   - glucides `[160, 400]` (2–5 g/kg) → 100 g → `under`.
    ///   - lipides `[40, 80]` (0,5–1,0 g/kg) → 40 g == min → `hit`.
    ///   - fibres `[25, ∞)` (pas perKg) → 10 g → `under`.
    /// → `hits == 2` (protéines, lipides), `total == 4`.
    @Test func activatedNutritionProgrammeReflectsLoggedIntake() async throws {
        let db = try makeDb()
        try db.debugActivateProgramme(programmeId: "seche-nutrients-2021", kind: "nutrition", startedOn: "2026-09-01", days: nil)
        try db.upsertWeight(date: "2026-09-25", kg: 80)
        _ = try db.insertLog(
            date: "2026-09-30", foodId: nil, name: "Repas test", grams: 500,
            kcal: 1600, protein: 200, carbs: 100, fiber: 10, fat: 40,
            unitLabel: nil, unitQty: nil, ts: Int(Date().timeIntervalSince1970))

        let backend = RealLocalPulseBackend(db: db)
        let current = try await getProgramme(backend, date: "2026-09-30")

        let nutrition = domain(current, .nutrition)
        #expect(nutrition.active?.programmeId == "seche-nutrients-2021")
        guard case .nutrition(let detail) = try #require(nutrition.detail) else {
            Issue.record("Détail attendu de type nutrition")
            return
        }
        #expect(detail.weightKg == 80)
        #expect(detail.days.count == 7)
        #expect(detail.today.date == "2026-09-30")
        #expect(detail.today.logged == true)
        #expect(detail.today.hits == 2)
        #expect(detail.today.total == 4)

        func status(_ key: String) -> ProgrammeStatus {
            detail.today.rules.first { $0.rule.key == key }!.status
        }
        #expect(status("protein") == .hit)
        #expect(status("carbs") == .under)
        #expect(status("fat") == .hit)
        #expect(status("fiber") == .under)

        let proteinRule = try #require(detail.today.rules.first { $0.rule.key == "protein" })
        #expect(proteinRule.target.min == 176)
        #expect(proteinRule.target.max == 240)
        #expect(proteinRule.value == 200)
    }

    // MARK: - Domaine sommeil, programme activé

    /// Programme régularité (`sommeil-regularite-nsf-2023`) activé, 8 nuits
    /// consécutives IDENTIQUES (même heure de coucher/réveil chaque nuit,
    /// 22 h → 6 h UTC, 8 h de sommeil) du 2026-09-14 (lundi) au 2026-09-21
    /// (lundi) — aucun changement d'heure sur cette fenêtre, donc le décalage
    /// fuseau (`LocalDb.localOffsetSeconds`) est constant sur les 8 nuits :
    /// les écarts-types calculés ci-dessous sont NULS indépendamment du
    /// fuseau réel de la machine de test.
    ///
    /// Jours ouvrés par défaut (`DEFAULT_WORK_DAYS` = lun-ven, aucun `days`
    /// seedé) : 14,15,16,17,18,21 = 6 nuits "travail" ; 19 (sam), 20 (dim) =
    /// 2 nuits "libres" → `groupsReady` (≥2 de chaque côté).
    ///
    /// Hand-checked (`sleep.ts`) :
    ///   - `nights == 8`, `workNights == 6`, `freeNights == 2`.
    ///   - `from == "2026-09-14"`, `to == "2026-09-21"`, `spanDays == 8`.
    ///   - interrogé au 2026-09-21 (= `to`) → `staleDays == 0`.
    ///   - `pairs` : paires de jours consécutifs COUVERTS (jour ET jour+1
    ///     enregistrés) ET dont les DEUX cases minute-par-minute
    ///     (`asleep[day]`/`asleep[next]`) existent — au plus 6 des 8 nuits
    ///     QUALIFIENT pour `covered` (la dernière, 09-21, n'a pas de
    ///     lendemain 09-22 enregistré ; l'avant-dernière, 09-20, en dépend
    ///     donc aussi) ; parmi elles, la case du TOUT PREMIER jour (09-14)
    ///     peut rester vide selon le fuseau de la machine de test (aucune
    ///     nuit 09-13 pour la "remplir" par débordement si le fuseau pousse
    ///     l'intégralité de la nuit 22 h-6 h UTC sur le calendrier local du
    ///     09-15) — d'où une borne `[5, 6]` plutôt qu'une valeur unique,
    ///     PAS un défaut de portage (vérifié : dépendant de
    ///     `LocalDb.localOffsetSeconds`, propre à la machine qui exécute le
    ///     test, cf. `TimeZone.current`).
    ///   - horaires identiques chaque nuit → écarts-types (coucher, durée)
    ///     NULS → métriques `coucher`/`duree-ecart` valent 0.
    ///   - durée moyenne 480 min (8 h), dans `[420, 540]` → `duree-moyenne`
    ///     = `hit`.
    ///   - horaires travail/libre identiques → `decalage-social` = 0.
    ///   - `rattrapage` : `workDuration` = 480 ≥ `SHORT_NIGHT_MIN` (420) →
    ///     `owed ≤ 0` → bornes `[nil, 120]`, `raw = free(480) - work(480) = 0`
    ///     → `hit`.
    @Test func activatedSleepProgrammeReflectsRegularNights() async throws {
        let db = try makeDb()
        try db.debugActivateProgramme(programmeId: "sommeil-regularite-nsf-2023", kind: "sleep", startedOn: "2026-09-01", days: nil)

        let dates = ["2026-09-14", "2026-09-15", "2026-09-16", "2026-09-17", "2026-09-18", "2026-09-19", "2026-09-20", "2026-09-21"]
        for (i, date) in dates.enumerated() {
            let day = 14 + i
            let startTs = epoch(2026, 9, day, 22, 0)
            let endTs = epoch(2026, 9, day + 1, 6, 0)
            let summary = FitSleepSummary(
                date: date, startTs: startTs, endTs: endTs, durationS: 28800, score: nil,
                deepS: 0, lightS: 28800, remS: 0, awakeS: 0, awakenings: nil,
                phases: [FitSleepPhase(from: startTs, to: endTs, stage: "light")])
            try db.storeSleep(summary, hash: "sleep-\(date)", fileName: "\(date).fit")
        }

        let backend = RealLocalPulseBackend(db: db)
        let current = try await getProgramme(backend, date: "2026-09-21")

        let sleep = domain(current, .sleep)
        #expect(sleep.active?.programmeId == "sommeil-regularite-nsf-2023")
        guard case .sleep(let detail) = try #require(sleep.detail) else {
            Issue.record("Détail attendu de type sleep")
            return
        }

        #expect(detail.nights == 8)
        #expect(detail.workNights == 6)
        #expect(detail.freeNights == 2)
        #expect(detail.from == "2026-09-14")
        #expect(detail.to == "2026-09-21")
        #expect(detail.spanDays == 8)
        #expect(detail.staleDays == 0)
        // Borne, pas une valeur unique — cf. commentaire d'en-tête du test :
        // dépend du fuseau de la machine (la case du tout premier jour peut
        // rester vide selon l'offset). `>= 4` (`MIN_PAIRS`) confirme aussi
        // que la métrique SRI a assez de paires pour être calculée (non
        // `nil`, cf. assertion plus bas).
        #expect((5...6).contains(detail.pairs))

        func metric(_ key: String) -> ProgrammeSleepMetric {
            detail.metrics.first { $0.key == key }!
        }
        #expect(metric("coucher").value == 0)
        #expect(metric("duree-ecart").value == 0)
        #expect(metric("duree-moyenne").value == 480)
        #expect(metric("duree-moyenne").status == .hit)
        #expect(metric("decalage-social").value == 0)
        #expect(metric("decalage-social").status == .hit)
        #expect(metric("rattrapage").value == 0)
        #expect(metric("rattrapage").status == .hit)
        // Bande "30 min ou moins" (ONSET_BANDS, upTo 30) pour un écart-type nul.
        #expect(metric("coucher").band?.label == "30 min ou moins")
    }
}
