//
//  PulseSocleTests.swift
//  allTests
//
//  Tests du socle partagé Pulse (`PulseAPIClient`, `AuthStore`). Aucun réseau
//  réel : toutes les requêtes passent par `StubURLProtocol`, enregistré sur
//  une session éphémère dédiée à chaque test.
//
//  Important : ces tests n'écrivent **jamais** dans le singleton global
//  `PulseConfig.baseURL` (contrairement à ce qu'un premier jet faisait). Ce
//  singleton est aussi lu par `Sync/LiveHeartRatePush.swift` et ses propres
//  tests (`PulseLiveHrPusherTests`, hors périmètre — on n'y touche pas) ; or
//  Swift Testing exécute les différentes suites **en parallèle** par défaut
//  (`.serialized` ne protège qu'à l'intérieur d'une suite, pas entre suites).
//  Muter ce global depuis ici a provoqué en pratique une vraie course avec
//  `PulseLiveHrPusherTests` (un test voyait `baseURL` redevenu `nil` en plein
//  milieu de son exécution). D'où `baseURLProvider` sur `PulseAPIClient` :
//  une indirection injectable (par défaut `{ PulseConfig.baseURL }`, donc
//  aucun changement de comportement en prod) qui permet aux tests de fournir
//  une URL fixe sans jamais écrire dans l'état global partagé du process de
//  test.
//

import Testing
import Foundation
@testable import all

// MARK: - Stub réseau

private let testBaseURL = URL(string: "https://pulse.invalid")! // TLD réservé IANA, ne résout jamais.

/// `URLProtocol` d'interception : chaque test pose son propre `handler`
/// juste avant d'appeler le client, donc aucune requête ne quitte jamais le
/// process. `@Suite(.serialized)` (voir plus bas) évite toute course entre
/// les tests de ce fichier sur ce handler statique partagé — aucun autre
/// fichier de test ne référence `StubURLProtocol`, donc pas de course
/// possible avec une suite extérieure non plus.
final class StubURLProtocol: URLProtocol {
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

private func makeStubSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [StubURLProtocol.self]
    return URLSession(configuration: config)
}

/// Client stubé pointant sur `testBaseURL` — via `baseURLProvider`, jamais
/// via `PulseConfig.baseURL` (cf. en-tête du fichier).
private func stubbedClient(baseURL: URL? = testBaseURL) -> PulseAPIClient {
    PulseAPIClient(session: makeStubSession(), baseURLProvider: { baseURL })
}

// MARK: - Backend local factice (routage Stockage, incrément L0)

/// Backend local factice — enregistre chaque appel, ne touche jamais le
/// réseau ni le disque. Jamais `StubLocalPulseBackend` (celui-ci répond avec
/// un `Data` fixé ou jette l'erreur fixée à la construction) — sauf le test
/// dédié à `StubLocalPulseBackend` lui-même, plus bas.
private final class RecordingLocalPulseBackend: LocalPulseBackend {
    private(set) var calls: [(method: String, path: String, query: [String: String], body: Data?)] = []
    var responseData = Data("{}".utf8)

    func handle(method: String, path: String, query: [String: String], body: Data?) async throws -> Data {
        calls.append((method, path, query, body))
        return responseData
    }
}

/// Client stubé avec routage explicite (`modeProvider` fixé, jamais
/// `StorageModeStore.current` — même raison que `baseURLProvider`, cf.
/// en-tête du fichier).
private func routedClient(mode: StorageMode, localBackend: LocalPulseBackend, baseURL: URL? = testBaseURL) -> PulseAPIClient {
    PulseAPIClient(session: makeStubSession(), baseURLProvider: { baseURL }, localBackend: localBackend, modeProvider: { mode })
}

/// `URLSession` convertit parfois `httpBody` en `httpBodyStream` avant de le
/// remettre au `URLProtocol` (comportement interne connu, indépendant de ce
/// qu'on a posé sur la requête) — on gère les deux cas pour lire le corps
/// envoyé par `PulseAPIClient.post`/`put` depuis un test.
private func bodyData(from request: URLRequest) -> Data? {
    if let body = request.httpBody { return body }
    guard let stream = request.httpBodyStream else { return nil }
    stream.open()
    defer { stream.close() }
    var data = Data()
    let bufferSize = 4096
    var buffer = [UInt8](repeating: 0, count: bufferSize)
    while stream.hasBytesAvailable {
        let read = stream.read(&buffer, maxLength: bufferSize)
        if read <= 0 { break }
        data.append(buffer, count: read)
    }
    return data
}

