//
//  PulseFilesPullTests.swift
//  allTests
//
//  Rapatriement des `.fit` de Pulse vers le téléphone (`Sync/PulseFilesPull.swift`,
//  `PulseFilesPullService.swift`, `PulseFilesStore.swift`), contrat
//  `custom-connect/docs/pulse-files-pull-contract.md` :
//   - moteur : diff manifeste/base, pagination, ordre, hash vérifié, fichier corrompu
//     ou ignoré mémorisé, activité gardée et retrouvée, mesures non gardées, journal du
//     spool intact, reprise sans double ingestion, coupure ;
//   - service : modes, 401, 404 du manifeste, reprise à délai croissant, compteur de
//     bannière qui retombe ;
//   - purge : le rapatrié s'efface, une nouvelle passe le reprend.
//  Transport FACTICE, fichiers FIT SYNTHÉTIQUES (`syntheticFit`), bases et dossiers
//  TEMPORAIRES : aucun réseau, jamais les vraies données de l'app.
//

import Testing
import CryptoKit
import Foundation
@testable import all

// MARK: - Doubles et aides

private func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private struct Item {
    let hash: String
    let kind: String
    let fileName: String?
    let bytes: Data

    init(kind: String, fileName: String? = nil, bytes: Data) {
        self.hash = sha256(bytes)
        self.kind = kind
        self.fileName = fileName
        self.bytes = bytes
    }

    static func wellness(_ salt: UInt8) -> Item { Item(kind: "wellness", fileName: "w\(salt).fit", bytes: syntheticFit(fileType: 32, salt: salt)) }
    static func activity(_ salt: UInt8) -> Item { Item(kind: "activity", fileName: "a\(salt).fit", bytes: syntheticFit(fileType: 4, salt: salt)) }
    /// FIT valide, sommeil sans nuit exploitable : l'ingestion répond « ignoré ».
    static func ignored(_ salt: UInt8) -> Item { Item(kind: "sleep", fileName: "s\(salt).fit", bytes: syntheticFit(fileType: 49, salt: salt)) }
    /// Octets qui ne sont pas du FIT.
    static func garbage(_ salt: UInt8) -> Item { Item(kind: "wellness", fileName: nil, bytes: Data([salt, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15])) }
}

private final class FakeFilesTransport: PulseFilesPullTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _items: [Item]
    private var _totalOverride: Int?
    private var _manifestStatus = 200
    private var _notConfigured = false
    private var _downloadStatus: [String: Int] = [:]
    private var _served: [String: Data] = [:]
    private var _failAfter: Int?
    private var _blocked: Set<String> = []
    private var _delayNs: UInt64 = 0
    private var _manifestCalls: [(offset: Int, limit: Int)] = []
    private var _downloads: [String] = []
    private var _blockedHits = 0
    private var inFlight = 0
    private var _peak = 0

    init(_ items: [Item]) { _items = items }

    // Réglages
    func setTotalOverride(_ n: Int?) { lock.withLock { _totalOverride = n } }
    func setManifestStatus(_ s: Int) { lock.withLock { _manifestStatus = s } }
    func setNotConfigured(_ b: Bool) { lock.withLock { _notConfigured = b } }
    func setDownloadStatus(_ hash: String, _ s: Int) { lock.withLock { _downloadStatus[hash] = s } }
    func serve(_ hash: String, bytes: Data) { lock.withLock { _served[hash] = bytes } }
    func failDownloadsAfter(_ n: Int?) { lock.withLock { _failAfter = n } }
    func block(_ hashes: Set<String>) { lock.withLock { _blocked = hashes } }
    func setDelay(ms: UInt64) { lock.withLock { _delayNs = ms * 1_000_000 } }

    // Observations
    var manifestCalls: [(offset: Int, limit: Int)] { lock.withLock { _manifestCalls } }
    var downloads: [String] { lock.withLock { _downloads } }
    var peakConcurrency: Int { lock.withLock { _peak } }
    var blockedHits: Int { lock.withLock { _blockedHits } }

    func manifest(offset: Int, limit: Int) async throws -> PulseFilesHTTPResponse {
        let (items, total, status, notConfigured) = lock.withLock { () -> ([Item], Int, Int, Bool) in
            _manifestCalls.append((offset, limit))
            return (_items, _totalOverride ?? _items.count, _manifestStatus, _notConfigured)
        }
        if notConfigured { throw PulseFilesPullError.notConfigured }
        guard status == 200 else { return PulseFilesHTTPResponse(status: status, body: Data("{}".utf8)) }
        let slice = items.dropFirst(offset).prefix(limit)
        let files = slice.map { item -> [String: Any] in
            var entry: [String: Any] = ["hash": item.hash, "kind": item.kind, "size": item.bytes.count]
            entry["fileName"] = item.fileName ?? NSNull()
            return entry
        }
        let object: [String: Any] = ["total": total, "offset": offset, "files": files]
        return PulseFilesHTTPResponse(status: 200, body: try JSONSerialization.data(withJSONObject: object))
    }

    func download(hash: String, to destination: URL) async throws -> Int {
        let step = lock.withLock { () -> (notConfigured: Bool, fail: Bool, block: Bool, status: Int?, bytes: Data?, delay: UInt64) in
            _downloads.append(hash)
            let ok = _downloads.count - 1 < (_failAfter ?? Int.max)
            let block = _blocked.contains(hash)
            if block { _blockedHits += 1 }
            inFlight += 1
            _peak = max(_peak, inFlight)
            return (_notConfigured, !ok, block, _downloadStatus[hash], _served[hash] ?? _items.first { $0.hash == hash }?.bytes, _delayNs)
        }
        defer { lock.withLock { inFlight -= 1 } }
        if step.notConfigured { throw PulseFilesPullError.notConfigured }
        if step.fail { throw URLError(.notConnectedToInternet) }
        if step.block { try await Task.sleep(nanoseconds: 60_000_000_000) }
        if step.delay > 0 { try await Task.sleep(nanoseconds: step.delay) }
        if let status = step.status, status != 200 { return status }
        guard let bytes = step.bytes else { return 404 }
        try bytes.write(to: destination)
        return 200
    }
}

