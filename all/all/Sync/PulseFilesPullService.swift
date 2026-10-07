//
//  PulseFilesPullService.swift
//  all (bridge-connect)
//
//  Pilote du rapatriement des `.fit` de Pulse (`PulseFilesPullEngine`) : QUAND une passe
//  tourne, jamais deux en parallèle, comment elle s'arrête, comment elle reprend.
//
//   - Seulement en mode « Les deux » ET au premier plan : iOS suspend l'app en
//     arrière-plan, la passe est alors COUPÉE proprement (`setForeground(false)`), comme
//     au changement de mode (`storageModeDidChange`) et pendant la purge
//     (`runExclusively`). Aucun curseur : le prochain déclencheur repart du diff.
//   - Déclencheurs : lancement, retour au premier plan, passage en « Les deux », après
//     une purge, et la reprise ci-dessous. Une demande reçue pendant une passe est
//     ignorée (la passe en cours couvre le même manifeste) — sauf si elle vient d'être
//     coupée (retour rapide au premier plan).
//   - Reprise automatique après un échec de transport/serveur/base, avec le délai
//     croissant de `SaisieRetryPolicy` (15 s … 4 min) ; un progrès remet le délai à zéro.
//     Jamais pour un 401 (signalé par `PulseUploadHealth`, comme l'échange des saisies),
//     sans configuration, ni sur un 404 du manifeste (route pas encore déployée : une
//     tentative par déclencheur, sans signal d'erreur).
//   - Activité déclarée à la bannière (`SyncWork`), libérée dans TOUS les chemins de sortie.
//
//  Sérialisation : le coordinateur est celui de l'échange des saisies (générique, malgré
//  son nom) — `runExclusively` attend la fin de la passe et retient les nouvelles.
//

import Foundation
import os

final class PulseFilesPullService: @unchecked Sendable {
    static let shared = PulseFilesPullService(
        engineProvider: {
            guard let db = try? LocalDb(), let store = try? PulseFilesStore.standard() else { return nil }
            return PulseFilesPullEngine(db: db, transport: URLSessionPulseFilesTransport(), store: store)
        },
        health: { SaisieSyncHealth.observeFromAnyThread($0) })

    private static let log = Logger(subsystem: "CleanYourRoom.all", category: "pulse-files-pull")

    private let engineProvider: @Sendable () -> PulseFilesPullEngine?
    private let modeProvider: @Sendable () -> StorageMode
    private let health: @Sendable (SaisieSyncHealthEvent) -> Void
    private let reporter: SyncWorkReporting
    private let retryTimer: WakeTimer

    private let lock = NSLock()
    private var coordinator: SaisieSyncCoordinator!
    private var foreground = true
    private var current: Task<PulseFilesPullReport, Never>?
    /// Passe coupée et pas encore terminée : une nouvelle demande doit passer.
    private var cancelling = false
    private var retryAttempt = 0
    private var _lastReport: PulseFilesPullReport?

    init(
        engineProvider: @escaping @Sendable () -> PulseFilesPullEngine?,
        modeProvider: @escaping @Sendable () -> StorageMode = { StorageModeStore.current },
        health: @escaping @Sendable (SaisieSyncHealthEvent) -> Void,
        reporter: SyncWorkReporting = MainSyncWorkReporter(),
        retryTimer: WakeTimer = TaskWakeTimer()
    ) {
        self.engineProvider = engineProvider
        self.modeProvider = modeProvider
        self.health = health
        self.reporter = reporter
        self.retryTimer = retryTimer
        // `weak` : une passe encore en file quand le service disparaît (tests) s'éteint.
        coordinator = SaisieSyncCoordinator { [weak self] in await self?.runPass() }
    }

    /// Aucune passe ne tourne (tests).
    var isIdle: Bool {
        get async { await coordinator.isIdle }
    }

    /// Rapport de la dernière passe terminée (tests).
    var lastReport: PulseFilesPullReport? {
        lock.lock()
        defer { lock.unlock() }
        return _lastReport
    }

