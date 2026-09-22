//
//  SyncEngineTests.swift
//  allTests
//
//  Couvre le moteur de synchronisation ajouté cette session : traversée/diff
//  pure (`SyncPlanner`), encodage `SET_FILE_FLAG(ARCHIVE)`, transitions du
//  Spool (`markDelivered`/`markArchived`), et le client d'upload Pulse
//  (`PulseUploader` : construction de requête + mapping code→action, PUR —
//  aucun test ici ne touche le réseau, cf. `Sync/PulseUploader.swift`).
//
//  Vecteurs de traversée inspirés de `GarminSessionDownloadTest`
//  (net.garminbridge.session, garmin-bridge, AGPL-3.0) :
//  `asksForTheMostRecentFileFirstSoAShortLinkBringsBackTheDaysData` /
//  `doesNotAskAgainForAFileItAlreadyHoldsWhenTheLinkComesBack`.
//

import Testing
import Foundation
@testable import all

// MARK: - SyncPlanner (traversée/diff purs)

struct SyncPlannerTests {
    /// Construit une entrée de manifeste avec une date arbitraire (secondes
    /// epoch Unix, converties en epoch Garmin) — `nil` pour une entrée sans
    /// date (sentinelle horodatage=0).
    private func entry(fileIndex: Int, dataType: UInt8 = 128, subType: UInt8 = 4, unixSeconds: UInt32?, sizeBytes: Int = 10) -> GarminDirectoryEntry {
        let garminTs: UInt32 = unixSeconds.map { UInt32(TimeInterval($0) - GarminEpoch.offsetFromUnix) } ?? 0
        return GarminDirectoryEntry(
            fileIndex: fileIndex, dataType: dataType, subType: subType,
            fileNumber: fileIndex, sizeBytes: sizeBytes, garminTimestamp: garminTs)!
    }

    /// Trois entrées datées, comme `THREE_DATED_ENTRIES` côté pont : la montre
    /// les liste dans un ordre arbitraire (chronologique, ou pas — peu importe,
    /// c'est justement ce que `SyncPlanner` doit corriger).
    @Test func asksForTheMostRecentFileFirst() {
        let august = entry(fileIndex: 11, unixSeconds: 1_722_000_000)
        let september = entry(fileIndex: 32, unixSeconds: 1_725_000_000)
        let today = entry(fileIndex: 7, unixSeconds: 1_727_000_000)

        let due = SyncPlanner.filesDue(from: [september, today, august], alreadyAcquired: [])

        #expect(due.map(\.fileIndex) == [7, 32, 11], "récent→ancien, quel que soit l'ordre du listing d'entrée")
    }

    /// Deux entrées à la même date : bris d'égalité par index décroissant
    /// (`thenComparing(getFileIndex, reverseOrder())` côté pont) — un simple
    /// ordre déterministe, pas une signification métier.
    @Test func tiesAtTheSameDateBreakByDescendingFileIndex() {
        let sameDate: UInt32 = 1_726_000_000
        let lower = entry(fileIndex: 3, unixSeconds: sameDate)
        let higher = entry(fileIndex: 9, unixSeconds: sameDate)

        let due = SyncPlanner.filesDue(from: [lower, higher], alreadyAcquired: [])

        #expect(due.map(\.fileIndex) == [9, 3])
    }

    /// Les entrées sans date (sentinelle) passent en dernier (`nullsLast`),
    /// jamais avant une entrée datée.
    @Test func undatedEntriesSortLast() {
        let dated = entry(fileIndex: 1, unixSeconds: 1_700_000_000)
        let undated = entry(fileIndex: 2, unixSeconds: nil)

        let due = SyncPlanner.filesDue(from: [undated, dated], alreadyAcquired: [])

        #expect(due.map(\.fileIndex) == [1, 2])
    }

    /// L'entrée DIRECTORY (dataType=subType=0) n'est jamais une cible de
    /// téléchargement de contenu — filtrée avant même le tri.
    @Test func filtersOutDirectoryEntries() {
        let directory = entry(fileIndex: 0, dataType: 0, subType: 0, unixSeconds: nil, sizeBytes: 100)
        let file = entry(fileIndex: 4, unixSeconds: 1_700_000_000)

        let due = SyncPlanner.filesDue(from: [directory, file], alreadyAcquired: [])

        #expect(due.map(\.fileIndex) == [4])
    }

    /// « ne redemande pas un fichier déjà tenu » — porté de
    /// `doesNotAskAgainForAFileItAlreadyHoldsWhenTheLinkComesBack`. Utilise un
    /// vrai `SpoolStore(root:)` pour construire l'ensemble `alreadyAcquired`,
    /// comme suggéré par la tâche (le journal réel, pas une simulation à la main).
    @Test func doesNotAskAgainForAFileAlreadyInTheSpool() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bridge-connect-syncplanner-tests-\(UUID().uuidString)", isDirectory: true)
        let store = try SpoolStore(root: root)
        defer { try? FileManager.default.removeItem(at: root) }

