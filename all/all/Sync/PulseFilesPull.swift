//
//  PulseFilesPull.swift
//  all (bridge-connect)
//
//  Rapatriement des `.fit` de la montre, Pulse → téléphone, en mode Stockage « Les
//  deux ». Contrat à respecter à la lettre :
//  `custom-connect/docs/pulse-files-pull-contract.md`. Pulse détient ~12 000 fichiers
//  que l'app n'a pas collectés elle-même ; le téléphone doit tout détenir.
//
//  Découpage :
//   - PUR : `PulseFilesWire` (routes, requêtes) ;
//   - `PulseFilesPullTransport` : couture réseau injectable — SEUL
//     `URLSessionPulseFilesTransport` parle à Pulse (`GET api/files/manifest`,
//     `GET api/files/<hash>`, Bearer = jeton d'ingestion). Aucun test ne l'instancie ;
//   - `PulseFilesPullEngine` : UNE passe — manifeste complet, écart des hash connus,
//     téléchargement du plus récent au plus ancien (2 à la fois), vérification du hash,
//     ingestion par `LocalIngestor.ingest` (la MÊME fonction que le spool, sans passer
//     par son journal : ces fichiers n'ont pas d'identité montre, ne sont jamais
//     renvoyés à Pulse ni archivés sur la montre) ;
//   - `PulseFilesPullService` (`PulseFilesPullService.swift`) : mode, santé, reprise.
//
//  Reprise : aucun curseur. Le diff manifeste − base locale (hash ingérés, activités,
//  fichiers écartés) fait foi à chaque passe ; interrompre à tout instant est sans
//  danger (un fichier est ingéré en UNE transaction, ou pas du tout).
//
//  Écritures en base : chaque fichier s'ingère dans une section brève
//  (`LocalIngestor.runBetween`), sérialisée avec les passes d'ingestion du spool et avec
//  la purge ; entre deux fichiers, la base est libre pour les écrans et l'échange des
//  saisies.
//

import Foundation

// MARK: - Fil de fer (contrat §2)

struct PulseManifestEntry: Decodable, Equatable, Sendable {
    let hash: String
    /// `activity`, `wellness`, `sleep` — toute autre valeur est tolérée.
    let kind: String
    let fileName: String?
    let size: Int?
}

struct PulseManifestPage: Decodable, Sendable {
    let total: Int?
    let offset: Int?
    let files: [PulseManifestEntry]
}

/// Réponse HTTP brute du manifeste — la couture ne connaît ni `URLSession` ni
/// `URLResponse`.
struct PulseFilesHTTPResponse: Sendable {
    var status: Int
    var body: Data
}

enum PulseFilesPullError: Error, Equatable {
    /// Adresse de Pulse ou jeton d'ingestion absents.
    case notConfigured
}

/// Couture d'injection réseau — substituée par un double dans tous les tests.
protocol PulseFilesPullTransport: Sendable {
    /// Une page du manifeste. Lève `PulseFilesPullError.notConfigured` sans adresse/jeton ;
    /// toute autre erreur est un échec de transport (hors-ligne, délai, TLS…).
    func manifest(offset: Int, limit: Int) async throws -> PulseFilesHTTPResponse
    /// Télécharge le fichier de `hash` VERS `destination` (jamais en mémoire) et rend le
    /// code HTTP. Hors 2xx, rien n'est laissé à `destination`.
    func download(hash: String, to destination: URL) async throws -> Int
}

enum PulseFilesWire {
    static let manifestPath = "api/files/manifest"
    static let filePath = "api/files"
    /// Plafond du serveur : au-delà, 400 (pas d'écrêtage, contrat §2).
    static let maxPageSize = 2_000

    static func manifestRequest(baseURL: URL, token: String, offset: Int, limit: Int) -> URLRequest {
        var components = URLComponents(url: baseURL.appendingPathComponent(manifestPath), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "offset", value: String(offset)), URLQueryItem(name: "limit", value: String(limit))]
        var request = URLRequest(url: components?.url ?? baseURL.appendingPathComponent(manifestPath))
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    static func fileRequest(baseURL: URL, token: String, hash: String) -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent("\(filePath)/\(hash)"))
        request.httpMethod = "GET"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }
}

/// Implémentation RÉELLE (la seule qui touche le réseau). Session éphémère dédiée, comme
/// l'échange des saisies : pas de cookies partagés, l'auth est le Bearer.
struct URLSessionPulseFilesTransport: PulseFilesPullTransport {
    private let session: URLSession
    private let baseURLProvider: @Sendable () -> URL?
    private let tokenProvider: @Sendable () -> String?

