//
//  SaisieSyncEngineTests.swift
//  allTests
//
//  Moteur d'échange des saisies (`Sync/SaisieSync.swift`) : requête/réponse du
//  contrat §4, curseurs mémorisés après succès seulement, drapeau `initial`,
//  lots, sérialisation des échanges, santé, convergence. Transports FACTICES :
//  aucun réseau, aucune base réelle.
//

import Testing
import Foundation
@testable import all

// MARK: - Doubles

private struct SentRequest: Decodable {
    var since: Int
    var initial: Bool
    var changes: [SaisieChange]
}

private struct WireResponse: Encodable {
    var cursor: Int
    var applied = 0
    var skipped = 0
    var changes: [SaisieChange] = []
}

private func ok(_ response: WireResponse) -> SaisieSyncHTTPResponse {
    SaisieSyncHTTPResponse(status: 200, body: (try? JSONEncoder().encode(response)) ?? Data())
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    private var peak = 0
    func increment() { lock.lock(); value += 1; lock.unlock() }
    func enter() { lock.lock(); value += 1; peak = max(peak, value); lock.unlock() }
    func leave() { lock.lock(); value -= 1; lock.unlock() }
    var current: Int { lock.lock(); defer { lock.unlock() }; return value }
    var maxConcurrent: Int { lock.lock(); defer { lock.unlock() }; return peak }
}

/// Transport factice : consigne chaque requête (décodée) et répond par `handler`.
private final class FakeTransport: SaisieSyncTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var bodies: [Data] = []
    var handler: @Sendable (Int, SentRequest) throws -> SaisieSyncHTTPResponse

    init(handler: @escaping @Sendable (Int, SentRequest) throws -> SaisieSyncHTTPResponse = { _, _ in ok(WireResponse(cursor: 1)) }) {
        self.handler = handler
    }

    var rawBodies: [Data] { lock.lock(); defer { lock.unlock() }; return bodies }
    var requests: [SentRequest] { rawBodies.map { try! JSONDecoder().decode(SentRequest.self, from: $0) } }

    func post(_ body: Data) async throws -> SaisieSyncHTTPResponse {
        lock.lock()
        bodies.append(body)
        let index = bodies.count - 1
        lock.unlock()
        return try handler(index, try JSONDecoder().decode(SentRequest.self, from: body))
    }
}

private func tempPath() -> String {
    FileManager.default.temporaryDirectory.appendingPathComponent("saisie-engine-tests-\(UUID().uuidString).sqlite").path
}

private func makeDb() throws -> LocalDb { try LocalDb(path: tempPath()) }

/// Base vide de semis et de journal — pour des scénarios lisibles.
private func makeBareDb() throws -> LocalDb {
    let db = try makeDb()
    try db.db.run("DELETE FROM foods")
    try db.db.run("DELETE FROM saisie_changes")
    return db
}

private func change(_ resource: String, _ key: String, at: Int, deleted: Bool = false, _ data: [String: SaisieJSON]? = nil) -> SaisieChange {
    SaisieChange(resource: resource, key: key, updatedAt: at, deleted: deleted, data: deleted ? nil : data)
}

private func waitUntil(timeout: TimeInterval = 30, _ condition: @escaping () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return await condition()
}

// MARK: - Requête

struct SaisieSyncWireTests {
    @Test func requestTargetsTheSyncRouteWithTheIngestToken() throws {
        let request = SaisieSyncWire.makeRequest(baseURL: URL(string: "https://pulse.invalid")!, token: "jeton-test", body: Data("{}".utf8))
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://pulse.invalid/api/saisies/sync")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer jeton-test")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.httpBody == Data("{}".utf8))
    }

    @Test func bodyUsesTheContractShapeWithStrictTypes() async throws {
        let db = try makeBareDb()
        try db.upsertWeight(date: "2026-10-01", kg: 72.4)
        try db.deleteWeight(date: "2026-10-02")
        let transport = FakeTransport()
        _ = try await SaisieSyncEngine(db: db, transport: transport).exchange()

        let body = try #require(transport.rawBodies.first)
        let object = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(object["since"] as? Int == 0)
        #expect(object["initial"] as? Bool == true)
        let changes = try #require(object["changes"] as? [[String: Any]])
        #expect(changes.count == 1)
        let weight = changes[0]
        #expect(weight["resource"] as? String == "weight")
        #expect(weight["key"] as? String == "2026-10-01")
        #expect(weight["deleted"] as? Bool == false)
        #expect(weight["updatedAt"] is Int)
        #expect((weight["data"] as? [String: Any])?["kg"] as? Double == 72.4)
    }

