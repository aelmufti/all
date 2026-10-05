//
//  SpoolPurger.swift
//  all (bridge-connect)
//
//  Purge du spool : supprime du disque les `.fit` dont on n'a plus besoin, pour
//  que le spool ne grossisse pas indéfiniment (un `.fit` MONITOR pèse quelques
//  dizaines de Ko, mais la montre en produit toute la journée).
//
//  Deux pièces, comme `ArchivePlanner` :
//  - `selectPurgeable` : sélection PURE (aucune E/S), testable à l'unité ;
//  - `execute` / `runIfDue` : exécuteur, qui revérifie sur le disque et en base
//    avant chaque suppression.
//
//  L'ENTRÉE du journal n'est jamais supprimée (`SpoolEntry.purgedAt`) : c'est elle
//  qui dit « ce fichier a déjà été reçu » à `SpoolStore.pendingAcquisition` et à
//  `SyncPlanner` ; sans elle la montre se verrait redemander un fichier déjà traité.
//
//  Prudence : la suppression est irréversible côté téléphone (la montre a archivé
//  son exemplaire). On ne supprime donc que ce dont la base locale a la preuve
//  (hash vérifié), jamais un échec, et jamais une ACTIVITÉ — le détail d'une
//  activité (flux, segments) est relu depuis le `.fit` (`RealLocalPulseBackend`).
//

import Foundation
import os

enum SpoolPurger {
    private static let log = Logger(subsystem: "CleanYourRoom.all", category: "spool-purge")

    /// Âge minimal de l'archivage montre ET du traitement local avant purge : une
    /// marge pour qu'une anomalie (preuve douteuse, archivage contesté) se voie
    /// avant que les octets ne disparaissent.
    static let minimumAge: TimeInterval = 24 * 3600

    /// Au plus une passe de purge par cette durée.
    static let cadence: TimeInterval = 24 * 3600

    /// Clé `UserDefaults` de l'horodatage de la dernière purge.
    static let lastRunDefaultsKey = "spool-purge-last-run"

    /// Liste blanche EXPLICITE des types purgeables : MONITOR et SLEEP. Tout le
    /// reste — activités comprises, et tout type inconnu — est conservé.
    static let purgeableFileTypes: Set<Int> = [
        GarminFileType.monitor.watchFileType,
        GarminFileType.sleep.watchFileType,
    ]

    // MARK: - Sélection pure

    /// Entrées purgeables, TOUTES conditions réunies :
    /// 1. pas déjà purgée ;
    /// 2. type MONITOR ou SLEEP (`purgeableFileTypes`) ;
    /// 3. `archived` depuis au moins `minimumAge` ;
    /// 4. preuve de traitement `ingested` ou `skipped` (jamais `failed`), vieille
    ///    d'au moins `minimumAge` ;
    /// 5. poussée vers Pulse, OU Pulse n'est pas configuré (`pulseConfigured ==
    ///    false`) — sinon le rattrapage (`PulseBacklogPusher`) aurait encore
    ///    besoin des octets.
    static func selectPurgeable(from entries: [SpoolEntry], now: Date, pulseConfigured: Bool) -> [SpoolEntry] {
        entries
            .filter { entry in
                guard entry.purgedAt == nil else { return false }
                guard purgeableFileTypes.contains(entry.id.fileType) else { return false }
                guard entry.state == .archived, let archivedAt = entry.archivedAt,
                      now.timeIntervalSince(archivedAt) >= minimumAge else { return false }
                guard let ingest = entry.ingest, ingest.status != .failed,
                      now.timeIntervalSince(ingest.at) >= minimumAge else { return false }
                guard entry.pushedToPulse || !pulseConfigured else { return false }
                return true
            }
            .sorted { ($0.acquiredAt, $0.id.index) < ($1.acquiredAt, $1.id.index) }
    }

    /// Vrai si la dernière purge remonte à `cadence` ou plus (ou n'a jamais eu lieu).
    static func isDue(now: Date, defaults: UserDefaults = .standard) -> Bool {
        guard let last = defaults.object(forKey: lastRunDefaultsKey) as? Date else { return true }
        // Horloge reculée : on ne bloque pas la purge indéfiniment.
        return now < last || now.timeIntervalSince(last) >= cadence
    }

