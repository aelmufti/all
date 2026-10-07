//
//  allApp.swift
//  all
//
//  Created by Ali El Mufti on 18/09/2026.
//

import SwiftUI

@main
struct allApp: App {
    // Requis pour que le CBCentralManager (restauration d'état, incrément 1)
    // existe dès le lancement, y compris un relance arrière-plan sur évènement BLE.
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        // Pivot premier-plan (SESSION-NOTES 2026-09-22) : l'état de connexion
        // affiché doit être véridique à chaque retour au premier plan, pas
        // seulement au lancement froid couvert par `willRestoreState`. Un
        // `.connected` affiché avant la mise en arrière-plan n'est pas garanti
        // tenir encore — cf. `BLEManager.revalidateOnForeground`, qui repasse
        // par la même revalidation que pour un périphérique restauré plutôt que
        // de faire confiance à l'affichage figé.
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                BLEManager.shared.revalidateOnForeground()
                // Temps réel toujours actif (FC GFDI + métriques connues) tant
                // que l'app est au premier plan — plus de toggle manuel ni
                // d'onglet dédié (remplace l'ancien Live-1b sur 0x2A37, retiré :
                // la FC en direct passe désormais par `REALTIME_HR`, cf.
                // `BLEManager.startRealtime`/`RealtimeSession.enableKnownMetrics`).
                BLEManager.shared.startRealtime()
                // Retour au premier plan : échange des saisies avec Pulse (mode
                // « Les deux » seulement, la méthode se garde elle-même).
                SaisieSyncService.shared.setForeground(true)
                SaisieSyncService.shared.requestExchange()
                PulseFilesPullService.shared.setForeground(true)
                PulseFilesPullService.shared.requestPass()
            case .background:
                BLEManager.shared.stopRealtime()
                // Plus de reprise automatique de l'échange des saisies hors premier plan.
                SaisieSyncService.shared.setForeground(false)
                // iOS suspend l'app : le rapatriement des fichiers de Pulse est coupé
                // proprement, le prochain retour au premier plan le reprend.
                PulseFilesPullService.shared.setForeground(false)
            case .inactive:
                break // transitoire (centre de notif, app switcher) — ne pas couper
            @unknown default:
                break
            }
        }
    }
}