    @Test func emptyChangesStillSendTheArray() async throws {
        let transport = FakeTransport()
        _ = try await SaisieSyncEngine(db: try makeBareDb(), transport: transport).exchange()
        let body = try #require(transport.rawBodies.first)
        let object = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect((object["changes"] as? [Any])?.isEmpty == true)
    }
}

// MARK: - Moteur

struct SaisieSyncEngineTests {
    @Test func firstExchangeSendsEverythingAsInitialAndRemembersTheState() async throws {
        let db = try makeBareDb()
        try db.upsertWeight(date: "2026-10-01", kg: 72)
        try db.setSetting(key: "sex", value: "male")
        let transport = FakeTransport { _, _ in ok(WireResponse(cursor: 412)) }
        let engine = SaisieSyncEngine(db: db, transport: transport)

        let report = try await engine.exchange()
        #expect(report.sent == 2 && report.batches == 1 && report.applied == 0)
        let first = try #require(transport.requests.first)
        #expect(first.since == 0 && first.initial)
        #expect(Set(first.changes.map(\.resource)) == ["weight", "setting"])

        let state = try db.saisieSyncState()
        #expect(state.cursor == 412 && state.initialDone)
        #expect(state.ackedRev == 2)
        #expect(!engine.hasPendingChanges())

        // Deuxième échange : incrémental, `since` = curseur mémorisé, plus `initial`.
        try db.upsertWeight(date: "2026-10-02", kg: 73)
        _ = try await engine.exchange()
        let second = try #require(transport.requests.last)
        #expect(second.since == 412 && !second.initial)
        #expect(second.changes.map(\.key) == ["2026-10-02"])
    }

    @Test(arguments: [
        ("transport", 0), ("401", 401), ("400", 400), ("413", 413), ("500", 500), ("illisible", 200),
    ] as [(String, Int)])
    func failuresLeaveTheStateUntouched(kind: String, status: Int) async throws {
        let db = try makeBareDb()
        try db.upsertWeight(date: "2026-10-01", kg: 72)
        let transport = FakeTransport { _, _ in
            if kind == "transport" { throw SaisieSyncError.transport(URLError(.notConnectedToInternet)) }
            return SaisieSyncHTTPResponse(status: status, body: Data(kind == "illisible" ? "pas du json".utf8 : "{}".utf8))
        }
        let engine = SaisieSyncEngine(db: db, transport: transport)
        let before = try db.saisieSyncState()

        do {
            _ = try await engine.exchange()
            Issue.record("devait échouer (\(kind))")
        } catch let error as SaisieSyncError {
            switch (kind, error) {
            case ("transport", .transport), ("401", .unauthorized), ("illisible", .invalidResponse): break
            case ("400", .http(400)), ("413", .http(413)), ("500", .http(500)): break
            default: Issue.record("erreur inattendue \(error) pour \(kind)")
            }
        }
        #expect(try db.saisieSyncState() == before)
        #expect(engine.hasPendingChanges())
        // Rien n'est perdu : le prochain échange renvoie le même changement, toujours `initial`.
        let retry = FakeTransport()
        _ = try await SaisieSyncEngine(db: db, transport: retry).exchange()
        #expect(retry.requests.first?.initial == true)
        #expect(retry.requests.first?.changes.map(\.key) == ["2026-10-01"])
    }

    @Test func aResponseThatCannotBeAppliedStoresNoCursor() async throws {
        let db = try makeBareDb()
        try db.db.run("DROP TABLE programme_plan")
        let bad = change("programme", "p9", at: 10, [
            "kind": .string("training"), "startedOn": .string("2026-10-05"), "active": .bool(true), "days": .null, "plan": .array([]),
        ])
        let transport = FakeTransport { _, _ in ok(WireResponse(cursor: 77, changes: [bad])) }
        await #expect(throws: (any Error).self) { _ = try await SaisieSyncEngine(db: db, transport: transport).exchange() }
        let state = try db.saisieSyncState()
        #expect(state.cursor == 0 && !state.initialDone)
    }

