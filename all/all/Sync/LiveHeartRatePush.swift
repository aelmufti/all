//
//  LiveHeartRatePush.swift
//  all (bridge-connect)
//
//  Client de push de la FC en direct vers Pulse — incrément Live-1b. Calque
//  `PulseUploader.swift` (même découpage : requête PURE + protocole de
//  transport injectable + seam au-dessus de `PulseConfig`), mais pour un flux
//  différent en nature :
//  - `PulseUploader` livre des `.fit` : ne jamais en perdre un octet (spool,
//    retry, quarantaine).
//  - `LiveHeartRatePush` livre un échantillon FC ~1×/s : **jetable**. Un POST
//    qui échoue est simplement abandonné, l'échantillon suivant le remplace
//    à la seconde suivante. Donc PAS de spool, PAS de retry, PAS de
//    quarantaine, PAS de completion métier — fire-and-forget.
//
//  Nouvel endpoint `POST <baseURL>/api/live/hr` (distinct de `/api/ingest`) :
//  corps JSON (pas octet-stream), forme exactement `LiveHeartRate.Reading`
//  (miroir du type serveur `LiveReading`, cf.
//  `custom-connect/server/src/sync/sync.types.ts`). `measuredAt` est encodé
//  en ISO 8601 **explicitement `null`** quand absent (pas omis) : le
//  `Codable` synthétisé par le compilateur appellerait `encodeIfPresent` sur
//  les `Optional` et omettrait la clé, ce qui n'est PAS le contrat — d'où
//  l'`encode(to:)` manuel de `LiveHrPushBody` ci-dessous.
//
//  ÉMISSION RÉSEAU ACTIVE (autorisation explicite de l'utilisateur pour la FC,
//  donnée pour cet incrément) : `URLSessionLiveHrPushTransport` émet
//  réellement (`.resume()`), en session `.default` (foreground, l'app pousse
//  seulement tant qu'elle est au premier plan — cf. `BLEManager.wantsRealtime`,
//  alimenté depuis la FC temps réel GFDI plutôt que l'ancien 0x2A37).
//  Jamais de bpm journalisé (règle héritée de `LiveHeartRate.swift`) : au plus
//  une ligne debug annonçant qu'un push est parti, sans valeur.
//
//  Découpage testé : `makeRequest` est PURE (aucune E/S), testée sans réseau
//  via un `LiveHrPushTransport` factice — jamais `URLSessionLiveHrPushTransport`
//  dans les tests (cf. `allTests/LiveHeartRatePushTests.swift`).
//

import Foundation
import os

/// Corps JSON du POST — miroir exact de `LiveHeartRate.Reading`, avec un
/// `encode(to:)` manuel pour garantir `null` explicite (jamais une clé omise)
/// sur les champs optionnels, contrairement à ce que produirait la synthèse
/// automatique de `Encodable` sur des `Optional`.
private struct LiveHrPushBody: Encodable {
    let enabled: Bool
    let broadcasting: Bool
    let heartRate: Int?
    let measuredAt: Date?
    let stale: Bool
    let hint: String?

    private enum CodingKeys: String, CodingKey {
        case enabled, broadcasting, heartRate, measuredAt, stale, hint
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(broadcasting, forKey: .broadcasting)
        if let heartRate {
            try container.encode(heartRate, forKey: .heartRate)
        } else {
            try container.encodeNil(forKey: .heartRate)
        }
        if let measuredAt {
            try container.encode(LiveHeartRatePush.isoFormatter.string(from: measuredAt), forKey: .measuredAt)
        } else {
            try container.encodeNil(forKey: .measuredAt)
        }
        try container.encode(stale, forKey: .stale)
        if let hint {
            try container.encode(hint, forKey: .hint)
        } else {
            try container.encodeNil(forKey: .hint)
        }
    }
}

/// Couture d'injection réseau — jamais `URLSessionLiveHrPushTransport` en
/// test. Pas de `completion` (contrairement à `PulseUploadTransport`) : le
/// live est fire-and-forget, aucun appelant n'a besoin du résultat.
protocol LiveHrPushTransport {
    func send(_ request: URLRequest)
}

