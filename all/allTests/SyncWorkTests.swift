//
//  SyncWorkTests.swift
//  allTests
//
//  Retour visuel du travail du téléphone (`Sync/SyncWork.swift`, `Pulse/SyncActivity.swift`) :
//   - décision PURE de la bannière (`SyncActivity.fromWork` / `resolve` / `label`) :
//     chaque activité, priorités, mode Téléphone ;
//   - anti-clignotement (`SyncActivityGate`, horloge en paramètre) ;
//   - état partagé (`SyncWork`, horloge et minuterie factices) ;
//   - RISQUE PRINCIPAL, les compteurs qui retombent à zéro dans tous les chemins de
//     sortie des producteurs : rattrapage Pulse (`PulseBacklogPusher.pushBacklog`) et
//     passe d'ingestion (`LocalIngestor.runPass`) ici ; session BLE dans
//     `TransferResilienceTests.swift` ; échange des saisies dans `SaisieRetryTests.swift`.
//  Aucun réseau, aucune vraie base ni vrai spool de l'appareil : dossiers temporaires.
//

import Testing
import Foundation
@testable import all

// MARK: - Doubles partagés par les fichiers de tests de ce sujet

/// Consigne ce que les producteurs déclarent ; `isIdle` = tout est retombé.
final class RecordingWorkReporter: SyncWorkReporting, @unchecked Sendable {
    private let lock = NSLock()
    private var uploadsBySource: [String: Int] = [:]
    private var _uploadLog: [Int] = []
    private var _ingestRuns = 0
    private var _ingestBegan = 0
    private var _ingestProgress: [Int] = []
    private var _exchangeRuns = 0
    private var _exchangeBegan = 0
    private var _exchangePeak = 0
    private var _pullRuns = 0
    private var _pullBegan = 0
    private var _pullProgress: [Int] = []

    var uploadsTotal: Int { lock.withLock { uploadsBySource.values.reduce(0, +) } }
    /// Total des envois après chaque déclaration, dans l'ordre.
    var uploadLog: [Int] { lock.withLock { _uploadLog } }
    var ingestRuns: Int { lock.withLock { _ingestRuns } }
    var ingestBeganCount: Int { lock.withLock { _ingestBegan } }
    var ingestProgressLog: [Int] { lock.withLock { _ingestProgress } }
    var exchangeRuns: Int { lock.withLock { _exchangeRuns } }
    var exchangeBeganCount: Int { lock.withLock { _exchangeBegan } }
    var exchangePeak: Int { lock.withLock { _exchangePeak } }
    var pullRuns: Int { lock.withLock { _pullRuns } }
    var pullBeganCount: Int { lock.withLock { _pullBegan } }
    var pullProgressLog: [Int] { lock.withLock { _pullProgress } }
    var isIdle: Bool { uploadsTotal == 0 && ingestRuns == 0 && exchangeRuns == 0 && pullRuns == 0 }

    func uploads(source: String, remaining: Int) {
        lock.withLock {
            uploadsBySource[source] = remaining > 0 ? remaining : nil
            _uploadLog.append(uploadsBySource.values.reduce(0, +))
        }
    }
    func ingestBegan() { lock.withLock { _ingestRuns += 1; _ingestBegan += 1 } }
    func ingestProgress(remaining: Int) { lock.withLock { _ingestProgress.append(remaining) } }
    func ingestEnded() { lock.withLock { _ingestRuns -= 1 } }
    func exchangeBegan() { lock.withLock { _exchangeRuns += 1; _exchangeBegan += 1; _exchangePeak = max(_exchangePeak, _exchangeRuns) } }
    func exchangeEnded() { lock.withLock { _exchangeRuns -= 1 } }
    func pullBegan() { lock.withLock { _pullRuns += 1; _pullBegan += 1 } }
    func pullProgress(remaining: Int) { lock.withLock { _pullProgress.append(remaining) } }
    func pullEnded() { lock.withLock { _pullRuns -= 1 } }
}

