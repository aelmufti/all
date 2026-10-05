//
//  SpoolIngestProofTests.swift
//  allTests
//
//  Preuve d'ingestion locale dans le journal du spool (`SpoolEntry.ingest`,
//  `purgedAt`) et ce qui s'y adosse :
//   - transitions du journal (`markIngest`/`clearIngest`/`markPurged`) et
//     rétrocompatibilité de décodage ;
//   - verrou d'archivage de `ArchivePlanner` (`requiresIngest`/`awaitingIngest`) ;
//   - passe d'ingestion incrémentale (`LocalIngestor.ingestPending`) ;
//   - sérialisation des passes (`SerialPassGate`) ;
//   - `LocalDb.holdsIngestedFile`.
//  Le pilotage de `GarminSession` vit dans `TransferResilienceTests.swift`
//  (`GarminSessionIngestLockTests`), la purge dans `SpoolPurgerTests.swift`.
//
//  Fichiers FIT SYNTHÉTIQUES (en-tête + un message `file_id`) : aucune donnée
//  personnelle. Les cas qui exigent un vrai fichier (activité) se sautent
//  proprement sans manifeste d'échantillons locaux, comme les tests voisins.
//

import Testing
import Foundation
import SQLite3
@testable import all

// MARK: - Fixtures

/// FIT minimal valide pour le décodeur maison : en-tête 12 o, définition de
/// `file_id` (1 champ : `type`), un message de données, CRC final (non vérifié
/// strictement : `crcValid` n'interrompt pas le décodage).
func syntheticFit(fileType: UInt8, salt: UInt8 = 0) -> Data {
    var body = Data([0x40, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00]) // définition file_id, champ 0 (enum, 1 o)
    body.append(contentsOf: [0x00, fileType]) // message de données
    var header = Data([12, 0x10, 0x00, 0x00])
    header.append(contentsOf: [UInt8(body.count), 0, 0, 0])
    header.append(contentsOf: Array(".FIT".utf8))
    // `salt` n'entre pas dans le décodage : il ne sert qu'à obtenir des octets (donc un hash) distincts.
    return header + body + Data([salt, 0x00])
}

private func makeSpool() throws -> (store: SpoolStore, root: URL) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("bridge-connect-ingest-proof-\(UUID().uuidString)", isDirectory: true)
    return (try SpoolStore(root: root), root)
}

private func makeDb() throws -> (db: LocalDb, path: String) {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("ingest-proof-\(UUID().uuidString).sqlite").path
    return (try LocalDb(path: path), path)
}

private let monitorType = GarminFileType.monitor.watchFileType
private let sleepType = GarminFileType.sleep.watchFileType
private let otherType = GarminFileTypeKey(dataType: 255, subType: 244).watchFileType

@discardableResult
private func acquire(_ store: SpoolStore, type: Int = monitorType, index: Int, data: Data) throws -> SpoolEntry {
    let id = WatchFileID(fileType: type, index: index, name: "f\(index).fit")
    return try store.recordAcquired(id, relativePath: "T/f\(index).fit", data: data)
}

private func outcome(_ status: SpoolIngestStatus = .ingested, hash: String = "h", at: Date = Date()) -> SpoolIngestOutcome {
    SpoolIngestOutcome(status: status, hash: hash, at: at)
}

// MARK: - Journal : décodage et transitions

struct SpoolIngestJournalTests {
    @Test func anEntryWrittenBeforeTheProofFieldsStillDecodes() throws {
        let json = """
        [{"id":{"fileType":32800,"index":1,"name":"a.fit"},"state":"delivered","acquiredAt":1000,\
        "relativePath":"MONITOR/a.fit"}]
        """
        let entries = try JSONDecoder().decode([SpoolEntry].self, from: Data(json.utf8))
        #expect(entries.count == 1)
        #expect(entries[0].ingest == nil)
        #expect(entries[0].purgedAt == nil)
        #expect(entries[0].pushedToPulse == false)
        #expect(entries[0].listedSize == nil)
    }

    @Test func theProofSurvivesAJournalRoundTripAndAnotherInstance() throws {
        let (store, root) = try makeSpool()
        defer { try? FileManager.default.removeItem(at: root) }
        let saved = try acquire(store, index: 1, data: Data("x".utf8))

        let at = Date(timeIntervalSince1970: 1_700_000_000)
        store.markIngest(saved.id, outcome: SpoolIngestOutcome(status: .skipped, hash: "abc", at: at), expectedAcquiredAt: saved.acquiredAt)
        store.markPurged(saved.id, expectedAcquiredAt: saved.acquiredAt)

        let reopened = try SpoolStore(root: root)
        let entry = try #require(reopened.entries[saved.id])
        #expect(entry.ingest == SpoolIngestOutcome(status: .skipped, hash: "abc", at: at))
        #expect(entry.purgedAt != nil)
    }

