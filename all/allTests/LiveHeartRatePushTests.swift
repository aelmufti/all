//
//  LiveHeartRatePushTests.swift
//  allTests
//
//  Couvre le push de FC live vers Pulse (incrément Live-1b) :
//  `LiveHeartRatePush.makeRequest` (construction de requête, PURE) et
//  l'encodage JSON exact du corps (y compris `measuredAt` en ISO 8601 et les
//  `null` explicites), via un `LiveHrPushTransport` factice — JAMAIS un vrai
//  `URLSession` (règle immuable du dépôt), comme `PulseUploaderRequestTests`
//  dans `SyncEngineTests.swift`.
//

import Testing
import Foundation
@testable import all

// MARK: - makeRequest — forme de la requête (PURE)

struct LiveHeartRatePushRequestTests {
    private func reading(
        enabled: Bool = true,
        broadcasting: Bool = true,
        heartRate: Int? = 74,
        measuredAt: Date? = Date(timeIntervalSince1970: 1_700_000_000),
        stale: Bool = false,
        hint: String? = nil
    ) -> LiveHeartRate.Reading {
        LiveHeartRate.Reading(enabled: enabled, broadcasting: broadcasting, heartRate: heartRate, measuredAt: measuredAt, stale: stale, hint: hint)
    }

    @Test func requestHasTheContractShape() {
        let baseURL = URL(string: "https://pulse.example.ts.net")!

        let request = LiveHeartRatePush.makeRequest(baseURL: baseURL, token: "s3cr3t-live-token", reading: reading())

        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://pulse.example.ts.net/api/live/hr")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer s3cr3t-live-token")
    }

    // MARK: - Corps JSON

    private func decodedBody(_ request: URLRequest) throws -> [String: Any] {
        let data = try #require(request.httpBody)
        let raw = try JSONSerialization.jsonObject(with: data)
        return try #require(raw as? [String: Any])
    }

    @Test func encodesEveryFieldOfAFullReading() throws {
        let baseURL = URL(string: "https://pulse.example.ts.net")!
        let measuredAt = Date(timeIntervalSince1970: 1_700_000_000) // 2023-11-14T22:13:20Z
        let request = LiveHeartRatePush.makeRequest(
            baseURL: baseURL, token: "t",
            reading: reading(enabled: true, broadcasting: true, heartRate: 88, measuredAt: measuredAt, stale: false, hint: nil)
        )

        let body = try decodedBody(request)

        #expect(body["enabled"] as? Bool == true)
        #expect(body["broadcasting"] as? Bool == true)
        #expect(body["heartRate"] as? Int == 88)
        #expect(body["stale"] as? Bool == false)
        #expect(body["measuredAt"] as? String == "2023-11-14T22:13:20Z")
    }

    /// Le contrat exige `null` explicite (pas une clé omise) sur les champs
    /// optionnels quand ils sont absents — c'est tout l'objet de l'`encode(to:)`
    /// manuel de `LiveHrPushBody` (la synthèse automatique de `Encodable`
    /// aurait utilisé `encodeIfPresent` et omis la clé).
    @Test func encodesNilOptionalFieldsAsExplicitJSONNullNotOmittedKeys() throws {
        let baseURL = URL(string: "https://pulse.example.ts.net")!
        let request = LiveHeartRatePush.makeRequest(
            baseURL: baseURL, token: "t",
            reading: reading(enabled: false, broadcasting: false, heartRate: nil, measuredAt: nil, stale: false, hint: nil)
        )

        let body = try decodedBody(request)

        #expect(body.keys.contains("heartRate"), "la clé doit être présente…")
        #expect(body["heartRate"] is NSNull, "…et valoir JSON null, pas une clé omise")
        #expect(body.keys.contains("measuredAt"))
        #expect(body["measuredAt"] is NSNull)
        #expect(body.keys.contains("hint"))
        #expect(body["hint"] is NSNull)
    }

