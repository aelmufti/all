//
//  PulseAPIClient.swift
//  all (bridge-connect)
//
//  Client HTTP générique vers l'API NestJS de Pulse (custom-connect). Socle
//  partagé consommé par tous les écrans natifs (Accueil, Santé, Activités,
//  Nutrition, Plus…) : eux ne connaissent que `PulseAPIClient.shared` et leurs
//  propres modèles `Decodable`/`Encodable`, jamais `URLSession` directement.
//
//  Auth : Pulse authentifie par **cookie de session httpOnly** (`POST
//  /api/auth/login` pose le cookie via `Set-Cookie`, cf.
//  `custom-connect/server/src/auth/auth.controller.ts`), pas par Bearer — le
//  Bearer existant (`PulseConfig.ingestToken`) est un canal différent (push
//  collecteur, `Sync/PulseUploader.swift`), on n'y touche pas ici. Le cookie
//  doit être reporté automatiquement sur toutes les requêtes suivantes : on
//  utilise `HTTPCookieStorage.shared` explicitement (même si c'est déjà le
//  comportement par défaut d'une session `.default`), pour que ce soit vrai
//  aussi si quelqu'un durcit la config plus tard (ex. désactivation du cache).
//

import Foundation
import os

final class PulseAPIClient {
    /// Instance partagée — c'est celle-ci que consomment les écrans et
    /// `AuthStore`. L'initialiseur reste public pour permettre l'injection
    /// d'une session stubée dans les tests (`PulseSocleTests.swift`), sans
    /// jamais toucher au réseau réel.
    static let shared = PulseAPIClient()

