//
//  PulseBacklogPusherTests.swift
//  allTests
//
//  Couvre `Sync/PulseBacklogPusher.swift` (rattrapage Pulse au basculement
//  Téléphone → Pulse/Les deux) et la rétrocompatibilité du nouveau champ
//  `SpoolEntry.pushedToPulse` (`Spool/SpooledFile.swift`). Aucun réseau réel :
//  `push(_:spool:uploader:)` est exercé avec un `SpoolUploading` factice, comme
//  `RoutingSpoolUploaderTests` (`StorageModeTests.swift`) — jamais
//  `PulseSpoolUploader`/`URLSessionPulseUploadTransport` (règle immuable du
//  dépôt). `pushIfNeeded()` lui-même (la tâche détachée qui ouvre une vraie
//  `SpoolStore`) n'est pas testé directement — même choix que
//  `LocalIngestor.ingestIfNeeded()` (cf. `LocalIngestorChangeTests.swift`) :
//  on teste les fonctions PURES qu'il consulte (`shouldAttemptPush`,
//  `backlog(from:fileExists:)`).
//

import Testing
import Foundation
@testable import all

// MARK: - SpoolEntry — rétrocompatibilité de `pushedToPulse`

struct SpoolEntryPushedToPulseCodableTests {
    private func sampleEntry(pushedToPulse: Bool) -> SpoolEntry {
        SpoolEntry(
            id: WatchFileID(fileType: (128 << 8) | 4, index: 3, name: "ACTIVITY_3.fit"),
            state: .archived,
            acquiredAt: Date(timeIntervalSince1970: 1_700_000_000),
            deliveredAt: Date(timeIntervalSince1970: 1_700_000_100),
            archivedAt: Date(timeIntervalSince1970: 1_700_000_200),
            relativePath: "ACTIVITY/2023/ACTIVITY_2023-11-14_22-13-20_3.fit",
            pushedToPulse: pushedToPulse)
    }

    @Test func roundTripsPushedToPulseWhenPresent() throws {
        let entry = sampleEntry(pushedToPulse: true)

        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(SpoolEntry.self, from: data)

        #expect(decoded.pushedToPulse == true)
    }

    @Test func roundTripsPushedToPulseFalseToo() throws {
        let entry = sampleEntry(pushedToPulse: false)

        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(SpoolEntry.self, from: data)

        #expect(decoded.pushedToPulse == false)
    }

    /// Rétrocompatibilité : un journal écrit AVANT ce champ (tout journal
    /// mode Téléphone antérieur à cet incrément) ne porte pas la clé
    /// `pushedToPulse`. Simulé en retirant la clé d'un JSON encodé par le
    /// type lui-même (plutôt qu'en écrivant le JSON à la main, fragile si
    /// l'encodage de `Date` change un jour) — l'invariant testé est
    /// « absent ⇒ `false` », pas la forme exacte du JSON.
    @Test func decodesMissingPushedToPulseAsFalseAndKeepsTheRestOfTheEntry() throws {
        let entry = sampleEntry(pushedToPulse: true) // valeur qui, si mal gérée, survivrait à tort au strip
        guard var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(entry)) as? [String: Any] else {
            Issue.record("encodage inattendu, pas un objet JSON")
            return
        }
        #expect(json["pushedToPulse"] != nil, "précondition : le champ est bien présent avant qu'on le retire")
        json.removeValue(forKey: "pushedToPulse")
        let strippedData = try JSONSerialization.data(withJSONObject: json)

        let decoded = try JSONDecoder().decode(SpoolEntry.self, from: strippedData)

        #expect(decoded.pushedToPulse == false)
        #expect(decoded.id == entry.id)
        #expect(decoded.state == entry.state)
        #expect(decoded.relativePath == entry.relativePath)
        #expect(decoded.deliveredAt == entry.deliveredAt)
        #expect(decoded.archivedAt == entry.archivedAt)
    }

    /// Le journal réel est un TABLEAU (`[SpoolEntry]`, cf.
    /// `SpoolStore.loadJournal`/`persist`) — vérifie que l'absence du
    /// champ sur une entrée ne fait pas échouer le décodage du tableau
    /// ENTIER, pas seulement d'une entrée isolée décodée seule.
    @Test func aWholeJournalArrayWithoutTheFieldOnOneEntryStillDecodesEntirely() throws {
        let withField = sampleEntry(pushedToPulse: true)
        let withoutFieldEntry = SpoolEntry(
            id: WatchFileID(fileType: (128 << 8) | 4, index: 9, name: "ACTIVITY_9.fit"),
            state: .acquired, acquiredAt: Date(timeIntervalSince1970: 1_600_000_000),
            relativePath: "ACTIVITY/ACTIVITY_9.fit")
        guard var withoutFieldJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(withoutFieldEntry)) as? [String: Any] else {
            Issue.record("encodage inattendu, pas un objet JSON")
            return
        }
        withoutFieldJSON.removeValue(forKey: "pushedToPulse")
        let arrayData = try JSONSerialization.data(withJSONObject: [
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(withField)),
            withoutFieldJSON,
        ])

        let decoded = try JSONDecoder().decode([SpoolEntry].self, from: arrayData)

        #expect(decoded.count == 2)
        #expect(decoded.first(where: { $0.id == withField.id })?.pushedToPulse == true)
        #expect(decoded.first(where: { $0.id == withoutFieldEntry.id })?.pushedToPulse == false)
    }
}