    @Test func encodesAPresentHintAsAString() throws {
        let baseURL = URL(string: "https://pulse.example.ts.net")!
        let request = LiveHeartRatePush.makeRequest(
            baseURL: baseURL, token: "t",
            reading: reading(hint: LiveHeartRate.notBroadcastingHint)
        )

        let body = try decodedBody(request)

        #expect(body["hint"] as? String == LiveHeartRate.notBroadcastingHint)
    }

    /// `Reading.off` est ce que `stopLiveHeartRate` pousse best-effort — vérifie
    /// que la forme reste cohérente pour ce cas précis (tous les champs à leur
    /// valeur « éteinte »).
    @Test func encodesTheOffReading() throws {
        let baseURL = URL(string: "https://pulse.example.ts.net")!
        let request = LiveHeartRatePush.makeRequest(baseURL: baseURL, token: "t", reading: .off)

        let body = try decodedBody(request)

        #expect(body["enabled"] as? Bool == false)
        #expect(body["broadcasting"] as? Bool == false)
        #expect(body["heartRate"] is NSNull)
        #expect(body["measuredAt"] is NSNull)
        #expect(body["stale"] as? Bool == false)
        #expect(body["hint"] is NSNull)
    }
}

// MARK: - PulseLiveHrPusher — orchestration via transport factice (jamais réseau)

/// Transport factice — ne touche JAMAIS le réseau (règle immuable du dépôt) :
/// se contente d'enregistrer la dernière requête reçue.
private final class RecordingLiveHrPushTransport: LiveHrPushTransport {
    private(set) var sent: [URLRequest] = []

    func send(_ request: URLRequest) {
        sent.append(request)
    }
}

// `.serialized` : les deux tests mutent le même singleton global `PulseConfig`
// (UserDefaults + Keychain) — Swift Testing exécute par défaut les tests d'une
// suite en parallèle, ce qui les fait s'entrelacer (observé : la mise à `nil`
// de `doesNothingWhenPulseConfigIsMissing` court-circuitait `PulseConfig` en
// plein milieu de `pushesThroughTheTransportWhenConfigured`). Le sérialiser
// évite la course sans changer `PulseConfig` lui-même.
@Suite(.serialized)
struct PulseLiveHrPusherTests {
    @Test func pushesThroughTheTransportWhenConfigured() throws {
        let previousBaseURL = PulseConfig.baseURL
        let previousToken = PulseConfig.ingestToken
        defer {
            PulseConfig.baseURL = previousBaseURL
            PulseConfig.ingestToken = previousToken
        }
        PulseConfig.baseURL = URL(string: "https://pulse.example.ts.net")
        PulseConfig.ingestToken = "s3cr3t"

        let transport = RecordingLiveHrPushTransport()
        let pusher = PulseLiveHrPusher(transport: transport)
        let reading = LiveHeartRate.Reading(enabled: true, broadcasting: true, heartRate: 60, measuredAt: Date(), stale: false, hint: nil)

        pusher.push(reading)

        #expect(transport.sent.count == 1)
        #expect(transport.sent.first?.url?.path == "/api/live/hr")
        #expect(transport.sent.first?.value(forHTTPHeaderField: "Authorization") == "Bearer s3cr3t")
    }

    /// Sans base URL/token renseignés (comme `PulseSpoolUploader` avant
    /// paramétrage) : no-op silencieux, jamais d'appel au transport.
    @Test func doesNothingWhenPulseConfigIsMissing() throws {
        let previousBaseURL = PulseConfig.baseURL
        let previousToken = PulseConfig.ingestToken
        defer {
            PulseConfig.baseURL = previousBaseURL
            PulseConfig.ingestToken = previousToken
        }
        PulseConfig.baseURL = nil
        PulseConfig.ingestToken = nil

        let transport = RecordingLiveHrPushTransport()
        let pusher = PulseLiveHrPusher(transport: transport)

        pusher.push(.off)

        #expect(transport.sent.isEmpty)
    }
}