        let held = entry(fileIndex: 11, unixSeconds: 1_722_000_000)
        let wanted = entry(fileIndex: 7, unixSeconds: 1_727_000_000)
        let (heldID, heldPath) = SpoolStore.identity(for: held)
        try store.recordAcquired(heldID, relativePath: heldPath, data: Data("déjà tenu".utf8))

        let due = SyncPlanner.filesDue(from: [held, wanted], alreadyAcquired: Set(store.entries.keys))

        #expect(due.map(\.fileIndex) == [7], "le fichier déjà acquis n'est pas redemandé")
    }

    /// Un fichier `delivered` ou `archived` (pas seulement `acquired`) compte
    /// aussi comme « déjà tenu » — `SpoolEntry.state` n'entre pas en ligne de
    /// compte, seule la présence de l'identité dans le journal (cf.
    /// `AcquiredFiles.holds` côté pont, qui ne distingue pas non plus).
    @Test func aDeliveredFileIsAlsoNeverAskedAgain() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bridge-connect-syncplanner-tests-\(UUID().uuidString)", isDirectory: true)
        let store = try SpoolStore(root: root)
        defer { try? FileManager.default.removeItem(at: root) }

        let delivered = entry(fileIndex: 11, unixSeconds: 1_722_000_000)
        let (id, path) = SpoolStore.identity(for: delivered)
        try store.recordAcquired(id, relativePath: path, data: Data("x".utf8))
        store.markDelivered(id)

        let due = SyncPlanner.filesDue(from: [delivered], alreadyAcquired: Set(store.entries.keys))

        #expect(due.isEmpty)
    }
}

// MARK: - SET_FILE_FLAG(ARCHIVE) — encodage octet-pour-octet

struct SetFileFlagsEncodingTests {
    /// Porté de `SetFileFlagsMessage.generateOutgoing` (messages/SetFileFlagsMessage.java,
    /// AGPL-3.0) : `UInt16LE(fileIndex)` + `UInt8(bitvector)`, ARCHIVE = 0x10.
    @Test func archivePayloadEncodesFileIndexLEThenArchiveBit() {
        let payload = GarminSession.setFileFlagsArchivePayload(fileIndex: 300) // 300 = 0x012C
        #expect(payload == Data([0x2C, 0x01, 0x10]))
    }

    @Test func archivePayloadForIndexZero() {
        let payload = GarminSession.setFileFlagsArchivePayload(fileIndex: 0)
        #expect(payload == Data([0x00, 0x00, 0x10]))
    }

    /// La trame complète (type 5008 + ce payload) doit rester une trame GFDI
    /// valide — round-trip via le codec déjà testé ailleurs (`GfdiFrameTests`).
    @Test func archiveFrameRoundTripsWithMessageType5008() throws {
        let payload = GarminSession.setFileFlagsArchivePayload(fileIndex: 9)
        let frameBytes = GfdiFrame.build(messageType: 5008, payload: payload)

        let parsed = try GfdiFrame.parse(frameBytes)
        #expect(parsed.messageType == 5008)
        #expect(parsed.payload == payload)
    }
}

// MARK: - SpoolStore — livraison / archivage

struct SpoolDeliveryTests {
    private func makeTempStore() throws -> (store: SpoolStore, root: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bridge-connect-spool-delivery-tests-\(UUID().uuidString)", isDirectory: true)
        return (try SpoolStore(root: root), root)
    }

    private func sampleEntry(fileIndex: Int) -> GarminDirectoryEntry {
        GarminDirectoryEntry(fileIndex: fileIndex, dataType: 128, subType: 4, fileNumber: fileIndex, sizeBytes: 6, garminTimestamp: 0)!
    }

    @Test func markDeliveredTransitionsAcquiredToDelivered() throws {
        let (store, root) = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let (id, relativePath) = SpoolStore.identity(for: sampleEntry(fileIndex: 1))
        try store.recordAcquired(id, relativePath: relativePath, data: Data("x".utf8))

        store.markDelivered(id)

        #expect(store.entries[id]?.state == .delivered)
        #expect(store.entries[id]?.deliveredAt != nil)
    }

    /// Idempotent : une entrée inconnue (jamais `recordAcquired`) est ignorée
    /// sans planter — un appelant en double ne doit jamais crasher le collecteur.
    @Test func markDeliveredIgnoredForUnknownEntry() throws {
        let (store, root) = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let unknown = WatchFileID(fileType: (128 << 8) | 4, index: 1, name: "ACTIVITY_1.fit")

        store.markDelivered(unknown)

        #expect(store.entries[unknown] == nil)
    }