    var retryAttemptCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return retryAttempt
    }

    // MARK: - Déclencheurs

    /// Demande une passe (mode « Les deux » seulement), sans attendre. Basse priorité,
    /// hors main actor.
    func requestPass() {
        guard modeProvider() == .both else { return }
        lock.lock()
        let allowed = foreground
        let wasCancelled = cancelling
        lock.unlock()
        guard allowed else { return }
        Task.detached(priority: .utility) { [coordinator] in
            guard let coordinator else { return }
            let idle = await coordinator.isIdle
            if wasCancelled || idle { await coordinator.request() }
        }
    }

    /// Passage au premier plan / en arrière-plan. L'arrière-plan COUPE la passe et annule
    /// la reprise ; le retour au premier plan est suivi d'un `requestPass` de l'appelant.
    func setForeground(_ value: Bool) {
        lock.lock()
        foreground = value
        lock.unlock()
        if !value { stop() }
    }

    /// Le mode Stockage vient de changer : la passe et la reprise ne valent plus (le
    /// nouveau mode relance lui-même une demande, `requestPass`).
    func storageModeDidChange() {
        stop()
    }

    /// Exécute `work` quand aucune passe ne tourne (en COUPANT celle qui tourne) et sans
    /// en laisser démarrer pendant ce temps — une demande reçue entre-temps déclenche une
    /// passe à la fin. Sert à la purge : ce qui a été rapatrié s'efface avec la base.
    func runExclusively<T>(_ work: @Sendable () async throws -> T) async rethrows -> T {
        stop()
        return try await coordinator.runExclusively(work)
    }

    private func stop() {
        lock.lock()
        cancelling = true
        let task = current
        retryAttempt = 0
        lock.unlock()
        task?.cancel()
        retryTimer.cancel()
    }

    // MARK: - Passe

    private func runPass() async {
        lock.lock()
        let isForeground = foreground
        lock.unlock()
        guard modeProvider() == .both, isForeground else {
            cancelRetry()
            return
        }
        // Déclarée à la bannière pour toute la durée de la passe ; `defer` = libérée sur
        // TOUTES les sorties (succès, échec, coupure, configuration absente).
        reporter.pullBegan()
        defer { reporter.pullEnded() }

        lock.lock()
        cancelling = false
        lock.unlock()
        guard let engine = engineProvider() else { return }

        let reporter = self.reporter
        let task = Task(priority: .utility) { await engine.run(progress: { reporter.pullProgress(remaining: $0) }) }
        lock.lock()
        current = task
        let stopped = cancelling || !foreground
        lock.unlock()
        // Une coupure arrivée avant que la tâche soit connue.
        if stopped || modeProvider() != .both { task.cancel() }
        let report = await task.value
        lock.lock()
        current = nil
        _lastReport = report
        lock.unlock()

        apply(report)
    }

    private func apply(_ report: PulseFilesPullReport) {
        if report.ingested > 0 || report.failed > 0 {
            Self.log.info("rapatriement : \(report.ingested, privacy: .public) ingéré(s), \(report.failed, privacy: .public) en échec, \(report.ignored, privacy: .public) ignoré(s), \(report.missing, privacy: .public) disparu(s)")
        }
        switch report.outcome {
        case .completed:
            health(.succeeded)
        case .unauthorized:
            health(.unauthorized)
        case .networkOrServerFailure, .storageFailure:
            Self.log.error("rapatriement interrompu par une erreur (\(String(describing: report.outcome), privacy: .public))")
        case .interrupted, .notConfigured, .routeMissing:
            break
        }
        scheduleRetry(after: report)
    }

    // MARK: - Reprise automatique (`SaisieRetryPolicy`)

    private func scheduleRetry(after report: PulseFilesPullReport) {
        let outcome: SaisieSyncPassOutcome
        switch report.outcome {
        case .completed: outcome = .succeeded
        case .notConfigured: outcome = .notConfigured
        case .unauthorized: outcome = .unauthorized
        case .networkOrServerFailure: outcome = .networkOrServerFailure
        case .storageFailure: outcome = .storageFailure
        // Coupée : le prochain déclencheur la relance. 404 du manifeste : une tentative
        // par déclencheur, jamais de boucle.
        case .interrupted, .routeMissing: outcome = .skipped
        }
        lock.lock()
        // Une passe qui a fait avancer le travail repart d'un délai court.
        let attempt = report.processed > 0 ? 0 : retryAttempt
        let isForeground = foreground
        lock.unlock()
        let decision = SaisieRetryPolicy.decide(
            outcome: outcome, foreground: isForeground, mode: modeProvider(),
            // `.succeeded` ne reprend jamais : ce qui manque encore (fichiers disparus)
            // ne se règle pas en réessayant. Les échecs, eux, laissent du travail.
            stillNeeded: outcome != .succeeded, attempt: attempt)
        switch decision {
        case .stop:
            cancelRetry()
        case .retry(let delay, let nextAttempt):
            lock.lock()
            retryAttempt = nextAttempt
            lock.unlock()
            retryTimer.arm(after: delay) { [weak self] in self?.retryTimerFired() }
        }
    }

    private func cancelRetry() {
        lock.lock()
        retryAttempt = 0
        lock.unlock()
        retryTimer.cancel()
    }

    private func retryTimerFired() {
        requestPass()
    }
}
