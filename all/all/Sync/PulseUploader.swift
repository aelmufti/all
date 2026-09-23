//
//  PulseUploader.swift
//  all (bridge-connect)
//
//  Client d'upload vers Pulse — cf. `docs/pulse-ingest-contract.md` : §2
//  endpoint, §5 en-têtes, §6 mapping code HTTP → action. Le corps de la requête
//  est le `.fit` du Spool tel quel (contrat §2, "octet-stream brut").
//
//  ÉMISSION RÉSEAU ACTIVE (autorisation explicite de l'utilisateur, datée
//  2026-09-22 — pivot premier-plan, cf. SESSION-NOTES) : `URLSessionPulseUploadTransport`
//  émet réellement, en session `.default` (foreground). Le dépôt a abandonné le
//  BLE arrière-plan (cf. CLAUDE.md, `BLEManager.swift`) : plus besoin d'une
//  session background ni de plomberie AppDelegate — la synchro se déclenche à
//  l'ouverture de l'app / connexion de la montre, pendant que l'app est au
//  premier plan.
//  - `GarminSession` (cf. `GFDI/GarminSession.swift`) appelle
//    `PulseSpoolUploader` (ci-dessous) après chaque fichier acquis dans le
//    Spool — plus de câblage manquant.
//  - Les tests (`allTests/PulseUploaderTests.swift`) continuent de n'exercer
//    QUE les fonctions pures (`makeUploadRequest`, `sha256Hex`,
//    `outcome(forHTTPStatusCode:)`) et un `PulseUploadTransport` factice qui ne
//    touche jamais le réseau — jamais `URLSessionPulseUploadTransport`.
//
//  Découpage (demandé par la tâche) : construction de requête + mapping de
//  réponse sont des fonctions PURES et TESTÉES ; l'exécution réseau elle-même
//  est derrière la couture `PulseUploadTransport` (protocole), substituée par un
//  mock en test — jamais un vrai `URLSession` qui `.resume()`.
//

import CryptoKit
import Foundation
import os

/// Action que l'appelant doit prendre sur le Spool/la montre suite à la
/// réponse de Pulse — porte le §6 du contrat (table HTTP → action) dans le
/// type plutôt que dans un code HTTP nu que chaque appelant réinterpréterait.
enum PulseUploadOutcome: Equatable {
    /// 2xx — `imported` / `wellness` / `duplicate` / `skipped` valent TOUS
    /// accusé (contrat §4, « un fichier déjà connu vaut accusé ») : l'appelant
    /// traduit en `SpoolStore.markDelivered`, puis
    /// `GarminSession.archivePendingDeliveries()` à la prochaine fenêtre BLE.
    case delivered
    /// 401 — token absent/invalide. Garder en spool, NE PAS réessayer
    /// automatiquement : erreur de configuration à signaler (contrat §6).
    case keepConfigError
    /// 403 — source active ≠ `phone` (gating `SyncGateService`, contrat §7).
    /// Garder, réessayer plus tard (la source peut redevenir `phone`).
    case keepRetryLater
    /// 400 / 413 / 415 / 422 — requête mal formée ou FIT illisible. Rejouer
    /// n'aide jamais : quarantaine locale + signalement (contrat §6).
    case quarantine
    /// 5xx, timeout, ou toute erreur réseau/transport (pas de code HTTP du
    /// tout) — Pulse indisponible ou lien coupé. Garder ; `URLSession`
    /// background réessaiera de lui-même (contrat §6, dernière ligne).
    case keepRetry
}

enum PulseUploadError: Error, Equatable {
    /// La réponse n'a pas pu être décodée comme `HTTPURLResponse` — ne devrait
    /// jamais arriver pour un `uploadTask` HTTP(S), garde défensive.
    case noHTTPResponse
}

