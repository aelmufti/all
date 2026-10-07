//
//  SaisieSync.swift
//  all (bridge-connect)
//
//  Échange des SAISIES (nutrition, poids, profil, réveil, programme) entre la base
//  locale et Pulse, en mode Stockage « Les deux ». Contrat à respecter à la lettre :
//  `custom-connect/docs/pulse-saisies-sync-contract.md`.
//
//  Découpage :
//   - PUR / base locale : collecte, sérialisation et application des changements —
//     `Local/Db/LocalDb+Saisies.swift` (testé sur des bases temporaires) ;
//   - `SaisieSyncEngine` : un échange complet (lots ≤ 5 000, curseurs mémorisés
//     seulement après application réussie, drapeau `initial`), transport injectable ;
//   - `SaisieSyncCoordinator` : sérialisation des échanges (jamais deux en
//     parallèle ; une demande reçue pendant un échange en déclenche un autre à la
//     fin — même logique que `Local/SerialPassGate.swift`, version `async`) ;
//   - `SaisieSyncService` : garde de mode, santé (`PulseUploadHealth`), effets de
//     bord après changements distants (poids du profil, réveil, rafraîchissement),
//     activité déclarée à la bannière (`SyncWork`) et REPRISE automatique après échec
//     (`SaisieRetryPolicy`, minuterie injectable).
//
//  Réseau : SEUL `URLSessionSaisieSyncTransport` parle à Pulse (`POST
//  api/saisies/sync`, Bearer = jeton d'ingestion — même garde que `POST /api/ingest`).
//  Aucun test ne l'instancie.
//

import Foundation
import os

// MARK: - Fil de fer (contrat §4)

struct SaisieSyncRequest: Encodable {
    var since: Int
    var initial: Bool
    var changes: [SaisieChange]
}

struct SaisieSyncResponse: Decodable {
    var cursor: Int
    var applied: Int?
    var skipped: Int?
    var changes: [SaisieChange]
}

/// Réponse HTTP brute — la couture d'injection ne connaît ni `URLSession` ni
/// `URLResponse`.
struct SaisieSyncHTTPResponse {
    var status: Int
    var body: Data
}

enum SaisieSyncError: Error {
    /// Adresse de Pulse ou jeton d'ingestion absents.
    case notConfigured
    /// 401 — jeton absent ou invalide : seul cas qui alimente `PulseUploadHealth`.
    case unauthorized
    /// Autre statut hors 2xx (400, 413, 5xx…).
    case http(Int)
    /// 2xx mais corps illisible.
    case invalidResponse
    /// Échec avant d'obtenir une réponse (DNS, TLS, hors-ligne, délai) — ne signale rien.
    case transport(Error)
}

/// Couture d'injection réseau — substituée par un double dans tous les tests.
protocol SaisieSyncTransport: Sendable {
    func post(_ body: Data) async throws -> SaisieSyncHTTPResponse
}

enum SaisieSyncWire {
    static let path = "api/saisies/sync"
    /// Au-delà, le serveur répond 413 (contrat §4) : le téléphone découpe.
    static let maxChangesPerBatch = 5_000

    /// Requête PURE (aucune E/S) : méthode, route, jeton, corps JSON.
    static func makeRequest(baseURL: URL, token: String, body: Data) -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = body
        return request
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
}

/// Implémentation RÉELLE (la seule qui touche le réseau). Session éphémère dédiée :
/// pas de cookies partagés avec `PulseAPIClient` (l'auth est le Bearer), délai court
/// pour ne pas bloquer longtemps les lectures qui attendent un échange.
struct URLSessionSaisieSyncTransport: SaisieSyncTransport {
    private let session: URLSession
    private let baseURLProvider: @Sendable () -> URL?
    private let tokenProvider: @Sendable () -> String?

    init(
        baseURLProvider: @escaping @Sendable () -> URL? = { PulseConfig.baseURL },
        tokenProvider: @escaping @Sendable () -> String? = { PulseConfig.ingestToken }
    ) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        session = URLSession(configuration: configuration)
        self.baseURLProvider = baseURLProvider
        self.tokenProvider = tokenProvider
    }

    func post(_ body: Data) async throws -> SaisieSyncHTTPResponse {
        guard let baseURL = baseURLProvider(), let token = tokenProvider(), !token.isEmpty else {
            throw SaisieSyncError.notConfigured
        }
        let request = SaisieSyncWire.makeRequest(baseURL: baseURL, token: token, body: body)
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw SaisieSyncError.transport(URLError(.badServerResponse))
            }
            return SaisieSyncHTTPResponse(status: http.statusCode, body: data)
        } catch let error as SaisieSyncError {
            throw error
        } catch {
            throw SaisieSyncError.transport(error)
        }
    }
}