enum LiveHeartRatePush {
    /// Chemin fixe — distinct de `PulseUploader.ingestPath`, nouvel endpoint
    /// dédié au live (cf. `LiveHrController` côté serveur).
    private static let livePath = "api/live/hr"

    /// Partagé par `LiveHrPushBody.encode(to:)` — `ISO8601DateFormatter` est
    /// immuable après construction, donc sûr à réutiliser/partager (pas de
    /// mutation concurrente de sa configuration).
    fileprivate static let isoFormatter = ISO8601DateFormatter()

    /// Construit la requête — PURE (aucune E/S), testée sans réseau. `Content-Type:
    /// application/json` (pas `application/octet-stream` : ce n'est pas
    /// `/api/ingest`, et `main.ts` côté serveur ne borne `express.raw()` qu'à
    /// cette dernière route).
    static func makeRequest(baseURL: URL, token: String, reading: LiveHeartRate.Reading) -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent(livePath))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let body = LiveHrPushBody(
            enabled: reading.enabled,
            broadcasting: reading.broadcasting,
            heartRate: reading.heartRate,
            measuredAt: reading.measuredAt,
            stale: reading.stale,
            hint: reading.hint
        )
        // N'échoue jamais en pratique pour cette forme (booléens/Int/String/nil
        // uniquement, pas de flottant NaN/infini) : `try?` plutôt que propager,
        // cohérent avec la nature best-effort de tout ce fichier.
        request.httpBody = try? JSONEncoder().encode(body)
        return request
    }
}

/// Implémentation réelle du transport — `URLSession` en configuration
/// `.default` (foreground, comme `URLSessionPulseUploadTransport`). Fire-and-
/// forget assumé : `.resume()` puis on ignore le résultat, jamais de retry
/// (contrairement à l'upload de fichiers, un échantillon perdu est remplacé
/// dans la seconde qui suit par le suivant).
///
/// ÉMET RÉELLEMENT — autorisation réseau explicite de l'utilisateur pour la FC
/// (cf. en-tête de fichier). Instanciée par `PulseLiveHrPusher` ci-dessous.
final class URLSessionLiveHrPushTransport: LiveHrPushTransport {
    private let log = Logger(subsystem: "CleanYourRoom.all", category: "live-hr-push")
    private let session: URLSession

    init() {
        session = URLSession(configuration: .default)
    }

    func send(_ request: URLRequest) {
        // Une seule ligne, sans bpm ni horodatage de mesure (règle héritée du
        // pont, cf. LiveHeartRate.swift) : juste le fait qu'un push est parti.
        log.debug("Push FC live envoyé")
        let task = session.dataTask(with: request) { _, _, _ in
            // Résultat ignoré à dessein : pas de retry, pas de remontée d'erreur
            // métier — l'échantillon suivant (~1 s) remplace celui-ci de toute
            // façon. Voir en-tête de fichier.
        }
        task.resume()
    }
}

/// Couture entre `BLEManager` et `LiveHeartRatePush` — ce que `BLEManager`
/// appelle, pas `LiveHeartRatePush.makeRequest` directement (même rôle que
/// `SpoolUploading`/`PulseSpoolUploader` pour l'upload de fichiers).
protocol LiveHrPushing {
    func push(_ reading: LiveHeartRate.Reading)
}

/// Implémentation concrète de `LiveHrPushing`. Relit `PulseConfig.baseURL`/
/// `PulseConfig.ingestToken` à **chaque appel** (même raison que
/// `PulseSpoolUploader` : ces réglages peuvent être renseignés après le début
/// d'une session live). No-op silencieux si l'un des deux manque — pas
/// d'erreur remontée, cohérent avec la nature jetable du live (rien à garder
/// ni à signaler, l'UI Pulse restera simplement en silence côté serveur).
final class PulseLiveHrPusher: LiveHrPushing {
    private let transport: LiveHrPushTransport

    init(transport: LiveHrPushTransport = URLSessionLiveHrPushTransport()) {
        self.transport = transport
    }

    func push(_ reading: LiveHeartRate.Reading) {
        guard let baseURL = PulseConfig.baseURL, let token = PulseConfig.ingestToken, !token.isEmpty else {
            return
        }
        let request = LiveHeartRatePush.makeRequest(baseURL: baseURL, token: token, reading: reading)
        transport.send(request)
    }
}