    @Test func splitsLargeJournalsInBatchesAndKeepsInitialUntilTheLast() async throws {
        let db = try makeDb()   // semis : plus de 50 aliments
        let total = try db.collectSaisieChanges(afterRev: 0, limit: 100_000).changes.count
        let transport = FakeTransport { index, _ in ok(WireResponse(cursor: (index + 1) * 10)) }
        let engine = SaisieSyncEngine(db: db, transport: transport, batchSize: 40)

        let report = try await engine.exchange()
        let requests = transport.requests
        #expect(requests.count == (total + 39) / 40)
        #expect(report.batches == requests.count && report.sent == total)
        #expect(requests.allSatisfy { $0.changes.count <= 40 })
        #expect(requests.allSatisfy { $0.initial })
        #expect(requests.map(\.since) == (0..<requests.count).map { $0 * 10 })
        let keys = requests.flatMap(\.changes).map { "\($0.resource)|\($0.key)" }
        #expect(Set(keys).count == total)

        let state = try db.saisieSyncState()
        #expect(state.initialDone && state.cursor == requests.count * 10)
        #expect(!engine.hasPendingChanges())
        _ = try await engine.exchange()
        #expect(transport.requests.last?.initial == false)
        #expect(transport.requests.last?.changes.isEmpty == true)
    }

    @Test func appliesRemoteChangesAndReportsWhatChanged() async throws {
        let db = try makeBareDb()
        let remote = [
            change("weight", "2026-09-30", at: 100, ["kg": .double(70.5)]),
            change("setting", "wakeSchedule", at: 100, ["value": .string("{\"2\":390}")]),
        ]
        let transport = FakeTransport { _, _ in ok(WireResponse(cursor: 5, changes: remote)) }
        let report = try await SaisieSyncEngine(db: db, transport: transport).exchange()
        #expect(report.applied == 2 && report.skipped == 0)
        #expect(report.weightChanged && report.wakeScheduleChanged)
        #expect(report.wakeScheduleJSON == "{\"2\":390}")
        #expect(try db.settingValue(key: "wakeSchedule") == "{\"2\":390}")
        // Les lignes écrites par l'échange ne repartent pas en écho.
        #expect(try !db.hasPendingSaisieChanges())
    }

    @Test func aLocalEditMadeDuringTheExchangeIsKeptForTheNextOne() async throws {
        let db = try makeBareDb()
        try db.upsertWeight(date: "2026-10-01", kg: 72)
        let transport = FakeTransport { _, _ in
            try? db.upsertWeight(date: "2026-10-09", kg: 74)   // saisie pendant l'aller-retour
            return ok(WireResponse(cursor: 3))
        }
        let engine = SaisieSyncEngine(db: db, transport: transport)
        _ = try await engine.exchange()
        #expect(engine.hasPendingChanges())
        _ = try await engine.exchange()
        #expect(transport.requests.last?.changes.map(\.key) == ["2026-10-09"])
    }
}

// MARK: - Sérialisation des échanges

struct SaisieSyncCoordinatorTests {
    @Test func neverRunsTwoPassesInParallelAndMergesRequestsMadeDuringAPass() async throws {
        let counter = Counter()
        let passes = Counter()
        let coordinator = SaisieSyncCoordinator {
            counter.enter()
            passes.increment()
            try? await Task.sleep(nanoseconds: 60_000_000)
            counter.leave()
        }
        await coordinator.request()
        _ = await waitUntil { passes.current == 1 }
        for _ in 0..<10 { await coordinator.request() }   // pendant la passe
        _ = await waitUntil { await coordinator.isIdle }
        #expect(counter.maxConcurrent == 1)
        // Dix demandes pendant une passe : UNE passe de plus, pas dix.
        #expect(passes.current == 2)
    }

    @Test func requestAndWaitReturnsOnlyWhenThePassIsDone() async throws {
        let done = Counter()
        let coordinator = SaisieSyncCoordinator {
            try? await Task.sleep(nanoseconds: 40_000_000)
            done.increment()
        }
        async let a: Void = coordinator.requestAndWait()
        async let b: Void = coordinator.requestAndWait()
        _ = await (a, b)
        #expect(done.current >= 1)
        #expect(await coordinator.isIdle)
    }
}