// MARK: - Moteur

struct SaisieSyncReport: Equatable {
    var batches = 0
    var sent = 0
    var applied = 0
    var skipped = 0
    var weightChanged = false
    var wakeScheduleChanged = false
    /// Valeur locale de `settings.wakeSchedule` après application (`nil` : absente),
    /// renseignée seulement si `wakeScheduleChanged`.
    var wakeScheduleJSON: String?
}

/// Un échange complet : tant qu'il reste des changements locaux, envoie un lot,
/// applique la réponse. Ne tient aucun état hors de la base (le `cursor` et le `rev`
/// accusé y sont dans `saisie_sync_state`). Non sérialisé lui-même : c'est
/// `SaisieSyncCoordinator` qui garantit qu'il n'en tourne qu'un.
final class SaisieSyncEngine: @unchecked Sendable {
    private let db: LocalDb
    private let transport: SaisieSyncTransport
    private let batchSize: Int
    /// Garde-fou contre une boucle de lots qui ne progresserait pas.
    private static let maxBatches = 1_000

    init(db: LocalDb, transport: SaisieSyncTransport, batchSize: Int = SaisieSyncWire.maxChangesPerBatch) {
        self.db = db
        self.transport = transport
        self.batchSize = max(1, batchSize)
    }

    func hasPendingChanges() -> Bool {
        (try? db.hasPendingSaisieChanges()) ?? false
    }

    /// Reste-t-il quelque chose à échanger : des changements locaux non accusés, OU un
    /// premier échange jamais abouti (contrat §6). Une base illisible compte comme « oui »
    /// (on ne sait pas, on retentera) — contrairement à `hasPendingChanges`, qui sert au
    /// routage des lectures.
    func needsExchange() -> Bool {
        guard let state = try? db.saisieSyncState() else { return true }
        if !state.initialDone { return true }
        return (try? db.hasPendingSaisieChanges()) ?? true
    }

    /// §5 : après un `weight` appliqué, le poids du profil se resynchronise.
    func resyncWeightProfile() {
        try? db.syncWeightProfile()
    }

    func exchange() async throws -> SaisieSyncReport {
        var report = SaisieSyncReport()
        for _ in 0..<Self.maxBatches {
            let state = try db.saisieSyncState()
            let batch = try db.collectSaisieChanges(afterRev: state.ackedRev, limit: batchSize)
            // `initial` reste vrai pour TOUS les lots du premier échange (le serveur
            // rapproche les `uid` sur chacun, §6) ; il ne tombe qu'après le dernier.
            let request = SaisieSyncRequest(since: state.cursor, initial: !state.initialDone, changes: batch.changes)
            let response = try await send(request)

            let result = try db.applySaisieResponse(
                cursor: response.cursor, changes: response.changes,
                sentMaxRev: batch.maxRev, markInitialDone: !batch.hasMore)

            report.batches += 1
            report.sent += batch.changes.count
            report.applied += result.applied
            report.skipped += result.skipped
            report.weightChanged = report.weightChanged || result.weightChanged
            report.wakeScheduleChanged = report.wakeScheduleChanged || result.wakeScheduleChanged
            guard batch.hasMore else { break }
        }
        if report.wakeScheduleChanged {
            report.wakeScheduleJSON = try db.settingValue(key: "wakeSchedule")
        }
        return report
    }

    private func send(_ request: SaisieSyncRequest) async throws -> SaisieSyncResponse {
        let body: Data
        do { body = try SaisieSyncWire.encoder.encode(request) } catch { throw SaisieSyncError.invalidResponse }
        let http = try await transport.post(body)
        if http.status == 401 { throw SaisieSyncError.unauthorized }
        guard (200..<300).contains(http.status) else { throw SaisieSyncError.http(http.status) }
        guard let response = try? JSONDecoder().decode(SaisieSyncResponse.self, from: http.body) else {
            throw SaisieSyncError.invalidResponse
        }
        return response
    }
}

