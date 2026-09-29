//
//  SyncActivity.swift
//  all (bridge-connect)
//
//  Résumé d'activité de synchro pour la bannière globale
//  (`SyncStatusBanner.swift`, posée dans `PulseShellView`) — une projection
//  pure de l'état déjà publié par `BLEManager`/`GarminSession`
//  (`BLEConnectionState`, `GarminHandshakeState`, `GarminSyncState`), sans
//  dupliquer leur logique métier ni ajouter de nouvel état source de vérité.
//
//  Le mapping vit dans une fonction statique pure (`from`), volontairement
//  indépendante de `BLEManager`/`GarminSession` eux-mêmes (juste leurs enums
//  publiés) — testable sans CoreBluetooth, cf. `allTests/SyncActivityTests.swift`.
//  `BLEManager.syncActivity` ne fait que l'appeler avec son état courant.
//

import Foundation

/// Résumé de l'activité de synchro en cours, pour affichage global (bannière
/// visible sur tous les écrans natifs). Ordre de priorité du mapping (`from`) :
/// un téléchargement de fichier en cours prime sur un listing en cours, qui
/// prime lui-même sur une simple connexion — cas normalement disjoints dans le
/// déroulé réel de `GarminSession` (le listing est terminé, `state == .listed`,
/// avant que `syncState` ne passe à `.downloading`), mais l'ordre reste
/// explicite pour rester correct même si un futur changement les faisait
/// se chevaucher.
enum SyncActivity: Equatable {
    case idle
    case connecting
    case listing
    case downloading(done: Int)

    /// Mapping pur des états bruts vers un résumé unique.
    ///
    /// - Parameters:
    ///   - connection: `BLEManager.connectionState`.
    ///   - handshake: `GarminSession.state`, `nil` si aucune session GFDI
    ///     n'existe encore sur ce lien (repli générique de l'incrément 1, ou
    ///     pas de lien du tout).
    ///   - sync: `GarminSession.syncState`, `nil` dans les mêmes conditions.
    ///   - deliveredCount: `GarminSession.deliveredFileIndexes.count` —
    ///     fichiers déjà livrés à Pulse durant la traversée en cours.
    static func from(
        connection: BLEConnectionState,
        handshake: GarminHandshakeState?,
        sync: GarminSyncState?,
        deliveredCount: Int
    ) -> SyncActivity {
        if case .downloading = sync {
            return .downloading(done: deliveredCount)
        }
        if case .listingDirectory = handshake {
            return .listing
        }
        switch handshake {
        case .gfdiChannelOpen, .initialized:
            return .connecting
        default:
            break // .idle / .listed / .failed / nil : pas de raison GFDI de se dire "connecting"
        }
        switch connection {
        case .scanning, .connecting, .reconnecting:
            // `.reconnecting` : lien présumé mais pas encore prouvé exploitable
            // (cf. `BLEManager.isLinkProvenLive`) — toujours "en train de se
            // connecter" du point de vue utilisateur, même texte que `.connecting`.
            return .connecting
        case .disconnected, .connected:
            return .idle
        }
    }
}
