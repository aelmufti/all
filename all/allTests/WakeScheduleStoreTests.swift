//
//  WakeScheduleStoreTests.swift
//  allTests
//
//  Valide `WakeScheduleStore.load()`/`set()` contre un `PulseAPIClient` stubé
//  (même principe que `PulseSocleTests.swift` : `URLProtocol` d'interception
//  dédié, aucune requête ne quitte jamais le process). Un `StubURLProtocol`
//  existe déjà dans `PulseSocleTests.swift` mais reste `private` à ce
//  fichier — on en définit ici un second, nommé différemment, suivant
//  exactement le même patron.
//

import Testing
import Foundation
@testable import all

private let wakeTestBaseURL = URL(string: "https://pulse.invalid")! // TLD réservé IANA, ne résout jamais.

/// `URLProtocol` d'interception dédié à ce fichier — même rôle que
/// `StubURLProtocol` (`PulseSocleTests.swift`), nom distinct pour éviter toute
/// collision entre fichiers de test.
final class WakeStubURLProtocol: URLProtocol {
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

private func makeWakeStubSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [WakeStubURLProtocol.self]
    return URLSession(configuration: config)
}

private func wakeStubbedClient() -> PulseAPIClient {
    PulseAPIClient(session: makeWakeStubSession(), baseURLProvider: { wakeTestBaseURL })
}

private func wakeJsonResponse(_ url: URL, status: Int, body: Data) -> (HTTPURLResponse, Data) {
    let response = HTTPURLResponse(
        url: url,
        statusCode: status,
        httpVersion: "HTTP/1.1",
        headerFields: ["Content-Type": "application/json"]
    )!
    return (response, body)
}

/// Une seule suite `.serialized` : `WakeStubURLProtocol.handler` est un état
/// statique partagé, même raison que `PulseSocleTests`.
@Suite(.serialized)
@MainActor
struct WakeScheduleStoreTests {
    private func freshDefaults() -> UserDefaults {
        let suiteName = "wake-schedule-store-tests-\(UUID().uuidString)"
        return UserDefaults(suiteName: suiteName)!
    }

    @Test func loadAdoptsNonEmptyServerMap() async throws {
        let store = WakeScheduleStore(defaults: freshDefaults(), client: wakeStubbedClient())
        WakeStubURLProtocol.handler = { request in
            #expect(request.httpMethod == "GET")
            let body = Data(#"{"schedule":{"1":420,"2":405}}"#.utf8)
            return wakeJsonResponse(request.url!, status: 200, body: body)
        }

        await store.load()

        #expect(store.minutes(for: 1) == 420)
        #expect(store.minutes(for: 2) == 405)
    }

    /// Migration / anti-écrasement : le serveur renvoie un planning vide alors
    /// que le cache local a déjà des réveils réglés — `load()` ne doit PAS
    /// adopter le vide (cf. commentaire dédié de `WakeScheduleStore.load()`).
    @Test func loadWithEmptyServerAndNonEmptyCacheDoesNotWipeLocal() async throws {
        let store = WakeScheduleStore(defaults: freshDefaults(), client: wakeStubbedClient())
        // Pose un état local non vide via `set` AVANT le `load()` — `set`
        // pousse lui-même en tâche de fond (best-effort, avalé par le handler
        // ci-dessous qui répond toujours vide le temps de cette première
        // phase) donc on fixe le handler pour accepter n'importe quel PUT.
        WakeStubURLProtocol.handler = { request in
            wakeJsonResponse(request.url!, status: 200, body: Data(#"{"schedule":{}}"#.utf8))
        }
        store.set(minutes: 420, weekdays: [1])
        #expect(store.minutes(for: 1) == 420)

        // Le serveur renvoie un planning vide pour ce `load()` explicite.
        WakeStubURLProtocol.handler = { request in
            wakeJsonResponse(request.url!, status: 200, body: Data(#"{"schedule":{}}"#.utf8))
        }

        await store.load()

        #expect(store.minutes(for: 1) == 420, "le cache local non vide ne doit pas être effacé par un serveur vide")
    }

    @Test func setUpdatesInMemoryMapImmediately() async throws {
        let store = WakeScheduleStore(defaults: freshDefaults(), client: wakeStubbedClient())
        WakeStubURLProtocol.handler = { request in
            wakeJsonResponse(request.url!, status: 200, body: Data(#"{"schedule":{}}"#.utf8))
        }

        store.set(minutes: 390, weekdays: [3, 5])

        #expect(store.minutes(for: 3) == 390)
        #expect(store.minutes(for: 5) == 390)
    }

    /// Hors-ligne : `load()` ne jette jamais et garde le cache tel quel.
    @Test func loadIsBestEffortOnTransportError() async throws {
        let store = WakeScheduleStore(defaults: freshDefaults(), client: wakeStubbedClient())
        WakeStubURLProtocol.handler = { request in
            wakeJsonResponse(request.url!, status: 200, body: Data(#"{"schedule":{"1":420}}"#.utf8))
        }
        store.set(minutes: 420, weekdays: [1])

        WakeStubURLProtocol.handler = { _ in
            throw URLError(.notConnectedToInternet)
        }
        await store.load()

        #expect(store.minutes(for: 1) == 420, "le cache reste inchangé si le serveur est injoignable")
    }
}
