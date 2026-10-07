//
//  LocalPurgePlanner.swift
//  all (bridge-connect)
//
//  Décisions PURES (aucune E/S) de la purge des données de l'iPhone (Paramètres ›
//  Stockage), comme `SpoolPurger.selectPurgeable` pour la purge quotidienne :
//  quand la purge est bloquée, quels `.fit` effacer, lesquels garder, et quelle
//  preuve de traitement laisser aux fichiers effacés. L'exécution est dans
//  `LocalDataPurge.swift`.
//
//  Ce qu'on efface : toute la base locale + les `.fit` que Pulse a reçus. Ce qu'on
//  GARDE : les `.fit` que Pulse n'a pas reçus (la montre ne les redonne pas) et
//  TOUTES les entrées du journal du spool (`SpoolEntry.purgedAt`, comme la purge
//  quotidienne) — ce sont elles qui empêchent `pendingAcquisition`/`SyncPlanner`
//  de redemander à la montre un fichier déjà eu.
//
//  Ce qui BLOQUE la purge : tout ce que la purge détruirait sans qu'aucune autre
//  copie n'existe — voir `Blocker`.
//

import Foundation

enum LocalPurgePlanner {
    // MARK: - Saisies

    /// Valeurs d'un aliment, sans identifiant ni date : sert à reconnaître un aliment
    /// de départ non modifié (`LocalDb.seedFoodSignatures`). Les nombres sont
    /// comparés exactement : la base relit les `Double` qu'elle a reçus.
    struct FoodSignature: Hashable {
        let name: String
        let kcal: Double?
        let protein: Double?
        let carbs: Double?
        let fiber: Double?
        let fat: Double?
        let unitLabel: String?
        let unitGrams: Double?
    }

    /// Un changement du journal des saisies que Pulse n'a pas accusé
    /// (`LocalDb.pendingSaisies`). `food` : valeurs actuelles de l'aliment, `nil` si
    /// ce n'est pas un aliment, s'il n'existe plus (pierre tombale) ou s'il porte un
    /// code-barres.
    struct PendingSaisie: Equatable {
        let resource: String
        let key: String
        let deleted: Bool
        let food: FoodSignature?
    }

    /// Nombre de saisies de l'UTILISATEUR parmi les changements en attente. Le journal
    /// contient aussi les aliments de départ semés à la création de la base (ils sont
    /// « en attente » tant qu'aucun échange n'a eu lieu) : un aliment dont les valeurs
    /// sont EXACTEMENT celles d'un aliment de départ ne compte pas. Un aliment modifié,
    /// supprimé (pierre tombale) ou scanné, et toute autre ressource (repas, poids,
    /// profil, réveil, programme), comptent.
    static func blockingSaisieCount(pending: [PendingSaisie], seeds: Set<FoodSignature>) -> Int {
        pending.filter { change in
            if change.resource == "food", !change.deleted, let food = change.food, seeds.contains(food) { return false }
            return true
        }.count
    }

    // MARK: - Fichiers

    /// `.fit` à effacer : Pulse l'a reçu (`pushedToPulse`), il est encore sur disque,
    /// Pulse ne l'a pas mis en quarantaine (`pulseRejectedAt` : la copie du spool est
    /// la seule qu'on puisse « Renvoyer »), et il n'est pas `acquired` (livraison pas
    /// terminée : `GarminSession` relit encore son octet pour l'envoyer). Ordre :
    /// acquisition, puis index.
    static func selectDeletable(from entries: [SpoolEntry]) -> [SpoolEntry] {
        entries
            .filter { entry in
                entry.purgedAt == nil && entry.pushedToPulse && entry.pulseRejectedAt == nil && entry.state != .acquired
            }
            .sorted { ($0.acquiredAt, $0.id.index) < ($1.acquiredAt, $1.id.index) }
    }

