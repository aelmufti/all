//
//  SerialPassGate.swift
//  all (bridge-connect)
//
//  Garde de sérialisation de l'ingestion locale. Même logique que
//  `Pulse/Core/ReloadGate.swift` (écrans), appliquée à un travail synchrone hors
//  main actor :
//   - rien en cours → lance la passe ;
//   - une passe tourne déjà → ne lance RIEN en parallèle, mais mémorise qu'une
//     passe de plus est due juste après la courante (qui a pu lire l'état d'avant).
//     Dix demandes pendant une même passe n'en produisent qu'une.
//
//  Sans ça, chaque `ingestIfNeeded()` partait dans sa propre tâche détachée :
//  deux passes pouvaient hacher/insérer les mêmes fichiers en même temps (et
//  `isActivityImported` puis `INSERT` n'est pas atomique entre deux tâches).
//
//  Verrou classique (`NSLock`) et non un `actor` : un acteur sérialise les
//  messages mais les met TOUS en file (une passe par demande), il ne les fusionne
//  pas — et une passe synchrone n'a aucun point de suspension où un appel
//  concurrent pourrait poser son drapeau.
//

import Foundation

final class SerialPassGate: @unchecked Sendable {
    private let lock = NSLock()
    private var running = false
    private var rerun = false

    /// Vrai quand aucune passe ne tourne et qu'aucune n'est due.
    var isIdle: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !running
    }

    /// Demande une passe. Rend `true` si elle part maintenant, `false` si elle est
    /// fusionnée dans une passe de rattrapage de la passe en cours.
    @discardableResult
    func request(priority: TaskPriority = .utility, _ pass: @escaping @Sendable () -> Void) -> Bool {
        lock.lock()
        if running {
            rerun = true
            lock.unlock()
            return false
        }
        running = true
        lock.unlock()

        Task.detached(priority: priority) { [self] in
            while true {
                pass()
                lock.lock()
                if rerun {
                    rerun = false
                    lock.unlock()
                    continue
                }
                running = false
                lock.unlock()
                return
            }
        }
        return true
    }

    /// Exécute `work` SEUL : attend qu'aucune passe ne tourne, puis tient la garde
    /// jusqu'à la fin de `work` — toute `request` reçue entre-temps est écartée, pas
    /// différée (la garde ne connaît pas la passe à rejouer) : l'appelant relance la
    /// sienne ensuite s'il en a besoin. Sert aux travaux qui ne doivent pas courir en
    /// même temps qu'une ingestion (purge des données de l'iPhone).
    func runExclusively<T>(_ work: () async throws -> T) async rethrows -> T {
        while !tryAcquire() {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        defer { release() }
        return try await work()
    }

    /// Comme `runExclusively`, pour un travail BREF qui s'intercale entre deux passes (un
    /// fichier rapatrié de Pulse, `PulseFilesPullEngine`) : rend en plus `true` si une
    /// `request` est arrivée pendant ce temps — écartée par la garde, donc due. L'appelant
    /// la relance (`LocalIngestor.runBetween`), sans quoi une passe demandée à cet instant
    /// précis (fin de téléchargement montre) serait perdue.
    func runInterleaved<T>(_ work: () async throws -> T) async rethrows -> (value: T, dropped: Bool) {
        while !tryAcquire() {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        let value: T
        do {
            value = try await work()
        } catch {
            _ = releaseReportingRequest()
            throw error
        }
        return (value, releaseReportingRequest())
    }

    private func releaseReportingRequest() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let had = rerun
        rerun = false
        running = false
        return had
    }

    private func tryAcquire() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !running else { return false }
        running = true
        return true
    }

    private func release() {
        lock.lock()
        rerun = false
        running = false
        lock.unlock()
    }

    /// Attend le retour au repos (tests). Interroge plutôt que d'ajouter un
    /// mécanisme de notification que la production n'utiliserait pas.
    func waitUntilIdle(timeout: TimeInterval = 30) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !isIdle {
            if Date() > deadline { return false }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return true
    }
}
