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
//  Retour au premier plan : les onglets restent tous vivants, donc CHAQUE écran
//  visité recharge à chaque `.active`. Un aller-retour de quelques secondes
//  (notification, autre app) déclenchait ainsi toute la série de requêtes de
//  tous les écrans pour rien : le retour au premier plan ne recharge que si le
//  dernier déclenchement date de plus de `foregroundMinInterval` ou si le jour
//  a changé entre-temps. Le minuteur de minuit, lui, déclenche toujours.
//

import SwiftUI

extension View {
    func refreshesAtDayChange(_ onDayChange: @escaping () async -> Void) -> some View {
        modifier(DayRolloverModifier(onDayChange: onDayChange))
    }
}

/// Délai minimal entre deux rechargements dus au retour au premier plan.
let foregroundMinInterval: TimeInterval = 30

/// Retour au premier plan : recharger si jamais déclenché, si le jour local a
/// changé depuis, ou si le dernier déclenchement est assez ancien.
func foregroundReloadDecision(lastFired: Date?, now: Date, calendar: Calendar = .current) -> Bool {
    guard let lastFired else { return true }
    if !calendar.isDate(lastFired, inSameDayAs: now) { return true }
    return now.timeIntervalSince(lastFired) >= foregroundMinInterval
}

private struct DayRolloverModifier: ViewModifier {
    let onDayChange: () async -> Void
    @Environment(\.scenePhase) private var scenePhase
    /// Dernier déclenchement (ou apparition de l'écran, qui charge déjà).
    @State private var lastFired: Date?

    func body(content: Content) -> some View {
        content
            .onAppear { if lastFired == nil { lastFired = Date() } }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active, foregroundReloadDecision(lastFired: lastFired, now: Date()) {
                    lastFired = Date()
                    Task { await onDayChange() }
                }
            }
            .task {
                // Se réveille à chaque minuit local, déclenche, puis se réarme.
                while !Task.isCancelled {
                    let delay = Self.secondsUntilNextLocalMidnight()
                    try? await Task.sleep(for: .seconds(delay))
                    if Task.isCancelled { break }
                    lastFired = Date()
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