// MARK: - Service : modes, santé, repli

private final class Events: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [SaisieSyncHealthEvent] = []
    private var remote = 0
    func add(_ e: SaisieSyncHealthEvent) { lock.lock(); items.append(e); lock.unlock() }
    func addRemote() { lock.lock(); remote += 1; lock.unlock() }
    var health: [SaisieSyncHealthEvent] { lock.lock(); defer { lock.unlock() }; return items }
    var remoteCount: Int { lock.lock(); defer { lock.unlock() }; return remote }
}

private func makeService(
    db: LocalDb, transport: SaisieSyncTransport, mode: StorageMode = .both, events: Events = Events(), now: @escaping @Sendable () -> Date = { Date() }
) -> SaisieSyncService {
    SaisieSyncService(
        engineProvider: { SaisieSyncEngine(db: db, transport: transport) },
        modeProvider: { mode },
        health: { events.add($0) },
        afterRemoteChanges: { _ in events.addRemote() },
        now: now)
}

struct SaisieSyncServiceTests {
    @Test(arguments: [StorageMode.pulse, .phone])
    func noExchangeInPulseOrPhoneMode(mode: StorageMode) async throws {
        let db = try makeBareDb()
        try db.upsertWeight(date: "2026-10-01", kg: 72)   // le journal s'alimente quand même
        let transport = FakeTransport()
        let service = makeService(db: db, transport: transport, mode: mode)
        service.requestExchange()
        await service.exchangeAndWait()
        let pending = await service.stillPendingAfterAttempt()
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(transport.rawBodies.isEmpty)
        #expect(!pending)
        #expect(try db.hasPendingSaisieChanges())
    }

    @Test func bothModeExchangesAndSignalsSuccess() async throws {
        let db = try makeBareDb()
        try db.upsertWeight(date: "2026-10-01", kg: 72)
        let transport = FakeTransport()
        let events = Events()
        let service = makeService(db: db, transport: transport, events: events)
        service.requestExchange()
        #expect(await waitUntil { transport.rawBodies.count == 1 })
        #expect(await waitUntil { events.health == [.succeeded] })
        #expect(await service.stillPendingAfterAttempt() == false)
    }

    @Test func unauthorizedAlimentsHealthAndTransportErrorsSignalNothing() async throws {
        let db = try makeBareDb()
        try db.upsertWeight(date: "2026-10-01", kg: 72)
        let events = Events()
        let unauthorized = FakeTransport { _, _ in SaisieSyncHTTPResponse(status: 401, body: Data()) }
        let service = makeService(db: db, transport: unauthorized, events: events)
        await service.exchangeAndWait()
        #expect(events.health == [.unauthorized])

        let offline = FakeTransport { _, _ in throw SaisieSyncError.transport(URLError(.notConnectedToInternet)) }
        let events2 = Events()
        let service2 = makeService(db: db, transport: offline, events: events2)
        await service2.exchangeAndWait()
        #expect(events2.health.isEmpty)

        // Erreurs 5xx / 400 : rien non plus.
        let server = FakeTransport { _, _ in SaisieSyncHTTPResponse(status: 500, body: Data()) }
        let events3 = Events()
        await makeService(db: db, transport: server, events: events3).exchangeAndWait()
        #expect(events3.health.isEmpty)
    }

    @Test func pendingReadAttemptsOneExchangeThenThrottlesAfterATransportFailure() async throws {
        let db = try makeBareDb()
        try db.upsertWeight(date: "2026-10-01", kg: 72)
        let offline = FakeTransport { _, _ in throw SaisieSyncError.transport(URLError(.timedOut)) }
        let clock = Clock()
        let service = makeService(db: db, transport: offline, now: { clock.now })

        #expect(await service.stillPendingAfterAttempt() == true)
        #expect(offline.rawBodies.count == 1)
        // Dans le délai : on ne rattend pas le réseau, on sert en local.
        #expect(await service.stillPendingAfterAttempt() == true)
        #expect(offline.rawBodies.count == 1)
        // Délai écoulé : nouvelle tentative.
        clock.advance(SaisieSyncService.retryDelay + 1)
        #expect(await service.stillPendingAfterAttempt() == true)
        #expect(offline.rawBodies.count == 2)
    }

