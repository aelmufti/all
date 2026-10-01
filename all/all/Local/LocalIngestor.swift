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

/// Notifié sur le main actor par `LocalIngestor.ingestIfNeeded()` quand le
/// rejeu du spool a réellement inséré quelque chose (pas seulement des
/// doublons/skips/erreurs) — cf. `.reloadsOnLocalDataChange`
/// (`Pulse/Core/LocalDataRefresh.swift`), consommé par les écrans de données
/// pour se rafraîchir sans attendre un redémarrage de l'app.
extension Notification.Name {
    static let allLocalDataDidChange = Notification.Name("allLocalDataDidChange")
}

enum LocalIngestKind: Equatable {
    case wellness
    case sleep
    /// Fichier ACTIVITÉ (`fileId.type == 4`) — incrément L3, cf.
    /// `docs/stockage-local.md`. Résumé stocké dans `activities`
    /// (`LocalDb.storeActivity`) ; le détail (flux/segments) se recalcule à
    /// la volée depuis le spool, cf. `RealLocalPulseBackend`.
    case activity
    case duplicate
    /// Type de fichier FIT reconnu mais pas wellness/sleep/activité, ou
    /// sommeil sans nuit exploitable (`extractSleep` renvoie `nil`).
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
            // Dédup wellness/sommeil : `imported_files`. Les activités ont
            // leur propre dédup (`activities.file_hash`, testée plus bas
            // juste avant `storeActivity`) — elles n'écrivent JAMAIS dans
            // `imported_files`, comme côté serveur (cf. commentaire de
            // `LocalDb.isActivityImported`).
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
            if fileType == FitProfile.fileTypeActivity {
                if try db.isActivityImported(hash: hash) {
                    return LocalIngestResult(fileName: fileName, kind: .duplicate)
                }
                let summary = FitActivityExtractor.extractSummary(messages: file.messages)
                try db.storeActivity(summary, hash: hash, fileName: fileName)
                return LocalIngestResult(fileName: fileName, kind: .activity)
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

    /// Vrai si AU MOINS UN résultat correspond à une insertion réelle
    /// (wellness/sommeil/activité nouvellement écrits) — décide si les écrans
    /// doivent être notifiés (`.allLocalDataDidChange`). `.duplicate`/
    /// `.skipped`/`.error` ne changent rien à ce que lit un écran, donc ne
    /// déclenchent jamais de rafraîchissement. Fonction PURE (aucune E/S),
    /// extraite pour être testable sans `SpoolStore`/`LocalDb` réels — cf.
    /// `allTests/LocalIngestorTests.swift`.
    static func hasNewInsertion(_ results: [LocalIngestResult]) -> Bool {
        results.contains { result in
            switch result.kind {
            case .wellness, .sleep, .activity:
                return true
            case .duplicate, .skipped, .error:
                return false
            }
        }
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
            // N'avertir les écrans QUE si quelque chose a réellement changé —
            // éviter un rechargement pour rien à chaque rejeu (idempotent la
            // plupart du temps, tout le spool étant déjà dans `imported_files`).
            guard hasNewInsertion(results) else { return }
            // Passe par le MÊME coalesceur que la livraison Pulse
            // (`DataRefreshNotifier`) : en mode « Les deux », ingestion locale
            // ET livraison Pulse arrivent quasi en même temps — sans coalescer,
            // ça faisait DEUX rechargements d'écran au lieu d'un.
            await MainActor.run {
                DataRefreshNotifier.postDataDidChangeDebounced()
            }
        }
    }
}