/// Minuterie factice : consigne les délais demandés, déclenche à la main. `arm` REMPLACE
/// la précédente, comme la vraie.
final class ManualWakeTimer: WakeTimer, @unchecked Sendable {
    private let lock = NSLock()
    private var _armed: [TimeInterval] = []
    private var _cancels = 0
    private var pending: (@Sendable () -> Void)?
    private var last: (@Sendable () -> Void)?

    var armedDelays: [TimeInterval] { lock.withLock { _armed } }
    var cancelCount: Int { lock.withLock { _cancels } }
    var isArmed: Bool { lock.withLock { pending != nil } }

    func arm(after delay: TimeInterval, _ fire: @escaping @Sendable () -> Void) {
        lock.withLock { _armed.append(delay); pending = fire; last = fire }
    }
    func cancel() { lock.withLock { _cancels += 1; pending = nil } }
    /// Rejoue la dernière minuterie armée MÊME annulée : une vraie `Task` déjà réveillée
    /// peut franchir l'annulation (course), le service doit s'en protéger lui-même.
    func fireStale() { lock.withLock { last }?() }
    /// Déclenche la minuterie armée (une seule fois), `false` si aucune.
    @discardableResult
    func fire() -> Bool {
        let fire = lock.withLock { () -> (@Sendable () -> Void)? in
            defer { pending = nil }
            return pending
        }
        fire?()
        return fire != nil
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

// MARK: - Décision pure de la bannière

struct SyncWorkDecisionTests {
    private func work(
        uploads: Int = 0, ingest: Bool = false, remaining: Int? = nil, exchange: Bool = false
    ) -> SyncWorkSnapshot {
        SyncWorkSnapshot(uploads: uploads, ingestRunning: ingest, ingestRemaining: remaining, exchangeRunning: exchange)
    }

    @Test func nothingRunningIsIdle() {
        for mode in StorageMode.allCases {
            #expect(SyncActivity.fromWork(work(), mode: mode) == .idle)
        }
    }

    @Test func eachActivityAloneIsShownInTheModesWhereItExists() {
        #expect(SyncActivity.fromWork(work(uploads: 4), mode: .pulse) == .uploading(remaining: 4))
        #expect(SyncActivity.fromWork(work(uploads: 4), mode: .both) == .uploading(remaining: 4))
        #expect(SyncActivity.fromWork(work(ingest: true, remaining: 12), mode: .phone) == .ingesting(remaining: 12))
        #expect(SyncActivity.fromWork(work(ingest: true, remaining: 12), mode: .both) == .ingesting(remaining: 12))
        #expect(SyncActivity.fromWork(work(ingest: true), mode: .both) == .ingesting(remaining: nil), "pas de décompte fiable : sans nombre")
        #expect(SyncActivity.fromWork(work(exchange: true), mode: .both) == .exchanging)
    }

    @Test func phoneModeNeverShowsAnUploadOrAnExchange() {
        #expect(SyncActivity.fromWork(work(uploads: 4, exchange: true), mode: .phone) == .idle)
        // L'ingestion locale, elle, existe en Téléphone.
        #expect(SyncActivity.fromWork(work(uploads: 4, ingest: true, remaining: 2, exchange: true), mode: .phone) == .ingesting(remaining: 2))
    }

    @Test func pulseModeHasNoLocalIngestionAndNoExchange() {
        #expect(SyncActivity.fromWork(work(ingest: true, remaining: 3), mode: .pulse) == .idle)
        #expect(SyncActivity.fromWork(work(exchange: true), mode: .pulse) == .idle)
    }

    @Test func priorityIsUploadThenIngestionThenExchange() {
        let all = work(uploads: 2, ingest: true, remaining: 5, exchange: true)
        #expect(SyncActivity.fromWork(all, mode: .both) == .uploading(remaining: 2))
        #expect(SyncActivity.fromWork(work(ingest: true, remaining: 5, exchange: true), mode: .both) == .ingesting(remaining: 5))
        #expect(SyncActivity.fromWork(work(exchange: true), mode: .both) == .exchanging)
    }

    @Test func theWatchSyncKeepsThePriorityOverThePhoneWork() {
        let busy = SyncActivity.uploading(remaining: 3)
        for watch in [SyncActivity.connecting, .listing, .downloading(done: 2)] {
            #expect(SyncActivity.resolve(watch: watch, work: busy) == watch)
        }
        #expect(SyncActivity.resolve(watch: .idle, work: busy) == busy)
        #expect(SyncActivity.resolve(watch: .idle, work: .idle) == .idle)
    }

    @Test func labelsAreShortAndCounted() {
        #expect(SyncActivity.uploading(remaining: 4).label == "Envoi vers Pulse · 4 restants")
        #expect(SyncActivity.uploading(remaining: 1).label == "Envoi vers Pulse · 1 restant")
        #expect(SyncActivity.ingesting(remaining: 12).label == "Mise à jour de la base · 12 restants")
        #expect(SyncActivity.ingesting(remaining: 1).label == "Mise à jour de la base · 1 restant")
        #expect(SyncActivity.ingesting(remaining: nil).label == "Mise à jour de la base")
        #expect(SyncActivity.ingesting(remaining: 0).label == "Mise à jour de la base")
        #expect(SyncActivity.exchanging.label == "Échange des saisies")
        // Libellés de la synchro montre : inchangés.
        #expect(SyncActivity.connecting.label == "Connexion à la montre…")
        #expect(SyncActivity.listing.label == "Lecture de la montre…")
        #expect(SyncActivity.downloading(done: 1).label == "Synchronisation… (1 fichier)")
        #expect(SyncActivity.downloading(done: 3).label == "Synchronisation… (3 fichiers)")
        #expect(SyncActivity.idle.label == "")
    }
}

// MARK: - Anti-clignotement

struct SyncActivityGateTests {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }
    private let busy = SyncActivity.uploading(remaining: 3)

    @Test func anActivityShorterThanTheShowDelayIsNeverShown() {
        var gate = SyncActivityGate()
        let wake = gate.update(desired: busy, now: at(0))
        #expect(gate.shown == .idle)
        #expect(wake == at(gate.showDelay), "demande une ré-évaluation à la fin du délai")
        gate.update(desired: .idle, now: at(0.1))
        #expect(gate.shown == .idle)
        // Et si on repasse au bout du délai initial, la demande précédente est oubliée.
        gate.update(desired: .idle, now: at(5))
        #expect(gate.shown == .idle)
    }

    @Test func aLongEnoughActivityAppearsAfterTheDelay() {
        var gate = SyncActivityGate()
        gate.update(desired: busy, now: at(0))
        gate.update(desired: busy, now: at(0.3))
        #expect(gate.shown == .idle)
        gate.update(desired: busy, now: at(0.45))
        #expect(gate.shown == busy)
    }

    @Test func onceShownItStaysAtLeastTheMinimumDuration() {
        var gate = SyncActivityGate()
        gate.update(desired: busy, now: at(0))
        gate.update(desired: busy, now: at(0.5)) // affichée à 0,5
        let wake = gate.update(desired: .idle, now: at(0.6))
        #expect(gate.shown == busy, "retombée trop vite : reste affichée")
        #expect(wake == at(0.5 + gate.minVisible))
        gate.update(desired: .idle, now: at(1.4))
        #expect(gate.shown == busy)
        gate.update(desired: .idle, now: at(1.5))
        #expect(gate.shown == .idle)
    }

    @Test func itLingersAfterTheActivityFallsBackSoBackToBackPassesDoNotFlicker() {
        var gate = SyncActivityGate()
        gate.update(desired: busy, now: at(0))
        gate.update(desired: busy, now: at(0.5))
        gate.update(desired: busy, now: at(10))
        gate.update(desired: .idle, now: at(10)) // fin de passe
        #expect(gate.shown == busy)
        gate.update(desired: busy, now: at(10.05)) // la passe suivante enchaîne
        gate.update(desired: .idle, now: at(10.4))
        #expect(gate.shown == busy, "la retombée repart de zéro : jamais masquée entre deux passes")
        gate.update(desired: .idle, now: at(10.9))
        #expect(gate.shown == .idle)
    }

    @Test func theContentFollowsWithoutDelayWhileVisible() {
        var gate = SyncActivityGate()
        gate.update(desired: .uploading(remaining: 4), now: at(0))
        gate.update(desired: .uploading(remaining: 4), now: at(0.5))
        gate.update(desired: .uploading(remaining: 3), now: at(0.51))
        #expect(gate.shown == .uploading(remaining: 3))
        gate.update(desired: .exchanging, now: at(0.52))
        #expect(gate.shown == .exchanging)
    }

    @Test func idleWhenIdleAsksForNothing() {
        var gate = SyncActivityGate()
        #expect(gate.update(desired: .idle, now: at(0)) == nil)
        #expect(gate.shown == .idle)
    }
}

// MARK: - Minuterie unique

struct TaskWakeTimerTests {
    private final class Fires: @unchecked Sendable {
        private let lock = NSLock()
        private var value: [String] = []
        func add(_ tag: String) { lock.withLock { value.append(tag) } }
        var tags: [String] { lock.withLock { value } }
    }