    /// `.fit` gardés qui portent encore une preuve de traitement : la base va être
    /// vidée, la preuve serait fausse. Elle est effacée pour que la passe d'ingestion
    /// les relise (`clearIngest`), et ils ne peuvent pas être archivés sur la montre
    /// d'ici là (`ArchivePlanner.awaitingIngest`, modes Téléphone/Les deux).
    static func selectKeptNeedingReingest(from entries: [SpoolEntry]) -> [SpoolEntry] {
        let deletable = Set(selectDeletable(from: entries).map(\.id))
        return entries.filter { $0.purgedAt == nil && !deletable.contains($0.id) && $0.ingest != nil }
    }

    /// Fichiers qui seront encore sur disque après la purge.
    static func keptFileCount(in entries: [SpoolEntry]) -> Int {
        entries.filter { $0.purgedAt == nil }.count - selectDeletable(from: entries).count
    }

    /// Preuve à poser sur une entrée JUSTE AVANT d'effacer son `.fit`, ou `nil` si
    /// celle qu'elle porte convient. La base va être vidée : une preuve `ingested` ne
    /// serait plus confirmée (`GarminSession.confirmIngestProof`), qui l'effacerait,
    /// et une entrée purgée n'est jamais ré-ingérée (`LocalIngestor.ingestPending`) →
    /// l'archivage montre resterait bloqué à jamais et l'index de la montre
    /// saturerait. `skipped` n'a rien à confirmer en base. Seule une entrée déjà
    /// archivée sur la montre, avec une preuve qui n'est pas un échec, garde la sienne
    /// (plus rien ne la consulte). Un `failed` devient `skipped` : le fichier n'existe
    /// plus, le compteur d'échecs affiché ne redescendrait jamais.
    static func proofBeforeDeletion(for entry: SpoolEntry, now: Date) -> SpoolIngestOutcome? {
        if entry.ingest?.status == .skipped { return nil }
        if entry.state == .archived, let ingest = entry.ingest, ingest.status != .failed { return nil }
        return SpoolIngestOutcome(status: .skipped, hash: entry.ingest?.hash ?? "", at: now)
    }

    /// Entrées déjà purgées du disque que Pulse n'a JAMAIS reçues (la purge
    /// quotidienne s'autorise ce cas quand aucune adresse Pulse n'est configurée) :
    /// leurs mesures n'existent plus que dans la base locale. Les quarantaines sont
    /// exclues (elles restent sur disque, jamais purgées).
    static func measuresOnlyInDatabaseCount(in entries: [SpoolEntry]) -> Int {
        entries.filter { $0.purgedAt != nil && !$0.pushedToPulse && $0.pulseRejectedAt == nil }.count
    }

    // MARK: - Blocages

    enum Blocker: Equatable {
        /// Saisies de l'utilisateur que Pulse n'a pas reçues (aucun échange accusé).
        case unsentSaisies(Int)
        /// Fichiers déjà supprimés du disque sans être passés par Pulse : la base
        /// locale est leur seule copie.
        case measuresOnlyOnPhone(Int)

        /// Raison courte, affichée sous le bouton désactivé.
        var message: String {
            switch self {
            case .unsentSaisies(let n):
                return n == 1 ? "1 saisie pas encore sur Pulse" : "\(n) saisies pas encore sur Pulse"
            case .measuresOnlyOnPhone(let n):
                return n == 1 ? "1 fichier de la montre seulement sur l'iPhone" : "\(n) fichiers de la montre seulement sur l'iPhone"
            }
        }
    }

    /// Vide si la purge est permise. Saisies d'abord : c'est ce que l'utilisateur
    /// peut débloquer (connexion à Pulse, échange en « Les deux »).
    static func blockers(entries: [SpoolEntry], pending: [PendingSaisie], seeds: Set<FoodSignature>) -> [Blocker] {
        var out: [Blocker] = []
        let saisies = blockingSaisieCount(pending: pending, seeds: seeds)
        if saisies > 0 { out.append(.unsentSaisies(saisies)) }
        let lost = measuresOnlyInDatabaseCount(in: entries)
        if lost > 0 { out.append(.measuresOnlyOnPhone(lost)) }
        return out
    }

    static func reason(for blockers: [Blocker]) -> String {
        blockers.map(\.message).joined(separator: " · ")
    }
}