    init(
        baseURLProvider: @escaping @Sendable () -> URL? = { PulseConfig.baseURL },
        tokenProvider: @escaping @Sendable () -> String? = { PulseConfig.ingestToken }
    ) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 600
        configuration.httpMaximumConnectionsPerHost = 2
        session = URLSession(configuration: configuration)
        self.baseURLProvider = baseURLProvider
        self.tokenProvider = tokenProvider
    }

    private func credentials() throws -> (URL, String) {
        guard let baseURL = baseURLProvider(), let token = tokenProvider(), !token.isEmpty else {
            throw PulseFilesPullError.notConfigured
        }
        return (baseURL, token)
    }

    func manifest(offset: Int, limit: Int) async throws -> PulseFilesHTTPResponse {
        let (baseURL, token) = try credentials()
        let (data, response) = try await session.data(
            for: PulseFilesWire.manifestRequest(baseURL: baseURL, token: token, offset: offset, limit: limit))
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return PulseFilesHTTPResponse(status: http.statusCode, body: data)
    }

    func download(hash: String, to destination: URL) async throws -> Int {
        let (baseURL, token) = try credentials()
        let (temporary, response) = try await session.download(
            for: PulseFilesWire.fileRequest(baseURL: baseURL, token: token, hash: hash))
        guard let http = response as? HTTPURLResponse else {
            try? FileManager.default.removeItem(at: temporary)
            throw URLError(.badServerResponse)
        }
        guard http.statusCode == 200 else {
            try? FileManager.default.removeItem(at: temporary)
            return http.statusCode
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporary, to: destination)
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUnlessOpen], ofItemAtPath: destination.path)
        return http.statusCode
    }
}

// MARK: - Moteur

/// Issue d'UNE passe, réduite à ce qui décide de la suite (santé, reprise).
enum PulseFilesPullOutcome: Equatable, Sendable {
    /// Tout ce que le manifeste listait est connu localement.
    case completed
    /// Passe coupée (arrière-plan, changement de mode, purge) : le prochain déclencheur
    /// la reprend, sans minuterie.
    case interrupted
    /// Adresse ou jeton absents.
    case notConfigured
    /// 401 — erreur de configuration, déjà signalée par `PulseUploadHealth`.
    case unauthorized
    /// 404 sur le manifeste : serveur pas encore à jour. Pas d'erreur, pas de reprise.
    case routeMissing
    /// Transport, 4xx/5xx autre que 401/404, réponse illisible.
    case networkOrServerFailure
    /// La base ou le disque local a échoué (occupée au-delà du `busy_timeout`…).
    case storageFailure
}

struct PulseFilesPullReport: Equatable {
    var outcome: PulseFilesPullOutcome = .completed
    /// Entrées du manifeste reçues (hash valides, sans doublon).
    var listed = 0
    /// Entrées à télécharger après l'écart avec la base locale.
    var toFetch = 0
    /// Fichiers ingérés (données nouvelles en base).
    var ingested = 0
    /// Dont `.fit` d'activité gardés.
    var activitiesKept = 0
    /// Fichiers mémorisés « ignoré » (rien à retenir) ou déjà connus à l'arrivée.
    var ignored = 0
    /// Fichiers mémorisés « en échec » (hash différent, FIT indécodable).
    var failed = 0
    /// 404/400 au téléchargement : disparu de Pulse entre-temps, ni mémorisé ni erreur.
    var missing = 0

    /// Fichiers traités (quelle que soit l'issue) dans cette passe.
    var processed: Int { ingested + ignored + failed + missing }
}

final class PulseFilesPullEngine: @unchecked Sendable {
    /// Issue d'UN fichier. `abort` interrompt la passe.
    private enum FileStep: Sendable {
        case ingested(activityKept: Bool)
        case ignored
        case failed
        case missing
        case abort(PulseFilesPullOutcome)
    }

    typealias Ingest = @Sendable (URL, String, String, LocalDb) -> LocalIngestResult
    /// Section brève, sérialisée avec les passes d'ingestion et la purge.
    typealias Serialize = @Sendable (@escaping @Sendable () -> Void) async -> Void

    static let defaultConcurrency = 2
    /// Garde-fou contre un manifeste qui ne se terminerait jamais.
    private static let maxPages = 1_000

    private let db: LocalDb
    private let transport: PulseFilesPullTransport
    private let store: PulseFilesStore
    private let pageSize: Int
    private let concurrency: Int
    private let ingest: Ingest
    private let serialize: Serialize
    private let refresh: @Sendable () -> Void
    private let now: @Sendable () -> Date
    private let refreshInterval: TimeInterval