    @Test func armingAgainReplacesThePreviousTimer() async {
        let timer = TaskWakeTimer()
        let fires = Fires()
        // Délai du premier assez long pour qu'un fil ralenti entre les deux `arm` ne
        // le laisse pas partir avant son remplacement.
        timer.arm(after: 0.4) { fires.add("premier") }
        timer.arm(after: 0.05) { fires.add("second") }
        #expect(await eventually { fires.tags.count >= 1 })
        try? await Task.sleep(nanoseconds: 600_000_000)
        #expect(fires.tags == ["second"], "une seule minuterie en vie")
    }

    @Test func cancellingPreventsTheFire() async {
        let timer = TaskWakeTimer()
        let fires = Fires()
        timer.arm(after: 0.05) { fires.add("x") }
        timer.cancel()
        try? await Task.sleep(nanoseconds: 150_000_000)
        #expect(fires.tags.isEmpty)
    }
}

// MARK: - État partagé (horloge et minuterie factices)

@MainActor
struct SyncWorkStateTests {
    private final class Clock: @unchecked Sendable {
        var now = Date(timeIntervalSince1970: 1_000_000)
        func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
    }
    private final class ModeBox: @unchecked Sendable { var mode: StorageMode = .both }

    private func make(mode: StorageMode = .both) -> (work: SyncWork, clock: Clock, timer: ManualWakeTimer, mode: ModeBox) {
        let clock = Clock(), timer = ManualWakeTimer(), box = ModeBox()
        box.mode = mode
        let work = SyncWork(mode: { box.mode }, now: { clock.now }, timer: timer)
        return (work, clock, timer, box)
    }

