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
/// `acquired` → `delivered` → `archived` (CADRAGE §5.2). Seule exception : un
/// fichier relu parce que sa taille listée a changé (`SpoolStore.recordAcquired`
/// sur une identité déjà journalisée) REPART à `acquired`, quel que soit son
/// état précédent — son contenu est nouveau, il doit être renvoyé à Pulse puis
/// archivé de nouveau.
enum SpoolState: String, Codable {
    /// Octets sur le disque du téléphone (après download BLE réussi).
    case acquired
    /// 2xx reçu de Pulse (après upload background).
    case delivered
    /// Flag ARCHIVE posé sur la montre ET **accusé par elle** (SET_FILE_FLAG
    /// avec statut appliqué, cf. `GarminSession.handleSetFileFlagStatus`) —
    /// jamais marqué à la simple émission de la commande.
    case archived
}

/// Issue du traitement local d'un `.fit` (ingestion en base, mode Téléphone/Les
/// deux). `failed` = le fichier lui-même est inexploitable (illisible, FIT
/// indécodable) : réessayer ne changerait rien ; ce n'est PAS une panne de base
/// (celle-ci ne laisse aucune trace, l'entrée est simplement retentée).
enum SpoolIngestStatus: String, Codable {
    /// Données en base (nouvellement insérées ou déjà connues par leur hash).
    case ingested
    /// Type de fichier sans donnée à retenir (ou sommeil sans nuit exploitable).
    case skipped
    case failed
}

/// Preuve, dans le journal, qu'un `.fit` a été traité localement — c'est elle,
/// et non le seul état `delivered`, qui autorise l'archivage montre et la purge
/// du `.fit` en mode Téléphone/Les deux.
struct SpoolIngestOutcome: Codable, Equatable {
    var status: SpoolIngestStatus
    /// SHA-256 hex du fichier au moment du traitement : la purge ne supprime que
    /// des octets identiques à ceux qui ont été ingérés.
    var hash: String
    var at: Date
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
    /// Taille (octets) que le MANIFESTE directory annonçait pour ce fichier au
    /// moment de son acquisition (`GarminDirectoryEntry.sizeBytes`) — pas
    /// forcément la taille réellement reçue. `SyncPlanner` la compare à la
    /// taille listée au manifeste suivant : une taille différente signifie que
    /// la montre a continué d'écrire dans ce fichier (même identité type +
    /// index + nom) et qu'il faut le relire ; `ArchivePlanner` ne demande
    /// jamais l'archivage d'un fichier dont la taille listée a changé depuis.
    /// `nil` = entrée écrite avant ce champ : traitée comme « tenue, taille
    /// inconnue » (jamais de re-téléchargement massif à la mise à jour).
    var listedSize: Int?
    /// Preuve de traitement local (cf. `SpoolIngestOutcome`). `nil` = pas encore
    /// traité. Repart à `nil` quand le fichier est relu (`recordAcquired` crée
    /// une entrée neuve : son contenu est nouveau).
    var ingest: SpoolIngestOutcome?
    /// Le `.fit` a été supprimé du spool (`SpoolPurger`). L'ENTRÉE reste pour
    /// toujours : c'est elle qui empêche `pendingAcquisition` de redemander à la
    /// montre un fichier qu'on a déjà eu.
    var purgedAt: Date?

    init(
        id: WatchFileID, state: SpoolState, acquiredAt: Date,
        deliveredAt: Date? = nil, archivedAt: Date? = nil,
        relativePath: String, pushedToPulse: Bool = false,
        listedSize: Int? = nil, ingest: SpoolIngestOutcome? = nil, purgedAt: Date? = nil
    ) {
        self.id = id
        self.state = state
        self.acquiredAt = acquiredAt
        self.deliveredAt = deliveredAt
        self.archivedAt = archivedAt
        self.relativePath = relativePath
        self.pushedToPulse = pushedToPulse
        self.listedSize = listedSize
        self.ingest = ingest
        self.purgedAt = purgedAt
    }

    /// Décodage manuel pour la seule rétrocompatibilité de `pushedToPulse`,
    /// `listedSize`, `ingest` et `purgedAt` : un journal écrit avant ces champs
    /// n'a pas ces clés — `decodeIfPresent` les défaute à `false`/`nil` plutôt que de faire échouer tout le décodage du
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
        listedSize = try container.decodeIfPresent(Int.self, forKey: .listedSize)
        ingest = try container.decodeIfPresent(SpoolIngestOutcome.self, forKey: .ingest)
        purgedAt = try container.decodeIfPresent(Date.self, forKey: .purgedAt)
    }
}