    // MARK: - Exécuteur

    struct Report: Equatable {
        /// Fichiers supprimés (ou déjà absents) et entrée marquée `purgedAt`.
        var purged = 0
        /// Preuves effacées parce que le disque ou la base contredisait le journal
        /// (hash différent, fichier absent de la base) : ré-ingestion due.
        var reingestDue = 0
        /// Entrées laissées telles quelles (lecture/suppression/base momentanément
        /// impossible) : retentées à la prochaine purge.
        var skipped = 0
    }

    /// Supprime `candidates` (issus de `selectPurgeable`), chacune après une
    /// dernière vérification :
    ///  - fichier absent : rien à supprimer, on marque seulement `purgedAt` ;
    ///  - son SHA-256 doit égaler `ingest.hash` (sinon le contenu n'est pas celui
    ///    qui a été traité) ;
    ///  - si `ingested`, la base doit détenir ce hash (`holdsIngestedFile`).
    /// Hash différent ou base qui ne le détient pas → `clearIngest` (l'entrée sera
    /// ré-ingérée) et AUCUNE suppression. Une panne de lecture/de base n'est pas
    /// une preuve contre l'entrée : on la laisse, sans effacer sa preuve.
    static func execute(_ candidates: [SpoolEntry], spool: SpoolStore, db: LocalDb) -> Report {
        var report = Report()
        for entry in candidates {
            guard let ingest = entry.ingest else { continue }
            let token = entry.acquiredAt
            let url = spool.fileURL(for: entry)

            guard FileManager.default.fileExists(atPath: url.path) else {
                spool.markPurged(entry.id, expectedAcquiredAt: token)
                report.purged += 1
                continue
            }
            guard let hash = try? PulseUploader.sha256Hex(ofFileAt: url) else {
                report.skipped += 1
                continue
            }
            guard hash == ingest.hash else {
                log.warning("purge: hash du fichier ≠ hash ingéré (\(entry.relativePath, privacy: .public)) — ré-ingestion, pas de suppression")
                spool.clearIngest(entry.id, expectedAcquiredAt: token)
                report.reingestDue += 1
                continue
            }
            if ingest.status == .ingested {
                let held: Bool
                do {
                    held = try db.holdsIngestedFile(hash: hash)
                } catch {
                    log.error("purge: base illisible (\(error.localizedDescription, privacy: .public)) — entrée laissée")
                    report.skipped += 1
                    continue
                }
                guard held else {
                    log.warning("purge: hash absent de la base (\(entry.relativePath, privacy: .public)) — ré-ingestion, pas de suppression")
                    spool.clearIngest(entry.id, expectedAcquiredAt: token)
                    report.reingestDue += 1
                    continue
                }
            }
            // Suppression + `purgedAt` sous le verrou du journal, avec le jeton :
            // un fichier relu depuis la vérification n'est pas supprimé.
            if spool.purgeFile(entry.id, expectedAcquiredAt: token) {
                report.purged += 1
            } else {
                report.skipped += 1
            }
        }
        return report
    }

    /// Purge au plus une fois par `cadence`. Rend `nil` si ce n'est pas l'heure.
    /// L'horodatage est posé après l'exécution (une purge est un passage complet,
    /// même quand il n'y avait rien à supprimer). Appelée en fin de passe
    /// d'ingestion, hors main actor, donc jamais en parallèle d'une ingestion.
    @discardableResult
    static func runIfDue(
        spool: SpoolStore, db: LocalDb, pulseConfigured: Bool,
        now: Date = Date(), defaults: UserDefaults = .standard
    ) -> Report? {
        guard isDue(now: now, defaults: defaults) else { return nil }
        spool.refreshFromDisk()
        let candidates = selectPurgeable(from: Array(spool.entries.values), now: now, pulseConfigured: pulseConfigured)
        let report = execute(candidates, spool: spool, db: db)
        defaults.set(now, forKey: lastRunDefaultsKey)
        log.info("purge: \(report.purged, privacy: .public) purgé(s), \(report.reingestDue, privacy: .public) à ré-ingérer, \(report.skipped, privacy: .public) laissé(s) sur \(candidates.count, privacy: .public) candidat(s)")
        return report
    }
}