// MARK: - Sérialisation des échanges

/// Jamais deux passes en parallèle ; une demande reçue pendant une passe en
/// déclenche UNE autre juste après (dix demandes pendant une passe n'en produisent
/// qu'une). `requestAndWait` rend la main quand le travail dû au moment de l'appel
/// est terminé.
actor SaisieSyncCoordinator {
    private let pass: @Sendable () async -> Void
    private var running = false
    private var rerun = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(pass: @escaping @Sendable () async -> Void) {
        self.pass = pass
    }

    var isIdle: Bool { !running }

    func request() {
        if running {
            rerun = true
            return
        }
        running = true
        Task { await self.loop() }
    }

    func requestAndWait() async {
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
            request()
        }
    }

    /// Exécute `work` quand aucun échange ne tourne, et en retient les nouveaux tant
    /// qu'il court : une demande reçue entre-temps déclenche UN échange à la fin.
    /// Sert aux travaux qui vident la base (purge des données de l'iPhone) : un échange
    /// en vol appliquerait sa réponse (curseur compris) sur une base remise à zéro.
    func runExclusively<T>(_ work: @Sendable () async throws -> T) async rethrows -> T {
        // Pas de suspension entre le test et la prise : l'acteur ne laisse personne
        // s'intercaler.
        while running { try? await Task.sleep(nanoseconds: 10_000_000) }
        running = true
        defer { finishExclusive() }
        return try await work()
    }

    private func finishExclusive() {
        if rerun {
            Task { await self.loop() }
        } else {
            running = false
        }
    }

    private func loop() async {
        repeat {
            rerun = false
            await pass()
        } while rerun
        running = false
        let done = waiters
        waiters = []
        for waiter in done { waiter.resume() }
    }
}

// MARK: - Service

/// Ce que l'écran d'accueil sait déjà afficher (`PulseUploadHealth`), alimenté par
/// l'échange.
enum SaisieSyncHealthEvent: Equatable {
    case unauthorized
    case succeeded
}

enum SaisieSyncHealth {
    /// 401 → même signal que le jeton refusé à l'envoi des fichiers. Un succès ne
    /// lève QUE ce signal : l'échange n'est pas soumis à la source de synchro, il ne
    /// prouve rien sur `wrongSource` (403 des fichiers). Les erreurs de transport
    /// n'arrivent jamais ici.
    @MainActor
    static func apply(_ event: SaisieSyncHealthEvent, to health: PulseUploadHealth) {
        switch event {
        case .unauthorized:
            health.record(.keepConfigError)
        case .succeeded:
            if health.configProblem == .invalidToken { health.record(.delivered) }
        }
    }

    static func observeFromAnyThread(_ event: SaisieSyncHealthEvent) {
        Task { @MainActor in apply(event, to: PulseUploadHealth.shared) }
    }
}

/// Ce que `PulseAPIClient` attend d'un échange de saisies (injectable en test).
protocol SaisieSyncing: AnyObject, Sendable {
    /// Demande un échange sans attendre (mode « Les deux » seulement).
    func requestExchange()
    /// Reste-t-il des changements locaux non envoyés, APRÈS une tentative d'échange ?
    /// Sans changement en attente : `false`, sans réseau.
    func stillPendingAfterAttempt() async -> Bool
}

final class SaisieSyncService: SaisieSyncing, @unchecked Sendable {
    static let shared = SaisieSyncService(
        engineProvider: {
            guard let db = try? LocalDb() else { return nil }
            return SaisieSyncEngine(db: db, transport: URLSessionSaisieSyncTransport())
        },
        health: { SaisieSyncHealth.observeFromAnyThread($0) },
        afterRemoteChanges: { report in
            if report.wakeScheduleChanged {
                await MainActor.run { WakeScheduleStore.shared.adoptSynced(json: report.wakeScheduleJSON) }
            }
            DataRefreshNotifier.postDataDidChangeDebounced()
        })

    private static let log = Logger(subsystem: "CleanYourRoom.all", category: "saisie-sync")
    /// Après un échec d'échange (transport, 401, 4xx/5xx), les lectures ne rattendent
    /// pas Pulse pendant ce délai (elles se servent en local tant qu'il reste des
    /// changements).
    static let retryDelay: TimeInterval = 15

