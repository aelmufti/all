//
//  ProgrammeWriteLocalTests.swift
//  allTests
//
//  Valide l'incrément L7b-Programme (écriture) — `docs/stockage-local.md` :
//  `POST api/programme/activate`/`stop`/`session` servis par
//  `RealLocalPulseBackend`/`LocalDb` (écriture RÉELLE de `programme_state`/
//  `programme_plan`/`programme_done`, miroir de `programme.controller.ts`
//  `activate()`/`stop()`/`toggleSession()`).
//
//  Même esprit que `ProgrammeReadLocalTests` : intégration
//  `RealLocalPulseBackend` + `LocalDb` temporaire, réponses décodées avec le
//  modèle RÉEL de l'écran (`PulseAPIClient.decoder`, `ProgrammeCurrent`,
//  `Pulse/Screens/Programme/ProgrammeModels.swift`). Les états intermédiaires
//  (`programme_state`/`programme_plan`/`programme_done`) sont vérifiés
//  directement via les méthodes de lecture de `LocalDb`
//  (`programmeActiveState`/`programmePlanRows`/`programmeDoneRows`), pas
//  seulement à travers la réponse HTTP.
//
//  AUCUN environnement Node/serveur n'est disponible ici : la parité EXACTE
//  avec `programme.controller.ts` n'est donc PAS recoupée bit-à-bit contre une
//  exécution réelle du TS — les valeurs attendues ci-dessous (dates de plan,
//  bornes de jours…) sont recalculées À LA MAIN à partir du code source lu
//  (`catalogue.ts`/`progress.ts`, cf. commentaires par test), pas rejouées.
//
//  `.serialized` : même raison que `ProgrammeReadLocalTests` (état global
//  partagé sous concurrence, course observée en pratique avec Swift Testing
//  qui exécute les suites en parallèle par défaut).
//

import Testing
import Foundation
@testable import all

@Suite(.serialized)
struct ProgrammeWriteLocalTests {
    private func makeDb() throws -> LocalDb {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("programme-write-local-tests-\(UUID().uuidString).sqlite").path
        return try LocalDb(path: path)
    }

    private func getProgramme(_ backend: RealLocalPulseBackend) async throws -> ProgrammeCurrent {
        let data = try await backend.handle(method: "GET", path: "api/programme", query: [:], body: nil)
        return try PulseAPIClient.decoder.decode(ProgrammeCurrent.self, from: data)
    }

    private func domain(_ current: ProgrammeCurrent, _ kind: ProgrammeKind) -> ProgrammeDomainView {
        current.domains.first { $0.kind == kind }!
    }

    private func activate(
        _ backend: RealLocalPulseBackend, programmeId: String, startedOn: String? = nil, days: [Int]
    ) async throws -> ProgrammeCurrent {
        var payload: [String: Any] = ["programmeId": programmeId, "days": days]
        if let startedOn { payload["startedOn"] = startedOn }
        let body = try JSONSerialization.data(withJSONObject: payload)
        let data = try await backend.handle(method: "POST", path: "api/programme/activate", query: [:], body: body)
        return try PulseAPIClient.decoder.decode(ProgrammeCurrent.self, from: data)
    }

    private func stop(_ backend: RealLocalPulseBackend, kind: String) async throws -> ProgrammeCurrent {
        let body = try JSONSerialization.data(withJSONObject: ["kind": kind])
        let data = try await backend.handle(method: "POST", path: "api/programme/stop", query: [:], body: body)
        return try PulseAPIClient.decoder.decode(ProgrammeCurrent.self, from: data)
    }

    private func toggleSession(
        _ backend: RealLocalPulseBackend, week: Int, session: String, done: Bool,
        date: String? = nil, activityId: Int? = nil
    ) async throws -> ProgrammeCurrent {
        var payload: [String: Any] = ["week": week, "session": session, "done": done]
        if let date { payload["date"] = date }
        if let activityId { payload["activityId"] = activityId }
        let body = try JSONSerialization.data(withJSONObject: payload)
        let data = try await backend.handle(method: "POST", path: "api/programme/session", query: [:], body: body)
        return try PulseAPIClient.decoder.decode(ProgrammeCurrent.self, from: data)
    }

    // MARK: - Activation

