//
//  SaisieRoutingTests.swift
//  allTests
//
//  Routage « Les deux » des saisies (`PulseAPIClient.routedBoth`, contrat §7) :
//  épinglage des écritures à `id`, déclenchement d'un échange, lecture locale tant
//  qu'il reste des changements non envoyés, absence d'échange en modes Pulse et
//  Téléphone. Serveur = `URLProtocol` factice, backend local et service d'échange
//  factices : aucun réseau.
//

import Testing
import Foundation
@testable import all

private let routeBaseURL = URL(string: "https://pulse.invalid")!

/// `URLProtocol` dédié à ce fichier (cf. `WakeStubURLProtocol`) : `handler` statique,
/// d'où la suite `.serialized`.
final class SaisieRouteURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private final class RecordingBackend: LocalPulseBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    func handle(method: String, path: String, query: [String: String], body: Data?) async throws -> Data {
        lock.lock(); recorded.append("\(method) \(path)"); lock.unlock()
        return Data("{\"ok\":true,\"from\":\"local\"}".utf8)
    }
    var calls: [String] { lock.lock(); defer { lock.unlock() }; return recorded }
}

private final class FakeSync: SaisieSyncing, @unchecked Sendable {
    private let lock = NSLock()
    var pending = false
    private var exchanges = 0
    private var checks = 0
    func requestExchange() { lock.lock(); exchanges += 1; lock.unlock() }
    func stillPendingAfterAttempt() async -> Bool { lock.lock(); defer { lock.unlock() }; checks += 1; return pending }
    var exchangeRequests: Int { lock.lock(); defer { lock.unlock() }; return exchanges }
    var pendingChecks: Int { lock.lock(); defer { lock.unlock() }; return checks }
}

private final class ServerLog: @unchecked Sendable {
    private let lock = NSLock()
    private var hits: [String] = []
    func add(_ s: String) { lock.lock(); hits.append(s); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return hits }
}

private struct Reply: Decodable { let ok: Bool; let from: String? }
private struct Body: Encodable { var name = "x"; var foodId: Int? }

private func makeClient(mode: StorageMode, sync: FakeSync, local: RecordingBackend) -> PulseAPIClient {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [SaisieRouteURLProtocol.self]
    return PulseAPIClient(
        session: URLSession(configuration: config), baseURLProvider: { routeBaseURL },
        localBackend: local, modeProvider: { mode }, saisieSync: sync)
}

/// Serveur joignable : consigne la requête et répond `{"ok":true,"from":"pulse"}`.
private func serverUp(_ log: ServerLog) {
    SaisieRouteURLProtocol.handler = { request in
        log.add("\(request.httpMethod ?? "") \(request.url?.path ?? "")")
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        return (response, Data("{\"ok\":true,\"from\":\"pulse\"}".utf8))
    }
}

/// Serveur injoignable : erreur de transport.
private func serverDown(_ log: ServerLog) {
    SaisieRouteURLProtocol.handler = { request in
        log.add("\(request.httpMethod ?? "") \(request.url?.path ?? "")")
        throw URLError(.notConnectedToInternet)
    }
}

// MARK: - Classement (pur)

struct SaisieRouteClassificationTests {
    @Test func readsAndWrites() {
        for path in ["api/nutrition/day/2026-10-01", "api/nutrition/frequent", "api/nutrition/foods", "api/weight",
                     "api/profile", "api/wake-schedule", "api/programme", "api/stats/tab-nutrition", "/api/nutrition/targets"] {
            #expect(SaisieRoute.isRead(method: "GET", path: path), "\(path)")
        }
        // Open Food Facts, activités, bien-être : pas des saisies.
        for path in ["api/nutrition/search", "api/nutrition/barcode/123", "api/activities", "api/wellness/day/2026-10-01", "api/programme/candidates"] {
            #expect(!SaisieRoute.isRead(method: "GET", path: path), "\(path)")
        }
        #expect(!SaisieRoute.isRead(method: "POST", path: "api/weight"))
        for (method, path) in [("POST", "api/nutrition/log"), ("PUT", "api/nutrition/log/4"), ("DELETE", "api/nutrition/log/4"),
                               ("POST", "api/nutrition/foods"), ("PUT", "api/nutrition/foods/9"), ("POST", "api/weight"),
                               ("DELETE", "api/weight/2026-10-01"), ("PUT", "api/profile"), ("PUT", "api/wake-schedule"),
                               ("POST", "api/programme/activate"), ("POST", "api/programme/session")] {
            #expect(SaisieRoute.isWrite(method: method, path: path), "\(method) \(path)")
        }
        #expect(!SaisieRoute.isWrite(method: "GET", path: "api/nutrition/log"))
        #expect(!SaisieRoute.isWrite(method: "POST", path: "api/ingest"))
        #expect(!SaisieRoute.isWrite(method: "POST", path: "api/auth/login"))
    }