private func jsonResponse(_ url: URL, status: Int, body: Data) -> (HTTPURLResponse, Data) {
    let response = HTTPURLResponse(
        url: url,
        statusCode: status,
        httpVersion: "HTTP/1.1",
        headerFields: ["Content-Type": "application/json"]
    )!
    return (response, body)
}

// MARK: - Fixtures

private struct HealthFixture: Decodable, Equatable {
    let restingHr: Int?
    let steps: Int
    let date: String
}

private let healthFixtureJSON = Data("""
{"restingHr": 52, "steps": 8342, "date": "2026-09-23"}
""".utf8)

// MARK: - Tests
//
// Un seul `@Suite(.serialized)` pour tout le fichier (plutôt que deux
// structs séparées `PulseAPIClient`/`AuthStore`) : Swift Testing traite
// chaque type comme une suite indépendante et peut paralléliser entre
// suites, or tous ces tests partagent `StubURLProtocol.handler` — les
// séparer aurait réintroduit une course entre eux.

@Suite(.serialized)
struct PulseSocleTests {

    @Test func getResolvesPathAgainstBaseURL() async throws {
        let client = stubbedClient()
        StubURLProtocol.handler = { request in
            #expect(request.url?.scheme == "https")
            #expect(request.url?.host == "pulse.invalid")
            #expect(request.url?.path == "/api/wellness/day/2026-09-23")
            #expect(request.httpMethod == "GET")
            return jsonResponse(request.url!, status: 200, body: healthFixtureJSON)
        }
        let fixture: HealthFixture = try await client.get("api/wellness/day/2026-09-23")
        #expect(fixture == HealthFixture(restingHr: 52, steps: 8342, date: "2026-09-23"))
    }

    @Test func getEncodesQueryItems() async throws {
        let client = stubbedClient()
        StubURLProtocol.handler = { request in
            let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
            let items = components?.queryItems ?? []
            #expect(items.contains(URLQueryItem(name: "limit", value: "10")))
            #expect(items.contains(URLQueryItem(name: "days", value: "30")))
            return jsonResponse(request.url!, status: 200, body: Data("[]".utf8))
        }
        let _: [Int] = try await client.get("api/wellness/days", query: ["limit": "10", "days": "30"])
    }

    @Test func decodesJSONFixture() async throws {
        let client = stubbedClient()
        StubURLProtocol.handler = { request in
            jsonResponse(request.url!, status: 200, body: healthFixtureJSON)
        }
        let fixture: HealthFixture = try await client.get("api/wellness/day/2026-09-23")
        #expect(fixture.steps == 8342)
        #expect(fixture.date == "2026-09-23")
        #expect(fixture.restingHr == 52)
    }

    @Test func unauthorizedMapsToDedicatedError() async throws {
        let client = stubbedClient()
        StubURLProtocol.handler = { request in
            jsonResponse(request.url!, status: 401, body: Data("{}".utf8))
        }
        do {
            let _: HealthFixture = try await client.get("api/auth/me")
            Issue.record("Devait jeter .unauthorized")
        } catch let error as PulseAPIError {
            guard case .unauthorized = error else {
                Issue.record("Attendu .unauthorized, obtenu \(error)")
                return
            }
        }
    }

    @Test func httpErrorCarriesStatusAndBody() async throws {
        let client = stubbedClient()
        let body = Data("Internal error".utf8)
        StubURLProtocol.handler = { request in
            jsonResponse(request.url!, status: 500, body: body)
        }
        do {
            let _: HealthFixture = try await client.get("api/wellness/day/2026-09-23")
            Issue.record("Devait jeter .http")
        } catch let error as PulseAPIError {
            guard case .http(let status, let receivedBody) = error else {
                Issue.record("Attendu .http, obtenu \(error)")
                return
            }
            #expect(status == 500)
            #expect(receivedBody == body)
        }
    }

    @Test func missingBaseURLThrowsNotConfigured() async throws {
        let client = stubbedClient(baseURL: nil)
        do {
            let _: HealthFixture = try await client.get("api/wellness/day/2026-09-23")
            Issue.record("Devait jeter .notConfigured")
        } catch let error as PulseAPIError {
            guard case .notConfigured = error else {
                Issue.record("Attendu .notConfigured, obtenu \(error)")
                return
            }
        }
    }