// MARK: - PulseBacklogPusher.backlog(from:fileExists:) — sélection PURE

struct PulseBacklogSelectionTests {
    private func entry(index: Int, pushedToPulse: Bool) -> SpoolEntry {
        SpoolEntry(
            id: WatchFileID(fileType: (128 << 8) | 4, index: index, name: "ACTIVITY_\(index).fit"),
            state: .archived, acquiredAt: Date(),
            relativePath: "ACTIVITY/ACTIVITY_\(index).fit", pushedToPulse: pushedToPulse)
    }

    @Test func selectsOnlyNotPushedEntriesWhoseFileStillExists() {
        let notPushedWithFile = entry(index: 1, pushedToPulse: false)
        let notPushedMissingFile = entry(index: 2, pushedToPulse: false)
        let alreadyPushed = entry(index: 3, pushedToPulse: true)
        let entries = [notPushedWithFile, notPushedMissingFile, alreadyPushed]
        let indexesWithFileOnDisk: Set<Int> = [1, 3]

        let due = PulseBacklogPusher.backlog(from: entries) { indexesWithFileOnDisk.contains($0.id.index) }

        #expect(due.map(\.id.index) == [1], "ni déjà poussé, ni fichier manquant")
    }

    @Test func emptyWhenEverythingAlreadyPushed() {
        let entries = [entry(index: 1, pushedToPulse: true), entry(index: 2, pushedToPulse: true)]

        let due = PulseBacklogPusher.backlog(from: entries) { _ in true }

        #expect(due.isEmpty)
    }

    @Test func emptyWhenNoFileRemainsOnDisk() {
        let entries = [entry(index: 1, pushedToPulse: false), entry(index: 2, pushedToPulse: false)]

        let due = PulseBacklogPusher.backlog(from: entries) { _ in false }

        #expect(due.isEmpty, "un fichier disparu du disque n'est pas retenté indéfiniment")
    }
}

// MARK: - PulseBacklogPusher.shouldAttemptPush — garde mode/config PURE

struct PulseBacklogPusherGuardTests {
    @Test func phoneModeNeverAttemptsRegardlessOfConfig() {
        #expect(PulseBacklogPusher.shouldAttemptPush(mode: .phone, baseURLConfigured: true, token: "t") == false)
        #expect(PulseBacklogPusher.shouldAttemptPush(mode: .phone, baseURLConfigured: false, token: nil) == false)
    }

    @Test func pulseOrBothWithoutBaseURLDoesNotAttempt() {
        #expect(PulseBacklogPusher.shouldAttemptPush(mode: .pulse, baseURLConfigured: false, token: "t") == false)
        #expect(PulseBacklogPusher.shouldAttemptPush(mode: .both, baseURLConfigured: false, token: "t") == false)
    }

    @Test func pulseOrBothWithoutATokenDoesNotAttempt() {
        #expect(PulseBacklogPusher.shouldAttemptPush(mode: .pulse, baseURLConfigured: true, token: nil) == false)
    }

    @Test func pulseOrBothWithAnEmptyTokenDoesNotAttempt() {
        #expect(PulseBacklogPusher.shouldAttemptPush(mode: .both, baseURLConfigured: true, token: "") == false)
    }

    @Test func pulseOrBothFullyConfiguredAttempts() {
        #expect(PulseBacklogPusher.shouldAttemptPush(mode: .pulse, baseURLConfigured: true, token: "t") == true)
        #expect(PulseBacklogPusher.shouldAttemptPush(mode: .both, baseURLConfigured: true, token: "t") == true)
    }
}

// MARK: - PulseBacklogPusher.push(_:spool:uploader:) — issue → journal, factice