/// Manifeste figé + téléchargement d'un seul fichier : pour les cas où le serveur « ment ».
private final class ManifestOnlyTransport: PulseFilesPullTransport, @unchecked Sendable {
    let body: String
    let item: Item
    private let lock = NSLock()
    private var _downloads: [String] = []
    var downloads: [String] { lock.withLock { _downloads } }
    init(body: String, item: Item) { self.body = body; self.item = item }
    func manifest(offset: Int, limit: Int) async throws -> PulseFilesHTTPResponse {
        PulseFilesHTTPResponse(status: 200, body: offset == 0 ? Data(body.utf8) : Data(#"{"total":4,"offset":4,"files":[]}"#.utf8))
    }
    func download(hash: String, to destination: URL) async throws -> Int {
        lock.withLock { _downloads.append(hash) }
        try item.bytes.write(to: destination)
        return 200
    }
}

private struct Rig {
    let root: URL
    let db: LocalDb
    let store: PulseFilesStore
    let spool: SpoolStore
    private let ingestLock = NSLock()

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("pulse-files-pull-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        db = try LocalDb(path: root.appendingPathComponent("db.sqlite").path)
        store = PulseFilesStore(root: root.appendingPathComponent("pulse-files", isDirectory: true))
        spool = try SpoolStore(root: root.appendingPathComponent("spool", isDirectory: true))
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }

    /// Moteur de test : sections sérialisées par un verrou propre au banc (la garde
    /// partagée de l'app n'a rien à faire dans un test isolé, mais deux ingestions ne
    /// doivent jamais se chevaucher sur la même connexion), rafraîchissement compté.
    func engine(
        _ transport: PulseFilesPullTransport, pageSize: Int = 2_000, concurrency: Int = 1,
        refresh: @escaping @Sendable () -> Void = {}, now: @escaping @Sendable () -> Date = { Date() },
        refreshInterval: TimeInterval = 30
    ) -> PulseFilesPullEngine {
        PulseFilesPullEngine(
            db: db, transport: transport, store: store, pageSize: pageSize, concurrency: concurrency,
            serialize: { [ingestLock] work in ingestLock.withLock { work() } }, refresh: refresh, now: now, refreshInterval: refreshInterval)
    }

    func count(_ table: String) throws -> Int {
        var n = 0
        try db.db.run("SELECT COUNT(*) FROM \"\(table)\"") { r in n = Int(r.double(0) ?? 0) }
        return n
    }

    var keptFiles: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: store.activitiesDir.path)) ?? []).sorted()
    }

    var incomingFiles: [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: store.incomingDir.path)) ?? []
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
}

private final class IntLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [Int] = []
    func append(_ v: Int) { lock.withLock { _values.append(v) } }
    var values: [Int] { lock.withLock { _values } }
}

private final class HealthLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [SaisieSyncHealthEvent] = []
    func record(_ event: SaisieSyncHealthEvent) { lock.withLock { _events.append(event) } }
    var events: [SaisieSyncHealthEvent] { lock.withLock { _events } }
}

private final class PullModeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _mode: StorageMode
    init(_ mode: StorageMode) { _mode = mode }
    var mode: StorageMode {
        get { lock.withLock { _mode } }
        set { lock.withLock { _mode = newValue } }
    }
}

