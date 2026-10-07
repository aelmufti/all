//
//  WakeTimer.swift
//  all (bridge-connect)
//
//  Minuterie à UN seul coup, REMPLAÇABLE : `arm` annule la précédente avant d'en
//  poser une nouvelle, donc il n'existe jamais deux minuteries en parallèle pour un
//  même propriétaire. Couture d'injection : la bannière d'activité (`SyncWork`) et la
//  reprise de l'échange des saisies (`SaisieSyncService`) la reçoivent, les tests y
//  mettent un double qui consigne les délais demandés et déclenche à la main — aucune
//  attente réelle.
//

import Foundation

protocol WakeTimer: AnyObject, Sendable {
    /// Pose la minuterie (remplace la précédente, éventuellement déjà armée).
    func arm(after delay: TimeInterval, _ fire: @escaping @Sendable () -> Void)
    /// Annule la minuterie en cours, sans effet si aucune.
    func cancel()
}

/// Implémentation réelle : une `Task` qui dort. Annulée = ne déclenche jamais, même si
/// elle dormait déjà (vérification d'annulation après le réveil).
final class TaskWakeTimer: WakeTimer, @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?

    func arm(after delay: TimeInterval, _ fire: @escaping @Sendable () -> Void) {
        let next = Task {
            try? await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            fire()
        }
        lock.lock()
        let previous = task
        task = next
        lock.unlock()
        previous?.cancel()
    }

    func cancel() {
        lock.lock()
        let previous = task
        task = nil
        lock.unlock()
        previous?.cancel()
    }
}