/// Couture d'injection réseau — cf. en-tête de fichier. Substituée par un objet
/// factice dans les tests (jamais par `URLSessionPulseUploadTransport`, la
/// seule conformance qui touche vraiment `URLSession`).
protocol PulseUploadTransport {
    /// Exécute la requête, corps = fichier sur disque (`fileURL`, jamais chargé
    /// en mémoire pour le corps — seul `PulseUploader.sha256Hex` en lit les
    /// octets, pour le hash). `completion` reçoit le code HTTP de la réponse,
    /// ou une erreur réseau/timeout (mappée par l'appelant vers `.keepRetry`).
    func send(_ request: URLRequest, fileURL: URL, completion: @escaping (Result<Int, Error>) -> Void)
}

enum PulseUploader {
    /// Chemin fixe du contrat §2 — `POST <baseURL>/api/ingest`.
    private static let ingestPath = "api/ingest"

    /// Construit la requête d'upload — PURE (aucune E/S, `sha256Hex` est
    /// calculé séparément et passé en paramètre), testée sans réseau. Porte le
    /// contrat §2 (méthode, `Content-Type`) et §5 (en-têtes).
    static func makeUploadRequest(baseURL: URL, token: String, watchFilename: String, sha256Hex: String) -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent(ingestPath))
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(watchFilename, forHTTPHeaderField: "X-Watch-Filename")
        request.setValue(sha256Hex, forHTTPHeaderField: "X-Content-SHA256")
        return request
    }

    /// SHA-256 hexadécimal des octets d'un fichier sur disque (contrat §4 :
    /// contrôle d'intégrité + court-circuit d'idempotence côté Pulse, non
    /// autoritatif — l'autorité reste le hash que Pulse calcule lui-même).
    /// Seule E/S : une lecture locale du `.fit` déjà sur le disque du
    /// téléphone — jamais un accès réseau.
    static func sha256Hex(ofFileAt url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Mapping réponse → action, contrat §6 — PUR, une classe de code HTTP à la
    /// fois. Toute classe non listée explicitement par le contrat (ex. 404)
    /// retombe sur `.keepRetry`, le comportement le plus sûr par défaut (ne
    /// jamais perdre/quarantainer sur un code qu'on ne reconnaît pas).
    static func outcome(forHTTPStatusCode statusCode: Int) -> PulseUploadOutcome {
        switch statusCode {
        case 200...299: return .delivered
        case 401: return .keepConfigError
        case 403: return .keepRetryLater
        case 400, 413, 415, 422: return .quarantine
        default: return .keepRetry
        }
    }

    /// Point d'entrée complet (construction + exécution via `transport` +
    /// mapping) — appelé par `PulseSpoolUploader.upload(fileURL:watchFilename:completion:)`
    /// à chaque fichier acquis dans le Spool (cf. en-tête de fichier).
    /// Une erreur de `transport` (réseau/timeout, pas de code HTTP) est mappée
    /// directement en `.keepRetry`, comme la dernière ligne du contrat §6.
    static func upload(
        fileURL: URL,
        watchFilename: String,
        baseURL: URL,
        token: String,
        transport: PulseUploadTransport,
        completion: @escaping (Result<PulseUploadOutcome, Error>) -> Void
    ) {
        do {
            let hex = try sha256Hex(ofFileAt: fileURL)
            let request = makeUploadRequest(baseURL: baseURL, token: token, watchFilename: watchFilename, sha256Hex: hex)
            transport.send(request, fileURL: fileURL) { result in
                switch result {
                case .success(let statusCode):
                    completion(.success(outcome(forHTTPStatusCode: statusCode)))
                case .failure:
                    completion(.success(.keepRetry))
                }
            }
        } catch {
            completion(.failure(error))
        }
    }
}