private final class ClockBox: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_900_000_000)
    private let step: TimeInterval
    init(step: TimeInterval = 0) { self.step = step }
    var now: Date {
        lock.withLock {
            defer { current = current.addingTimeInterval(step) }
            return current
        }
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

// MARK: - Moteur : diff, pagination, ordre

struct PulseFilesPullEngineTests {
    @Test func hashesAreSha256LowercaseHexLikePulse() throws {
        // Même algorithme et même forme que `createHash('sha256').digest('hex')` côté
        // Pulse : le hash local d'un fichier est celui que le manifeste annonce.
        let rig = try Rig()
        defer { rig.cleanup() }
        let data = syntheticFit(fileType: 32, salt: 9)
        let url = rig.root.appendingPathComponent("x.fit")
        try data.write(to: url)
        let local = try PulseUploader.sha256Hex(ofFileAt: url)
        #expect(local == sha256(data))
        #expect(PulseFilesStore.isHash(local))
        #expect(local == local.lowercased())
        #expect(!PulseFilesStore.isHash(local.uppercased()))
        #expect(!PulseFilesStore.isHash("../../etc/passwd"))
        #expect(!PulseFilesStore.isHash(String(local.dropLast())))
    }

    @Test func downloadsOnlyWhatTheLocalBaseDoesNotKnowNewestFirst() async throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        let items = [Item.wellness(1), .wellness(2), .activity(3), .wellness(4)]
        // Le 2 est déjà connu : ingéré par le chemin local habituel (spool).
        let known = rig.root.appendingPathComponent("known.fit")
        try items[1].bytes.write(to: known)
        _ = LocalIngestor.ingest(fileURL: known, hash: items[1].hash, fileName: "known.fit", into: rig.db)
        let transport = FakeFilesTransport(items)

        let report = await rig.engine(transport).run()

        #expect(report.outcome == .completed)
        #expect(report.listed == 4)
        #expect(report.toFetch == 3)
        #expect(transport.downloads == [items[0].hash, items[2].hash, items[3].hash], "ordre du manifeste, hash connu écarté")
        #expect(report.ingested == 3)
        #expect(try rig.count("imported_files") == 3)
        #expect(try rig.count("activities") == 1)
    }

    @Test func aSecondPassAfterCompletionDownloadsNothing() async throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        let transport = FakeFilesTransport([.wellness(1), .activity(2), .ignored(3), .garbage(4)])
        let engine = rig.engine(transport)
        _ = await engine.run()
        let first = transport.downloads.count
        let report = await engine.run()
        #expect(report.outcome == .completed)
        #expect(report.toFetch == 0)
        #expect(transport.downloads.count == first, "ingéré, activité, ignoré et en échec : tout est connu")
    }

    @Test func paginatesStrictlyAndAdvancesByTheNumberOfEntriesReceived() async throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        let transport = FakeFilesTransport((1...5).map { Item.wellness(UInt8($0)) })
        _ = await rig.engine(transport, pageSize: 2).run()
        #expect(transport.manifestCalls.map(\.offset) == [0, 2, 4])
        #expect(transport.manifestCalls.allSatisfy { $0.limit == 2 })
        #expect(transport.downloads.count == 5)
    }

    @Test func thePageSizeNeverExceedsTheServerCeiling() async throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        let transport = FakeFilesTransport([.wellness(1)])
        _ = await rig.engine(transport, pageSize: 5_000).run()
        #expect(transport.manifestCalls.first?.limit == 2_000)
    }

    @Test func aTotalOffByOneNeverLoopsAndStopsOnAnEmptyPage() async throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        let transport = FakeFilesTransport((1...5).map { Item.wellness(UInt8($0)) })
        transport.setTotalOverride(6) // un fichier a disparu entre deux lectures
        let report = await rig.engine(transport, pageSize: 5).run()
        #expect(report.outcome == .completed)
        #expect(transport.manifestCalls.map(\.offset) == [0, 5], "la page vide arrête la lecture")
        #expect(report.ingested == 5)
    }

    @Test func aTotalSmallerThanTheRealCountStopsAtTheTotal() async throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        let transport = FakeFilesTransport((1...5).map { Item.wellness(UInt8($0)) })
        transport.setTotalOverride(4)
        let report = await rig.engine(transport, pageSize: 2).run()
        #expect(transport.manifestCalls.map(\.offset) == [0, 2])
        #expect(report.listed == 4)
    }

    @Test func malformedAndDuplicateHashesAreDroppedFromTheManifest() async throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        let good = Item.wellness(1)
        // Un manifeste qui porte un hash en forme de chemin, une casse inattendue et un doublon.
        let transport = ManifestOnlyTransport(body: """
        {"total":4,"offset":0,"files":[
          {"hash":"../../etc/passwd","kind":"wellness","fileName":null,"size":1},
          {"hash":"\(good.hash.uppercased())","kind":"wellness","fileName":"w.fit","size":1},
          {"hash":"\(good.hash)","kind":"wellness","fileName":"w.fit","size":1},
          {"hash":"abc","kind":"wellness","fileName":"w.fit","size":1}]}
        """, item: good)
        let report = await rig.engine(transport).run()
        #expect(report.listed == 1)
        #expect(transport.downloads == [good.hash])
    }

    @Test func concurrencyNeverExceedsTwoDownloads() async throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        let transport = FakeFilesTransport((1...8).map { Item.wellness(UInt8($0)) })
        transport.setDelay(ms: 15)
        let report = await rig.engine(transport, concurrency: 2).run()
        #expect(report.ingested == 8)
        #expect(transport.peakConcurrency == 2)
    }

    @Test func anUnknownKindIsToleratedAndIngestedByItsRealType() async throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        let weird = Item(kind: "weird", fileName: "x.fit", bytes: syntheticFit(fileType: 32, salt: 7))
        let weirdBroken = Item(kind: "weird", fileName: nil, bytes: Data([9, 9, 9]))
        let transport = FakeFilesTransport([weird, weirdBroken])
        let report = await rig.engine(transport).run()
        #expect(report.outcome == .completed)
        #expect(report.ingested == 1)
        #expect(report.failed == 1)
    }

    @Test func theLocalFileNameFallsBackOnTheHashAndNeverTakesAPath() {
        let hash = String(repeating: "a", count: 64)
        #expect(PulseFilesPullEngine.localName(for: PulseManifestEntry(hash: hash, kind: "x", fileName: nil, size: nil)) == "\(hash).fit")
        #expect(PulseFilesPullEngine.localName(for: PulseManifestEntry(hash: hash, kind: "x", fileName: "../../a.fit", size: nil)) == "a.fit")
        #expect(PulseFilesPullEngine.localName(for: PulseManifestEntry(hash: hash, kind: "x", fileName: "", size: nil)) == "\(hash).fit")
    }
}

// MARK: - Moteur : vérification, échecs, ignorés, conservation

struct PulseFilesPullStorageTests {
    @Test func aWrongHashIsRecordedAsFailedAndNeverAskedAgain() async throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        let item = Item.wellness(1)
        let transport = FakeFilesTransport([item])
        transport.serve(item.hash, bytes: syntheticFit(fileType: 32, salt: 99)) // FIT valide, mais pas celui annoncé
        let engine = rig.engine(transport)

        let first = await engine.run()
        #expect(first.failed == 1)
        #expect(first.ingested == 0)
        #expect(try rig.count("imported_files") == 0, "rien n'est ingéré sur un hash qui ne correspond pas")
        #expect(try rig.db.pulledMarkCount(.failed) == 1)