    /// `JSONDecoder` partagé par tout le socle — un seul point de vérité pour
    /// la stratégie de décodage.
    ///
    /// Stratégie de dates retenue (inspection de `custom-connect/server/src`,
    /// ex. `wellness/wellness.controller.ts`, `activities/activities.controller.ts`) :
    /// l'API Pulse ne sérialise **jamais** de type "date" générique. Elle expose
    /// soit des **epoch secondes** en nombre (`ts`, `startTs`, `generatedAt`…,
    /// `Int`/`Double`), soit des **chaînes calendaires `YYYY-MM-DD`** (`date`,
    /// `night.date`…, `String`). Les deux formats coexistent dans une même
    /// réponse (ex. `Spo2Report`) et un `dateDecodingStrategy` global ne peut
    /// choisir qu'une seule convention — imposer `.iso8601` ou `.secondsSince1970`
    /// romprait silencieusement l'autre moitié des champs.
    ///
    /// Décision : **pas de stratégie de date au niveau du décodeur**. Les
    /// modèles d'écran typent ces champs en `Int`/`Double` (epoch) ou `String`
    /// (calendaire) — jamais en `Date` — et convertissent eux-mêmes si besoin
    /// (`Date(timeIntervalSince1970:)` pour un epoch, un `DateFormatter`/
    /// `Calendar` dédié pour `YYYY-MM-DD`). Seule concession globale : les clés
    /// JSON renvoyées par Nest sont déjà en camelCase identique aux propriétés
    /// Swift (`restingHr`, `fileHash`…), donc `keyDecodingStrategy` reste au
    /// défaut (`.useDefaultKeys`).
    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        return decoder
    }()

    /// `JSONEncoder` partagé pour les corps de requête (`login`, futurs POST/PUT
    /// des écrans). Même raisonnement côté clés : les contrôleurs Nest
    /// attendent des corps camelCase (`{ username, password }`), donc pas de
    /// `keyEncodingStrategy` particulière.
    static let encoder: JSONEncoder = {
        JSONEncoder()
    }()

    /// Journal des échecs réseau/décodage (visible dans Console.app, subsystem
    /// `CleanYourRoom.all`, catégorie `pulse-api`) — complément du message
    /// affiché à l'écran, pour diagnostiquer précisément une réponse illisible.
    private static let logger = Logger(subsystem: "CleanYourRoom.all", category: "pulse-api")

    private let session: URLSession
    private let baseURLProvider: () -> URL?

    /// - Parameters:
    ///   - session: session HTTP à utiliser. Par défaut, une session dédiée
    ///     avec le cookie storage partagé (voir en-tête du fichier). Les
    ///     tests injectent une session configurée avec un `URLProtocol` stub
    ///     — aucune requête ne part jamais réellement sur le réseau depuis eux.
    ///   - baseURLProvider: source de l'URL de base, relue à **chaque appel**
    ///     (par défaut `{ PulseConfig.baseURL }`, cohérent avec le reste du
    ///     socle : l'adresse peut être renseignée après coup, cf. commentaire
    ///     similaire sur `PulseLiveHrPusher.push`). Ce niveau d'indirection
    ///     n'existe que pour les tests (`PulseSocleTests.swift`) : muter
    ///     directement le singleton `PulseConfig.baseURL` depuis un test
    ///     pollue un état **global** partagé par tout le process de test —
    ///     `Sync/LiveHeartRatePush.swift` a ses propres tests qui lisent ce
    ///     même singleton, et Swift Testing exécute les suites en parallèle
    ///     par défaut (`.serialized` ne protège qu'à l'intérieur d'une
    ///     suite) : une vraie course a été observée en pratique. Injecter le
    ///     fournisseur d'URL évite d'y toucher du tout depuis les tests de ce
    ///     fichier, sans changer le comportement par défaut de `.shared`.
    init(
        session: URLSession = PulseAPIClient.makeDefaultSession(),
        baseURLProvider: @escaping () -> URL? = { PulseConfig.baseURL }
    ) {
        self.session = session
        self.baseURLProvider = baseURLProvider
    }

    private static func makeDefaultSession() -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.httpCookieStorage = .shared
        configuration.httpShouldSetCookies = true
        return URLSession(configuration: configuration)
    }

    // MARK: - API publique

    /// `GET path?query`. `path` est relatif à `PulseConfig.baseURL` (ex.
    /// `"api/wellness/day/2026-09-23"`).
    func get<T: Decodable>(_ path: String, query: [String: String] = [:]) async throws -> T {
        var request = try makeRequest(path: path, method: "GET", query: query)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await perform(request)
        return try decode(data, path: path, status: response.statusCode)
    }

    /// `POST path` avec un corps `Encodable`.
    func post<Body: Encodable, T: Decodable>(_ path: String, body: Body) async throws -> T {
        var request = try makeRequest(path: path, method: "POST", query: [:])
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request = try attach(body: body, to: request)
        let (data, response) = try await perform(request)
        return try decode(data, path: path, status: response.statusCode)
    }

    /// `POST path` sans corps (ex. `api/auth/logout`).
    func post<T: Decodable>(_ path: String) async throws -> T {
        var request = try makeRequest(path: path, method: "POST", query: [:])
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await perform(request)
        return try decode(data, path: path, status: response.statusCode)
    }

    /// `PUT path` avec un corps `Encodable`.
    func put<Body: Encodable, T: Decodable>(_ path: String, body: Body) async throws -> T {
        var request = try makeRequest(path: path, method: "PUT", query: [:])
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request = try attach(body: body, to: request)
        let (data, response) = try await perform(request)
        return try decode(data, path: path, status: response.statusCode)
    }

    /// `DELETE path`. Pas de corps de réponse exploité par le socle (les
    /// endpoints de suppression de Pulse renvoient un petit accusé JSON, mais
    /// aucun écran n'en a besoin pour l'instant) — seul le statut HTTP compte.
    func delete(_ path: String) async throws {
        let request = try makeRequest(path: path, method: "DELETE", query: [:])
        _ = try await perform(request)
    }

    // MARK: - Construction de requête

    private func makeRequest(path: String, method: String, query: [String: String]) throws -> URLRequest {
        let url = try resolve(path, query: query)
        var request = URLRequest(url: url)
        request.httpMethod = method
        return request
    }

    private func attach<Body: Encodable>(body: Body, to request: URLRequest) throws -> URLRequest {
        var request = request
        do {
            request.httpBody = try Self.encoder.encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        } catch {
            throw PulseAPIError.decoding(error)
        }
        return request
    }

    private func resolve(_ path: String, query: [String: String]) throws -> URL {
        guard let base = baseURLProvider() else {
            throw PulseAPIError.notConfigured
        }
        let full = base.appendingPathComponent(path)
        guard query.isEmpty else {
            guard var components = URLComponents(url: full, resolvingAgainstBaseURL: false) else {
                throw PulseAPIError.transport(URLError(.badURL))
            }
            components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
            guard let url = components.url else {
                throw PulseAPIError.transport(URLError(.badURL))
            }
            return url
        }
        return full
    }

    // MARK: - Exécution

    /// Exécute la requête et applique le mapping d'erreurs commun (401 →
    /// `.unauthorized`, autre code hors 2xx → `.http`). Renvoie le corps brut
    /// pour que les appelants GET/POST/PUT le décodent, et que `delete`
    /// puisse l'ignorer sans dupliquer la logique de statut.
    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as PulseAPIError {
            throw error
        } catch {
            throw PulseAPIError.transport(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw PulseAPIError.transport(URLError(.badServerResponse))
        }
        if http.statusCode == 401 {
            throw PulseAPIError.unauthorized
        }
        guard (200..<300).contains(http.statusCode) else {
            throw PulseAPIError.http(status: http.statusCode, body: data)
        }
        return (data, http)
    }

    private func decode<T: Decodable>(_ data: Data, path: String, status: Int) throws -> T {
        // Chemin normal.
        do {
            return try Self.decoder.decode(T.self, from: data)
        } catch let firstError {
            // Diagnostic : écrit le corps brut fautif dans le conteneur de l'app
            // pour analyse hors ligne (récupéré via `devicectl`, aucun réseau).
            Self.dumpFailingBody(data, path: path)
            // Le parseur natif de `JSONDecoder` (Foundation Swift) rejette parfois
            // un corps pourtant **valide** que `JSONSerialization` accepte. On
            // reparse via `JSONSerialization`, on ré-émet un JSON canonique, puis
            // on redécode. Deux issues :
            //  - ça décode → c'était un caprice du parseur natif, résolu ;
            //  - ça échoue encore → c'est un vrai décalage de modèle, et l'erreur
            //    de CE décodage-ci (clé/type/chemin) est la bonne à remonter, pas
            //    le « not valid JSON » trompeur du brut.
            if let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
               let normalized = try? JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed]) {
                do {
                    let value = try Self.decoder.decode(T.self, from: normalized)
                    Self.logger.warning("Décodé après normalisation JSONSerialization (\(path, privacy: .public))")
                    return value
                } catch let normalizedError {
                    let detail = Self.decodeFailureDetail(normalizedError, data: normalized, status: status, note: "après normalisation")
                    Self.logger.error("Décodage échoué (\(path, privacy: .public)) : \(detail, privacy: .public)")
                    throw PulseAPIError.decoding(PulseDecodingFailure(path: path, detail: detail))
                }
            }
            // `JSONSerialization` n'a pas pu parser non plus : corps réellement
            // invalide (tronqué, non-UTF-8, HTML de repli, vide…).
            let detail = Self.decodeFailureDetail(firstError, data: data, status: status, note: "corps non-JSON")
            Self.logger.error("Décodage échoué (\(path, privacy: .public)) : \(detail, privacy: .public)")
            throw PulseAPIError.decoding(PulseDecodingFailure(path: path, detail: detail))
        }
    }

    /// Écrit le corps brut d'une réponse non décodable dans
    /// `Documents/pulse-echec-<endpoint>.json` (récupérable via `devicectl`,
    /// zéro réseau) pour analyse octet-près hors ligne. Diagnostic temporaire.
    private static func dumpFailingBody(_ data: Data, path: String) {
        let name = "pulse-echec-" + path.replacingOccurrences(of: "/", with: "_") + ".json"
        guard let dir = try? FileManager.default.url(
            for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ) else { return }
        try? data.write(to: dir.appendingPathComponent(name))
    }

    /// Construit le détail affiché : la clé/type/chemin fautifs (placés **en
    /// tête**, donc lisibles même si le message est long) + le code HTTP, et —
    /// pour un corps qui n'est pas du JSON du tout — un aperçu taille/début/fin.
    private static func decodeFailureDetail(_ error: Error, data: Data, status: Int, note: String) -> String {
        guard let decodingError = error as? DecodingError else {
            return "\(note) — \(error) [HTTP \(status)]"
        }
        var detail = "\(note) — \(describe(decodingError)) [HTTP \(status)]"
        if case .dataCorrupted = decodingError {
            func snippet(_ slice: Data) -> String {
                (String(data: slice, encoding: .utf8) ?? "\(slice.count) o non-UTF8")
                    .replacingOccurrences(of: "\n", with: " ")
                    .trimmingCharacters(in: .whitespaces)
            }
            detail += " ; taille \(data.count) o ; début: \(snippet(data.prefix(120))) ; fin: \(snippet(data.suffix(120)))"
        }
        return detail
    }

    /// Traduit une `DecodingError` en une phrase courte et exploitable :
    /// **quelle clé** (ou quel index) et **quel type** ont fait échouer le
    /// décodage, avec le chemin depuis la racine — pour pointer le champ du
    /// modèle Swift à corriger vis-à-vis de la vraie réponse de Pulse.
    private static func describe(_ error: DecodingError) -> String {
        func pathString(_ context: DecodingError.Context) -> String {
            let path = context.codingPath
                .map { $0.intValue.map { "[\($0)]" } ?? $0.stringValue }
                .joined(separator: ".")
            return path.isEmpty ? "racine" : path
        }
        switch error {
        case .keyNotFound(let key, let context):
            return "clé manquante « \(key.stringValue) » (sous \(pathString(context)))"
        case .typeMismatch(let type, let context):
            return "type inattendu, \(type) attendu à \(pathString(context))"
        case .valueNotFound(let type, let context):
            return "valeur nulle inattendue (\(type)) à \(pathString(context))"
        case .dataCorrupted(let context):
            return "donnée invalide à \(pathString(context)) : \(context.debugDescription)"
        @unknown default:
            return String(describing: error)
        }
    }
}