    /// Laisse passer l'anti-clignotement d'apparition.
    private func letItAppear(_ work: SyncWork, _ clock: Clock) {
        clock.advance(0.5)
        work.refresh()
    }

    @Test func nothingIsShownAtRestAndNoTimerRuns() {
        let (work, _, timer, _) = make()
        work.refresh()
        #expect(work.displayed == .idle)
        #expect(!timer.isArmed)
    }

    @Test func uploadsFromSeveralSourcesAddUp() {
        let (work, clock, timer, _) = make()
        work.setUploads(source: "session-1", remaining: 3)
        work.setUploads(source: "backlog-1", remaining: 2)
        #expect(work.displayed == .idle, "pas avant le délai d'apparition")
        #expect(timer.isArmed)
        letItAppear(work, clock)
        #expect(work.displayed == .uploading(remaining: 5))
        work.setUploads(source: "session-1", remaining: 1)
        #expect(work.displayed == .uploading(remaining: 3), "le décompte descend en direct")
    }

    @Test func aBriefActivityNeverAppears() {
        let (work, clock, timer, _) = make()
        work.exchangeBegan()
        clock.advance(0.2)
        work.exchangeEnded()
        #expect(work.displayed == .idle)
        clock.advance(5)
        work.refresh()
        #expect(work.displayed == .idle)
        #expect(!timer.isArmed, "plus rien en attente : minuterie annulée")
    }

