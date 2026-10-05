//
//  ArchivePlanner.swift
//  all (bridge-connect)
//
//  Logique PURE de l'archivage montre (SET_FILE_FLAG / ARCHIVE), sans
//  CoreBluetooth — même schéma que `SyncPlanner` : testable sans
//  `CBPeripheral`/`CommunicatorV2`, seul appelant `GarminSession`.
//
//  Trois pièces :
//  - `ArchivePlanner.plan` : parmi les entrées `delivered`, lesquelles peuvent
//    être archivées MAINTENANT (identité complète présente au manifeste
//    courant, taille listée inchangée depuis l'acquisition, et — modes
//    Téléphone/Les deux — preuve d'ingestion locale) et lesquelles doivent
//    attendre (absentes, à relire d'abord, ou en attente d'ingestion) ;
//  - `SetFileFlagStatus` : décodage du statut renvoyé par la montre ;
//  - `ArchiveRequestTracker` : demandes d'archivage envoyées UNE PAR UNE, la
//    réponse est appariée à la demande en vol (la réponse ne permet pas un
//    appariement fiable par identifiant, cf. `SetFileFlagStatus`).
//
//  Pourquoi un accusé : l'archivage est ce qui empêche l'index de la montre de
//  saturer (elle cesse alors d'exposer ses nouveaux fichiers — panne connue,
//  CLAUDE.md). Le pont Linux marque « tenu » à l'émission parce que SA copie
//  locale est définitive ; ici une commande perdue ou refusée, notée
//  `archived`, ne serait plus jamais retentée.
//

import Foundation

enum ArchivePlanner {
    /// Résultat du filtrage des entrées `delivered` contre le manifeste courant.
    struct Plan {
        /// À archiver maintenant : identité complète au manifeste, taille
        /// inchangée (ou jamais enregistrée). Ordre déterministe (acquisition,
        /// puis index).
        var eligible: [SpoolEntry] = []
        /// `delivered` mais ABSENTES du manifeste courant : laissées `delivered`
        /// (jamais archivées à l'aveugle par index — la montre peut avoir
        /// réattribué l'index à un autre fichier jamais téléchargé ; absente =
        /// déjà archivée/supprimée côté montre, ou autre lien, dans tous les cas
        /// rien à faire de sûr).
        var absentFromManifest: [SpoolEntry] = []
        /// Listées avec une taille différente de celle enregistrée : le contenu
        /// du spool est périmé, `SyncPlanner.filesDue` les relira ; archiver
        /// d'abord masquerait la suite de leurs données.
        var resizedSinceAcquisition: [(entry: SpoolEntry, recordedSize: Int, listedSize: Int)] = []
        /// Archivables côté montre MAIS sans preuve d'ingestion locale
        /// (`SpoolEntry.ingest == nil`) alors que le mode Stockage l'exige
        /// (`requiresIngest`) : archiver maintenant détruirait le seul exemplaire
        /// non traité. Débloquées par `LocalIngestor` (qui notifie
        /// `.spoolIngestDidAdvance`). Toute preuve — `failed` et `skipped`
        /// compris — suffit : on tient la copie, et ne pas archiver saturerait
        /// l'index de la montre.
        var awaitingIngest: [SpoolEntry] = []
    }

    /// `delivered` : entrées à trier (les autres états sont ignorés). `listing` :
    /// manifeste directory courant (`GarminSession.files`). La correspondance
    /// utilise l'identité COMPLÈTE `SpoolStore.identity(for:)` (type + index +
    /// nom, donc date) — jamais l'index seul. `requiresIngest` (modes Téléphone/Les
    /// deux) range dans `awaitingIngest` toute entrée sans preuve d'ingestion ;
    /// `false` (mode Pulse, défaut) ne change rien.
    static func plan(delivered: [SpoolEntry], listing: [GarminDirectoryEntry], requiresIngest: Bool = false) -> Plan {
        var listedByID: [WatchFileID: GarminDirectoryEntry] = [:]
        for entry in listing where !entry.isDirectory {
            listedByID[SpoolStore.identity(for: entry).id] = entry
        }
        var plan = Plan()
        let ordered = delivered
            .filter { $0.state == .delivered }
            // Jamais une entrée DIRECTORY (dataType=subType=0) : garde défensive
            // fidèle au `if DIRECTORY return` d'`archiveOnWatch` côté pont.
            .filter { $0.id.fileType != 0 }
            .sorted { ($0.acquiredAt, $0.id.index) < ($1.acquiredAt, $1.id.index) }
        for entry in ordered {
            guard let listed = listedByID[entry.id] else {
                plan.absentFromManifest.append(entry)
                continue
            }
            if let recorded = entry.listedSize, recorded != listed.sizeBytes {
                plan.resizedSinceAcquisition.append((entry, recorded, listed.sizeBytes))
                continue
            }
            if requiresIngest && entry.ingest == nil {
                plan.awaitingIngest.append(entry)
                continue
            }
            plan.eligible.append(entry)
        }
        return plan
    }
}