/// Échec de décodage enrichi : porte l'endpoint et la clé/type fautifs pour
/// que le message affiché (`ErrorView`) soit directement diagnostique, au lieu
/// du générique « Réponse illisible ». Transporté dans `PulseAPIError.decoding`
/// (la forme de l'énum ne change pas).
struct PulseDecodingFailure: Error, LocalizedError {
    let path: String
    let detail: String
    var errorDescription: String? { "Réponse illisible (\(path)) : \(detail)" }
}

/// Erreurs typées du socle réseau. Les écrans/`AuthStore` distinguent
/// principalement `.unauthorized` (rebascule vers la porte de login) des
/// autres cas (affichage générique via `ErrorView`, cf. `DesignSystem.swift`).
enum PulseAPIError: Error {
    /// `PulseConfig.baseURL` n'est pas encore renseignée.
    case notConfigured
    /// Réponse HTTP 401 — session expirée ou jamais ouverte.
    case unauthorized
    /// Réponse HTTP hors 2xx (autre que 401), avec le corps brut si présent
    /// (utile pour logguer/diagnostiquer sans reparser côté appelant).
    case http(status: Int, body: Data?)
    /// Le corps 2xx n'a pas pu être décodé dans le type attendu.
    case decoding(Error)
    /// Échec avant même d'obtenir une réponse HTTP (DNS, TLS, offline…) —
    /// inclut aussi une URL de requête malformée.
    case transport(Error)
}

extension PulseAPIError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Adresse de Pulse non configurée."
        case .unauthorized:
            return "Session expirée — reconnecte-toi."
        case .http(let status, _):
            return "Pulse a répondu \(status)."
        case .decoding(let error):
            // Si l'erreur sous-jacente est enrichie (endpoint + clé/type),
            // on affiche ce détail plutôt que le message générique.
            return (error as? LocalizedError)?.errorDescription ?? "Réponse de Pulse illisible."
        case .transport:
            return "Pulse est inatteignable."
        }
    }
}