    @Test func aShownBannerStaysAtLeastTheMinimumThenDisappears() {
        let (work, clock, timer, _) = make()
        work.exchangeBegan()
        letItAppear(work, clock) // affichée à 0,5
        #expect(work.displayed == .exchanging)
        clock.advance(0.1)
        work.exchangeEnded()
        #expect(work.displayed == .exchanging)
        #expect(timer.isArmed, "une minuterie pour la disparition différée")
        clock.advance(1.0)
        work.refresh()
        #expect(work.displayed == .idle)
        #expect(!timer.isArmed)
    }

    @Test func phoneModeShowsNeitherUploadsNorExchange() {
        let (work, clock, _, _) = make(mode: .phone)
        work.setUploads(source: "session-1", remaining: 4)
        work.exchangeBegan()
        letItAppear(work, clock)
        #expect(work.displayed == .idle)
        work.ingestBegan()
        work.ingestProgress(remaining: 7)
        letItAppear(work, clock)
        #expect(work.displayed == .ingesting(remaining: 7))
    }

    @Test func aModeChangeIsTakenIntoAccountOnRefresh() {
        let (work, clock, _, box) = make(mode: .both)
        work.setUploads(source: "s", remaining: 2)
        letItAppear(work, clock)
        #expect(work.displayed == .uploading(remaining: 2))
        box.mode = .phone
        work.refresh()
        clock.advance(2)
        work.refresh()
        #expect(work.displayed == .idle)
    }

    @Test func priorityAcrossLiveActivitiesThenEachFallsBackInTurn() {
        let (work, clock, _, _) = make()
        work.exchangeBegan()
        work.ingestBegan()
        work.ingestProgress(remaining: 9)
        work.setUploads(source: "s", remaining: 2)
        letItAppear(work, clock)
        #expect(work.displayed == .uploading(remaining: 2))
        work.setUploads(source: "s", remaining: 0)
        #expect(work.displayed == .ingesting(remaining: 9))
        work.ingestEnded()
        #expect(work.displayed == .exchanging)
    }

    @Test func ingestRemainingIsUnknownUntilTheFirstProgress() {
        let (work, clock, _, _) = make()
        work.ingestBegan()
        letItAppear(work, clock)
        #expect(work.displayed == .ingesting(remaining: nil))
        work.ingestProgress(remaining: 12)
        #expect(work.displayed == .ingesting(remaining: 12))
        // Une nouvelle passe repart sans décompte (l'ancien n'est plus fiable).
        work.ingestEnded()
        work.ingestBegan()
        #expect(work.displayed == .ingesting(remaining: nil))
    }

    @Test func anEndWithoutABeginIsIgnoredAndNeverLeavesANegativeCounter() {
        let (work, clock, _, _) = make()
        work.ingestEnded()
        work.exchangeEnded()
        work.ingestBegan()
        work.exchangeBegan()
        letItAppear(work, clock)
        #expect(work.displayed == .ingesting(remaining: nil))
        work.ingestEnded()
        work.exchangeEnded()
        clock.advance(3)
        work.refresh()
        #expect(work.displayed == .idle, "un `end` en trop n'a pas décalé les compteurs")
    }

    @Test func nestedBeginsNeedTheirOwnEnds() {
        let (work, clock, _, _) = make()
        work.exchangeBegan()
        work.exchangeBegan()
        work.exchangeEnded()
        letItAppear(work, clock)
        #expect(work.displayed == .exchanging)
        work.exchangeEnded()
        clock.advance(3)
        work.refresh()
        #expect(work.displayed == .idle)
    }

