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
    /// Vrai seulement après un accusé **réel** de Pulse (2xx obtenu par
    /// `PulseSpoolUploader`, cf. `Sync/PulseUploader.swift`) — jamais mis à
    /// vrai par la livraison locale du mode Téléphone (`RoutingSpoolUploader`,
    /// branche `.phone`, qui déclare `.delivered` sans requête réseau). C'est
    /// ce qui distingue « livré » (`state`, peut être local) de « effectivement
    /// poussé vers Pulse » : `Sync/PulseBacklogPusher.swift` s'en sert pour
    /// retrouver, au basculement `phone` → `pulse`/`both`, les fichiers
    /// collectés localement qui n'ont jamais atteint Pulse.
    var pushedToPulse: Bool

    init(
        id: WatchFileID, state: SpoolState, acquiredAt: Date,
        deliveredAt: Date? = nil, archivedAt: Date? = nil,
        relativePath: String, pushedToPulse: Bool = false
    ) {
        self.id = id
        self.state = state
        self.acquiredAt = acquiredAt
        self.deliveredAt = deliveredAt
        self.archivedAt = archivedAt
        self.relativePath = relativePath
        self.pushedToPulse = pushedToPulse
    }

    /// Décodage manuel pour la seule rétrocompatibilité de `pushedToPulse` :
    /// un journal écrit avant ce champ (tout journal mode Téléphone antérieur
    /// à cet incrément) n'a pas la clé `pushedToPulse` — `decodeIfPresent` la
    /// défaute à `false` plutôt que de faire échouer tout le décodage du
    /// journal (`JSONDecoder().decode([SpoolEntry].self, ...)` dans
    /// `SpoolStore.loadJournal`, qui perdrait alors le journal ENTIER, pas
    /// seulement ce champ). `encode(to:)` reste synthétisé par le compilateur
    /// (aucune raison de le personnaliser, tous les champs sont `Codable`).
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(WatchFileID.self, forKey: .id)
        state = try container.decode(SpoolState.self, forKey: .state)
        acquiredAt = try container.decode(Date.self, forKey: .acquiredAt)
        deliveredAt = try container.decodeIfPresent(Date.self, forKey: .deliveredAt)
        archivedAt = try container.decodeIfPresent(Date.self, forKey: .archivedAt)
        relativePath = try container.decode(String.self, forKey: .relativePath)
        pushedToPulse = try container.decodeIfPresent(Bool.self, forKey: .pushedToPulse) ?? false
    }
}