/// Uploader factice — enregistre chaque appel, ne touche jamais le réseau ni
/// le disque. Copie volontaire de `RecordingSpoolUploading`
/// (`StorageModeTests.swift`, `private`, donc invisible depuis ce fichier)
/// plutôt qu'un partage inter-fichiers pour un si petit type.
private final class StubBacklogUploader: SpoolUploading {
    private(set) var calls: [(fileURL: URL, watchFilename: String)] = []
    var outcomeToReturn: PulseUploadOutcome = .delivered

    func upload(fileURL: URL, watchFilename: String, completion: @escaping (PulseUploadOutcome) -> Void) {
        calls.append((fileURL, watchFilename))
        completion(outcomeToReturn)
    }
}

struct PulseBacklogPushOutcomeTests {
    private func makeTempStore() throws -> (store: SpoolStore, root: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bridge-connect-backlog-push-tests-\(UUID().uuidString)", isDirectory: true)
        return (try SpoolStore(root: root), root)
    }

    private func sampleDirectoryEntry(fileIndex: Int) -> GarminDirectoryEntry {
        GarminDirectoryEntry(fileIndex: fileIndex, dataType: 128, subType: 4, fileNumber: fileIndex, sizeBytes: 6, garminTimestamp: 0)!
    }

    /// Le cas nominal du rattrapage : un fichier collecté en mode Téléphone —
    /// déjà `delivered`/`archived` LOCALEMENT (cf. `RoutingSpoolUploader`,
    /// branche `.phone`), jamais poussé — reçoit un accusé Pulse réel (simulé
    /// par le factice) et se voit marqué `pushedToPulse`.
    @Test func aDeliveredOutcomeMarksPushedToPulseWithoutTouchingState() async throws {
        let (store, root) = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let (id, relativePath) = SpoolStore.identity(for: sampleDirectoryEntry(fileIndex: 1))
        try store.recordAcquired(id, relativePath: relativePath, data: Data("x".utf8))
        store.markDelivered(id)
        store.markArchived(id)
        #expect(store.entries[id]?.pushedToPulse == false, "précondition : jamais poussé avant le rattrapage")

        let uploader = StubBacklogUploader()
        uploader.outcomeToReturn = .delivered

        await PulseBacklogPusher.push(store.entries[id]!, spool: store, uploader: uploader)

        #expect(store.entries[id]?.pushedToPulse == true)
        #expect(uploader.calls.count == 1)
        #expect(uploader.calls.first?.watchFilename == id.name)
        #expect(store.entries[id]?.state == .archived, "le pusher ne touche jamais `state` — seulement `pushedToPulse`")
    }

    @Test func aFailureOutcomeLeavesPushedToPulseFalseForARetryLater() async throws {
        let (store, root) = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let (id, relativePath) = SpoolStore.identity(for: sampleDirectoryEntry(fileIndex: 2))
        try store.recordAcquired(id, relativePath: relativePath, data: Data("x".utf8))
        store.markDelivered(id)
        store.markArchived(id)

        let uploader = StubBacklogUploader()
        uploader.outcomeToReturn = .keepRetry

        await PulseBacklogPusher.push(store.entries[id]!, spool: store, uploader: uploader)

        #expect(store.entries[id]?.pushedToPulse == false)
    }

    @Test func aQuarantineOutcomeAlsoLeavesPushedToPulseFalse() async throws {
        let (store, root) = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let (id, relativePath) = SpoolStore.identity(for: sampleDirectoryEntry(fileIndex: 3))
        try store.recordAcquired(id, relativePath: relativePath, data: Data("x".utf8))
        store.markDelivered(id)
        store.markArchived(id)

        let uploader = StubBacklogUploader()
        uploader.outcomeToReturn = .quarantine

        await PulseBacklogPusher.push(store.entries[id]!, spool: store, uploader: uploader)

        #expect(store.entries[id]?.pushedToPulse == false)
    }

    @Test func pushedToPulsePersistsAcrossAFreshSpoolStoreInstance() async throws {
        let (store, root) = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let (id, relativePath) = SpoolStore.identity(for: sampleDirectoryEntry(fileIndex: 4))
        try store.recordAcquired(id, relativePath: relativePath, data: Data("x".utf8))
        store.markDelivered(id)
        store.markArchived(id)

        let uploader = StubBacklogUploader()
        await PulseBacklogPusher.push(store.entries[id]!, spool: store, uploader: uploader)

        let reloaded = try SpoolStore(root: root)
        #expect(reloaded.entries[id]?.pushedToPulse == true)
    }
}