    @Test func aCounterWithNoSignOfLifeIsAbandonedSoTheBannerCannotStayForever() {
        let (work, clock, timer, _) = make()
        work.setUploads(source: "session-fantome", remaining: 3)
        work.ingestBegan()
        work.exchangeBegan()
        letItAppear(work, clock)
        #expect(work.displayed == .uploading(remaining: 3))
        #expect(timer.isArmed, "la péremption est elle-même planifiée")

        clock.advance(SyncWork.staleAfter + 1)
        let snapshot = work.snapshot(at: clock.now)
        #expect(snapshot == SyncWorkSnapshot(), "plus rien ne compte")
        work.refresh()
        clock.advance(2)
        work.refresh()
        #expect(work.displayed == .idle)
        #expect(!timer.isArmed)
    }

    @Test func aSignOfLifeKeepsACounterAlive() {
        let (work, clock, _, _) = make()
        work.ingestBegan()
        clock.advance(SyncWork.staleAfter - 10)
        work.ingestProgress(remaining: 5)
        clock.advance(SyncWork.staleAfter - 10)
        #expect(work.snapshot(at: clock.now).ingestRunning)
    }

    @Test func completionsTickWhenAnActivityEndsAndOnlyThen() {
        let (work, clock, _, _) = make()
        #expect(work.completions == 0)
        work.setUploads(source: "a", remaining: 2)
        work.setUploads(source: "b", remaining: 1)
        work.setUploads(source: "a", remaining: 0)
        #expect(work.completions == 0, "il reste un envoi")
        work.setUploads(source: "b", remaining: 0)
        #expect(work.completions == 1)
        work.ingestBegan()
        work.ingestBegan()
        work.ingestEnded()
        #expect(work.completions == 1, "une passe imbriquée n'est pas la fin")
        work.ingestEnded()
        #expect(work.completions == 2)
        work.exchangeBegan()
        work.exchangeEnded()
        #expect(work.completions == 3)
        work.setUploads(source: "z", remaining: 0)
        #expect(work.completions == 3, "libérer une source inconnue n'est pas une fin")
        _ = clock
    }

    @Test func theTimerIsReArmedNotStackedOnEveryChange() {
        let (work, _, timer, _) = make()
        work.setUploads(source: "s", remaining: 5)
        work.setUploads(source: "s", remaining: 4)
        work.setUploads(source: "s", remaining: 3)
        #expect(timer.isArmed)
        #expect(timer.fire() == true)
        #expect(timer.fire() == false, "une seule minuterie en vie à la fois")
    }
}

// MARK: - Rattrapage Pulse : le compte retombe quelle que soit l'issue

struct PulseBacklogActivityTests {
    private final class ScriptedUploader: SpoolUploading {
        var outcomes: [PulseUploadOutcome]
        private var index = 0
        init(_ outcomes: [PulseUploadOutcome]) { self.outcomes = outcomes }
        func upload(fileURL: URL, watchFilename: String, completion: @escaping (PulseUploadOutcome) -> Void) {
            completion(outcomes[min(index, outcomes.count - 1)])
            index += 1
        }
    }

    private func makeStore(count: Int) throws -> (store: SpoolStore, entries: [SpoolEntry], root: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bridge-connect-backlog-activity-\(UUID().uuidString)", isDirectory: true)
        let store = try SpoolStore(root: root)
        var ids: [WatchFileID] = []
        for index in 1...count {
            let directory = GarminDirectoryEntry(fileIndex: index, dataType: 128, subType: 4, fileNumber: index, sizeBytes: 6, garminTimestamp: 0)!
            let (id, path) = SpoolStore.identity(for: directory)
            try store.recordAcquired(id, relativePath: path, data: Data("x".utf8))
            ids.append(id)
        }
        return (store, ids.compactMap { store.entries[$0] }, root)
    }