    @Test func idCarryingWrites() {
        #expect(SaisieRoute.carriesLocalId(method: "PUT", path: "api/nutrition/log/12", body: nil))
        #expect(SaisieRoute.carriesLocalId(method: "DELETE", path: "api/nutrition/log/12", body: nil))
        #expect(SaisieRoute.carriesLocalId(method: "PUT", path: "api/nutrition/foods/3", body: nil))
        #expect(SaisieRoute.carriesLocalId(method: "POST", path: "api/nutrition/log", body: Data("{\"foodId\":7,\"date\":\"2026-10-01\"}".utf8)))
        #expect(!SaisieRoute.carriesLocalId(method: "POST", path: "api/nutrition/log", body: Data("{\"foodId\":null}".utf8)))
        #expect(!SaisieRoute.carriesLocalId(method: "POST", path: "api/nutrition/log", body: Data("{\"name\":\"x\"}".utf8)))
        #expect(!SaisieRoute.carriesLocalId(method: "POST", path: "api/nutrition/log", body: nil))
        #expect(!SaisieRoute.carriesLocalId(method: "POST", path: "api/nutrition/foods", body: Data("{\"foodId\":7}".utf8)))
        #expect(!SaisieRoute.carriesLocalId(method: "DELETE", path: "api/weight/2026-10-01", body: nil))
        #expect(!SaisieRoute.carriesLocalId(method: "PUT", path: "api/profile", body: nil))
    }
}

// MARK: - Routage « Les deux »

@Suite(.serialized)
struct SaisieBothRoutingTests {
    @Test func idWriteGoesToPulseWhenTheLastReadCameFromPulse() async throws {
        let log = ServerLog(); let sync = FakeSync(); let local = RecordingBackend()
        let client = makeClient(mode: .both, sync: sync, local: local)
        serverUp(log)
        let _: Reply = try await client.get("api/nutrition/day/2026-10-01")
        let _: Reply = try await client.put("api/nutrition/log/5", body: Body())
        #expect(log.all == ["GET /api/nutrition/day/2026-10-01", "PUT /api/nutrition/log/5"])
        #expect(local.calls.isEmpty)
        #expect(sync.exchangeRequests == 1)
    }