    private let engineProvider: @Sendable () -> SaisieSyncEngine?
    private let modeProvider: @Sendable () -> StorageMode
    private let health: @Sendable (SaisieSyncHealthEvent) -> Void
    private let afterRemoteChanges: @Sendable (SaisieSyncReport) async -> Void
    private let now: @Sendable () -> Date
    private let reporter: SyncWorkReporting
    private let retryTimer: WakeTimer

    private let lock = NSLock()
    private var cachedEngine: SaisieSyncEngine?
    private var engineResolved = false
    private var lastFailure: Date?
    private var coordinator: SaisieSyncCoordinator!
    /// App au premier plan ? Vrai au lancement (le premier `.active` de la scène
    /// n'est pas toujours notifié) ; `allApp` le met à jour aux passages en arrière-plan.
    private var foreground = true
    /// Tentatives consécutives sans aboutissement complet (`SaisieRetryPolicy`).
    private var retryAttempt = 0
    /// La reprise armée suit un échec de BASE (occupée) : la fin d'une passe d'ingestion
    /// la devance (`ingestPassDidEnd`).
    private var retryWaitsForIngest = false

    init(
        engineProvider: @escaping @Sendable () -> SaisieSyncEngine?,
        modeProvider: @escaping @Sendable () -> StorageMode = { StorageModeStore.current },
        health: @escaping @Sendable (SaisieSyncHealthEvent) -> Void,
        afterRemoteChanges: @escaping @Sendable (SaisieSyncReport) async -> Void,
        now: @escaping @Sendable () -> Date = { Date() },
        reporter: SyncWorkReporting = MainSyncWorkReporter(),
        retryTimer: WakeTimer = TaskWakeTimer()
    ) {
        self.engineProvider = engineProvider
        self.modeProvider = modeProvider
        self.health = health
        self.afterRemoteChanges = afterRemoteChanges
        self.now = now
        self.reporter = reporter
        self.retryTimer = retryTimer
        // `weak` : une passe encore en file quand le service disparaît (tests) s'éteint
        // sans rien faire au lieu d'abattre le processus.
        coordinator = SaisieSyncCoordinator { [weak self] in await self?.runPass() }
    }

    /// Opérations de la passe, exposées aux tests.
    var isIdle: Bool {
        get async { await coordinator.isIdle }
    }

    private var engine: SaisieSyncEngine? {
        lock.lock()
        defer { lock.unlock() }
        if !engineResolved {
            cachedEngine = engineProvider()
            engineResolved = true
        }
        return cachedEngine
    }

    func requestExchange() {
        // Jamais en mode Pulse ni Téléphone : le journal local continue de
        // s'alimenter par les triggers, il partira au passage en « Les deux ».
        guard modeProvider() == .both else { return }
        Task.detached(priority: .utility) { [coordinator] in await coordinator?.request() }
    }

    /// Lance un échange et attend sa fin (mode « Les deux » seulement).
    func exchangeAndWait() async {
        guard modeProvider() == .both else { return }
        await coordinator.requestAndWait()
    }

    /// Exécute `work` quand aucun échange ne tourne, sans en laisser démarrer pendant
    /// ce temps (cf. `SaisieSyncCoordinator.runExclusively`). Quel que soit le mode.
    func runExclusively<T>(_ work: @Sendable () async throws -> T) async rethrows -> T {
        try await coordinator.runExclusively(work)
    }

    func stillPendingAfterAttempt() async -> Bool {
        guard modeProvider() == .both, let engine, engine.hasPendingChanges() else { return false }
        lock.lock()
        let recentFailure = lastFailure.map { now().timeIntervalSince($0) < Self.retryDelay } ?? false
        lock.unlock()
        if !recentFailure { await coordinator.requestAndWait() }
        return engine.hasPendingChanges()
    }

    private func markFailure() {
        lock.lock()
        lastFailure = now()
        lock.unlock()
    }

    private func runPass() async {
        guard modeProvider() == .both, let engine else {
            cancelRetry()
            return
        }
        // Déclarée à la bannière pour toute la durée de la passe ; `defer` = libérée sur
        // TOUTES les sorties (succès, erreur, configuration absente).
        reporter.exchangeBegan()
        defer { reporter.exchangeEnded() }
        let outcome = await exchangeOnce(engine)
        scheduleRetry(after: outcome, engine: engine)
    }