        let second = await engine.run()
        #expect(second.toFetch == 0)
        #expect(transport.downloads.count == 1, "plus jamais redemandé")
    }

    @Test func anUndecodableFileIsRecordedAsFailedAndNeverAskedAgain() async throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        let transport = FakeFilesTransport([.garbage(1)])
        let engine = rig.engine(transport)
        let first = await engine.run()
        #expect(first.failed == 1)
        #expect(try rig.db.pulledMarkCount(.failed) == 1)
        _ = await engine.run()
        #expect(transport.downloads.count == 1)
        #expect(rig.incomingFiles.isEmpty)
    }

    @Test func anIgnoredFileIsRememberedSoItIsNotDownloadedAgain() async throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        let transport = FakeFilesTransport([.ignored(1)])
        let engine = rig.engine(transport)
        let first = await engine.run()
        #expect(first.ignored == 1)
        #expect(try rig.db.pulledMarkCount(.ignored) == 1)
        #expect(try rig.count("imported_files") == 0)
        let second = await engine.run()
        #expect(second.toFetch == 0)
        #expect(transport.downloads.count == 1)
    }

    @Test func anActivityKeepsItsFitByHashAndMeasuresAreNotKept() async throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        let activity = Item.activity(1)
        let items = [Item.wellness(2), activity, .ignored(3), .garbage(4)]
        let report = await rig.engine(FakeFilesTransport(items)).run()
        #expect(report.activitiesKept == 1)
        #expect(rig.keptFiles == ["\(activity.hash).fit"], "seule l'activité est gardée, nommée par son hash")
        #expect(rig.store.activityURL(hash: activity.hash) != nil)
        #expect(rig.store.activityURL(hash: items[0].hash) == nil)
        #expect(rig.incomingFiles.isEmpty, "rien ne reste en cours de réception")
        let kept = try Data(contentsOf: rig.store.activityURL(hash: activity.hash)!)
        #expect(kept == activity.bytes)
    }

    @Test func theActivityDetailIsFoundFromTheKeptFile() async throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        let activity = Item.activity(1)
        _ = await rig.engine(FakeFilesTransport([activity])).run()
        let id = try #require(try rig.db.activities(limit: 10, offset: 0).first?.id)
        let backend = RealLocalPulseBackend(db: rig.db, spool: rig.spool, pulledFiles: rig.store)

        // Fichier présent : le détail le relit (ici un `.fit` illisible → erreur, preuve qu'il est trouvé).
        try Data([1, 2, 3]).write(to: rig.store.activityURL(hash: activity.hash)!)
        await #expect(throws: (any Error).self) {
            _ = try await backend.handle(method: "GET", path: "api/activities/\(id)", query: [:], body: nil)
        }
        // Fichier absent : résumé seul, comme avant.
        rig.store.removeKept(hash: activity.hash)
        let summaryOnly = try await backend.handle(method: "GET", path: "api/activities/\(id)", query: [:], body: nil)
        #expect(!summaryOnly.isEmpty)
    }

    @Test func theSpoolJournalIsNeverTouched() async throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        let id = WatchFileID(fileType: GarminFileType.monitor.watchFileType, index: 1, name: "f1.fit")
        try rig.spool.recordAcquired(id, relativePath: "MONITOR/f1.fit", data: syntheticFit(fileType: 32, salt: 42))
        let journal = rig.root.appendingPathComponent("spool/journal.json")
        let before = try Data(contentsOf: journal)

        let items = [Item.wellness(1), .activity(2), .ignored(3), .garbage(4)]
        _ = await rig.engine(FakeFilesTransport(items)).run()

        rig.spool.refreshFromDisk()
        #expect(try Data(contentsOf: journal) == before)
        #expect(rig.spool.entries.count == 1)
        let entry = try #require(rig.spool.entries[id])
        #expect(entry.state == .acquired)
        #expect(!entry.pushedToPulse)
        #expect(entry.ingest == nil, "aucune preuve posée, aucune livraison, aucun archivage")
    }

    @Test func aMissingFileOnPulseIsSkippedWithoutBeingRecordedAsFailed() async throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        let items = [Item.wellness(1), .wellness(2), .wellness(3)]
        let transport = FakeFilesTransport(items)
        transport.setDownloadStatus(items[1].hash, 404)
        let engine = rig.engine(transport)
        let first = await engine.run()
        #expect(first.outcome == .completed)
        #expect(first.missing == 1)
        #expect(first.ingested == 2)
        #expect(try rig.db.pulledMarkCount() == 0, "pas d'échec définitif sur un 404")
        // Il revient sur Pulse : la passe suivante le prend.
        transport.setDownloadStatus(items[1].hash, 200)
        let second = await engine.run()
        #expect(second.ingested == 1)
    }

    @Test func staleIncomingFilesAreClearedAtTheStartOfAPass() async throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        try rig.store.prepare()
        try Data([1]).write(to: rig.store.incomingDir.appendingPathComponent("stale"))
        _ = await rig.engine(FakeFilesTransport([])).run()
        #expect(rig.incomingFiles.isEmpty)
    }

    @Test func screensAreRefreshedInGroupsNotPerFile() async throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        let refreshes = Counter()
        let clock = ClockBox()
        let transport = FakeFilesTransport((1...6).map { Item.wellness(UInt8($0)) })
        // Horloge figée : tout tient dans un intervalle, un seul rafraîchissement, à la fin.
        let report = await rig.engine(transport, refresh: { refreshes.increment() }, now: { clock.now }).run()
        #expect(report.ingested == 6)
        #expect(refreshes.count == 1)

        // Horloge qui avance de 20 s à chaque lecture, intervalle de 30 s : un
        // rafraîchissement périodique, jamais un par fichier.
        let rig2 = try Rig()
        defer { rig2.cleanup() }
        let periodic = Counter()
        let ticking = ClockBox(step: 20)
        let transport2 = FakeFilesTransport((11...16).map { Item.wellness(UInt8($0)) })
        _ = await rig2.engine(transport2, refresh: { periodic.increment() }, now: { ticking.now }, refreshInterval: 30).run()
        #expect(periodic.count >= 2)
        #expect(periodic.count < 6)
    }

    @Test func nothingIsRefreshedWhenNothingWasInserted() async throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        let refreshes = Counter()
        _ = await rig.engine(FakeFilesTransport([.ignored(1), .garbage(2)]), refresh: { refreshes.increment() }).run()
        #expect(refreshes.count == 0)
    }
}