/// Statut renvoyé par la montre à un `SET_FILE_FLAG` — porté de
/// `SetFileFlagsStatusMessage.parseIncoming` (messages/status/GFDIStatusMessage.java,
/// AGPL-3.0) : `status` (0 = ACK), puis `flagsStatus` (0 = APPLIED),
/// `fileIdentifier` (u16 LE) et `flags` (bitmask).
struct SetFileFlagStatus: Equatable {
    let status: UInt8
    let flagsStatus: UInt8?
    let fileIdentifierRaw: UInt16?
    let flags: UInt8?

    /// Appliqué = ACK de la trame ET flags appliqués. C'est la SEULE condition
    /// pour marquer `archived`. Une trame tronquée (champs manquants) n'est pas
    /// un accusé : refus.
    var isApplied: Bool { status == 0 && flagsStatus == 0 }

    /// `nil` si la charge est vide (pas même un octet de statut).
    static func parse(_ rest: Data) -> SetFileFlagStatus? {
        var reader = GarminByteReader(rest)
        guard let status = reader.readUInt8() else { return nil }
        // Un statut ≠ ACK peut ne pas porter le reste : on lit ce qui vient.
        let flagsStatus = reader.readUInt8()
        let identifier = reader.readUInt16LE()
        let flags = reader.readUInt8()
        return SetFileFlagStatus(status: status, flagsStatus: flagsStatus, fileIdentifierRaw: identifier, flags: flags)
    }
}

/// Une demande d'archivage à la fois, appariée à sa réponse par l'ORDRE (la
/// demande en vol), pas par l'identifiant renvoyé : le `+1` sur l'identifiant du
/// pont de référence est une hypothèse jamais vérifiée (`GarminSession` le
/// journalise seulement). Valeur PURE, détenue par `GarminSession` (une
/// instance par lien BLE : disconnexion = état perdu = tout retenté à la
/// session suivante, ce qui est voulu).
///
/// Garde-fous :
/// - jamais deux demandes en vol (`next` rend `nil` tant qu'une attend) ;
/// - jamais deux envois pour la même acquisition d'une même entrée sur un lien
///   (`attempted`) : un refus n'est retenté qu'à la session suivante, pas en
///   boucle ;
/// - après une absence de réponse (`timeOut`), plus AUCUNE demande sur ce lien
///   (`halted`) : une réponse tardive de la demande expirée serait sinon prise
///   pour celle de la suivante et ferait marquer `archived` à tort.
struct ArchiveRequestTracker {
    struct InFlight: Equatable {
        let id: WatchFileID
        let fileIndex: Int
        /// Jeton d'acquisition (`SpoolEntry.acquiredAt`) : l'accusé ne doit pas
        /// marquer un contenu relu entre-temps.
        let acquiredAt: Date
        /// Distingue deux demandes successives (garde du minuteur d'absence de
        /// réponse).
        let sequence: Int
    }

    enum Outcome: Equatable {
        case applied(InFlight)
        case refused(InFlight)
    }

    private struct Attempt: Hashable {
        let id: WatchFileID
        let acquiredAt: Date
    }

    private(set) var inFlight: InFlight?
    private(set) var halted = false
    private var attempted: Set<Attempt> = []
    private var nextSequence = 0

    /// Prochaine demande à émettre parmi `eligible` (déjà filtrées par
    /// `ArchivePlanner.plan`), ou `nil` si une demande est en vol, si le lien est
    /// interrompu (`halted`) ou si tout a déjà été tenté sur ce lien. Le
    /// retour est AUSSI enregistré comme demande en vol : l'appelant doit
    /// l'émettre.
    mutating func next(from eligible: [SpoolEntry]) -> InFlight? {
        guard inFlight == nil, !halted else { return nil }
        guard let entry = eligible.first(where: { !attempted.contains(Attempt(id: $0.id, acquiredAt: $0.acquiredAt)) }) else {
            return nil
        }
        attempted.insert(Attempt(id: entry.id, acquiredAt: entry.acquiredAt))
        nextSequence += 1
        let request = InFlight(id: entry.id, fileIndex: entry.id.index, acquiredAt: entry.acquiredAt, sequence: nextSequence)
        inFlight = request
        return request
    }

    /// Réponse de la montre : libère la demande en vol et dit si elle est
    /// appliquée. `nil` = aucune demande en vol (réponse tardive/non sollicitée :
    /// à ignorer, jamais à attribuer à une entrée).
    mutating func receive(applied: Bool) -> Outcome? {
        guard let request = inFlight else { return nil }
        inFlight = nil
        return applied ? .applied(request) : .refused(request)
    }

    /// Retire une demande que `next` vient de rendre mais que l'appelant a
    /// finalement décidé de NE PAS émettre (dernière vérification d'archivage
    /// négative) : elle n'est ni en vol ni comptée comme tentée sur ce lien, donc
    /// elle pourra partir plus tard (par exemple une fois ré-ingérée). Sans effet
    /// si `request` n'est pas la demande en vol.
    mutating func withdraw(_ request: InFlight) {
        guard inFlight == request else { return }
        inFlight = nil
        attempted.remove(Attempt(id: request.id, acquiredAt: request.acquiredAt))
    }

    /// Pas de réponse à temps : libère la demande (l'entrée reste `delivered`,
    /// retentée à la session suivante) et interrompt les archivages de ce lien.
    mutating func timeOut() -> InFlight? {
        guard let request = inFlight else { return nil }
        inFlight = nil
        halted = true
        return request
    }
}
