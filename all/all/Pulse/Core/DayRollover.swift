//
//  DayRollover.swift
//  all (bridge-connect)
//
//  Rafraîchissement au changement de jour local. Les écrans « du jour »
//  (Accueil, Santé, Nutrition) calent leur date sur « aujourd'hui » ; comme
//  les données arrivent en direct tant que l'app est ouverte, à minuit le
//  nouveau jour a immédiatement des données — on doit donc y basculer.
//
//  `.refreshesAtDayChange { … }` déclenche la fermeture fournie :
//    - au retour au premier plan (`scenePhase == .active`) — couvre le cas où
//      l'app a passé minuit en arrière-plan ;
//    - au passage de **minuit local** tant que l'écran est visible (timer qui
//      se réarme sur le prochain minuit).
//  Chaque écran fournit la fermeture qui n'avance QUE s'il est déjà sur le
//  dernier jour (voir `reloadForNewDay`/`load` des vue-modèles), pour ne pas
//  arracher l'utilisateur qui consulte un jour passé.
//

import SwiftUI

extension View {
    func refreshesAtDayChange(_ onDayChange: @escaping () async -> Void) -> some View {
        modifier(DayRolloverModifier(onDayChange: onDayChange))
    }
}

private struct DayRolloverModifier: ViewModifier {
    let onDayChange: () async -> Void
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    Task { await onDayChange() }
                }
            }
            .task {
                // Se réveille à chaque minuit local, déclenche, puis se réarme.
                while !Task.isCancelled {
                    let delay = Self.secondsUntilNextLocalMidnight()
                    try? await Task.sleep(for: .seconds(delay))
                    if Task.isCancelled { break }
                    await onDayChange()
                }
            }
    }

    /// Secondes jusqu'au prochain minuit local (+1 s de marge pour être sûr
    /// d'être dans le nouveau jour au réveil).
    private static func secondsUntilNextLocalMidnight() -> Double {
        let calendar = Calendar.current
        let now = Date()
        let startOfToday = calendar.startOfDay(for: now)
        let nextMidnight = calendar.date(byAdding: .day, value: 1, to: startOfToday)
            ?? now.addingTimeInterval(86_400)
        return max(nextMidnight.timeIntervalSince(now) + 1, 1)
    }
}