    @Test func markArchivedTransitionsDeliveredToArchived() throws {
        let (store, root) = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let (id, relativePath) = SpoolStore.identity(for: sampleEntry(fileIndex: 5))
        try store.recordAcquired(id, relativePath: relativePath, data: Data("x".utf8))
        store.markDelivered(id)

        store.markArchived(id)

        #expect(store.entries[id]?.state == .archived)
        #expect(store.entries[id]?.archivedAt != nil)
    }

    /// Un fichier encore `acquired` (jamais `delivered`) ne doit JAMAIS être
    /// archivé — c'est tout le sens de l'archivage différé (contrat §7).
    @Test func markArchivedIgnoredWhileStillAcquired() throws {
        let (store, root) = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let (id, relativePath) = SpoolStore.identity(for: sampleEntry(fileIndex: 6))
        try store.recordAcquired(id, relativePath: relativePath, data: Data("x".utf8))

        store.markArchived(id)

        #expect(store.entries[id]?.state == .acquired)
    }

    @Test func deliveryAndArchivalPersistAcrossAFreshInstance() throws {
        let (store, root) = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let (id, relativePath) = SpoolStore.identity(for: sampleEntry(fileIndex: 8))
        try store.recordAcquired(id, relativePath: relativePath, data: Data("x".utf8))
        store.markDelivered(id)
        store.markArchived(id)

        let reloaded = try SpoolStore(root: root)

        #expect(reloaded.entries[id]?.state == .archived)
        #expect(reloaded.entries[id]?.deliveredAt != nil)
        #expect(reloaded.entries[id]?.archivedAt != nil)
    }

    /// `fileURL(for:)` doit pointer vers les octets réellement écrits par
    /// `recordAcquired` — c'est ce que `PulseUploader` lira pour l'upload.
    @Test func fileURLPointsToTheBytesWrittenByRecordAcquired() throws {
        let (store, root) = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let (id, relativePath) = SpoolStore.identity(for: sampleEntry(fileIndex: 9))
        try store.recordAcquired(id, relativePath: relativePath, data: Data("contenu".utf8))

        guard let spoolEntry = store.entries[id] else {
            Issue.record("entrée absente juste après recordAcquired")
            return
        }
        let onDisk = try Data(contentsOf: store.fileURL(for: spoolEntry))

        #expect(onDisk == Data("contenu".utf8))
    }

    /// `pendingArchive()` ne rend que les entrées `delivered` — jamais
    /// `acquired` (pas encore livré) ni `archived` (déjà fait).
    @Test func pendingArchiveOnlyReturnsDeliveredEntries() throws {
        let (store, root) = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let (acquiredID, acquiredPath) = SpoolStore.identity(for: sampleEntry(fileIndex: 10))
        let (deliveredID, deliveredPath) = SpoolStore.identity(for: sampleEntry(fileIndex: 11))
        try store.recordAcquired(acquiredID, relativePath: acquiredPath, data: Data("a".utf8))
        try store.recordAcquired(deliveredID, relativePath: deliveredPath, data: Data("b".utf8))
        store.markDelivered(deliveredID)

        let pending = store.pendingArchive()

        #expect(pending.map(\.id) == [deliveredID])
    }
}

// MARK: - PulseUploader — construction de requête (PURE)

struct PulseUploaderRequestTests {
    @Test func requestHasTheContractShape() {
        let baseURL = URL(string: "https://pulse.example.ts.net")!

        let request = PulseUploader.makeUploadRequest(
            baseURL: baseURL,
            token: "s3cr3t-test-token",
            watchFilename: "ACTIVITY_2024-01-01_00-00-00_7.fit",
            sha256Hex: "deadbeef")

        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://pulse.example.ts.net/api/ingest")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/octet-stream")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer s3cr3t-test-token")
        #expect(request.value(forHTTPHeaderField: "X-Watch-Filename") == "ACTIVITY_2024-01-01_00-00-00_7.fit")
        #expect(request.value(forHTTPHeaderField: "X-Content-SHA256") == "deadbeef")
    }
}

// MARK: - PulseUploader — SHA-256 (PURE, octets fictifs)

struct PulseUploaderHashTests {
    /// Vecteur NIST bien connu : SHA-256("abc") — vérifié indépendamment via
    /// `shasum -a 256` avant l'écriture de ce test.
    @Test func sha256HexMatchesAKnownVector() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("pulse-upload-hash-\(UUID().uuidString).fit")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try Data("abc".utf8).write(to: tmp)

