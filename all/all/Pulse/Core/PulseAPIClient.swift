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
//  Routage « Stockage » (incrément L0, `docs/stockage-local.md`) : chaque
//  appel passe par `routedData`, qui consulte `StorageModeStore.current` (via
//  `modeProvider`, relu à CHAQUE appel — jamais capturé) pour décider serveur
//  ou `LocalPulseBackend` :
//   - `pulse` : serveur, comme avant cet incrément — jamais le backend local.
//   - `phone` : backend local directement, AUCUNE requête serveur construite
//     (pas même besoin de `baseURL`).
//   - `both`  : tente le serveur ; replie sur le backend local **seulement**
//     sur une erreur de transport (`PulseAPIError.transport` — DNS/TLS/offline/
//     timeout, PAS un code HTTP même 5xx, PAS 401) — cf. `docs/stockage-local.md`,
//     « erreur de transport seulement, pas 4xx/401 ».
//  Le backend local répond aux mêmes routes avec le même JSON (mêmes modèles
//  `Decodable`) : les écrans ne changent jamais selon le mode.
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
    private let localBackend: LocalPulseBackend
    private let modeProvider: () -> StorageMode

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
    ///   - localBackend: répondant local « Pulse embarqué » (cf. en-tête de
    ///     fichier). Par défaut `LocalPulseBackendFactory.make()` —
    ///     `RealLocalPulseBackend` (SQLite local, `Local/LocalPulseBackend.swift`)
    ///     si `LocalDb` s'ouvre, sinon repli sur `StubLocalPulseBackend`
    ///     (incrément L1, `docs/stockage-local.md` — routes `wellness/days`/
    ///     `wellness/dates` seulement ; le reste lève encore
    ///     `LocalPulseUnavailableError`, à faire en L2/L3). Injectable pour
    ///     les tests.
    ///   - modeProvider: même raison d'être que `baseURLProvider` — relu à
    ///     chaque appel, jamais capturé, injectable en test pour ne pas muter
    ///     le singleton global `StorageModeStore`.
    init(
        session: URLSession = PulseAPIClient.makeDefaultSession(),
        baseURLProvider: @escaping () -> URL? = { PulseConfig.baseURL },
        localBackend: LocalPulseBackend = LocalPulseBackendFactory.make(),
        modeProvider: @escaping () -> StorageMode = { StorageModeStore.current }
    ) {
        self.session = session
        self.baseURLProvider = baseURLProvider
        self.localBackend = localBackend
        self.modeProvider = modeProvider
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
        let (data, status) = try await routedData(method: "GET", path: path, query: query, bodyData: nil)
        return try decode(data, path: path, status: status)
    }

    /// `POST path` avec un corps `Encodable`.
    func post<Body: Encodable, T: Decodable>(_ path: String, body: Body) async throws -> T {
        let bodyData = try encodeBody(body)
        let (data, status) = try await routedData(method: "POST", path: path, query: [:], bodyData: bodyData)
        return try decode(data, path: path, status: status)
    }

    /// `POST path` sans corps (ex. `api/auth/logout`).
    func post<T: Decodable>(_ path: String) async throws -> T {
        let (data, status) = try await routedData(method: "POST", path: path, query: [:], bodyData: nil)
        return try decode(data, path: path, status: status)
    }

    /// `PUT path` avec un corps `Encodable`.
    func put<Body: Encodable, T: Decodable>(_ path: String, body: Body) async throws -> T {
        let bodyData = try encodeBody(body)
        let (data, status) = try await routedData(method: "PUT", path: path, query: [:], bodyData: bodyData)
        return try decode(data, path: path, status: status)
    }

    /// `DELETE path`. Pas de corps de réponse exploité par le socle (les
    /// endpoints de suppression de Pulse renvoient un petit accusé JSON, mais
    /// aucun écran n'en a besoin pour l'instant) — seul le statut HTTP compte
    /// côté serveur (le backend local, lui, n'a pas de statut : `routedData`
    /// gère les deux cas).
    func delete(_ path: String) async throws {
        _ = try await routedData(method: "DELETE", path: path, query: [:], bodyData: nil)
    }

    // MARK: - Routage Stockage (serveur vs backend local)

    /// Point d'entrée unique de routage — cf. en-tête de fichier. Renvoie le
    /// corps brut (JSON) à décoder par l'appelant, plus le code HTTP quand la
    /// réponse vient du serveur (`nil` depuis le backend local, qui n'en a
    /// pas — `decode` s'en sert seulement pour un message de diagnostic).
    private func routedData(method: String, path: String, query: [String: String], bodyData: Data?) async throws -> (Data, Int?) {
        switch modeProvider() {
        case .phone:
            return (try localBackend.handle(method: method, path: path, query: query, body: bodyData), nil)
        case .pulse:
            return try await serverData(method: method, path: path, query: query, bodyData: bodyData)
        case .both:
            do {
                return try await serverData(method: method, path: path, query: query, bodyData: bodyData)
            } catch PulseAPIError.transport(_), PulseAPIError.notConfigured {
                // Repli local si Pulse est injoignable : erreur de transport
                // (DNS/TLS/offline/timeout) OU aucune adresse Pulse configurée
                // (`.notConfigured` — « pas de Pulse du tout → tout local »,
                // décision 2026-09-29). Jamais sur un code HTTP (même 5xx) ni
                // sur 401 : ceux-là veulent dire que Pulse a répondu, donc ils
                // remontent tels quels — cf. en-tête et `docs/stockage-local.md`.
                return (try localBackend.handle(method: method, path: path, query: query, body: bodyData), nil)
            }
        }
    }

    /// Exécute réellement contre Pulse — construit la requête, y attache le
    /// corps s'il y en a un, l'envoie, renvoie le corps brut 2xx + le statut.
    private func serverData(method: String, path: String, query: [String: String], bodyData: Data?) async throws -> (Data, Int?) {
        var request = try makeRequest(path: path, method: method, query: query)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let bodyData {
            request = attach(bodyData: bodyData, to: request)
        }
        let (data, response) = try await perform(request)
        return (data, response.statusCode)
    }

    // MARK: - Construction de requête

    private func makeRequest(path: String, method: String, query: [String: String]) throws -> URLRequest {
        let url = try resolve(path, query: query)
        var request = URLRequest(url: url)
        request.httpMethod = method
        return request
    }

    private func attach(bodyData: Data, to request: URLRequest) -> URLRequest {
        var request = request
        request.httpBody = bodyData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    /// Encode un corps `Encodable` en `Data` — utilisé à la fois par le
    /// chemin serveur et le backend local (même corps envoyé aux deux,
    /// cf. `LocalPulseBackend`).
    private func encodeBody<Body: Encodable>(_ body: Body) throws -> Data {
        do {
            return try Self.encoder.encode(body)
        } catch {
            throw PulseAPIError.decoding(error)
        }
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

    private func decode<T: Decodable>(_ data: Data, path: String, status: Int?) throws -> T {
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
    /// tête**, donc lisibles même si le message est long) + le code HTTP (ou
    /// « backend local » si la réponse ne vient pas du serveur, cf.
    /// `routedData`), et — pour un corps qui n'est pas du JSON du tout — un
    /// aperçu taille/début/fin.
    private static func decodeFailureDetail(_ error: Error, data: Data, status: Int?, note: String) -> String {
        let statusSuffix = status.map { "[HTTP \($0)]" } ?? "[backend local]"
        guard let decodingError = error as? DecodingError else {
            return "\(note) — \(error) \(statusSuffix)"
        }
        var detail = "\(note) — \(describe(decodingError)) \(statusSuffix)"
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

// MARK: - Backend local « Pulse embarqué » (mode Téléphone/Les deux)

/// Répondant local — cf. en-tête de fichier et `docs/stockage-local.md`.
/// Traite une requête EXACTEMENT comme le ferait le serveur pour la même
/// route (même méthode/chemin/query/corps), et renvoie le même JSON brut —
/// `PulseAPIClient` le décode ensuite avec le même `decoder` que la réponse
/// serveur, donc les modèles `Decodable` des écrans ne savent jamais d'où
/// vient la réponse. Pas `async` : le futur portage réel (L1+, SQLite système)
/// est local et rapide — si ça change, `async throws` s'ajoutera alors.
protocol LocalPulseBackend {
    func handle(method: String, path: String, query: [String: String], body: Data?) throws -> Data
}

/// Erreur dédiée du backend local — message stable et testé
/// (`localizedDescription`), montrable tel quel tant qu'aucun écran ne le
/// spécialise.
struct LocalPulseUnavailableError: Error, LocalizedError {
    var errorDescription: String? { "Pas encore disponible en mode Téléphone" }
}

/// Implémentation de repli — utilisée pour toute route que
/// `RealLocalPulseBackend` ne sert pas encore (`Local/LocalPulseBackend.swift`,
/// incrément L1, `docs/stockage-local.md`), et directement comme backend par
/// défaut si `LocalDb` n'a pas pu s'ouvrir (`LocalPulseBackendFactory.make`).
/// Échoue systématiquement avec un message clair plutôt que de renvoyer un
/// JSON vide trompeur ou de planter.
struct StubLocalPulseBackend: LocalPulseBackend {
    func handle(method: String, path: String, query: [String: String], body: Data?) throws -> Data {
        throw LocalPulseUnavailableError()
    }
}