    @Test func theCountDownThenReleasesToZero() async throws {
        let (store, entries, root) = try makeStore(count: 3)
        defer { try? FileManager.default.removeItem(at: root) }
        let reporter = RecordingWorkReporter()

        await PulseBacklogPusher.pushBacklog(entries, spool: store, uploader: ScriptedUploader([.delivered]), reporter: reporter)

        #expect(reporter.uploadLog == [3, 2, 1, 0, 0], "3 restants, puis chaque fichier terminé, puis la libération")
        #expect(reporter.isIdle)
    }

    @Test(arguments: [PulseUploadOutcome.keepRetry, .keepRetryLater, .keepConfigError, .quarantine])
    func everyOutcomeEndsAtZero(outcome: PulseUploadOutcome) async throws {
        let (store, entries, root) = try makeStore(count: 2)
        defer { try? FileManager.default.removeItem(at: root) }
        let reporter = RecordingWorkReporter()

        await PulseBacklogPusher.pushBacklog(entries, spool: store, uploader: ScriptedUploader([outcome]), reporter: reporter)

        #expect(reporter.isIdle)
        #expect(reporter.uploadLog.last == 0)
    }

    @Test func aMixedRunStillEndsAtZero() async throws {
        let (store, entries, root) = try makeStore(count: 4)
        defer { try? FileManager.default.removeItem(at: root) }
        let reporter = RecordingWorkReporter()

        await PulseBacklogPusher.pushBacklog(
            entries, spool: store, uploader: ScriptedUploader([.delivered, .keepRetry, .quarantine, .keepConfigError]), reporter: reporter)

        #expect(reporter.isIdle)
    }

    @Test func nothingDueDeclaresNothingStuck() async throws {
        let (store, _, root) = try makeStore(count: 1)
        defer { try? FileManager.default.removeItem(at: root) }
        let reporter = RecordingWorkReporter()

        await PulseBacklogPusher.pushBacklog([], spool: store, uploader: ScriptedUploader([.delivered]), reporter: reporter)

        #expect(reporter.isIdle)
    }

    @Test func twoConcurrentBacklogsAddUpWithoutTrampling() async throws {
        let (store, entries, root) = try makeStore(count: 2)
        defer { try? FileManager.default.removeItem(at: root) }
        let reporter = RecordingWorkReporter()

        async let first: Void = PulseBacklogPusher.pushBacklog(entries, spool: store, uploader: ScriptedUploader([.keepRetry]), reporter: reporter)
        async let second: Void = PulseBacklogPusher.pushBacklog(entries, spool: store, uploader: ScriptedUploader([.keepRetry]), reporter: reporter)
        _ = await (first, second)

        #expect(reporter.isIdle, "chaque rattrapage libère SA source")
    }
}

// MARK: - Passe d'ingestion : le compteur retombe quelle que soit la sortie

struct LocalIngestActivityTests {
    private struct Rig {
        let spool: SpoolStore
        let db: LocalDb
        let root: URL
        let defaults: UserDefaults
    }

    private func makeRig(entries: Int) throws -> Rig {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bridge-connect-ingest-activity-\(UUID().uuidString)", isDirectory: true)
        let spool = try SpoolStore(root: root)
        if entries > 0 {
            for index in 1...entries {
                let directory = GarminDirectoryEntry(fileIndex: index, dataType: 128, subType: 4, fileNumber: index, sizeBytes: 6, garminTimestamp: 0)!
                let (id, path) = SpoolStore.identity(for: directory)
                // Contenu non FIT : l'entrée est traitée (échec journalisé), ce qui suffit à
                // faire avancer le décompte.
                try spool.recordAcquired(id, relativePath: path, data: Data("pas du fit".utf8))
            }
        }
        let db = try LocalDb(path: root.appendingPathComponent("test.sqlite").path)
        return Rig(spool: spool, db: db, root: root, defaults: UserDefaults(suiteName: "ingest-activity-\(UUID().uuidString)")!)
    }