/// Implémentation réelle du transport — `URLSession` en configuration
/// **`.default`** (foreground) : le dépôt a pivoté vers une synchro premier-plan
/// (cf. SESSION-NOTES 2026-09-22 et en-tête de fichier), plus besoin de session
/// background ni de délégués AppDelegate. API à completion handler, autorisée
/// hors arrière-plan (`uploadTask(with:fromFile:completionHandler:)`), corps =
/// fichier sur disque comme le contrat §2 le prescrit déjà.
///
/// ÉMET RÉELLEMENT (`task.resume()`) — autorisation réseau explicite de
/// l'utilisateur, datée 2026-09-22. Instanciée par `PulseSpoolUploader`
/// ci-dessous, elle-même appelée par `GarminSession` à chaque fichier acquis.
final class URLSessionPulseUploadTransport: PulseUploadTransport {
    private let log = Logger(subsystem: "CleanYourRoom.all", category: "pulse-upload")
    private let session: URLSession

    init() {
        session = URLSession(configuration: .default)
    }

    func send(_ request: URLRequest, fileURL: URL, completion: @escaping (Result<Int, Error>) -> Void) {
        log.info("Upload démarré pour \(fileURL.lastPathComponent, privacy: .public)")
        let task = session.uploadTask(with: request, fromFile: fileURL) { [log] data, response, error in
            if let error {
                completion(.failure(error))
                return
            }
            guard let http = response as? HTTPURLResponse else {
                completion(.failure(PulseUploadError.noHTTPResponse))
                return
            }
            // Diagnostic sur rejet (non-2xx) : journalise le code EXACT + le corps
            // de réponse (message d'erreur Nest, pas de donnée de santé) — sans ça
            // on ne voit que « 400/413/415/422 » groupés, insuffisant pour trancher
            // un rejet d'ingestion. Local uniquement (Console.app).
            if !(200...299).contains(http.statusCode) {
                let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? "(vide)"
                log.error("Upload Pulse rejeté \(http.statusCode, privacy: .public) pour \(fileURL.lastPathComponent, privacy: .public) : \(body, privacy: .public)")
            }
            completion(.success(http.statusCode))
        }
        task.resume()
    }
}

/// Couture entre le Spool et `PulseUploader` — c'est ce que `GarminSession`
/// appelle, pas `PulseUploader` directement (cf. `PulseSpoolUploader` ci-dessous).
protocol SpoolUploading {
    func upload(fileURL: URL, watchFilename: String, completion: @escaping (PulseUploadOutcome) -> Void)
}

/// Implémentation concrète de `SpoolUploading`, posée entre `GarminSession` et
/// `PulseUploader`. Relit `PulseConfig.baseURL`/`PulseConfig.ingestToken` à
/// **chaque appel** plutôt qu'une fois à l'init : l'utilisateur peut renseigner
/// ces réglages (écran diagnostic, cf. `BLEDiagnosticView`) APRÈS que la montre
/// se soit déjà connectée et que des fichiers soient déjà en file — une valeur
/// mise en cache à la construction manquerait ce cas (token renseigné en cours
/// de session).
final class PulseSpoolUploader: SpoolUploading {
    private let transport: PulseUploadTransport

    init(transport: PulseUploadTransport = URLSessionPulseUploadTransport()) {
        self.transport = transport
    }

    func upload(fileURL: URL, watchFilename: String, completion: @escaping (PulseUploadOutcome) -> Void) {
        guard let baseURL = PulseConfig.baseURL, let token = PulseConfig.ingestToken, !token.isEmpty else {
            completion(.keepConfigError)
            return
        }
        PulseUploader.upload(fileURL: fileURL, watchFilename: watchFilename, baseURL: baseURL, token: token, transport: transport) { result in
            switch result {
            case .success(let outcome):
                completion(outcome)
            case .failure:
                // Ex. lecture du `.fit` impossible (`sha256Hex` a levé) : garder
                // en spool, retenter à la prochaine sync plutôt que de perdre le
                // fichier — même logique prudente que `.keepRetry` côté mapping HTTP.
                completion(.keepRetry)
            }
        }
    }
}
