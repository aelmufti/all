//
//  LocalIngestor.swift
//  all (bridge-connect)
//
//  Ingestion locale d'un `.fit` — miroir de `IngestService.ingestBuffer`
//  (`custom-connect/server/src/ingest/ingest.service.ts`), sans la branche
//  `activity` (hors périmètre L1, cf. `docs/stockage-local.md`). Dédup par
//  hash SHA-256 du contenu, exactement comme Pulse (`imported_files`).
//
//  Le hash est calculé avec `PulseUploader.sha256Hex` (même convention déjà
//  utilisée par ce dépôt pour l'upload vers Pulse, `Sync/PulseUploader.swift`)
//  — pas de deuxième implémentation du hachage.
//

import Foundation
import os

enum LocalIngestKind: Equatable {
    case wellness
    case sleep
    case duplicate
    /// Type de fichier FIT reconnu mais pas wellness/sleep (ex. activité —
    /// L3+), ou sommeil sans nuit exploitable (`extractSleep` renvoie `nil`).
    case skipped
    case error(String)
}

struct LocalIngestResult {
    let fileName: String
    let kind: LocalIngestKind
}

enum LocalIngestor {
    private static let log = Logger(subsystem: "CleanYourRoom.all", category: "local-ingest")

    /// Ingère un `.fit` déjà sur disque. Ne lève jamais : un fichier
    /// illisible/corrompu remonte en `.error`, pour que l'appelant (ex.
    /// `ingestAll`) continue avec les fichiers suivants plutôt que d'arrêter
    /// tout le rejeu du spool.
    static func ingest(fileURL: URL, hash: String, fileName: String, into db: LocalDb) -> LocalIngestResult {
        do {
            if try db.isImported(hash: hash) {
                return LocalIngestResult(fileName: fileName, kind: .duplicate)
            }
            let data = try Data(contentsOf: fileURL)
            let file = try FitDecoder.decode(data)
            guard let fileType = fileTypeValue(file) else {
                return LocalIngestResult(fileName: fileName, kind: .skipped)
            }

            if fileType == FitProfile.fileTypeMonitoringB {
                let wellness = FitWellnessExtractor.extractWellness(messages: file.messages)
                try db.storeWellness(wellness, hash: hash, fileName: fileName)
                return LocalIngestResult(fileName: fileName, kind: .wellness)
            }
            if fileType == FitProfile.fileTypeSleep {
                guard let sleep = FitWellnessExtractor.extractSleep(messages: file.messages) else {
                    return LocalIngestResult(fileName: fileName, kind: .skipped)
                }
                try db.storeSleep(sleep, hash: hash, fileName: fileName)
                return LocalIngestResult(fileName: fileName, kind: .sleep)
            }
            return LocalIngestResult(fileName: fileName, kind: .skipped)
        } catch {
            log.error("Ingestion locale échouée pour \(fileName, privacy: .public) : \(error.localizedDescription, privacy: .public)")
            return LocalIngestResult(fileName: fileName, kind: .error(error.localizedDescription))
        }
    }

    private static func fileTypeValue(_ file: FitFile) -> Double? {
        file.messages.first { $0.globalMessageNumber == FitProfile.mesgFileId }?.double(0)
    }

    /// Rejoue TOUT le spool existant dans les tables locales (§4 de la tâche
    /// d'incrément : « spool → tables »). Ne touche JAMAIS au journal du
    /// spool (`SpoolStore` reste seul maître de `acquired`/`delivered`/
    /// `archived`, cf. `Spool/SpoolStore.swift`) — l'idempotence vient
    /// entièrement de `imported_files` (hash), comme côté Pulse : rejouer
    /// deux fois ne duplique rien.
    static func ingestAll(from spool: SpoolStore, into db: LocalDb) -> [LocalIngestResult] {
        spool.entries.values.map { entry in
            let url = spool.fileURL(for: entry)
            guard let hash = try? PulseUploader.sha256Hex(ofFileAt: url) else {
                return LocalIngestResult(fileName: entry.relativePath, kind: .error("hash illisible"))
            }
            let fileName = (entry.relativePath as NSString).lastPathComponent
            return ingest(fileURL: url, hash: hash, fileName: fileName, into: db)
        }
    }

    // MARK: - Câblage (incrément L2, `docs/stockage-local.md`)
    //
    // `ingestAll` existait déjà (L1) mais n'était appelée nulle part — la
    // base locale restait vide même en mode Téléphone/Les deux tant que
    // personne ne rejouait le spool. Deux points d'appel (cf. rapport
    // d'incrément) : lancement (`ContentView.task`) et fin de traversée BLE
    // (`GarminSession.advanceDownloadQueue`, transition vers `.done`).
    //
    // Ouvre sa PROPRE `SpoolStore`/`LocalDb` à chaque appel plutôt que de
    // réutiliser une instance vivante passée par l'appelant : `SpoolStore.entries`
    // est un dictionnaire **mutable**, lu/écrit sur le main actor ailleurs
    // dans l'app (`GarminSession`) — le lire depuis une tâche détachée en
    // même temps qu'une mutation main-actor serait une course. Une deuxième
    // instance indépendante relit `journal.json` (petit fichier, coût
    // négligeable) et élimine le problème plutôt que de le gérer. Ouvrir une
    // deuxième connexion SQLite vers le même fichier `LocalDb` est sûr
    // (`PRAGMA journal_mode = WAL`, cf. `SQLiteDatabase.init`).
    //
    // Toujours hors main actor (IO fichier + hachage SHA-256 + SQLite) via
    // `Task.detached` — jamais attendue par l'appelant (fire-and-forget,
    // comme un rafraîchissement en arrière-plan ; les écrans relisent la
    // base au prochain `load()`, pas besoin de signal de fin ici).
    static func ingestIfNeeded() {
        guard StorageModeStore.current != .pulse else { return }
        Task.detached(priority: .utility) {
            guard let spool = try? SpoolStore(), let db = try? LocalDb() else {
                log.error("ingestIfNeeded: SpoolStore/LocalDb indisponible, ingestion sautée")
                return
            }
            let results = ingestAll(from: spool, into: db)
            let errors = results.filter { if case .error = $0.kind { return true }; return false }
            if errors.isEmpty {
                log.info("ingestIfNeeded: \(results.count, privacy: .public) entrée(s) du spool rejouée(s), 0 erreur")
            } else {
                log.error("ingestIfNeeded: \(errors.count, privacy: .public)/\(results.count, privacy: .public) entrée(s) en erreur")
            }
        }
    }
}
