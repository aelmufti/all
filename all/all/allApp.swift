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
                // Live-1b : la mesure + push de la FC est pilotée par le premier
                // plan de l'app (et la connexion montre), et NON par la présence
                // de l'onglet FC natif. Sinon, regarder « Maintenant » dans Pulse
                // (donc quitter l'onglet FC) coupait le flux et Pulse ne démarrait
                // jamais l'animation en direct. La montre diffuse 0x2A37 dès que
                // « Diffuser la FC » est activé côté montre, indépendamment de
                // notre abonnement : découpler de l'onglet ne coûte quasi rien.
                BLEManager.shared.startLiveHeartRate()
            case .background:
                BLEManager.shared.stopLiveHeartRate()
            case .inactive:
                break // transitoire (centre de notif, app switcher) — ne pas couper
            @unknown default:
                break
            }
        }
    }
}