    @Test func progressCountsDownFromTheTotalToZero() throws {
        let rig = try makeRig(entries: 3)
        defer { try? FileManager.default.removeItem(at: rig.root) }
        var seen: [Int] = []

        _ = LocalIngestor.ingestPending(from: rig.spool, into: rig.db, progress: { seen.append($0) })

        #expect(seen == [3, 2, 1, 0])
    }

    @Test func progressIsSilentWhenThereIsNothingToIngest() throws {
        let rig = try makeRig(entries: 0)
        defer { try? FileManager.default.removeItem(at: rig.root) }
        var seen: [Int] = []

        _ = LocalIngestor.ingestPending(from: rig.spool, into: rig.db, progress: { seen.append($0) })

        #expect(seen.isEmpty)
    }

    @Test func aNormalPassBeginsReportsAndEnds() throws {
        let rig = try makeRig(entries: 2)
        defer { try? FileManager.default.removeItem(at: rig.root) }
        let reporter = RecordingWorkReporter()

        LocalIngestor.runPass(mode: { .both }, stores: { (rig.spool, rig.db) }, reporter: reporter, defaults: rig.defaults)

        #expect(reporter.ingestBeganCount == 1)
        #expect(reporter.ingestProgressLog == [2, 1, 0])
        #expect(reporter.isIdle)
    }

    @Test func anEmptyPassIsBalancedToo() throws {
        let rig = try makeRig(entries: 0)
        defer { try? FileManager.default.removeItem(at: rig.root) }
        let reporter = RecordingWorkReporter()

        LocalIngestor.runPass(mode: { .phone }, stores: { (rig.spool, rig.db) }, reporter: reporter, defaults: rig.defaults)

        #expect(reporter.ingestBeganCount == 1)
        #expect(reporter.isIdle)
    }

    @Test func unavailableStoresStillRelease() {
        let reporter = RecordingWorkReporter()

        LocalIngestor.runPass(mode: { .both }, stores: { nil }, reporter: reporter)

        #expect(reporter.ingestBeganCount == 1, "la passe avait démarré")
        #expect(reporter.isIdle, "base indisponible : libérée quand même")
    }

    @Test func pulseModeNeverStartsAndDeclaresNothing() throws {
        let rig = try makeRig(entries: 2)
        defer { try? FileManager.default.removeItem(at: rig.root) }
        let reporter = RecordingWorkReporter()

        LocalIngestor.runPass(mode: { .pulse }, stores: { (rig.spool, rig.db) }, reporter: reporter, defaults: rig.defaults)

        #expect(reporter.ingestBeganCount == 0)
        #expect(reporter.isIdle)
    }

    /// La purge des données de l'iPhone prend la garde (`runExclusively`) : les demandes
    /// reçues pendant ce temps sont ÉCARTÉES, la passe ne démarre donc jamais — et ne laisse
    /// rien derrière elle, puisqu'elle n'a rien déclaré.
    @Test func aPassDiscardedByTheExclusiveGateNeverDeclaresAnything() async {
        let gate = SerialPassGate()
        let reporter = RecordingWorkReporter()

        let started: Bool = await gate.runExclusively {
            gate.request { LocalIngestor.runPass(mode: { .both }, stores: { nil }, reporter: reporter) }
        }

        #expect(started == false)
        #expect(await gate.waitUntilIdle())
        #expect(reporter.ingestBeganCount == 0)
        #expect(reporter.isIdle)
    }

    @Test func passesRunThroughTheGateAreEachBalanced() async throws {
        let rig = try makeRig(entries: 1)
        defer { try? FileManager.default.removeItem(at: rig.root) }
        let gate = SerialPassGate()
        let reporter = RecordingWorkReporter()
        let work: @Sendable () -> Void = {
            LocalIngestor.runPass(mode: { .both }, stores: { (rig.spool, rig.db) }, reporter: reporter, defaults: rig.defaults)
        }

        gate.request(work)
        gate.request(work) // fusionnée en une passe de rattrapage
        #expect(await gate.waitUntilIdle())

        #expect(reporter.ingestBeganCount >= 1)
        #expect(reporter.isIdle)
    }
}