// MARK: - Moteur : reprise, coupure, échecs de passe

struct PulseFilesPullResumeTests {
    @Test func anInterruptedPassResumesWithoutIngestingTwice() async throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        let items = (1...6).map { Item.wellness(UInt8($0)) }
        let transport = FakeFilesTransport(items)
        transport.failDownloadsAfter(2) // le réseau tombe au 3e téléchargement
        let engine = rig.engine(transport)

        let first = await engine.run()
        #expect(first.outcome == .networkOrServerFailure)
        #expect(first.ingested == 2)
        #expect(try rig.count("imported_files") == 2)

        transport.failDownloadsAfter(nil)
        let before = transport.downloads.count
        let second = await engine.run()
        #expect(second.outcome == .completed)
        #expect(second.ingested == 4)
        #expect(Array(transport.downloads.dropFirst(before)) == items.dropFirst(2).map(\.hash), "reprend là où elle en était, sans rien redemander")
        #expect(try rig.count("imported_files") == 6, "chaque fichier exactement une fois")
    }

    @Test func cancellingAPassStopsItCleanlyThenItResumes() async throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        let items = (1...4).map { Item.wellness(UInt8($0)) }
        let transport = FakeFilesTransport(items)
        transport.block([items[1].hash])
        let engine = rig.engine(transport)

        let task = Task { await engine.run() }
        #expect(await eventually { transport.blockedHits > 0 })
        task.cancel()
        let report = await task.value

        #expect(report.outcome == .interrupted)
        #expect(report.ingested == 1)
        #expect(rig.incomingFiles.isEmpty, "le fichier en cours de réception est supprimé")
        #expect(try rig.count("imported_files") == 1)

        transport.block([])
        let resumed = await engine.run()
        #expect(resumed.outcome == .completed)
        #expect(resumed.ingested == 3)
        #expect(try rig.count("imported_files") == 4)
    }

    @Test func aRefusedTokenAbortsThePassWithoutMarkingAnything() async throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        let transport = FakeFilesTransport([.wellness(1)])
        transport.setManifestStatus(401)
        let report = await rig.engine(transport).run()
        #expect(report.outcome == .unauthorized)
        #expect(transport.downloads.isEmpty)
    }

    @Test func aMissingManifestRouteIsNeitherAnErrorNorARetry() async throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        let transport = FakeFilesTransport([.wellness(1)])
        transport.setManifestStatus(404)
        let report = await rig.engine(transport).run()
        #expect(report.outcome == .routeMissing)
        #expect(transport.manifestCalls.count == 1)
    }

    @Test func serverErrorsAndUnreadableManifestsAreFailuresOfThePass() async throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        let transport = FakeFilesTransport([.wellness(1)])
        transport.setManifestStatus(500)
        #expect(await rig.engine(transport).run().outcome == .networkOrServerFailure)
        transport.setManifestStatus(400)
        #expect(await rig.engine(transport).run().outcome == .networkOrServerFailure)
        let download = FakeFilesTransport([.wellness(2)])
        download.setDownloadStatus(sha256(syntheticFit(fileType: 32, salt: 2)), 503)
        #expect(await rig.engine(download).run().outcome == .networkOrServerFailure)
    }

    @Test func aRefusedTokenOnADownloadAbortsThePass() async throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        let item = Item.wellness(1)
        let transport = FakeFilesTransport([item, .wellness(2)])
        transport.setDownloadStatus(item.hash, 401)
        let report = await rig.engine(transport).run()
        #expect(report.outcome == .unauthorized)
        #expect(transport.downloads.count == 1)
    }

    @Test func progressCountsDownAndEveryOutcomeCountsAsDone() async throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        let items = [Item.wellness(1), .garbage(2), .ignored(3)]
        let transport = FakeFilesTransport(items)
        transport.setDownloadStatus(items[2].hash, 404)
        let log = IntLog()
        _ = await rig.engine(transport).run(progress: { log.append($0) })
        #expect(log.values == [3, 2, 1, 0])
    }

    @Test func theDefaultSerializationUsesTheSharedIngestionGate() async throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        let items = [Item.wellness(1), .activity(2)]
        let engine = PulseFilesPullEngine(db: rig.db, transport: FakeFilesTransport(items), store: rig.store, refresh: {})
        let report = await engine.run()
        #expect(report.ingested == 2)
    }
}

// MARK: - Garde d'ingestion

struct PulseFilesPullGateTests {
    @Test func aRequestDroppedDuringAnInterleavedSectionIsReported() async {
        let gate = SerialPassGate()
        let (value, dropped) = await gate.runInterleaved { () -> Int in
            gate.request { }
            return 7
        }
        #expect(value == 7)
        #expect(dropped)
        #expect(gate.isIdle)
        let (_, none) = await gate.runInterleaved { 1 }
        #expect(!none)
    }

    @Test func anInterleavedSectionWaitsForARunningPass() async throws {
        let gate = SerialPassGate()
        let started = Counter()
        gate.request {
            started.increment()
            Thread.sleep(forTimeInterval: 0.1)
        }
        let seen = IntLog()
        _ = await gate.runInterleaved { seen.append(started.count) }
        #expect(seen.values == [1], "la section ne passe qu'après la fin de la passe qui tournait")
        #expect(await gate.waitUntilIdle())
    }
}

// MARK: - Service

private struct ServiceRig {
    let rig: Rig
    let transport: FakeFilesTransport
    let mode: PullModeBox
    let health = HealthLog()
    let reporter = RecordingWorkReporter()
    let timer = ManualWakeTimer()
    let service: PulseFilesPullService

