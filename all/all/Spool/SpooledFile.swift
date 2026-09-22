//
//  SpooledFile.swift
//  all (bridge-connect)
//
//  Modèle du spool local. Cf. CADRAGE §5.2.
//

import Foundation

/// Identité d'un fichier montre, **stable entre sessions** : type + index montre,
/// avec le nom canonique renvoyé par la montre (cf. `DirectoryEntry.getFileName()`
/// du pont). Le rang dans le listing n'est PAS stable (la montre réordonne ses
/// fichiers entre sessions) — on ne s'en sert jamais comme identité.
struct WatchFileID: Hashable, Codable {
    let fileType: Int
    let index: Int
    /// Nom canonique tel que renvoyé par la montre (source de vérité de l'identité).
    let name: String
}

/// État d'un fichier dans le spool. Progression **stricte** :
/// `acquired` → `delivered` → `archived` (CADRAGE §5.2).
enum SpoolState: String, Codable {
    /// Octets sur le disque du téléphone (après download BLE réussi).
    case acquired
    /// 2xx reçu de Pulse (après upload background).
    case delivered
    /// Flag ARCHIVE posé sur la montre (à la prochaine fenêtre BLE, après l'ack Pulse).
    case archived
}

/// Une entrée du journal de spool.
struct SpoolEntry: Codable {
    let id: WatchFileID
    var state: SpoolState
    let acquiredAt: Date
    var deliveredAt: Date?
    var archivedAt: Date?
    /// Chemin relatif du `.fit` dans le répertoire de spool.
    let relativePath: String
}