    init(
        db: LocalDb, transport: PulseFilesPullTransport, store: PulseFilesStore,
        pageSize: Int = PulseFilesWire.maxPageSize, concurrency: Int = PulseFilesPullEngine.defaultConcurrency,
        ingest: @escaping Ingest = { url, hash, name, db in LocalIngestor.ingest(fileURL: url, hash: hash, fileName: name, into: db) },
        serialize: @escaping Serialize = { work in await LocalIngestor.runBetween { work() } },
        refresh: @escaping @Sendable () -> Void = { DataRefreshNotifier.postDataDidChangeDebounced() },
        now: @escaping @Sendable () -> Date = { Date() },
        refreshInterval: TimeInterval = 30
    ) {
        self.db = db
        self.transport = transport
        self.store = store
        self.pageSize = min(max(1, pageSize), PulseFilesWire.maxPageSize)
        self.concurrency = max(1, concurrency)
        self.ingest = ingest
        self.serialize = serialize
        self.refresh = refresh
        self.now = now
        self.refreshInterval = refreshInterval
    }

    /// Une passe complète. Ne lève jamais : l'issue est dans le rapport. `progress` reçoit
    /// le nombre de fichiers RESTANT à traiter — le total au départ (seulement s'il y en
    /// a), puis une valeur de moins après chaque fichier, quelle que soit son issue.
    func run(progress: @Sendable (Int) -> Void = { _ in }) async -> PulseFilesPullReport {
        var report = PulseFilesPullReport()
        do { try store.prepare() } catch {
            report.outcome = .storageFailure
            return report
        }
        store.clearIncoming()

        // 1. Manifeste complet, page après page.
        let entries: [PulseManifestEntry]
        switch await readManifest() {
        case .failure(let outcome):
            report.outcome = outcome
            return report
        case .success(let all):
            entries = all
        }
        report.listed = entries.count

        // 2. Écart avec ce que la base connaît : ingéré, activité, ou écarté.
        let known: Set<String>
        do { known = try db.pulledKnownHashes() } catch {
            report.outcome = .storageFailure
            return report
        }
        let todo = entries.filter { !known.contains($0.hash) }
        report.toFetch = todo.count
        if !todo.isEmpty { progress(todo.count) }

        // 3. Téléchargement, du plus récent au plus ancien (ordre du manifeste), `concurrency`
        // à la fois ; chaque fichier ingéré dès qu'il est reçu.
        var abort: PulseFilesPullOutcome?
        var lastRefresh = now()
        var inserted = false
        var done = 0
        await withTaskGroup(of: FileStep.self) { group in
            var next = todo.makeIterator()
            func launch() -> Bool {
                guard let entry = next.next() else { return false }
                group.addTask { [self] in await process(entry) }
                return true
            }
            for _ in 0..<concurrency { if !launch() { break } }
            while let step = await group.next() {
                done += 1
                switch step {
                case .ingested(let kept):
                    report.ingested += 1
                    if kept { report.activitiesKept += 1 }
                    inserted = true
                case .ignored: report.ignored += 1
                case .failed: report.failed += 1
                case .missing: report.missing += 1
                case .abort(let outcome):
                    if abort == nil { abort = outcome }
                }
                if abort == nil { progress(todo.count - done) }
                // Rafraîchissement GROUPÉ des écrans : au plus un toutes les `refreshInterval`.
                if inserted, now().timeIntervalSince(lastRefresh) >= refreshInterval {
                    refresh()
                    lastRefresh = now()
                    inserted = false
                }
                if abort == nil, !Task.isCancelled { _ = launch() }
            }
        }
        if inserted { refresh() }
        report.outcome = abort ?? (Task.isCancelled ? .interrupted : .completed)
        return report
    }

    // MARK: - Manifeste

    private enum ManifestResult {
        case success([PulseManifestEntry])
        case failure(PulseFilesPullOutcome)
    }

    /// Pagine strictement (`limit` ≤ 2 000) et avance `offset` du nombre d'entrées REÇUES,
    /// jusqu'à `total` ou une page vide : `total` peut être faux d'une unité (fichier
    /// disparu entre deux lectures), on ne boucle jamais pour l'atteindre. Aucun ordre
    /// chronologique n'est supposé (l'ordre du serveur est la date d'import).
    private func readManifest() async -> ManifestResult {
        var entries: [PulseManifestEntry] = []
        var seen = Set<String>()
        var offset = 0
        for _ in 0..<Self.maxPages {
            if Task.isCancelled { return .failure(.interrupted) }
            let http: PulseFilesHTTPResponse
            do {
                http = try await transport.manifest(offset: offset, limit: pageSize)
            } catch {
                return .failure(Self.classify(error))
            }
            switch http.status {
            case 200..<300: break
            case 401: return .failure(.unauthorized)
            case 404 where offset == 0: return .failure(.routeMissing)
            default: return .failure(.networkOrServerFailure)
            }
            guard let page = try? JSONDecoder().decode(PulseManifestPage.self, from: http.body) else {
                return .failure(.networkOrServerFailure)
            }
            guard !page.files.isEmpty else { break }
            for file in page.files {
                // Barrière de forme : un hash est le nom d'un fichier local et un segment d'URL.
                let hash = file.hash.lowercased()
                guard PulseFilesStore.isHash(hash), seen.insert(hash).inserted else { continue }
                entries.append(PulseManifestEntry(hash: hash, kind: file.kind, fileName: file.fileName, size: file.size))
            }
            offset += page.files.count
            if let total = page.total, offset >= total { break }
        }
        return .success(entries)
    }