    init(_ items: [Item], mode: StorageMode = .both, configured: Bool = true, engineAvailable: Bool = true) throws {
        let rig = try Rig()
        self.rig = rig
        let transport = FakeFilesTransport(items)
        self.transport = transport
        let box = PullModeBox(mode)
        self.mode = box
        let log = health
        let engine = rig.engine(transport)
        service = PulseFilesPullService(
            engineProvider: { engineAvailable ? engine : nil }, modeProvider: { box.mode },
            health: { log.record($0) }, reporter: reporter, retryTimer: timer)
        transport.setNotConfigured(!configured)
    }

    /// Au moins `n` passes ont commencé, plus aucune ne tourne.
    func settled(_ n: Int) async -> Bool {
        let idle = await service.isIdle
        return reporter.pullBeganCount >= n && reporter.pullRuns == 0 && idle
    }

    /// Demande une passe et attend sa fin (la `n`-ième).
    @discardableResult
    func pass(_ n: Int = 1) async -> Bool {
        service.requestPass()
        return await eventually { await settled(n) }
    }
}

struct PulseFilesPullServiceTests {
    @Test(arguments: [StorageMode.pulse, .phone])
    func noPassOutsideTheBothMode(mode: StorageMode) async throws {
        let rig = try ServiceRig([.wellness(1)], mode: mode)
        defer { rig.rig.cleanup() }
        rig.service.requestPass()
        try await Task.sleep(nanoseconds: 150_000_000)
        #expect(rig.transport.manifestCalls.isEmpty)
        #expect(rig.reporter.pullBeganCount == 0)
        #expect(!rig.timer.isArmed)
    }

    @Test func aPassInBothModeIngestsAndReportsHealthSuccess() async throws {
        let rig = try ServiceRig([.wellness(1), .activity(2)])
        defer { rig.rig.cleanup() }
        #expect(await rig.pass())
        #expect(rig.service.lastReport?.outcome == .completed)
        #expect(rig.service.lastReport?.ingested == 2)
        #expect(rig.health.events == [.succeeded])
        #expect(!rig.timer.isArmed)
        #expect(rig.reporter.pullProgressLog == [2, 1, 0])
    }

    @Test func aRefusedTokenFeedsTheHealthAndNeverLoops() async throws {
        let rig = try ServiceRig([.wellness(1)])
        defer { rig.rig.cleanup() }
        rig.transport.setManifestStatus(401)
        #expect(await rig.pass())
        #expect(rig.health.events == [.unauthorized])
        #expect(!rig.timer.isArmed, "pas de reprise automatique sur un 401")
        #expect(rig.transport.manifestCalls.count == 1)
        #expect(rig.reporter.pullRuns == 0)
    }

    @Test func aMissingManifestRouteMakesOneAttemptPerTriggerWithoutSignal() async throws {
        let rig = try ServiceRig([.wellness(1)])
        defer { rig.rig.cleanup() }
        rig.transport.setManifestStatus(404)
        #expect(await rig.pass())
        #expect(rig.health.events.isEmpty, "aucun signal d'erreur")
        #expect(!rig.timer.isArmed)
        #expect(rig.transport.manifestCalls.count == 1)
        // Un nouveau déclencheur = une nouvelle tentative, une seule.
        #expect(await rig.pass(2))
        #expect(rig.transport.manifestCalls.count == 2)
        #expect(!rig.timer.isArmed)
    }

    @Test func missingConfigurationIsNeverRetried() async throws {
        let rig = try ServiceRig([.wellness(1)], configured: false)
        defer { rig.rig.cleanup() }
        #expect(await rig.pass())
        #expect(rig.health.events.isEmpty)
        #expect(!rig.timer.isArmed)
        #expect(rig.reporter.pullRuns == 0)
    }

    @Test func aNetworkFailureIsRetriedWithGrowingDelaysThenResumes() async throws {
        let items = (1...4).map { Item.wellness(UInt8($0)) }
        let rig = try ServiceRig(items)
        defer { rig.rig.cleanup() }
        rig.transport.failDownloadsAfter(0) // hors-ligne dès le premier téléchargement
        #expect(await rig.pass())
        #expect(rig.timer.armedDelays == [15])
        #expect(rig.health.events.isEmpty, "le hors-ligne ne signale rien")
        #expect(rig.service.retryAttemptCount == 1)

        // La minuterie se déclenche : nouvel échec sans progrès, délai plus long.
        #expect(rig.timer.fire())
        #expect(await eventually { await rig.settled(2) })
        #expect(rig.timer.armedDelays == [15, 30])

        // Le réseau revient : la reprise termine, plus aucune minuterie.
        rig.transport.failDownloadsAfter(nil)
        #expect(rig.timer.fire())
        #expect(await eventually { await rig.settled(3) })
        #expect(rig.service.lastReport?.outcome == .completed)
        #expect(try rig.rig.count("imported_files") == 4)
        #expect(!rig.timer.isArmed)
        #expect(rig.service.retryAttemptCount == 0)
    }

    @Test func goingToTheBackgroundCancelsTheRetryAndForbidsNewPasses() async throws {
        let rig = try ServiceRig([.wellness(1)])
        defer { rig.rig.cleanup() }
        rig.transport.failDownloadsAfter(0)
        #expect(await rig.pass())
        #expect(rig.timer.isArmed)
        rig.service.setForeground(false)
        #expect(!rig.timer.isArmed)
        let calls = rig.transport.manifestCalls.count
        rig.timer.fireStale()
        rig.service.requestPass()
        try await Task.sleep(nanoseconds: 150_000_000)
        #expect(rig.transport.manifestCalls.count == calls, "rien ne démarre en arrière-plan")
    }