    @Test func idWriteFailsExplicitlyWhenPulseIsPinnedButUnreachable() async throws {
        let log = ServerLog(); let sync = FakeSync(); let local = RecordingBackend()
        let client = makeClient(mode: .both, sync: sync, local: local)
        serverUp(log)
        let _: Reply = try await client.get("api/nutrition/day/2026-10-01")
        serverDown(log)
        await #expect(throws: PulseAPIError.self) {
            try await client.delete("api/nutrition/log/5")
        }
        // Jamais de repli local sur un `id` étranger, aucun échange déclenché.
        #expect(local.calls.isEmpty)
        #expect(sync.exchangeRequests == 0)
    }

    @Test func idWriteGoesLocalWhenTheLastReadWasServedLocally() async throws {
        let log = ServerLog(); let sync = FakeSync(); let local = RecordingBackend()
        let client = makeClient(mode: .both, sync: sync, local: local)
        serverDown(log)
        let read: Reply = try await client.get("api/nutrition/day/2026-10-01")
        #expect(read.from == "local")
        // Pulse revient, mais l'`id` vient de la base locale : on y reste.
        serverUp(log)
        let before = log.all.count
        let _: Reply = try await client.put("api/nutrition/log/5", body: Body())
        #expect(log.all.count == before)
        #expect(local.calls == ["GET api/nutrition/day/2026-10-01", "PUT api/nutrition/log/5"])
        #expect(sync.exchangeRequests == 1)
    }

    @Test func withoutAnyReadAnIdWriteAssumesPulseAndFailsWhenItIsDown() async throws {
        let log = ServerLog(); let sync = FakeSync(); let local = RecordingBackend()
        let client = makeClient(mode: .both, sync: sync, local: local)
        serverDown(log)
        await #expect(throws: PulseAPIError.self) { try await client.delete("api/nutrition/log/3") }
        #expect(local.calls.isEmpty)
    }

    @Test func logWithFoodIdIsPinnedLikeAnIdRoute() async throws {
        let log = ServerLog(); let sync = FakeSync(); let local = RecordingBackend()
        let client = makeClient(mode: .both, sync: sync, local: local)
        serverUp(log)
        let _: Reply = try await client.get("api/nutrition/foods")
        serverDown(log)
        await #expect(throws: PulseAPIError.self) {
            let _: Reply = try await client.post("api/nutrition/log", body: Body(foodId: 7))
        }
        #expect(local.calls.isEmpty)
        // Sans `foodId` : repli local habituel.
        let reply: Reply = try await client.post("api/nutrition/log", body: Body())
        #expect(reply.from == "local")
        #expect(sync.exchangeRequests == 1)
    }

    @Test func writesWithoutIdKeepPulseFirstThenLocalFallbackAndAlwaysRequestAnExchange() async throws {
        let log = ServerLog(); let sync = FakeSync(); let local = RecordingBackend()
        let client = makeClient(mode: .both, sync: sync, local: local)
        serverUp(log)
        let viaPulse: Reply = try await client.post("api/weight", body: Body())
        #expect(viaPulse.from == "pulse")
        #expect(sync.exchangeRequests == 1)
        serverDown(log)
        let viaLocal: Reply = try await client.post("api/weight", body: Body())
        #expect(viaLocal.from == "local")
        #expect(sync.exchangeRequests == 2)
    }

    @Test func httpErrorsStillSurfaceWithoutFallbackNorExchange() async throws {
        let sync = FakeSync(); let local = RecordingBackend()
        let client = makeClient(mode: .both, sync: sync, local: local)
        SaisieRouteURLProtocol.handler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: "HTTP/1.1", headerFields: nil)!, Data())
        }
        await #expect(throws: PulseAPIError.self) { let _: Reply = try await client.post("api/weight", body: Body()) }
        #expect(local.calls.isEmpty)
        #expect(sync.exchangeRequests == 0)
    }

    @Test func readsAreServedLocallyWhileLocalChangesRemainUnsent() async throws {
        let log = ServerLog(); let sync = FakeSync(); let local = RecordingBackend()
        let client = makeClient(mode: .both, sync: sync, local: local)
        serverUp(log)
        sync.pending = true
        let reply: Reply = try await client.get("api/nutrition/day/2026-10-01")
        #expect(reply.from == "local")
        #expect(log.all.isEmpty)
        #expect(sync.pendingChecks == 1)

        sync.pending = false
        let after: Reply = try await client.get("api/nutrition/day/2026-10-01")
        #expect(after.from == "pulse")
    }

    @Test func nonSaisieReadsNeverConsultTheExchange() async throws {
        let log = ServerLog(); let sync = FakeSync(); let local = RecordingBackend()
        let client = makeClient(mode: .both, sync: sync, local: local)
        serverUp(log)
        sync.pending = true
        let _: Reply = try await client.get("api/wellness/day/2026-10-01")
        let _: Reply = try await client.get("api/nutrition/search", query: ["q": "pain"])
        #expect(sync.pendingChecks == 0)
        #expect(local.calls.isEmpty)
    }

    @Test(arguments: [StorageMode.pulse, .phone])
    func noExchangeNorPendingCheckOutsideBothMode(mode: StorageMode) async throws {
        let log = ServerLog(); let sync = FakeSync(); let local = RecordingBackend()
        let client = makeClient(mode: mode, sync: sync, local: local)
        serverUp(log)
        sync.pending = true
        let _: Reply = try await client.get("api/nutrition/day/2026-10-01")
        let _: Reply = try await client.post("api/weight", body: Body())
        let _: Reply = try await client.put("api/nutrition/log/5", body: Body())
        #expect(sync.exchangeRequests == 0)
        #expect(sync.pendingChecks == 0)
        // Le mode décide seul de la base servie, comme avant.
        #expect(mode == .phone ? log.all.isEmpty : local.calls.isEmpty)
    }
}
