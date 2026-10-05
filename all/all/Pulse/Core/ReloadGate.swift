//
//  ReloadGate.swift
//  all (bridge-connect)
//
//  Fusion des rechargements d'un écran. Plusieurs déclencheurs visent le même
//  `load()` (retour au premier plan, synchro montre, changement de source,
//  pull-to-refresh, minuit…) et peuvent arriver à quelques ms d'écart : sans
//  garde, chacun relançait une série complète de requêtes en parallèle, et
//  chaque série repassait l'écran en chargement.
//
//  `run` ne lance JAMAIS deux rechargements en même temps :
//   - rien en cours → exécute `operation` ;
//   - un rechargement est déjà en cours → on le REJOINT (l'appelant attend sa
//     fin, aucune requête de plus) ;
//   - `trailing: true` (la donnée vient de changer — synchro, changement de
//     source) → en plus, UN seul rechargement est rejoué juste après la fin du
//     courant (qui a pu lire l'état d'avant). Plusieurs demandes pendant un
//     même rechargement n'en produisent qu'un.
//
//  L'opération tourne dans une `Task` non structurée : l'annulation d'un
//  `.task`/`.refreshable` SwiftUI (vue qui se re-rend, onglet masqué) ne tue
//  plus la requête en vol ; l'appelant, lui, peut toujours être annulé sans
//  effet sur le rechargement.
//
//  Ne couvre PAS les changements de date (Santé, Sommeil, Nutrition) : il faut
//  alors interrompre/ignorer la réponse de l'ancienne date, pas la rejoindre —
//  chaque view-model garde pour cela un compteur de génération.
//

import Foundation

@MainActor
final class ReloadGate {
    private var current: Task<Void, Never>?
    private var rerun = false

    /// Vrai pendant qu'un rechargement est en cours.
    var isRunning: Bool { current != nil }

    func run(trailing: Bool = false, _ operation: @escaping @MainActor () async -> Void) async {
        if let current {
            if trailing { rerun = true }
            await current.value
            return
        }
        let task = Task { @MainActor [weak self] in
            defer { self?.current = nil }
            repeat {
                self?.rerun = false
                await operation()
            } while self?.rerun == true
        }
        current = task
        await task.value
    }
}