    @Test func goingToTheBackgroundInterruptsARunningPassAndTheForegroundResumesIt() async throws {
        let items = (1...3).map { Item.wellness(UInt8($0)) }
        let rig = try ServiceRig(items)
        defer { rig.rig.cleanup() }
        rig.transport.block([items[1].hash])
        rig.service.requestPass()
        #expect(await eventually { rig.transport.blockedHits > 0 })
        rig.service.setForeground(false)
        #expect(await eventually { await rig.settled(1) })
        #expect(rig.service.lastReport?.outcome == .interrupted)
        #expect(!rig.timer.isArmed, "une coupure ne programme aucune reprise")

        rig.transport.block([])
        rig.service.setForeground(true)
        #expect(await rig.pass(2))
        #expect(rig.service.lastReport?.outcome == .completed)
        #expect(try rig.rig.count("imported_files") == 3)
    }

    @Test func aStorageModeChangeInterruptsThePass() async throws {
        let items = (1...3).map { Item.wellness(UInt8($0)) }
        let rig = try ServiceRig(items)
        defer { rig.rig.cleanup() }
        rig.transport.block([items[0].hash])
        rig.service.requestPass()
        #expect(await eventually { rig.transport.blockedHits > 0 })
        rig.mode.mode = .phone
        rig.service.storageModeDidChange()
        #expect(await eventually { await rig.settled(1) })
        #expect(rig.service.lastReport?.outcome == .interrupted)
        #expect(try rig.rig.count("imported_files") == 0)
        #expect(!rig.timer.isArmed)
    }

    @Test func theActivityCounterFallsOnEveryExit() async throws {
        // Succès, 401, 404, 500, hors-ligne, non configuré, aucun moteur : jamais de compteur coincé.
        let cases: [(String, (ServiceRig) -> Void)] = [
            ("succès", { _ in }),
            ("401", { $0.transport.setManifestStatus(401) }),
            ("404", { $0.transport.setManifestStatus(404) }),
            ("500", { $0.transport.setManifestStatus(500) }),
            ("hors-ligne", { $0.transport.failDownloadsAfter(0) }),
            ("non configuré", { $0.transport.setNotConfigured(true) }),
        ]
        for (name, configure) in cases {
            let rig = try ServiceRig([.wellness(1)])
            defer { rig.rig.cleanup() }
            configure(rig)
            #expect(await rig.pass(), "\(name)")
            #expect(rig.reporter.pullRuns == 0, "\(name) : compteur retombé")
            #expect(rig.reporter.pullBeganCount == 1, "\(name)")
        }
        let noEngine = try ServiceRig([.wellness(1)], engineAvailable: false)
        defer { noEngine.rig.cleanup() }
        #expect(await noEngine.pass())
        #expect(noEngine.reporter.pullRuns == 0)
    }

    @Test func requestsDuringAPassDoNotStartAnotherOne() async throws {
        let items = (1...3).map { Item.wellness(UInt8($0)) }
        let rig = try ServiceRig(items)
        defer { rig.rig.cleanup() }
        rig.transport.setDelay(ms: 80)
        rig.service.requestPass()
        #expect(await eventually { rig.reporter.pullRuns == 1 })
        for _ in 0..<5 { rig.service.requestPass() }
        #expect(await eventually { await rig.settled(1) })
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(rig.reporter.pullBeganCount == 1, "jamais deux passes, pas de passe de rattrapage inutile")
    }

    @Test func exclusiveWorkInterruptsThePassAndRunsAlone() async throws {
        let items = (1...3).map { Item.wellness(UInt8($0)) }
        let rig = try ServiceRig(items)
        defer { rig.rig.cleanup() }
        rig.transport.block([items[0].hash])
        rig.service.requestPass()
        #expect(await eventually { rig.transport.blockedHits > 0 })

        let observedRunning = Counter()
        let reporter = rig.reporter
        await rig.service.runExclusively {
            if reporter.pullRuns > 0 { observedRunning.increment() }
        }
        #expect(observedRunning.count == 0, "aucune passe ne tourne pendant le travail exclusif")
        #expect(rig.service.lastReport?.outcome == .interrupted)
    }
}

// MARK: - Purge

struct PulseFilesPullPurgeTests {
    @Test func purgeErasesWhatWasPulledThenANewPassPullsItAgain() async throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        let items = [Item.wellness(1), .activity(2), .ignored(3), .garbage(4)]
        let transport = FakeFilesTransport(items)
        let engine = rig.engine(transport)
        _ = await engine.run()
        #expect(try rig.count("imported_files") == 1)
        #expect(try rig.count("activities") == 1)
        #expect(try rig.db.pulledMarkCount() == 2)
        #expect(rig.keptFiles.count == 1)
        try Data([1]).write(to: rig.store.incomingDir.appendingPathComponent("leftover"))

        let report = try LocalDataPurge.run(spool: rig.spool, db: rig.db, pulledFiles: rig.store)

        #expect(report.filesDeleted == 0)
        #expect(try rig.count("imported_files") == 0)
        #expect(try rig.count("activities") == 0)
        #expect(try rig.db.pulledMarkCount() == 0, "la table des fichiers écartés est vidée avec le reste")
        #expect(rig.keptFiles.isEmpty, "les `.fit` d'activité rapatriés sont effacés")
        #expect(rig.incomingFiles.isEmpty)

