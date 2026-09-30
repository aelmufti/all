//
//  LocalDataRefresh.swift
//  all (bridge-connect)
//
//  Rafraîchissement des écrans après une ingestion locale réussie (mode
//  Téléphone/Les deux) — cf. `LocalIngestor.ingestIfNeeded`, qui poste
//  `.allLocalDataDidChange` sur le main actor dès qu'au moins un fichier du
//  spool a été réellement inséré (pas un doublon/skip/erreur,
//  `LocalIngestor.hasNewInsertion`). Sans ce pont, un écran déjà ouvert au
//  moment d'une synchro montre n'affichait la nouvelle donnée qu'au
//  redémarrage de l'app.
//
//  `.reloadsOnLocalDataChange { … }` — même forme que `.refreshesAtDayChange`
//  (`DayRollover.swift`) : chaque écran fournit la fermeture qui recharge SA
//  sélection courante, pas seulement « le dernier jour ». Là où l'écran a déjà
//  un garde-fou « jour du jour » (`reloadForNewDay`), on le réutilise tel quel
//  — pas la peine d'arracher l'utilisateur qui consulte un jour passé.
//

import SwiftUI

extension View {
    func reloadsOnLocalDataChange(_ onChange: @escaping () async -> Void) -> some View {
        modifier(LocalDataChangeModifier(onChange: onChange))
    }
}

private struct LocalDataChangeModifier: ViewModifier {
    let onChange: () async -> Void

    func body(content: Content) -> some View {
        content
            .task {
                // Flux async, annulé automatiquement par SwiftUI à la
                // disparition de l'écran — même mécanisme que le `.task` de
                // rafraîchissement périodique de `HomeView`. Pas de
                // debounce : chaque notification correspond déjà à un rejeu
                // de spool complet côté `LocalIngestor` (pas de rafale).
                for await _ in NotificationCenter.default.notifications(named: .allLocalDataDidChange) {
                    await onChange()
                }
            }
    }
}