    @Test func markIngestClearIngestAndMarkPurgedHonourTheAcquisitionToken() throws {
        let (store, root) = try makeSpool()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try acquire(store, index: 1, data: Data("v1".utf8))
        // Relecture : nouveau contenu, nouveau jeton.
        let second = try acquire(store, index: 1, data: Data("v2".utf8))
        #expect(second.acquiredAt > first.acquiredAt)

        store.markIngest(first.id, outcome: outcome(), expectedAcquiredAt: first.acquiredAt)
        #expect(store.entries[first.id]?.ingest == nil, "preuve périmée ignorée")

        store.markIngest(first.id, outcome: outcome(), expectedAcquiredAt: second.acquiredAt)
        #expect(store.entries[first.id]?.ingest != nil)

        store.clearIngest(first.id, expectedAcquiredAt: first.acquiredAt)
        #expect(store.entries[first.id]?.ingest != nil, "effacement périmé ignoré")
        store.clearIngest(first.id, expectedAcquiredAt: second.acquiredAt)
        #expect(store.entries[first.id]?.ingest == nil)

        store.markPurged(first.id, expectedAcquiredAt: first.acquiredAt)
        #expect(store.entries[first.id]?.purgedAt == nil, "purge périmée ignorée")
        store.markPurged(first.id, expectedAcquiredAt: second.acquiredAt)
        #expect(store.entries[first.id]?.purgedAt != nil)
    }

    @Test func aFileReadAgainStartsWithoutProof() throws {
        let (store, root) = try makeSpool()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try acquire(store, index: 1, data: Data("v1".utf8))
        store.markIngest(first.id, outcome: outcome())
        store.markPurged(first.id)
        #expect(store.entries[first.id]?.ingest != nil)

        let again = try acquire(store, index: 1, data: Data("v2".utf8))

        #expect(again.ingest == nil)
        #expect(again.purgedAt == nil)
        #expect(store.entries[first.id]?.ingest == nil)
        #expect(store.entries[first.id]?.purgedAt == nil)
    }

    @Test func transitionsOnAnUnknownEntryChangeNothing() throws {
        let (store, root) = try makeSpool()
        defer { try? FileManager.default.removeItem(at: root) }
        let ghost = WatchFileID(fileType: monitorType, index: 9, name: "ghost.fit")
        store.markIngest(ghost, outcome: outcome())
        store.clearIngest(ghost)
        store.markPurged(ghost)
        #expect(store.entries.isEmpty)
    }

    @Test func failedIngestCountReadsTheFreshJournal() throws {
        let (store, root) = try makeSpool()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try acquire(store, index: 1, data: Data("a".utf8))
        let b = try acquire(store, index: 2, data: Data("b".utf8))
        let other = try SpoolStore(root: root) // autre instance : son cache date de maintenant
        #expect(other.failedIngestCount() == 0)

        store.markIngest(a.id, outcome: outcome(.failed))
        store.markIngest(b.id, outcome: outcome(.skipped))

        #expect(other.failedIngestCount() == 1)
    }
}

// MARK: - ArchivePlanner : verrou d'ingestion

struct ArchivePlannerIngestTests {
    private func listed(_ index: Int) -> GarminDirectoryEntry {
        GarminDirectoryEntry(fileIndex: index, dataType: 128, subType: 32, fileNumber: index, sizeBytes: 10, garminTimestamp: 0)!
    }

    private func delivered(_ index: Int, ingest: SpoolIngestOutcome?) -> SpoolEntry {
        let (id, path) = SpoolStore.identity(for: listed(index))
        return SpoolEntry(id: id, state: .delivered, acquiredAt: Date(timeIntervalSince1970: Double(index)), relativePath: path, listedSize: 10, ingest: ingest)
    }

    @Test func withoutTheRequirementBehaviourIsUnchanged() {
        let entries = [delivered(1, ingest: nil), delivered(2, ingest: outcome())]
        let plan = ArchivePlanner.plan(delivered: entries, listing: [listed(1), listed(2)])
        #expect(plan.eligible.map(\.id.index) == [1, 2])
        #expect(plan.awaitingIngest.isEmpty)
    }