        let again = await engine.run()
        #expect(again.toFetch == 4, "un nouveau passage rapatrie de nouveau, échecs compris")
        #expect(again.ingested == 2)
        #expect(rig.keptFiles.count == 1)
        #expect(try rig.db.pulledMarkCount() == 2)
    }

    @Test func purgeOfAnEmptyRapatriementChangesNothingElse() throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        let report = try LocalDataPurge.run(spool: rig.spool, db: rig.db, pulledFiles: rig.store)
        #expect(report == LocalDataPurge.Report())
    }

    @Test func theMigrationIsAppendedAndTheTableIsCoveredByThePurgeScan() throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        #expect(LocalDb.migrations.count == 2)
        #expect(LocalDb.migrations.first == LocalDb.saisieSyncMigration, "les migrations existantes ne bougent pas")
        #expect(try LocalDb.schemaVersion(rig.db.db) == 2)
        var names: [String] = []
        try rig.db.db.run("SELECT name FROM sqlite_master WHERE type = 'table'") { r in if let n = r.text(0) { names.append(n) } }
        #expect(names.contains("pulse_pull_marks"), "la purge vide toutes les tables lues dans sqlite_master")
    }

    @Test func storageUsageCountsKeptActivitiesAndIgnoresIncoming() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pull-usage-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PulseFilesStore(root: root.appendingPathComponent("pulse-files"))
        try store.prepare()
        try Data(count: 400).write(to: store.activitiesDir.appendingPathComponent("a.fit"))
        try Data(count: 100).write(to: store.incomingDir.appendingPathComponent("transitoire"))
        let spool = root.appendingPathComponent("spool")
        let files = spool.appendingPathComponent("files/ACTIVITY")
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        try Data(count: 1000).write(to: files.appendingPathComponent("b.fit"))

        let usage = LocalStorageUsage.measure(
            spoolRoot: spool, databaseRoot: root.appendingPathComponent("absent"), pulledFilesRoot: store.root)
        #expect(usage.watchFileCount == 2)
        #expect(usage.watchFileBytes == 1400)
        #expect(usage.watchFileBytesByType == ["ACTIVITY": 1400])
        // Sans dossier rapatrié : mesure inchangée.
        let plain = LocalStorageUsage.measure(spoolRoot: spool, databaseRoot: root.appendingPathComponent("absent"))
        #expect(plain.watchFileCount == 1)
    }
}

// MARK: - Bannière

struct PulseFilesPullBannerTests {
    private func work(
        uploads: Int = 0, pull: Bool = false, pullRemaining: Int? = nil, ingest: Bool = false, exchange: Bool = false
    ) -> SyncWorkSnapshot {
        SyncWorkSnapshot(
            uploads: uploads, ingestRunning: ingest, ingestRemaining: 3, exchangeRunning: exchange,
            pullRunning: pull, pullRemaining: pullRemaining)
    }

    @Test func labelIsShortAndCounted() {
        #expect(SyncActivity.pulling(remaining: 12_000).label == "Récupération depuis Pulse · 12000 restants")
        #expect(SyncActivity.pulling(remaining: 1).label == "Récupération depuis Pulse · 1 restant")
        #expect(SyncActivity.pulling(remaining: nil).label == "Récupération depuis Pulse")
        #expect(SyncActivity.pulling(remaining: 0).label == "Récupération depuis Pulse")
    }

    @Test func priorityIsUploadThenPullThenIngestionThenExchange() {
        #expect(SyncActivity.fromWork(work(uploads: 2, pull: true, ingest: true, exchange: true), mode: .both) == .uploading(remaining: 2))
        #expect(SyncActivity.fromWork(work(pull: true, pullRemaining: 5, ingest: true, exchange: true), mode: .both) == .pulling(remaining: 5))
        #expect(SyncActivity.fromWork(work(ingest: true, exchange: true), mode: .both) == .ingesting(remaining: 3))
        #expect(SyncActivity.fromWork(work(exchange: true), mode: .both) == .exchanging)
    }

    @Test func theWatchSyncStillOutranksThePull() {
        #expect(SyncActivity.resolve(watch: .downloading(done: 1), work: .pulling(remaining: 9)) == .downloading(done: 1))
        #expect(SyncActivity.resolve(watch: .idle, work: .pulling(remaining: 9)) == .pulling(remaining: 9))
    }

    @Test(arguments: [StorageMode.pulse, .phone])
    func theRecoveryOnlyExistsInBothMode(mode: StorageMode) {
        #expect(SyncActivity.fromWork(work(pull: true, pullRemaining: 5), mode: mode) == .idle)
    }

    @MainActor
    @Test func theSharedStateCountsAndFallsToZero() {
        let sync = SyncWork(mode: { .both }, timer: ManualWakeTimer())
        sync.pullBegan()
        sync.pullProgress(remaining: 40)
        #expect(sync.snapshot(at: Date()).pullRunning)
        #expect(sync.snapshot(at: Date()).pullRemaining == 40)
        let before = sync.completions
        sync.pullEnded()
        #expect(!sync.snapshot(at: Date()).pullRunning)
        #expect(sync.snapshot(at: Date()).pullRemaining == nil)
        #expect(sync.completions == before + 1, "les tailles du Stockage se remesurent")
        sync.pullEnded() // fin sans début : ignorée
        #expect(sync.completions == before + 1)
        sync.pullProgress(remaining: 3) // progrès sans passe : ignoré
        #expect(sync.snapshot(at: Date()).pullRemaining == nil)
    }

    @MainActor
    @Test func aStuckPullCounterIsAbandonedAfterTheStaleDelay() {
        var clock = Date(timeIntervalSince1970: 1_900_000_000)
        let sync = SyncWork(mode: { .both }, now: { clock }, timer: ManualWakeTimer())
        sync.pullBegan()
        clock = clock.addingTimeInterval(SyncWork.staleAfter + 1)
        #expect(!sync.snapshot(at: clock).pullRunning)
    }

    @Test func theConfirmationSentenceForBothModeMentionsTheRecovery() {
        #expect(StorageMode.both.changeConfirmation.contains("récupère aussi ceux de Pulse"))
        #expect(StorageMode.both.changeConfirmation.contains("saisies sont échangées"))
    }
}