    @Test func postSendsJSONBody() async throws {
        let client = stubbedClient()
        struct LoginBody: Codable { let username: String; let password: String }
        struct LoginReply: Decodable, Equatable { let username: String }
        StubURLProtocol.handler = { request in
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
            let sent = try JSONDecoder().decode(LoginBody.self, from: bodyData(from: request) ?? Data())
            #expect(sent.username == "ali")
            return jsonResponse(request.url!, status: 200, body: Data(#"{"username":"ali"}"#.utf8))
        }
        let reply: LoginReply = try await client.post(
            "api/auth/login",
            body: LoginBody(username: "ali", password: "secret")
        )
        #expect(reply == LoginReply(username: "ali"))
    }

    @Test func deleteSucceedsOn2xxWithoutDecoding() async throws {
        let client = stubbedClient()
        StubURLProtocol.handler = { request in
            #expect(request.httpMethod == "DELETE")
            return jsonResponse(request.url!, status: 200, body: Data())
        }
        try await client.delete("api/activities/42")
    }

    // MARK: AuthStore

    @Test @MainActor func loginSetsUsernameOnSuccess() async throws {
        let store = AuthStore(client: stubbedClient())
        StubURLProtocol.handler = { request in
            jsonResponse(request.url!, status: 200, body: Data(#"{"username":"ali"}"#.utf8))
        }
        try await store.login(username: "ali", password: "secret")
        #expect(store.username == "ali")
    }

    @Test @MainActor func loginKeepsUsernameNilOnUnauthorized() async throws {
        let store = AuthStore(client: stubbedClient())
        StubURLProtocol.handler = { request in
            jsonResponse(request.url!, status: 401, body: Data("{}".utf8))
        }
        await #expect(throws: PulseAPIError.self) {
            try await store.login(username: "ali", password: "wrong")
        }
        #expect(store.username == nil)
    }

    @Test @MainActor func checkPopulatesUsernameWhenSessionValid() async throws {
        let store = AuthStore(client: stubbedClient())
        StubURLProtocol.handler = { request in
            jsonResponse(request.url!, status: 200, body: Data(#"{"username":"ali"}"#.utf8))
        }
        let ok = await store.check()
        #expect(ok)
        #expect(store.username == "ali")
    }

    @Test @MainActor func checkReturnsFalseWhenUnauthorized() async throws {
        let store = AuthStore(client: stubbedClient())
        StubURLProtocol.handler = { request in
            jsonResponse(request.url!, status: 401, body: Data("{}".utf8))
        }
        let ok = await store.check()
        #expect(!ok)
        #expect(store.username == nil)
    }

    @Test @MainActor func logoutClearsUsernameEvenIfRequestFails() async throws {
        let store = AuthStore(client: stubbedClient())
        StubURLProtocol.handler = { request in
            jsonResponse(request.url!, status: 200, body: Data(#"{"username":"ali"}"#.utf8))
        }
        try await store.login(username: "ali", password: "secret")
        #expect(store.username == "ali")

        StubURLProtocol.handler = { request in
            throw URLError(.notConnectedToInternet)
        }
        await store.logout()
        #expect(store.username == nil)
    }

    // MARK: - Routage Stockage (incrément L0, `docs/stockage-local.md`)

    @Test func phoneModeRoutesDirectlyToLocalBackendWithoutTouchingTheNetwork() async throws {
        let local = RecordingLocalPulseBackend()
        local.responseData = healthFixtureJSON
        let client = routedClient(mode: .phone, localBackend: local)
        StubURLProtocol.handler = { _ in
            Issue.record("Ne doit jamais toucher le réseau en mode Téléphone")
            throw URLError(.unsupportedURL)
        }

        let fixture: HealthFixture = try await client.get("api/wellness/day/2026-09-23")

        #expect(fixture == HealthFixture(restingHr: 52, steps: 8342, date: "2026-09-23"))
        #expect(local.calls.count == 1)
        #expect(local.calls.first?.method == "GET")
        #expect(local.calls.first?.path == "api/wellness/day/2026-09-23")
    }

    /// L'auth est purement serveur (le backend local n'a pas de comptes) : même
    /// en mode Téléphone, `api/auth/*` doit partir au serveur, jamais au local
    /// — sinon basculer vers Pulse depuis le picker de stockage échouait avec
    /// « Pas encore disponible en mode Téléphone ». Cf. `PulseAPIClient
    /// .isServerOnly`.
    @Test func authRoutesAlwaysHitServerEvenInPhoneMode() async throws {
        let local = RecordingLocalPulseBackend()
        let client = routedClient(mode: .phone, localBackend: local)
        StubURLProtocol.handler = { request in
            jsonResponse(request.url!, status: 200, body: Data(#"{"username":"ali"}"#.utf8))
        }

        struct Creds: Encodable { let username: String; let password: String }
        struct Me: Decodable, Equatable { let username: String }
        let me: Me = try await client.post("api/auth/login", body: Creds(username: "ali", password: "x"))

        #expect(me == Me(username: "ali"))
        #expect(local.calls.isEmpty, "l'auth ne doit jamais toucher le backend local")
    }

    @Test func pulseModeNeverCallsTheLocalBackendEvenOnServerError() async throws {
        let local = RecordingLocalPulseBackend()
        let client = routedClient(mode: .pulse, localBackend: local)
        StubURLProtocol.handler = { request in
            jsonResponse(request.url!, status: 500, body: Data("boom".utf8))
        }

        do {
            let _: HealthFixture = try await client.get("api/wellness/day/2026-09-23")
            Issue.record("Devait jeter .http")
        } catch let error as PulseAPIError {
            guard case .http(let status, _) = error else {
                Issue.record("Attendu .http, obtenu \(error)")
                return
            }
            #expect(status == 500)
        }
        #expect(local.calls.isEmpty, "pulse ne doit jamais replier sur le backend local")
    }

    @Test func bothModeFallsBackToLocalBackendOnTransportErrorOnly() async throws {
        let local = RecordingLocalPulseBackend()
        local.responseData = healthFixtureJSON
        let client = routedClient(mode: .both, localBackend: local)
        StubURLProtocol.handler = { _ in
            throw URLError(.notConnectedToInternet)
        }

        let fixture: HealthFixture = try await client.get("api/wellness/day/2026-09-23")

        #expect(fixture == HealthFixture(restingHr: 52, steps: 8342, date: "2026-09-23"))
        #expect(local.calls.count == 1)
    }

    @Test func bothModeDoesNotFallBackOnHTTPErrorStatus() async throws {
        let local = RecordingLocalPulseBackend()
        let client = routedClient(mode: .both, localBackend: local)
        StubURLProtocol.handler = { request in
            jsonResponse(request.url!, status: 500, body: Data("boom".utf8))
        }

        do {
            let _: HealthFixture = try await client.get("api/wellness/day/2026-09-23")
            Issue.record("Devait jeter .http, sans repli local — un 5xx n'est pas une erreur de transport")
        } catch let error as PulseAPIError {
            guard case .http(let status, _) = error else {
                Issue.record("Attendu .http, obtenu \(error)")
                return
            }
            #expect(status == 500)
        }
        #expect(local.calls.isEmpty)
    }

    @Test func bothModeDoesNotFallBackOnUnauthorized() async throws {
        let local = RecordingLocalPulseBackend()
        let client = routedClient(mode: .both, localBackend: local)
        StubURLProtocol.handler = { request in
            jsonResponse(request.url!, status: 401, body: Data("{}".utf8))
        }

        do {
            let _: HealthFixture = try await client.get("api/wellness/day/2026-09-23")
            Issue.record("Devait jeter .unauthorized, sans repli local")
        } catch let error as PulseAPIError {
            guard case .unauthorized = error else {
                Issue.record("Attendu .unauthorized, obtenu \(error)")
                return
            }
        }
        #expect(local.calls.isEmpty)
    }

    @Test func stubLocalBackendThrowsTheDedicatedNotAvailableMessage() async {
        let backend = StubLocalPulseBackend()
        do {
            _ = try await backend.handle(method: "GET", path: "api/wellness/day/2026-09-23", query: [:], body: nil)
            Issue.record("Devait jeter LocalPulseUnavailableError")
        } catch {
            #expect(error.localizedDescription == "Pas encore disponible en mode Téléphone")
        }
    }
}