    @Test func anEntryWithoutProofWaitsWhenIngestionIsRequired() {
        let entries = [delivered(1, ingest: nil), delivered(2, ingest: outcome())]
        let plan = ArchivePlanner.plan(delivered: entries, listing: [listed(1), listed(2)], requiresIngest: true)
        #expect(plan.eligible.map(\.id.index) == [2])
        #expect(plan.awaitingIngest.map(\.id.index) == [1])
    }

    @Test(arguments: [SpoolIngestStatus.ingested, .skipped, .failed])
    func anyProofMakesTheEntryEligible(status: SpoolIngestStatus) {
        let plan = ArchivePlanner.plan(delivered: [delivered(1, ingest: outcome(status))], listing: [listed(1)], requiresIngest: true)
        #expect(plan.eligible.map(\.id.index) == [1])
        #expect(plan.awaitingIngest.isEmpty)
    }

    /// Absente du manifeste ou à relire : ces seaux priment, l'ingestion n'y change rien.
    @Test func absentOrResizedEntriesKeepTheirOwnBucket() {
        let resized = SpoolEntry(
            id: SpoolStore.identity(for: listed(3)).id, state: .delivered, acquiredAt: Date(), relativePath: "x", listedSize: 5)
        let plan = ArchivePlanner.plan(delivered: [delivered(1, ingest: nil), resized], listing: [listed(3)], requiresIngest: true)
        #expect(plan.absentFromManifest.map(\.id.index) == [1])
        #expect(plan.resizedSinceAcquisition.count == 1)
        #expect(plan.awaitingIngest.isEmpty)
    }

    @Test func aWithdrawnRequestIsNeitherInFlightNorAttempted() {
        var tracker = ArchiveRequestTracker()
        let entries = [delivered(1, ingest: outcome())]
        let request = tracker.next(from: entries)!
        #expect(tracker.inFlight == request)

        tracker.withdraw(request)

        #expect(tracker.inFlight == nil)
        #expect(tracker.next(from: entries)?.id == request.id, "peut repartir : non consommée comme tentée")
    }
}

// MARK: - holdsIngestedFile

struct HoldsIngestedFileTests {
    @Test func seesWellnessSleepAndActivityHashes() throws {
        let (db, _) = try makeDb()
        #expect(try db.holdsIngestedFile(hash: "w") == false)

        try db.storeWellness(FitWellnessData(days: [], counters: [], counterSamples: [], samples: []), hash: "w", fileName: "w.fit")
        try db.storeSleep(
            FitSleepSummary(date: "2026-01-01", startTs: 0, endTs: 100, durationS: 100, score: nil, deepS: 50, lightS: 30, remS: 20, awakeS: 0, awakenings: nil, phases: []),
            hash: "s", fileName: "s.fit")
        #expect(try db.holdsIngestedFile(hash: "w"))
        #expect(try db.holdsIngestedFile(hash: "s"))

        try db.storeActivity(
            FitActivityExtractor.Summary(sport: "running", subSport: nil, startTime: "2026-01-01T00:00:00Z", durationS: 1, distanceM: 1, calories: 1, avgHr: 1, maxHr: 1),
            hash: "a", fileName: "a.fit")
        #expect(try db.holdsIngestedFile(hash: "a"))
        #expect(try db.holdsIngestedFile(hash: "other") == false)
    }

    /// Plus de double insert : deux écritures du même fichier ne dupliquent pas la ligne.
    @Test func storingTheSameActivityTwiceKeepsOneRow() throws {
        let (db, _) = try makeDb()
        let summary = FitActivityExtractor.Summary(sport: "running", subSport: nil, startTime: "2026-01-01T00:00:00Z", durationS: 1, distanceM: 1, calories: 1, avgHr: 1, maxHr: 1)
        let first = try db.storeActivity(summary, hash: "a", fileName: "a.fit")
        let second = try db.storeActivity(summary, hash: "a", fileName: "a.fit")
        #expect(first == second)
        #expect(try db.activitiesCount() == 1)
    }
}

// MARK: - Passe d'ingestion incrémentale