    @Test func nothingPendingMeansNoNetworkAtAll() async throws {
        let db = try makeBareDb()
        let transport = FakeTransport()
        let service = makeService(db: db, transport: transport)
        #expect(await service.stillPendingAfterAttempt() == false)
        #expect(transport.rawBodies.isEmpty)
    }

    @Test func remoteChangesTriggerOneRefreshAndResyncTheWeightProfile() async throws {
        let db = try makeBareDb()
        let remote = [change("weight", "2026-09-30", at: 100, ["kg": .double(70.5)])]
        let transport = FakeTransport { _, _ in ok(WireResponse(cursor: 5, changes: remote)) }
        let events = Events()
        let service = makeService(db: db, transport: transport, events: events)
        await service.exchangeAndWait()
        #expect(events.remoteCount == 1)
        #expect(try db.settingValue(key: "weightKg") == "70.5")
        // Un échange sans rien d'appliqué ne rafraîchit pas.
        let quiet = Events()
        await makeService(db: db, transport: FakeTransport(), events: quiet).exchangeAndWait()
        #expect(quiet.remoteCount == 0)
    }
}

private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 1_790_000_000)
    var now: Date { lock.lock(); defer { lock.unlock() }; return date }
    func advance(_ seconds: TimeInterval) { lock.lock(); date.addTimeInterval(seconds); lock.unlock() }
}

// MARK: - Santé

@MainActor
struct SaisieSyncHealthTests {
    private func makeHealth() -> PulseUploadHealth {
        PulseUploadHealth(defaults: UserDefaults(suiteName: "saisie-health-\(UUID().uuidString)")!)
    }

    @Test func unauthorizedRaisesTheTokenIssueAndSuccessLiftsIt() {
        let health = makeHealth()
        SaisieSyncHealth.apply(.unauthorized, to: health)
        #expect(health.issue == .invalidToken)
        SaisieSyncHealth.apply(.succeeded, to: health)
        #expect(health.issue == nil)
    }

    @Test func successDoesNotLiftTheWrongSourceProblem() {
        let health = makeHealth()
        health.record(.keepRetryLater)
        SaisieSyncHealth.apply(.succeeded, to: health)
        #expect(health.issue == .wrongSource)
    }

    @Test func successWithoutProblemChangesNothing() {
        let health = makeHealth()
        SaisieSyncHealth.apply(.succeeded, to: health)
        #expect(health.issue == nil)
    }
}

// MARK: - Convergence

/// Serveur factice : une seconde base locale jouant le rôle de Pulse (même journal,
/// même règle d'application), qui — comme le vrai — recalcule le profil après un
/// poids appliqué et ne renvoie pas les clés que la requête vient d'appliquer.
private final class FakeServer: SaisieSyncTransport, @unchecked Sendable {
    let db: LocalDb
    private(set) var exchanges = 0
    private(set) var lastReceived: [SaisieChange] = []

    init(db: LocalDb) { self.db = db }

    func post(_ body: Data) async throws -> SaisieSyncHTTPResponse {
        let request = try JSONDecoder().decode(SentRequest.self, from: body)
        exchanges += 1
        lastReceived = request.changes
        let result = try db.applySaisieResponse(cursor: 0, changes: request.changes, sentMaxRev: nil, markInitialDone: false)
        if result.weightChanged { try db.syncWeightProfile() }
        // « Hors les clés que cette requête vient d'appliquer » : une ligne ignorée
        // (plus ancienne que la locale) reste, elle, dans la réponse.
        var stamps: [String: Int] = [:]
        try db.db.run("SELECT resource, key, updated_at FROM saisie_changes") { r in
            stamps["\(r.text(0) ?? "")|\(r.text(1) ?? "")"] = Int(r.double(2) ?? 0)
        }
        let applied = Set(request.changes.filter { stamps["\($0.resource)|\($0.key)"] == $0.updatedAt }.map { "\($0.resource)|\($0.key)" })
        let outgoing = try db.collectSaisieChanges(afterRev: request.since, limit: 100_000).changes
            .filter { !applied.contains("\($0.resource)|\($0.key)") }
        let cursor = try db.db.max("saisie_changes", "rev")
        return ok(WireResponse(cursor: cursor, changes: outgoing))
    }
}