        let hex = try PulseUploader.sha256Hex(ofFileAt: tmp)

        #expect(hex == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
}

// MARK: - PulseUploader — mapping réponse → action (PUR, §6 du contrat)

struct PulseUploaderOutcomeMappingTests {
    @Test func twoHundredClassAlwaysMeansDelivered() {
        for code in [200, 201, 250, 299] {
            #expect(PulseUploader.outcome(forHTTPStatusCode: code) == .delivered, "code \(code)")
        }
    }

    @Test func fourZeroOneMeansKeepConfigError() {
        #expect(PulseUploader.outcome(forHTTPStatusCode: 401) == .keepConfigError)
    }

    @Test func fourZeroThreeMeansKeepRetryLater() {
        #expect(PulseUploader.outcome(forHTTPStatusCode: 403) == .keepRetryLater)
    }

    @Test func malformedRequestOrUnreadableFitMeansQuarantine() {
        for code in [400, 413, 415, 422] {
            #expect(PulseUploader.outcome(forHTTPStatusCode: code) == .quarantine, "code \(code)")
        }
    }

    @Test func fiveXXAndUnlistedCodesMeanKeepRetry() {
        for code in [500, 502, 503, 404, 418] {
            #expect(PulseUploader.outcome(forHTTPStatusCode: code) == .keepRetry, "code \(code)")
        }
    }
}

// MARK: - PulseUploader — orchestration via transport factice (jamais réseau)

/// Transport factice — ne touche JAMAIS le réseau (règle immuable du dépôt) :
/// rejoue un code HTTP ou une erreur fixés à la construction, synchrone.
private struct StubPulseUploadTransport: PulseUploadTransport {
    enum Behavior {
        case statusCode(Int)
        case failure(Error)
    }
    let behavior: Behavior

    func send(_ request: URLRequest, fileURL: URL, completion: @escaping (Result<Int, Error>) -> Void) {
        switch behavior {
        case .statusCode(let code): completion(.success(code))
        case .failure(let error): completion(.failure(error))
        }
    }
}

private enum StubTransportError: Error {
    case simulatedNetworkFailure
}

struct PulseUploaderOrchestrationTests {
    private func makeFixtureFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pulse-upload-orch-\(UUID().uuidString).fit")
        try Data("pas vraiment un FIT".utf8).write(to: url)
        return url
    }

    @Test func aTwoHundredResponseDeliversTheOutcome() throws {
        let fixture = try makeFixtureFile()
        defer { try? FileManager.default.removeItem(at: fixture) }

        var captured: Result<PulseUploadOutcome, Error>?
        PulseUploader.upload(
            fileURL: fixture, watchFilename: "x.fit",
            baseURL: URL(string: "https://pulse.example.ts.net")!, token: "t",
            transport: StubPulseUploadTransport(behavior: .statusCode(200))
        ) { captured = $0 }

        switch captured {
        case .success(let outcome): #expect(outcome == .delivered)
        default: Issue.record("Attendu .success(.delivered), obtenu \(String(describing: captured))")
        }
    }

    /// Dernière ligne du contrat §6 : une erreur de transport (réseau/timeout,
    /// pas de code HTTP) vaut `.keepRetry`, jamais une quarantaine.
    @Test func aTransportFailureMapsToKeepRetry() throws {
        let fixture = try makeFixtureFile()
        defer { try? FileManager.default.removeItem(at: fixture) }

        var captured: Result<PulseUploadOutcome, Error>?
        PulseUploader.upload(
            fileURL: fixture, watchFilename: "x.fit",
            baseURL: URL(string: "https://pulse.example.ts.net")!, token: "t",
            transport: StubPulseUploadTransport(behavior: .failure(StubTransportError.simulatedNetworkFailure))
        ) { captured = $0 }

        switch captured {
        case .success(let outcome): #expect(outcome == .keepRetry)
        default: Issue.record("Attendu .success(.keepRetry), obtenu \(String(describing: captured))")
        }
    }
}

// MARK: - PulseConfig — token en Keychain

struct PulseConfigIngestTokenTests {
    /// Aller-retour Keychain — nettoie après lui (restaure la valeur d'avant)
    /// pour ne pas polluer les exécutions suivantes sur la même machine/simulateur.
    @Test func ingestTokenRoundTripsAndClearsThroughKeychain() {
        let original = PulseConfig.ingestToken
        defer { PulseConfig.ingestToken = original }

        let fake = "test-token-\(UUID().uuidString)"
        PulseConfig.ingestToken = fake
        #expect(PulseConfig.ingestToken == fake)

        PulseConfig.ingestToken = nil
        #expect(PulseConfig.ingestToken == nil)
    }
}