struct IngestPassTests {
    @Test func statusMappingFollowsTheSpec() {
        for kind in [LocalIngestKind.wellness, .sleep, .activity, .duplicate] {
            #expect(LocalIngestor.ingestStatus(for: kind, fileType: monitorType) == .ingested)
        }
        #expect(LocalIngestor.ingestStatus(for: .skipped, fileType: monitorType) == .skipped)
        #expect(LocalIngestor.ingestStatus(for: .error("x"), fileType: monitorType) == .failed)
        #expect(LocalIngestor.ingestStatus(for: .error("x"), fileType: sleepType) == .failed)
        #expect(LocalIngestor.ingestStatus(for: .error("x"), fileType: GarminFileType.activity.watchFileType) == .failed)
        // Une erreur de base n'est pas un résultat.
        #expect(LocalIngestor.ingestStatus(for: .storageError("x"), fileType: monitorType) == nil)
        // Un type que l'app n'exploite pas ne peut pas être « en échec ».
        #expect(LocalIngestor.ingestStatus(for: .error("x"), fileType: otherType) == .skipped)
    }

    @Test func aWellnessFileIsIngestedWithItsHashAndNotProcessedAgain() throws {
        let (store, root) = try makeSpool()
        let (db, _) = try makeDb()
        defer { try? FileManager.default.removeItem(at: root) }
        let data = syntheticFit(fileType: 32)
        let saved = try acquire(store, index: 1, data: data)

        let first = LocalIngestor.ingestPending(from: store, into: db)

        #expect(first.results.map(\.kind) == [.wellness])
        #expect(first.marked == 1)
        let proof = try #require(store.entries[saved.id]?.ingest)
        #expect(proof.status == .ingested)
        #expect(proof.hash == (try PulseUploader.sha256Hex(ofFileAt: store.fileURL(for: saved))))
        #expect(try db.holdsIngestedFile(hash: proof.hash))

        // Le fichier est altéré sur le disque : une entrée déjà marquée n'est ni
        // hachée ni décodée, donc la passe suivante n'y touche pas.
        try Data("corrompu".utf8).write(to: store.fileURL(for: saved))
        let second = LocalIngestor.ingestPending(from: store, into: db)
        #expect(second.results.isEmpty)
        #expect(second.marked == 0)
        #expect(store.entries[saved.id]?.ingest == proof)
    }

    @Test func aDecodeErrorIsFailedAndAnUnhandledFitTypeIsSkipped() throws {
        let (store, root) = try makeSpool()
        let (db, _) = try makeDb()
        defer { try? FileManager.default.removeItem(at: root) }
        let garbage = try acquire(store, type: monitorType, index: 1, data: Data("pas du FIT du tout".utf8))
        let workout = try acquire(store, type: monitorType, index: 2, data: syntheticFit(fileType: 5)) // FIT valide, type 5 : ni wellness, ni sommeil, ni activité
        let noNight = try acquire(store, type: sleepType, index: 3, data: syntheticFit(fileType: 49)) // sommeil sans nuit exploitable
        let errorReport = try acquire(store, type: otherType, index: 4, data: Data("rapport texte".utf8)) // type non géré, pas du FIT

        let report = LocalIngestor.ingestPending(from: store, into: db)

        #expect(report.marked == 4)
        #expect(store.entries[garbage.id]?.ingest?.status == .failed)
        #expect(store.entries[garbage.id]?.ingest?.hash == (try PulseUploader.sha256Hex(ofFileAt: store.fileURL(for: garbage))))
        #expect(store.entries[workout.id]?.ingest?.status == .skipped)
        #expect(store.entries[noNight.id]?.ingest?.status == .skipped)
        #expect(store.entries[errorReport.id]?.ingest?.status == .skipped)
    }

    @Test func aDatabaseFailureLeavesTheEntryUnmarkedSoItIsRetried() throws {
        let (store, root) = try makeSpool()
        let (db, dbPath) = try makeDb()
        defer { try? FileManager.default.removeItem(at: root) }
        let saved = try acquire(store, index: 1, data: syntheticFit(fileType: 32))

        // Sabote la base par une AUTRE connexion : `imported_files` disparaît.
        var handle: OpaquePointer?
        #expect(sqlite3_open(dbPath, &handle) == SQLITE_OK)
        #expect(sqlite3_exec(handle, "DROP TABLE imported_files", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(handle)

        let broken = LocalIngestor.ingestPending(from: store, into: db)
        #expect(broken.marked == 0)
        #expect(store.entries[saved.id]?.ingest == nil, "une panne de base n'est pas un résultat")
        if case .storageError = try #require(broken.results.first).kind {} else {
            Issue.record("attendu .storageError, obtenu \(broken.results)")
        }
        #expect(LocalIngestor.hasNewInsertion(broken.results) == false)

