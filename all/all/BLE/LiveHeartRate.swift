//
//  LiveHeartRate.swift
//  all (bridge-connect)
//
//  Ne contient plus que le DTO `Reading` du push Pulse (incrément Live-1b,
//  `Sync/LiveHeartRatePush.swift`) — le reste de ce fichier (profil Bluetooth
//  standard Heart Rate 0x2A37, moteur `Engine`/décodage/fraîcheur) a été
//  retiré : la FC en direct passe désormais par GFDI (service ML
//  `REALTIME_HR`, cf. `GFDI/RealtimeSession.swift`/`RealtimeDecoders.swift`),
//  0x2A37 s'étant montré instable (la montre coupe sa diffusion FC d'elle-
//  même — « lien silencieux » fréquent). `Reading` reste le contrat exact
//  attendu par `/api/live/hr` côté Pulse (`LiveReading`,
//  `custom-connect/server/src/sync/sync.types.ts`) : inchangé, seule sa
//  source d'alimentation change (`BLEManager.handleRealtimeHeartRate`).
//

import Foundation

enum LiveHeartRate {

    /// Ce que l'UI/le push Pulse envoie. `enabled` est notre abonnement,
    /// `broadcasting` est l'interrupteur de la montre, `stale` est l'état du
    /// lien : trois faits séparés à dessein — les fusionner en un seul statut
    /// est ce qui pousse une interface à dire aux gens de vérifier la
    /// mauvaise chose.
    struct Reading: Equatable {
        let enabled: Bool
        let broadcasting: Bool
        let heartRate: Int?
        let measuredAt: Date?
        let stale: Bool
        let hint: String?

        static let off = Reading(enabled: false, broadcasting: false, heartRate: nil, measuredAt: nil, stale: false, hint: nil)
    }
}