private extension SQLiteDatabase {
    func max(_ table: String, _ column: String) throws -> Int {
        var value = 0
        try run("SELECT COALESCE(MAX(\(column)), 0) FROM \(table)") { r in value = Int(r.double(0) ?? 0) }
        return value
    }
}

struct SaisieSyncConvergenceTests {
    @Test func successiveExchangesWithoutRealChangeSendNothingMore() async throws {
        let phone = try makeBareDb()
        let server = try makeBareDb()
        let fake = FakeServer(db: server)
        let service = makeService(db: phone, transport: fake)

        // Saisies du téléphone, dont un poids (profil dérivé des deux côtés).
        try phone.upsertWeight(date: "2026-10-01", kg: 72.4)
        try phone.syncWeightProfile()
        try phone.setSetting(key: "wakeSchedule", value: "{\"1\":450}")
        // Saisie côté serveur (front web), postérieure à celle du téléphone (pas d'égalité
        // à la milliseconde : à égalité le téléphone gagne, ce qui coûterait un échange de plus).
        try await Task.sleep(nanoseconds: 20_000_000)
        try server.upsertWeight(date: "2026-10-02", kg: 73.1)
        try server.syncWeightProfile()

        await service.exchangeAndWait()
        #expect(fake.lastReceived.count == 3)   // poids, profil (weightKg), réveil

        // Les deux bases ont convergé.
        for db in [phone, server] {
            #expect(try db.settingValue(key: "wakeSchedule") == "{\"1\":450}")
            #expect(try db.weightList(days: 3660).entries == 2)
        }
        #expect(try phone.settingValue(key: "weightKg") == server.settingValue(key: "weightKg"))

        // Échanges suivants, rien de réel n'a changé : plus rien à envoyer, plus rien à appliquer.
        for _ in 0..<3 {
            #expect(try !phone.hasPendingSaisieChanges())
            await service.exchangeAndWait()
            #expect(fake.lastReceived.isEmpty)
        }
        #expect(fake.exchanges == 4)
    }

    @Test func aRemoteWeightDoesNotMakeThePhoneEchoItsDerivedProfileForever() async throws {
        let phone = try makeBareDb()
        let server = try makeBareDb()
        let fake = FakeServer(db: server)
        let service = makeService(db: phone, transport: fake)
        await service.exchangeAndWait()   // échange initial à vide

        try server.upsertWeight(date: "2026-10-05", kg: 71.0)
        try server.syncWeightProfile()
        await service.exchangeAndWait()
        #expect(try phone.settingValue(key: "weightKg") == "71")

        // Au plus un échange de rattrapage (profil dérivé localement), puis le silence.
        await service.exchangeAndWait()
        await service.exchangeAndWait()
        #expect(fake.lastReceived.isEmpty)
        #expect(try !phone.hasPendingSaisieChanges())
    }
}

// MARK: - Cache de l'horaire de réveil

@MainActor
struct WakeScheduleAdoptionTests {
    private func makeStore() -> WakeScheduleStore {
        let client = PulseAPIClient(
            session: URLSession(configuration: .ephemeral), baseURLProvider: { nil },
            localBackend: StubLocalPulseBackend(), modeProvider: { .pulse })
        return WakeScheduleStore(defaults: UserDefaults(suiteName: "wake-adopt-\(UUID().uuidString)")!, client: client)
    }

    @Test func adoptsTheSyncedScheduleIncludingAnEmptyOne() {
        let store = makeStore()
        store.adoptSynced(json: "{\"1\":420,\"5\":390,\"9\":10}")
        #expect(store.minutesByWeekday == [1: 420, 5: 390])
        // Un effacement fait de l'autre côté se propage (sans repousser le cache).
        store.adoptSynced(json: "{}")
        #expect(store.minutesByWeekday.isEmpty)
        store.adoptSynced(json: "{\"2\":400}")
        store.adoptSynced(json: nil)
        #expect(store.minutesByWeekday.isEmpty)
    }
}
