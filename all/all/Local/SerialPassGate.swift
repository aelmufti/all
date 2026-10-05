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

    /// Attend le retour au repos (tests). Interroge plutôt que d'ajouter un
    /// mécanisme de notification que la production n'utiliserait pas.
    func waitUntilIdle(timeout: TimeInterval = 10) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !isIdle {
            if Date() > deadline { return false }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return true
    }
}