    // MARK: - Un fichier

    private func process(_ entry: PulseManifestEntry) async -> FileStep {
        if Task.isCancelled { return .abort(.interrupted) }
        let staged = store.incomingURL(hash: entry.hash)
        defer { try? FileManager.default.removeItem(at: staged) }

        let status: Int
        do {
            status = try await transport.download(hash: entry.hash, to: staged)
        } catch {
            return .abort(Self.classify(error))
        }
        switch status {
        case 200..<300: break
        case 401: return .abort(.unauthorized)
        // Disparu de Pulse (activité supprimée…) : pas une erreur de passe, pas un échec
        // définitif — le prochain manifeste ne le listera plus.
        case 400, 404: return .missing
        default: return .abort(.networkOrServerFailure)
        }

        // Le serveur ne recalcule pas le hash avant l'envoi : c'est ici qu'on le vérifie.
        let actual: String
        do { actual = try PulseUploader.sha256Hex(ofFileAt: staged) } catch { return .abort(.storageFailure) }

        let outcome = Outcome()
        let fileName = Self.localName(for: entry)
        await serialize { [self] in outcome.step = ingestStaged(entry, at: staged, actualHash: actual, fileName: fileName) }
        return outcome.step ?? .abort(.interrupted)
    }

    /// Boîte pour rapporter l'issue d'une section sérialisée (la fermeture ne renvoie rien).
    private final class Outcome: @unchecked Sendable {
        var step: FileStep?
    }

    /// Dans la section sérialisée : vérification, ingestion, conservation. Une activité
    /// est PLACÉE avant d'être ingérée (si le manifeste l'annonce) : un arrêt entre les
    /// deux laisse un fichier orphelin (re-ingéré au prochain passage), jamais une ligne
    /// en base sans son `.fit`.
    private func ingestStaged(_ entry: PulseManifestEntry, at staged: URL, actualHash: String, fileName: String) -> FileStep {
        if Task.isCancelled { return .abort(.interrupted) }
        if actualHash != entry.hash {
            do { try db.markPulled(hash: entry.hash, as: .failed, detail: "hash reçu différent") } catch { return .abort(.storageFailure) }
            return .failed
        }
        let announcedActivity = entry.kind == "activity"
        var source = staged
        if announcedActivity {
            do { source = try store.keep(staged, hash: entry.hash) } catch { return .abort(.storageFailure) }
        }
        let result = ingest(source, entry.hash, fileName, db)
        switch result.kind {
        case .activity:
            // Type annoncé autrement que `activity` : le fichier est tout de même gardé.
            if !announcedActivity { _ = try? store.keep(staged, hash: entry.hash) }
            return .ingested(activityKept: true)
        case .wellness, .sleep:
            if announcedActivity { store.removeKept(hash: entry.hash) }
            return .ingested(activityKept: false)
        case .duplicate:
            // Déjà en base (ingéré entre-temps par le spool) : rien à écrire. Le `.fit`
            // placé reste (redondant au pire, jamais le seul exemplaire perdu).
            return .ignored
        case .skipped:
            if announcedActivity { store.removeKept(hash: entry.hash) }
            do { try db.markPulled(hash: entry.hash, as: .ignored, detail: nil) } catch { return .abort(.storageFailure) }
            return .ignored
        case .error(let message):
            if announcedActivity { store.removeKept(hash: entry.hash) }
            do { try db.markPulled(hash: entry.hash, as: .failed, detail: message) } catch { return .abort(.storageFailure) }
            return .failed
        case .storageError:
            // Ce n'est pas le fichier : retenté à la prochaine passe.
            if announcedActivity { store.removeKept(hash: entry.hash) }
            return .abort(.storageFailure)
        }
    }

    // MARK: - Utilitaires purs

    /// Nom enregistré en base (`file_name`) : celui de Pulse s'il y en a un, sinon dérivé
    /// du hash. Jamais un chemin.
    static func localName(for entry: PulseManifestEntry) -> String {
        let name = ((entry.fileName ?? "") as NSString).lastPathComponent
        return name.isEmpty || name == "." || name == ".." ? "\(entry.hash).fit" : String(name.prefix(255))
    }

    static func classify(_ error: Error) -> PulseFilesPullOutcome {
        if error is CancellationError || Task.isCancelled || (error as? URLError)?.code == .cancelled { return .interrupted }
        if (error as? PulseFilesPullError) == .notConfigured { return .notConfigured }
        return .networkOrServerFailure
    }
}
