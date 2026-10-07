//
//  SaisieRetryTests.swift
//  allTests
//
//  Reprise automatique de l'échange des saisies (`Sync/SaisieRetryPolicy.swift`,
//  `SaisieSyncService`) et activité déclarée à la bannière pendant les passes :
//   - décision PURE : délais croissants et plafonnés, remise à zéro, rien sur 401 ni
//     sans configuration, rien hors premier plan / hors « Les deux » ;
//   - service : minuterie factice (`ManualWakeTimer`), transport factice, base
//     temporaire — aucun réseau, aucune vraie donnée ;
//   - le compteur d'activité de l'échange retombe dans TOUS les chemins de sortie.
//

import Testing
import Foundation
@testable import all

// MARK: - Décision pure

struct SaisieRetryPolicyTests {
    private func decide(
        _ outcome: SaisieSyncPassOutcome, foreground: Bool = true, mode: StorageMode = .both,
        stillNeeded: Bool = true, attempt: Int = 0
    ) -> SaisieRetryPolicy.Decision {
        SaisieRetryPolicy.decide(outcome: outcome, foreground: foreground, mode: mode, stillNeeded: stillNeeded, attempt: attempt)
    }

    @Test func delaysGrowThenStayAtTheCeiling() {
        let seen = (1...8).map { SaisieRetryPolicy.delay(afterAttempt: $0) }
        #expect(seen == [15, 30, 60, 120, 240, 240, 240, 240])
        #expect(SaisieRetryPolicy.delay(afterAttempt: 0) == 15, "valeur défensive")
    }

    @Test func eachFailureEscalatesTheDelay() {
        var attempt = 0
        var delays: [TimeInterval] = []
        for _ in 0..<4 {
            guard case .retry(let after, let next) = decide(.networkOrServerFailure, attempt: attempt) else {
                Issue.record("devait reprogrammer")
                return
            }
            delays.append(after)
            attempt = next
        }
        #expect(delays == [15, 30, 60, 120])
    }

    @Test func aStorageFailureIsRetriedLikeAnyOther() {
        #expect(decide(.storageFailure) == .retry(after: 15, attempt: 1))
    }

    @Test func aCompleteSuccessStopsAndResets() {
        #expect(decide(.succeeded, stillNeeded: false, attempt: 3) == .stop)
    }

    @Test func aSuccessThatLeavesChangesEscalatesInsteadOfLoopingAtTheFirstDelay() {
        #expect(decide(.succeeded, stillNeeded: true, attempt: 0) == .retry(after: 15, attempt: 1))
        #expect(decide(.succeeded, stillNeeded: true, attempt: 2) == .retry(after: 60, attempt: 3))
    }

    @Test func nothingLeftToExchangeMeansNoRetryEvenAfterAFailure() {
        #expect(decide(.networkOrServerFailure, stillNeeded: false) == .stop)
        #expect(decide(.storageFailure, stillNeeded: false) == .stop)
    }

    @Test func aRefusedTokenIsNeverRetried() {
        #expect(decide(.unauthorized) == .stop)
        #expect(decide(.unauthorized, attempt: 4) == .stop)
    }

    @Test func missingConfigurationIsNeverRetried() {
        #expect(decide(.notConfigured) == .stop)
    }

    @Test func aPassThatTriedNothingStops() {
        #expect(decide(.skipped) == .stop)
    }

    @Test func noRetryInTheBackground() {
        #expect(decide(.networkOrServerFailure, foreground: false) == .stop)
        #expect(decide(.succeeded, foreground: false, stillNeeded: true) == .stop)
    }

    @Test(arguments: [StorageMode.pulse, .phone])
    func noRetryOutsideBothMode(mode: StorageMode) {
        #expect(decide(.networkOrServerFailure, mode: mode) == .stop)
    }
}

// MARK: - Service

private final class ScriptedTransport: SaisieSyncTransport, @unchecked Sendable {
    enum Step {
        case ok
        case status(Int)
        case offline
        case notConfigured
    }
    private let lock = NSLock()
    private var steps: [Step]
    private var _calls = 0
    init(_ steps: [Step]) { self.steps = steps }
    var calls: Int { lock.withLock { _calls } }