    /// Programme escalade (`seche-escalade-nutrients-2021`, `sessionsPerWeek
    /// == 3`, cf. `ProgrammeCatalogueEngineTests.climbBlockCounts`) activé
    /// avec 3 jours (lun/mer/ven, `[1, 3, 5]`, convention `Date.getUTCDay()`)
    /// à partir du 2026-09-14 (lundi, même date que
    /// `ProgrammeReadLocalTests.activatedTrainingProgrammeReflectsMatchedSession`).
    ///
    /// `buildPlan` (hand-checked, `progress.ts`) : semaine 1 (`from ==
    /// startedOn`) — parcours des 7 jours depuis le lundi, ceux qui tombent
    /// sur `{1,3,5}` sont 09-14 (lun), 09-16 (mer), 09-18 (ven), dans cet
    /// ordre chronologique ; les 3 séances du catalogue (`escalade-intensite`,
    /// `escalade-volume`, `renfo`, dans cet ordre) leur sont assignées 1-1.
    /// Semaine 2 (`from = 09-21`, lundi suivant) : mêmes offsets → 09-21,
    /// 09-23, 09-25. 4 semaines × 3 séances = 12 lignes au total.
    @Test func activateTrainingProgrammeCreatesActiveStateAndPlan() async throws {
        let db = try makeDb()
        let backend = RealLocalPulseBackend(db: db)

        let current = try await activate(
            backend, programmeId: "seche-escalade-nutrients-2021", startedOn: "2026-09-14", days: [1, 3, 5])

        let training = domain(current, .training)
        let active = try #require(training.active)
        #expect(active.programmeId == "seche-escalade-nutrients-2021")
        #expect(active.startedOn == "2026-09-14")
        #expect(active.days == [1, 3, 5])
        #expect(active.perWeek == 3)

        let state = try #require(try db.programmeActiveState(kind: "training"))
        #expect(state.startedOn == "2026-09-14")
        #expect(state.days == "1,3,5")

        let plan = try db.programmePlanRows(programmeId: "seche-escalade-nutrients-2021")
        #expect(plan.count == 12) // 4 semaines × 3 séances.
        let week1Intensite = try #require(plan.first { $0.week == 1 && $0.session == "escalade-intensite" })
        #expect(week1Intensite.date == "2026-09-14")
        let week1Volume = try #require(plan.first { $0.week == 1 && $0.session == "escalade-volume" })
        #expect(week1Volume.date == "2026-09-16")
        let week1Renfo = try #require(plan.first { $0.week == 1 && $0.session == "renfo" })
        #expect(week1Renfo.date == "2026-09-18")
        let week2Renfo = try #require(plan.first { $0.week == 2 && $0.session == "renfo" })
        #expect(week2Renfo.date == "2026-09-25")
    }