    private func exchangeOnce(_ engine: SaisieSyncEngine) async -> SaisieSyncPassOutcome {
        do {
            let report = try await engine.exchange()
            lock.lock()
            lastFailure = nil
            lock.unlock()
            health(.succeeded)
            guard report.applied > 0 else { return .succeeded }
            Self.log.info("échange : \(report.applied, privacy: .public) changement(s) distant(s) appliqué(s)")
            if report.weightChanged { engine.resyncWeightProfile() }
            await afterRemoteChanges(report)
            return .succeeded
        } catch SaisieSyncError.notConfigured {
            // Pas d'adresse ou de jeton : rien à signaler ici (l'Accueil le sait déjà).
            return .notConfigured
        } catch {
            markFailure()
            if case SaisieSyncError.unauthorized = error {
                health(.unauthorized)
                return .unauthorized
            } else if case SaisieSyncError.transport = error {
                // Hors-ligne : normal, ne signale rien.
                return .networkOrServerFailure
            } else if error is SaisieSyncError {
                // 400/413/5xx, réponse illisible : rien n'a été appliqué ni mémorisé.
                Self.log.error("échange de saisies échoué : \(String(describing: error), privacy: .public)")
                return .networkOrServerFailure
            } else {
                // Tout le reste vient de la base locale (occupée au-delà du
                // `busy_timeout`, erreur SQLite) : le moteur ne lève que des
                // `SaisieSyncError` côté réseau.
                Self.log.error("échange de saisies échoué (base) : \(String(describing: error), privacy: .public)")
                return .storageFailure
            }
        }
    }

    // MARK: - Reprise automatique (cf. `SaisieRetryPolicy`)

    /// Programme (ou annule) la prochaine tentative. `arm` REMPLACE la minuterie
    /// précédente : jamais deux en parallèle. Appelée depuis la passe, donc sérialisée par
    /// le coordinateur.
    private func scheduleRetry(after outcome: SaisieSyncPassOutcome, engine: SaisieSyncEngine) {
        lock.lock()
        let isForeground = foreground
        let attempt = retryAttempt
        lock.unlock()
        // Le test de « reste-t-il quelque chose » lit la base : seulement quand il peut
        // changer la décision.
        let stillNeeded = isForeground && outcome != .notConfigured && outcome != .unauthorized && engine.needsExchange()
        let decision = SaisieRetryPolicy.decide(
            outcome: outcome, foreground: isForeground, mode: modeProvider(), stillNeeded: stillNeeded, attempt: attempt)
        switch decision {
        case .stop:
            cancelRetry()
        case .retry(let delay, let nextAttempt):
            lock.lock()
            retryAttempt = nextAttempt
            retryWaitsForIngest = outcome == .storageFailure
            lock.unlock()
            retryTimer.arm(after: delay) { [weak self] in self?.retryTimerFired() }
        }
    }

    private func cancelRetry() {
        lock.lock()
        retryAttempt = 0
        retryWaitsForIngest = false
        lock.unlock()
        retryTimer.cancel()
    }

    private func retryTimerFired() {
        lock.lock()
        let isForeground = foreground
        retryWaitsForIngest = false
        lock.unlock()
        guard isForeground else { return }
        requestExchange()
    }

    /// Passage au premier plan / en arrière-plan. L'arrière-plan annule la reprise (iOS
    /// suspend l'app, et un réveil au retour relance de toute façon un échange).
    func setForeground(_ value: Bool) {
        lock.lock()
        foreground = value
        lock.unlock()
        if !value { cancelRetry() }
    }

    /// Le mode Stockage vient de changer : la reprise en cours ne vaut plus (le
    /// nouveau mode relance lui-même un échange, `requestExchange`).
    func storageModeDidChange() {
        cancelRetry()
    }

    /// Une passe d'ingestion vient de finir (la base est libérée). Si la reprise armée
    /// attendait justement ça (échec de base), la devance au lieu d'attendre le
    /// minuteur — un seul départ : la minuterie est annulée avant.
    func ingestPassDidEnd() {
        lock.lock()
        let waiting = retryWaitsForIngest && foreground
        if waiting { retryWaitsForIngest = false }
        lock.unlock()
        guard waiting else { return }
        retryTimer.cancel()
        requestExchange()
    }

    /// Tentatives consécutives sans aboutissement complet (tests).
    var retryAttemptCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return retryAttempt
    }
}