    func post(_ body: Data) async throws -> SaisieSyncHTTPResponse {
        let step = lock.withLock { () -> Step in
            _calls += 1
            return steps.count > 1 ? steps.removeFirst() : steps[0]
        }
        switch step {
        case .ok: return SaisieSyncHTTPResponse(status: 200, body: Data(#"{"cursor":1,"changes":[]}"#.utf8))
        case .status(let code): return SaisieSyncHTTPResponse(status: code, body: Data())
        case .offline: throw SaisieSyncError.transport(URLError(.notConnectedToInternet))
        case .notConfigured: throw SaisieSyncError.notConfigured
        }
    }
}

private final class SaisieModeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: StorageMode
    init(_ value: StorageMode) { self.value = value }
    var mode: StorageMode {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

private func eventually(timeout: TimeInterval = 30, _ condition: () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return await condition()
}

fileprivate struct SaisieRetryServiceTests {
    private struct Rig {
        let service: SaisieSyncService
        let db: LocalDb
        let transport: ScriptedTransport
        let timer: ManualWakeTimer
        let reporter: RecordingWorkReporter
        let mode: SaisieModeBox
    }

    /// Base sans semis ni journal, avec UN changement local en attente (un poids).
    private func makeRig(_ steps: [ScriptedTransport.Step], mode: StorageMode = .both, pending: Bool = true) throws -> Rig {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("saisie-retry-\(UUID().uuidString).sqlite").path
        let db = try LocalDb(path: path)
        try db.db.run("DELETE FROM foods")
        try db.db.run("DELETE FROM saisie_changes")
        if pending { try db.upsertWeight(date: "2026-10-01", kg: 72) }
        let transport = ScriptedTransport(steps)
        let timer = ManualWakeTimer()
        let reporter = RecordingWorkReporter()
        let box = SaisieModeBox(mode)
        let service = SaisieSyncService(
            engineProvider: { SaisieSyncEngine(db: db, transport: transport) },
            modeProvider: { box.mode },
            health: { _ in },
            afterRemoteChanges: { _ in },
            reporter: reporter,
            retryTimer: timer)
        return Rig(service: service, db: db, transport: transport, timer: timer, reporter: reporter, mode: box)
    }

    /// Une passe complète, minuterie de reprise comprise.
    private func pass(_ rig: Rig) async {
        await rig.service.exchangeAndWait()
    }

    // MARK: Délais, remise à zéro

    @Test func consecutiveFailuresArmGrowingDelaysUpToTheCeiling() async throws {
        let rig = try makeRig([.offline])
        await pass(rig)
        #expect(rig.timer.armedDelays == [15])
        for expected in 2...6 {
            #expect(rig.timer.fire(), "la reprise est armée")
            #expect(await eventually { rig.timer.armedDelays.count == expected })
        }
        #expect(rig.timer.armedDelays == [15, 30, 60, 120, 240, 240])
        #expect(rig.service.retryAttemptCount == 6)
    }

    @Test func aServerErrorIsRetriedToo() async throws {
        let rig = try makeRig([.status(503)])
        await pass(rig)
        #expect(rig.timer.armedDelays == [15])
    }

    @Test func aSuccessResetsTheCounterAndCancelsTheTimer() async throws {
        let rig = try makeRig([.offline, .offline, .ok])
        await pass(rig)
        #expect(rig.timer.fire())
        #expect(await eventually { rig.timer.armedDelays.count == 2 })
        #expect(rig.timer.fire())
        #expect(await eventually { rig.service.retryAttemptCount == 0 && !rig.timer.isArmed })

        #expect(rig.timer.armedDelays == [15, 30])
        #expect(try !rig.db.hasPendingSaisieChanges(), "l'échange a bien abouti")
    }

    @Test func afterASuccessANewFailureStartsBackAtTheFirstDelay() async throws {
        let rig = try makeRig([.offline, .ok, .offline])
        await pass(rig) // échec : 15
        #expect(rig.timer.fire())
        #expect(await eventually { rig.service.retryAttemptCount == 0 && !rig.timer.isArmed })
        try rig.db.upsertWeight(date: "2026-10-02", kg: 73)
        await pass(rig) // nouvel échec : repart de 15
        #expect(rig.timer.armedDelays == [15, 15])
        #expect(rig.service.retryAttemptCount == 1)
    }

    @Test func noRetryWhenNothingIsLeftToExchangeAfterAFailure() async throws {
        let rig = try makeRig([.ok, .offline], pending: false)
        await pass(rig) // premier échange abouti : plus rien à faire
        #expect(rig.timer.armedDelays.isEmpty)
        await pass(rig) // échec, mais ni changement ni premier échange en attente
        #expect(rig.timer.armedDelays.isEmpty)
        #expect(!rig.timer.isArmed)
    }

    @Test func aFirstExchangeThatNeverSucceededIsRetriedEvenWithoutLocalChanges() async throws {
        let rig = try makeRig([.offline], pending: false)
        await pass(rig)
        #expect(rig.timer.armedDelays == [15])
    }

    // MARK: Pas de reprise

    @Test func aRefusedTokenIsNotRetried() async throws {
        let rig = try makeRig([.status(401)])
        await pass(rig)
        #expect(rig.timer.armedDelays.isEmpty)
        #expect(!rig.timer.isArmed)
        #expect(rig.service.retryAttemptCount == 0)
    }

    @Test func missingConfigurationIsNotRetried() async throws {
        let rig = try makeRig([.notConfigured])
        await pass(rig)
        #expect(rig.timer.armedDelays.isEmpty)
        #expect(!rig.timer.isArmed)
    }

    @Test func aRefusalAfterFailuresCancelsTheRetryAlreadyArmed() async throws {
        let rig = try makeRig([.offline, .status(401)])
        await pass(rig)
        #expect(rig.timer.isArmed)
        #expect(rig.timer.fire())
        #expect(await eventually { rig.timer.cancelCount > 0 && !rig.timer.isArmed })
        #expect(rig.timer.armedDelays == [15], "pas de seconde reprise après le 401")
    }

    // MARK: Annulations

    @Test func goingToTheBackgroundCancelsTheRetry() async throws {
        let rig = try makeRig([.offline])
        await pass(rig)
        #expect(rig.timer.isArmed)

        rig.service.setForeground(false)

        #expect(!rig.timer.isArmed)
        #expect(rig.service.retryAttemptCount == 0)
        // Une passe qui échoue encore en arrière-plan ne reprogramme rien.
        await pass(rig)
        #expect(rig.timer.armedDelays == [15])
        #expect(!rig.timer.isArmed)
    }

    @Test func aTimerThatFiresAfterTheBackgroundStartsNothing() async throws {
        let rig = try makeRig([.offline])
        await pass(rig)
        let callsBefore = rig.transport.calls
        rig.service.setForeground(false)
        // Course : la minuterie était déjà réveillée quand l'annulation est arrivée.
        rig.timer.fireStale()
        try? await Task.sleep(nanoseconds: 80_000_000)
        #expect(rig.transport.calls == callsBefore)
        #expect(rig.reporter.exchangeBeganCount == 1)
    }

    @Test func returningToTheForegroundRestartsWithoutAnyLeftoverState() async throws {
        let rig = try makeRig([.offline])
        await pass(rig)
        rig.service.setForeground(false)
        rig.service.setForeground(true)
        await pass(rig)
        #expect(rig.timer.armedDelays == [15, 15], "compteur remis à zéro par l'arrière-plan")
    }

    @Test func aStorageModeChangeCancelsTheRetry() async throws {
        let rig = try makeRig([.offline])
        await pass(rig)
        #expect(rig.timer.isArmed)

        rig.service.storageModeDidChange()

        #expect(!rig.timer.isArmed)
        #expect(rig.service.retryAttemptCount == 0)
    }

    @Test func aRetryThatFiresInAnotherModeStartsNothing() async throws {
        let rig = try makeRig([.offline])
        await pass(rig)
        let callsBefore = rig.transport.calls

        rig.mode.mode = .pulse
        #expect(rig.timer.fire())
        try? await Task.sleep(nanoseconds: 80_000_000)

        #expect(rig.transport.calls == callsBefore)
        #expect(rig.reporter.exchangeBeganCount == 1)
        #expect(!rig.timer.isArmed)
    }

    // MARK: Une seule minuterie

    @Test func eachPassArmsExactlyOneTimerAndOverlappingRequestsDoNotStackThem() async throws {
        let rig = try makeRig([.offline])
        for _ in 0..<10 { rig.service.requestExchange() }
        #expect(await eventually { rig.reporter.exchangeBeganCount >= 1 })
        #expect(await eventually { await rig.service.isIdle })
        #expect(rig.timer.armedDelays.count == rig.reporter.exchangeBeganCount, "une armement par passe, jamais plus")
        // Les armements se REMPLACENT : une seule échéance en attente.
        #expect(rig.timer.fire())
        #expect(!rig.timer.fire())
    }

    // MARK: Fin d'ingestion plutôt que le seul minuteur (base occupée)

    /// Fait échouer le moteur côté BASE (et non réseau) : la table d'état n'existe plus.
    private func breakDatabase(_ rig: Rig) throws {
        try rig.db.db.run("DROP TABLE saisie_sync_state")
    }

    @Test func aStorageFailureIsRetriedWhenTheIngestionPassEndsWithoutWaitingForTheTimer() async throws {
        let rig = try makeRig([.ok])
        try breakDatabase(rig)
        await pass(rig)
        #expect(rig.timer.armedDelays == [15])
        let began = rig.reporter.exchangeBeganCount

        rig.service.ingestPassDidEnd()

        #expect(await eventually { rig.reporter.exchangeBeganCount == began + 1 }, "un nouvel échange part tout de suite")
        #expect(await eventually { rig.timer.armedDelays.count == 2 })
        #expect(rig.timer.armedDelays == [15, 30], "et le délai a continué de croître")
        #expect(rig.timer.cancelCount >= 1, "la minuterie précédente a été annulée avant le départ")
    }

    @Test func aNetworkFailureIsNotDevancedByAnIngestionPass() async throws {
        let rig = try makeRig([.offline])
        await pass(rig)
        let began = rig.reporter.exchangeBeganCount

        rig.service.ingestPassDidEnd()
        try? await Task.sleep(nanoseconds: 80_000_000)

        #expect(rig.reporter.exchangeBeganCount == began, "Pulse injoignable : l'ingestion n'y change rien")
        #expect(rig.timer.isArmed)
    }

    @Test func theIngestionSignalIsConsumedOnce() async throws {
        let rig = try makeRig([.ok])
        try breakDatabase(rig)
        await pass(rig)
        rig.service.ingestPassDidEnd()
        rig.service.ingestPassDidEnd() // second signal immédiat : un seul départ
        #expect(await eventually { rig.timer.armedDelays.count >= 2 })
        try? await Task.sleep(nanoseconds: 80_000_000)
        #expect(rig.reporter.exchangeBeganCount <= 3, "pas de rafale")
    }

    // MARK: Activité déclarée : retombe dans tous les chemins

    @Test func theExchangeActivityIsBalancedOnSuccess() async throws {
        let rig = try makeRig([.ok])
        await pass(rig)
        #expect(rig.reporter.exchangeBeganCount == 1)
        #expect(rig.reporter.isIdle)
    }

    @Test(arguments: [ScriptedTransport.Step.offline, .status(401), .status(500), .status(400), .notConfigured])
    func theExchangeActivityIsBalancedOnEveryFailure(step: ScriptedTransport.Step) async throws {
        let rig = try makeRig([step])
        await pass(rig)
        #expect(rig.reporter.exchangeBeganCount == 1)
        #expect(rig.reporter.isIdle)
    }

    @Test func theExchangeActivityIsBalancedOnADatabaseFailure() async throws {
        let rig = try makeRig([.ok])
        try breakDatabase(rig)
        await pass(rig)
        #expect(rig.reporter.exchangeBeganCount == 1)
        #expect(rig.reporter.isIdle)
    }

    @Test(arguments: [StorageMode.pulse, .phone])
    func noActivityIsDeclaredOutsideBothMode(mode: StorageMode) async throws {
        let rig = try makeRig([.ok], mode: mode)
        rig.service.requestExchange()
        await rig.service.exchangeAndWait()
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(rig.reporter.exchangeBeganCount == 0)
        #expect(rig.transport.calls == 0)
    }

    @Test func passesRequestedDuringAnExclusiveWorkAreDiscardedFromTheCounterAndRunAfterwards() async throws {
        let rig = try makeRig([.ok])

        await rig.service.runExclusively {
            rig.service.requestExchange()
            rig.service.requestExchange()
            try? await Task.sleep(nanoseconds: 60_000_000)
            #expect(rig.reporter.exchangeBeganCount == 0, "rien ne court pendant la purge : rien n'est déclaré")
            #expect(rig.reporter.isIdle)
        }

        #expect(await eventually { rig.reporter.exchangeBeganCount >= 1 })
        #expect(await eventually { await rig.service.isIdle })
        #expect(rig.reporter.isIdle, "la passe différée s'est libérée elle aussi")
    }

    @Test func aThrowingExclusiveWorkLeavesTheCounterAtZero() async throws {
        struct Boom: Error {}
        let rig = try makeRig([.ok])
        do {
            try await rig.service.runExclusively { throw Boom() }
            Issue.record("devait lever")
        } catch {}
        #expect(rig.reporter.isIdle)
        #expect(await rig.service.isIdle)
    }

    @Test func manyOverlappingRequestsNeverOverlapTheirActivity() async throws {
        let rig = try makeRig([.ok])
        for _ in 0..<20 { rig.service.requestExchange() }
        #expect(await eventually { await rig.service.isIdle && rig.reporter.exchangeBeganCount >= 1 })
        #expect(rig.reporter.exchangePeak == 1, "jamais deux échanges déclarés en même temps")
        #expect(rig.reporter.isIdle)
    }
}
