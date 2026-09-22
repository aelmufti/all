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
            guard newPhase == .active else { return }
            BLEManager.shared.revalidateOnForeground()
        }
    }
}