        // Base saine : retentée et traitée.
        let (healthy, _) = try makeDb()
        let retried = LocalIngestor.ingestPending(from: store, into: healthy)
        #expect(retried.marked == 1)
        #expect(store.entries[saved.id]?.ingest?.status == .ingested)
    }

    @Test func aMissingFileIsFailedAndAPurgedEntryIsIgnored() throws {
        let (store, root) = try makeSpool()
        let (db, _) = try makeDb()
        defer { try? FileManager.default.removeItem(at: root) }
        let missing = try acquire(store, index: 1, data: syntheticFit(fileType: 32))
        try FileManager.default.removeItem(at: store.fileURL(for: missing))
        let purged = try acquire(store, index: 2, data: syntheticFit(fileType: 32, salt: 1))
        store.markPurged(purged.id)

        let report = LocalIngestor.ingestPending(from: store, into: db)

        #expect(report.marked == 1)
        #expect(store.entries[missing.id]?.ingest?.status == .failed)
        #expect(store.entries[purged.id]?.ingest == nil)
    }

    @Test func aFileReadAgainDuringThePassGetsNoStaleProof() throws {
        // Le jeton capturé avant le hachage protège la preuve : simulé en posant
        // la preuve avec l'ancien jeton après une relecture.
        let (store, root) = try makeSpool()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try acquire(store, index: 1, data: syntheticFit(fileType: 32))
        _ = try acquire(store, index: 1, data: syntheticFit(fileType: 32, salt: 9))
        store.markIngest(first.id, outcome: outcome(), expectedAcquiredAt: first.acquiredAt)
        #expect(store.entries[first.id]?.ingest == nil)
    }

    @Test func anActivityFileIsIngestedAsSuch() throws {
        guard FitSamples.available, let path = FitSamples.path("running") else { return }
        let (store, root) = try makeSpool()
        let (db, _) = try makeDb()
        defer { try? FileManager.default.removeItem(at: root) }
        let saved = try acquire(store, type: GarminFileType.activity.watchFileType, index: 1, data: Data(contentsOf: URL(fileURLWithPath: path)))

        let report = LocalIngestor.ingestPending(from: store, into: db)

        #expect(report.results.map(\.kind) == [.activity])
        let proof = try #require(store.entries[saved.id]?.ingest)
        #expect(proof.status == .ingested)
        #expect(try db.holdsIngestedFile(hash: proof.hash))
    }
}

// MARK: - Sérialisation des passes

/// Compte les passes et la concurrence maximale observée.
private final class PassProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var running = 0
    private var _passes = 0
    private var _maxConcurrent = 0
    var passes: Int { lock.lock(); defer { lock.unlock() }; return _passes }
    var maxConcurrent: Int { lock.lock(); defer { lock.unlock() }; return _maxConcurrent }

    func begin() -> Int {
        lock.lock()
        defer { lock.unlock() }
        _passes += 1
        running += 1
        _maxConcurrent = max(_maxConcurrent, running)
        return _passes
    }

    func end() {
        lock.lock()
        running -= 1
        lock.unlock()
    }
}

struct SerialPassGateTests {
    @Test func aBurstDuringAPassProducesExactlyOneMorePassNeverInParallel() async {
        let gate = SerialPassGate()
        let probe = PassProbe()
        let release = DispatchSemaphore(value: 0)
        let pass: @Sendable () -> Void = {
            let number = probe.begin()
            if number == 1 { release.wait() }
            probe.end()
        }

        #expect(gate.request(pass) == true)
        while probe.passes == 0 { try? await Task.sleep(nanoseconds: 1_000_000) }
        for _ in 0..<5 { #expect(gate.request(pass) == false) }
        release.signal()

        #expect(await gate.waitUntilIdle())
        #expect(probe.passes == 2, "la passe en cours + UNE de rattrapage")
        #expect(probe.maxConcurrent == 1)
    }

    @Test func aRequestAtRestStartsANewPass() async {
        let gate = SerialPassGate()
        let probe = PassProbe()
        let pass: @Sendable () -> Void = { _ = probe.begin(); probe.end() }

        gate.request(pass)
        #expect(await gate.waitUntilIdle())
        gate.request(pass)
        #expect(await gate.waitUntilIdle())

        #expect(probe.passes == 2)
    }
}