    /// `days` insuffisant pour un programme `training` (`sessionsPerWeek ==
    /// 3`, seulement 2 jours fournis) → lève AVANT toute écriture, miroir du
    /// `BadRequestException` côté serveur (levé avant la transaction).
    @Test func activateWithTooFewDaysThrows() async throws {
        let db = try makeDb()
        let backend = RealLocalPulseBackend(db: db)

        await #expect(throws: (any Error).self) {
            _ = try await self.activate(backend, programmeId: "seche-escalade-nutrients-2021", days: [1, 3])
        }
        #expect(try db.programmeActiveState(kind: "training") == nil)
    }

    /// `programmeId` inconnu du catalogue → lève avant toute écriture.
    @Test func activateUnknownProgrammeThrows() async throws {
        let backend = RealLocalPulseBackend(db: try makeDb())
        await #expect(throws: (any Error).self) {
            _ = try await self.activate(backend, programmeId: "ne-existe-pas", days: [1, 3, 5])
        }
    }

    // MARK: - Arrêt

    /// `stop` désactive le programme `training` actif — `active` redevient
    /// `nil` côté `current()`, `programme_state.active` repasse à 0 en base
    /// (`programmeActiveState` ne le retrouve donc plus).
    @Test func stopDeactivatesActiveProgramme() async throws {
        let db = try makeDb()
        let backend = RealLocalPulseBackend(db: db)
        _ = try await activate(backend, programmeId: "seche-escalade-nutrients-2021", startedOn: "2026-09-14", days: [1, 3, 5])

        let current = try await stop(backend, kind: "training")
        #expect(domain(current, .training).active == nil)
        #expect(try db.programmeActiveState(kind: "training") == nil)
    }

    /// `kind` hors des trois domaines catalogués (`training`/`nutrition`/
    /// `sleep`) → lève (`Unknown kind`).
    @Test func stopWithUnknownKindThrows() async throws {
        let backend = RealLocalPulseBackend(db: try makeDb())
        await #expect(throws: (any Error).self) {
            _ = try await self.stop(backend, kind: "not-a-kind")
        }
    }

    // MARK: - Bascule de séance

    /// `done: true` avec un `activityId` connu — `programme_done` reçoit la
    /// ligne (date = jour calendaire de l'activité, `substr(start_time,1,10)`,
    /// miroir `activityDate`), `current()` la reflète : `done: true`,
    /// `manual: true` (TOUT pointage venant de `programme_done` ressort
    /// `manual`, y compris avec un `activityId` — cf. la branche `forced` de
    /// `matchSessions`, distincte du rapprochement automatique).
    @Test func sessionDoneWithKnownActivityCreatesDoneRow() async throws {
        let db = try makeDb()
        let backend = RealLocalPulseBackend(db: db)
        _ = try await activate(backend, programmeId: "seche-escalade-nutrients-2021", startedOn: "2026-09-14", days: [1, 3, 5])
        let activityId = try db.storeActivity(
            FitActivityExtractor.Summary(
                sport: "rockClimbing", subSport: "indoorClimbing", startTime: "2026-09-14T09:00:00Z",
                durationS: 3000, distanceM: nil, calories: 400, avgHr: 140, maxHr: 160),
            hash: "activity-climb-write-1", fileName: "climb1.fit")

        let current = try await toggleSession(backend, week: 1, session: "escalade-intensite", done: true, activityId: activityId)

        let done = try db.programmeDoneRows(programmeId: "seche-escalade-nutrients-2021")
        let row = try #require(done.first { $0.week == 1 && $0.session == "escalade-intensite" })
        #expect(row.date == "2026-09-14")
        #expect(row.activityId == activityId)

        guard case .training(let detail) = try #require(domain(current, .training).detail) else {
            Issue.record("Détail attendu de type training")
            return
        }
        let matched = try #require(detail.sessions.first { $0.week == 1 && $0.session.key == "escalade-intensite" })
        #expect(matched.done == true)
        #expect(matched.manual == true)
        #expect(matched.activityId == activityId)
    }

    /// `activityId` inconnu (aucune activité en base) → lève (`Unknown
    /// activity`), rien n'est écrit dans `programme_done`.
    @Test func sessionWithUnknownActivityThrows() async throws {
        let db = try makeDb()
        let backend = RealLocalPulseBackend(db: db)
        _ = try await activate(backend, programmeId: "seche-escalade-nutrients-2021", startedOn: "2026-09-14", days: [1, 3, 5])

        await #expect(throws: (any Error).self) {
            _ = try await self.toggleSession(backend, week: 1, session: "escalade-intensite", done: true, activityId: 999_999)
        }
        let done = try db.programmeDoneRows(programmeId: "seche-escalade-nutrients-2021")
        #expect(done.isEmpty)
    }

    /// `done: false` supprime le pointage existant (sans `activityId`, date
    /// donnée explicitement dans le corps).
    @Test func sessionDoneFalseRemovesRow() async throws {
        let db = try makeDb()
        let backend = RealLocalPulseBackend(db: db)
        _ = try await activate(backend, programmeId: "seche-escalade-nutrients-2021", startedOn: "2026-09-14", days: [1, 3, 5])
        _ = try await toggleSession(backend, week: 1, session: "escalade-intensite", done: true, date: "2026-09-14")
        #expect(try db.programmeDoneRows(programmeId: "seche-escalade-nutrients-2021").count == 1)

        _ = try await toggleSession(backend, week: 1, session: "escalade-intensite", done: false)
        #expect(try db.programmeDoneRows(programmeId: "seche-escalade-nutrients-2021").isEmpty)
    }

    /// Aucun programme `training` actif → lève (`No active programme`) AVANT
    /// même de regarder `week`/`session`.
    @Test func sessionWithoutActiveTrainingProgrammeThrows() async throws {
        let backend = RealLocalPulseBackend(db: try makeDb())
        await #expect(throws: (any Error).self) {
            _ = try await self.toggleSession(backend, week: 1, session: "escalade-intensite", done: true)
        }
    }

    // MARK: - Réactivation

    /// Réactiver le MÊME programme, MÊME date de départ, mais des `days`
    /// DIFFÉRENTS (le programme "bouge" — `moved == true` côté
    /// `LocalDb.programmeActivate`, comparaison `previous.days ?? '' !=
    /// days.join(',')`) purge `programme_done` — un pointage posé sous
    /// l'ancienne activation disparaît. `[0, 2, 4]` reste un compte valide
    /// (3 jours, ≥ `sessionsPerWeek == 3`) : seule la COMPOSITION change, pas
    /// le nombre, pour isoler l'effet de `moved` de la validation de compte.
    @Test func reactivateWithChangedDaysClearsDoneRows() async throws {
        let db = try makeDb()
        let backend = RealLocalPulseBackend(db: db)
        _ = try await activate(backend, programmeId: "seche-escalade-nutrients-2021", startedOn: "2026-09-14", days: [1, 3, 5])
        _ = try await toggleSession(backend, week: 1, session: "escalade-intensite", done: true, date: "2026-09-14")
        #expect(try db.programmeDoneRows(programmeId: "seche-escalade-nutrients-2021").count == 1)

        _ = try await activate(backend, programmeId: "seche-escalade-nutrients-2021", startedOn: "2026-09-14", days: [0, 2, 4])

        #expect(try db.programmeDoneRows(programmeId: "seche-escalade-nutrients-2021").isEmpty)
        let state = try #require(try db.programmeActiveState(kind: "training"))
        #expect(state.days == "0,2,4")
    }
}
