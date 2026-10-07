//
//  LocalDataPurge.swift
//  all (bridge-connect)
//
//  Exécuteur de la purge des données de l'iPhone (Paramètres › Stockage). Les
//  décisions sont dans `LocalPurgePlanner` (pur) ; ici, les E/S, dans cet ordre :
//
//  1. re-contrôle des blocages (l'écran peut être périmé) ;
//  2. spool : preuve de remplacement puis suppression des `.fit` reçus par Pulse
//     (`SpoolStore.purgeFile`, entrée conservée), preuve de traitement effacée sur
//     ceux qu'on garde ;
//  3. base : `LocalDb.purgeAllData`, EN DERNIER. Si l'app s'arrête avant, rien n'est
//     perdu (la base garde tout, rejouer la purge est sans danger) ; dans l'autre
//     sens, des `.fit` gardés auraient gardé une preuve fausse et ne seraient jamais
//     ré-ingérés ;
//  4. `.fit` d'activité RAPATRIÉS de Pulse (`PulseFilesStore`), APRÈS la base : ils sont
//     sur Pulse par définition, et la table des fichiers écartés part avec la base. Un
//     arrêt entre les deux laisse des fichiers orphelins (re-rapatriés puis remplacés),
//     jamais une activité en base sans son `.fit` — l'ordre inverse la laisserait pour
//     toujours, son hash étant connu.
//
//  JAMAIS de requête vers Pulse (ni suppression, ni envoi) et aucune commande vers
//  la montre : cette purge n'efface que ce qui est sur le téléphone.
//
//  `performInApp` ajoute la sérialisation avec l'ingestion locale et l'échange des
//  saisies : ni l'une ni l'autre ne doit courir pendant que la base est vidée.
//

import Foundation
import os

enum LocalDataPurge {
    private static let log = Logger(subsystem: "CleanYourRoom.all", category: "local-purge")

    struct Report: Equatable {
        /// `.fit` supprimés du disque (entrée marquée `purgedAt`).
        var filesDeleted = 0
        /// `.fit` encore sur disque après la purge (non reçus par Pulse, ou en
        /// quarantaine) : ils seront ré-ingérés.
        var filesKept = 0
        /// `.fit` que la purge devait supprimer et qui n'ont pas pu l'être.
        var filesSkipped = 0
    }

    /// La purge est refusée : ce qui la bloque (cf. `LocalPurgePlanner.Blocker`).
    struct Blocked: Error, Equatable {
        let blockers: [LocalPurgePlanner.Blocker]
    }

    /// Base ou spool impossible à ouvrir.
    struct Unavailable: Error {}

    /// Ce qui bloque la purge aujourd'hui — vide si elle est permise. Lit le journal
    /// du spool sur disque (autre instance : le cache de celle-ci serait périmé).
    static func blockers(spool: SpoolStore, db: LocalDb) throws -> [LocalPurgePlanner.Blocker] {
        spool.refreshFromDisk()
        return LocalPurgePlanner.blockers(
            entries: Array(spool.entries.values), pending: try db.pendingSaisies(), seeds: LocalDb.seedFoodSignatures)
    }

    /// Exécute la purge (étapes en en-tête). Lève `Blocked` sans rien toucher si un
    /// blocage subsiste. À appeler hors main actor et sous exclusion
    /// (`performInApp`) : suppressions de fichiers et SQL.
    static func run(spool: SpoolStore, db: LocalDb, pulledFiles: PulseFilesStore? = nil, now: Date = Date()) throws -> Report {
        let blocking = try blockers(spool: spool, db: db)
        guard blocking.isEmpty else { throw Blocked(blockers: blocking) }

        let entries = Array(spool.entries.values)
        var report = Report()

        for entry in LocalPurgePlanner.selectDeletable(from: entries) {
            let token = entry.acquiredAt
            if let proof = LocalPurgePlanner.proofBeforeDeletion(for: entry, now: now) {
                spool.markIngest(entry.id, outcome: proof, expectedAcquiredAt: token)
            }
            if spool.purgeFile(entry.id, expectedAcquiredAt: token) {
                report.filesDeleted += 1
            } else {
                // Le fichier reste (suppression impossible, ou relu depuis) : il doit
                // être ré-ingéré comme les autres, pas rester « traité » d'une base vide.
                spool.clearIngest(entry.id, expectedAcquiredAt: token)
                report.filesSkipped += 1
            }
        }
        for entry in LocalPurgePlanner.selectKeptNeedingReingest(from: entries) {
            spool.clearIngest(entry.id, expectedAcquiredAt: entry.acquiredAt)
        }
        report.filesKept = LocalPurgePlanner.keptFileCount(in: entries) + report.filesSkipped

        try db.purgeAllData()
        pulledFiles?.removeAll()
        log.info("purge iPhone: \(report.filesDeleted, privacy: .public) fichier(s) supprimé(s), \(report.filesKept, privacy: .public) gardé(s), \(report.filesSkipped, privacy: .public) non supprimé(s)")
        return report
    }

    // MARK: - Dans l'app (vrais dossiers, sérialisation)

    /// Blocages sur les vraies données de l'app ; `nil` si le spool ou la base n'ont
    /// pas pu être lus (on ne sait pas : le bouton reste désactivé).
    static func assessInApp() -> [LocalPurgePlanner.Blocker]? {
        guard let spool = try? SpoolStore(), let db = try? LocalDb() else { return nil }
        return try? blockers(spool: spool, db: db)
    }

    /// La purge sur les vraies données, sans passe d'ingestion, rapatriement de Pulse
    /// (COUPÉ s'il tourne) ni échange de saisies en cours ni démarrable pendant ce temps. Appelante : relancer ensuite
    /// `LocalIngestor.ingestIfNeeded()` (les demandes reçues entre-temps sont écartées).
    static func performInApp() async throws -> Report {
        try await PulseFilesPullService.shared.runExclusively {
            try await LocalIngestor.runExclusively {
                try await SaisieSyncService.shared.runExclusively {
                    guard let spool = try? SpoolStore(), let db = try? LocalDb() else { throw Unavailable() }
                    return try run(spool: spool, db: db, pulledFiles: try? PulseFilesStore.standard())
                }
            }
        }
    }
}
