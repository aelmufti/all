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
    /// Notifié sur le main actor quand une passe d'ingestion a posé au moins une
    /// preuve de traitement dans le journal du spool (`SpoolEntry.ingest`) — que
    /// des données aient été insérées ou non (un fichier `skipped` débloque lui
    /// aussi l'archivage). `BLEManager` s'y abonne pour relancer l'archivage
    /// montre, verrouillé tant que la preuve manque (`GarminSession`).
    static let spoolIngestDidAdvance = Notification.Name("spoolIngestDidAdvance")
    /// Notifié sur le main à la fin de CHAQUE passe d'ingestion, qu'elle ait traité
    /// quelque chose ou non : la base vient d'être libérée. `ContentView` le relaie à la
    /// reprise de l'échange des saisies (`SaisieSyncService.ingestPassDidEnd`).
    static let localIngestPassDidEnd = Notification.Name("localIngestPassDidEnd")
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
    /// Le FICHIER est en cause : illisible, ou FIT indécodable. Réessayer ne
    /// changerait rien → journalisé `failed`.
    case error(String)
    /// Ce n'est PAS le fichier : base SQLite indisponible/en échec, ou lecture
    /// refusée par la protection des données (appareil verrouillé). Aucun résultat
    /// à journaliser — l'entrée est retentée à la prochaine passe.
    case storageError(String)
}

struct LocalIngestResult {
    let fileName: String
    let kind: LocalIngestKind
}

enum LocalIngestor {
    private static let log = Logger(subsystem: "CleanYourRoom.all", category: "local-ingest")

    /// Ingère un `.fit` déjà sur disque. Ne lève jamais. Deux familles d'échec,
    /// à ne pas confondre (la première est un verdict sur le fichier, la seconde
    /// non) : `.error` = fichier illisible ou FIT indécodable ; `.storageError` =
    /// base SQLite en échec (ouverture, `isImported`, `store*`) ou lecture
    /// refusée par la protection des données. L'appelant (`ingestPending`)
    /// continue avec les fichiers suivants dans les deux cas.
    static func ingest(fileURL: URL, hash: String, fileName: String, into db: LocalDb) -> LocalIngestResult {
        func result(_ kind: LocalIngestKind) -> LocalIngestResult { LocalIngestResult(fileName: fileName, kind: kind) }
        func storageFailure(_ error: Error) -> LocalIngestResult {
            log.error("Ingestion locale: base en échec pour \(fileName, privacy: .public) : \(error.localizedDescription, privacy: .public)")
            return result(.storageError(error.localizedDescription))
        }

        // Dédup wellness/sommeil : `imported_files`. Les activités ont
        // leur propre dédup (`activities.file_hash`, testée plus bas
        // juste avant `storeActivity`) — elles n'écrivent JAMAIS dans
        // `imported_files`, comme côté serveur (cf. commentaire de
        // `LocalDb.isActivityImported`).
        do {
            if try db.isImported(hash: hash) { return result(.duplicate) }
        } catch { return storageFailure(error) }

        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            if isProtectedDataError(error) {
                log.warning("Ingestion locale: lecture refusée (données protégées) pour \(fileName, privacy: .public) — retentée")
                return result(.storageError(error.localizedDescription))
            }
            log.error("Ingestion locale: fichier illisible \(fileName, privacy: .public) : \(error.localizedDescription, privacy: .public)")
            return result(.error(error.localizedDescription))
        }
        let file: FitFile
        do {
            file = try FitDecoder.decode(data)
        } catch {
            log.error("Ingestion locale: FIT indécodable \(fileName, privacy: .public) : \(error.localizedDescription, privacy: .public)")
            return result(.error(error.localizedDescription))
        }
        guard let fileType = fileTypeValue(file) else { return result(.skipped) }

        do {
            if fileType == FitProfile.fileTypeMonitoringB {
                let wellness = FitWellnessExtractor.extractWellness(messages: file.messages)
                try db.storeWellness(wellness, hash: hash, fileName: fileName)
                return result(.wellness)
            }
            if fileType == FitProfile.fileTypeSleep {
                guard let sleep = FitWellnessExtractor.extractSleep(messages: file.messages) else {
                    return result(.skipped)
                }
                try db.storeSleep(sleep, hash: hash, fileName: fileName)
                return result(.sleep)
            }
            if fileType == FitProfile.fileTypeActivity {
                if try db.isActivityImported(hash: hash) { return result(.duplicate) }
                let summary = FitActivityExtractor.extractSummary(messages: file.messages)
                try db.storeActivity(summary, hash: hash, fileName: fileName)
                return result(.activity)
            }
            return result(.skipped)
        } catch {
            return storageFailure(error)
        }
    }

    /// Lecture refusée parce que l'appareil est verrouillé (protection
    /// `completeUnlessOpen` du spool) : `NSFileReadNoPermissionError`. Transitoire
    /// — le fichier n'est pas en cause, il sera relu appareil déverrouillé.
    private static func isProtectedDataError(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileReadNoPermissionError
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
            case .duplicate, .skipped, .error, .storageError:
                return false
            }
        }
    }

    /// Rejoue TOUT le spool existant dans les tables locales, sans rien journaliser.
    /// N'est plus utilisée par l'app (elle re-hachait tout le spool à chaque
    /// passage) : remplacée par `ingestPending`, incrémentale. Conservée comme
    /// outil de rejeu complet (idempotent grâce à `imported_files`, comme côté
    /// Pulse) pour les tests de bout en bout.
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

    // MARK: - Passe incrémentale (preuve d'ingestion dans le journal)

    /// Issue journalisable d'un résultat d'ingestion, ou `nil` s'il n'y a rien à
    /// journaliser (`.storageError` : la base n'a pas tranché, l'entrée sera
    /// retentée). Fonction PURE.
    ///
    /// `fileType` (type montre de l'entrée) nuance `.error` : seuls les types
    /// qu'on ingère vraiment (activité, MONITOR, SLEEP) peuvent être `failed`. Un
    /// type que l'app n'exploite pas (rapports d'erreur, fichiers de réglages…)
    /// peut ne pas être du FIT : « indécodable » y est sans conséquence, c'est un
    /// `skipped` — sinon le compteur d'échecs affiché à l'écran ne redescendrait
    /// jamais.
    static func ingestStatus(for kind: LocalIngestKind, fileType: Int) -> SpoolIngestStatus? {
        switch kind {
        case .wellness, .sleep, .activity, .duplicate:
            return .ingested
        case .skipped:
            return .skipped
        case .error:
            return ingestedFileTypes.contains(fileType) ? .failed : .skipped
        case .storageError:
            return nil
        }
    }

    private static let ingestedFileTypes: Set<Int> = [
        GarminFileType.activity.watchFileType,
        GarminFileType.monitor.watchFileType,
        GarminFileType.sleep.watchFileType,
    ]

    struct PassReport {
        var results: [LocalIngestResult] = []
        /// Entrées dont la preuve a été posée dans le journal.
        var marked = 0
    }

    /// Une passe : ne traite QUE les entrées sans preuve (`ingest == nil`) et non
    /// purgées, lues dans le journal frais. Une entrée déjà traitée n'est ni
    /// hachée ni décodée. Pour chaque entrée : jeton d'acquisition capturé AVANT,
    /// hash, ingestion, puis `markIngest` avec ce jeton — un fichier relu pendant
    /// la passe reste sans preuve (son nouveau contenu sera traité à la suivante).
    /// Une panne de base ou de lecture protégée ne marque rien.
    ///
    /// `progress` reçoit le nombre d'entrées RESTANT à traiter : le total au départ
    /// (seulement s'il y en a), puis une valeur de moins après chaque entrée — un
    /// décompte fiable pour la bannière d'activité (`SyncWork`).
    static func ingestPending(
        from spool: SpoolStore, into db: LocalDb, now: @autoclosure () -> Date = Date(),
        progress: (Int) -> Void = { _ in }
    ) -> PassReport {
        spool.refreshFromDisk()
        let pending = spool.entries.values
            .filter { $0.ingest == nil && $0.purgedAt == nil }
            .sorted { ($0.acquiredAt, $0.id.index) < ($1.acquiredAt, $1.id.index) }
        var report = PassReport()
        if !pending.isEmpty { progress(pending.count) }
        for (position, entry) in pending.enumerated() {
            // `defer` : le décompte descend aussi sur les `continue` ci-dessous.
            defer { progress(pending.count - position - 1) }
            let token = entry.acquiredAt
            let url = spool.fileURL(for: entry)
            let fileName = (entry.relativePath as NSString).lastPathComponent

            func record(_ kind: LocalIngestKind, hash: String) {
                report.results.append(LocalIngestResult(fileName: fileName, kind: kind))
                guard let status = ingestStatus(for: kind, fileType: entry.id.fileType) else { return }
                spool.markIngest(entry.id, outcome: SpoolIngestOutcome(status: status, hash: hash, at: now()), expectedAcquiredAt: token)
                report.marked += 1
            }

            guard FileManager.default.fileExists(atPath: url.path) else {
                // Ni purgé ni sur le disque : rien à ingérer, jamais. `failed` plutôt
                // que de retenter à l'infini (et de verrouiller l'archivage).
                record(.error("fichier absent"), hash: "")
                continue
            }
            let hash: String
            do {
                hash = try PulseUploader.sha256Hex(ofFileAt: url)
            } catch {
                if isProtectedDataError(error) {
                    report.results.append(LocalIngestResult(fileName: fileName, kind: .storageError(error.localizedDescription)))
                } else {
                    record(.error(error.localizedDescription), hash: "")
                }
                continue
            }
            let result = ingest(fileURL: url, hash: hash, fileName: fileName, into: db)
            record(result.kind, hash: hash)
        }
        return report
    }

    // MARK: - Câblage (incrément L2, `docs/stockage-local.md`)
    //
    // Points d'appel de `ingestIfNeeded` : lancement (`ContentView.task`),
    // changement de mode, fin de traversée BLE (`GarminSession.advanceDownloadQueue`)
    // et chaque fichier acquis (`GarminSession.finishDownload`) — la preuve
    // d'ingestion débloque l'archivage montre, autant ne pas l'attendre.
    //
    // Ouvre sa PROPRE `SpoolStore`/`LocalDb` à chaque passe plutôt que de
    // recevoir celles de l'appelant : on travaille hors main actor et on ne
    // veut pas posséder/garder vivante une instance partagée. C'est sûr : le
    // cache `SpoolStore.entries` est lu sous le verrou commun à toutes les
    // instances, et le journal est relu/fusionné sur disque à chaque
    // transition (cf. `Spool/SpoolStore.swift`). Ouvrir une deuxième connexion
    // SQLite vers le même fichier `LocalDb` est sûr (`PRAGMA journal_mode = WAL`,
    // cf. `SQLiteDatabase.init`).
    //
    // Jamais deux passes en parallèle (`SerialPassGate`) : un appel pendant une
    // passe en demande UNE de plus juste après. Toujours hors main actor (IO
    // fichier + hachage SHA-256 + SQLite), fire-and-forget pour l'appelant.

    private static let gate = SerialPassGate()

    /// Exécute `work` quand aucune passe d'ingestion ne tourne, et en interdit une
    /// autre tant qu'il court (cf. `SerialPassGate.runExclusively`). Les demandes
    /// reçues pendant ce temps sont écartées : relancer `ingestIfNeeded()` après.
    static func runExclusively<T>(_ work: () async throws -> T) async rethrows -> T {
        try await gate.runExclusively(work)
    }

    /// Exécute un travail BREF entre deux passes d'ingestion (cf.
    /// `SerialPassGate.runInterleaved`) et relance la passe qu'une `request` reçue
    /// pendant ce temps aurait fait écarter. Sert à l'ingestion d'un fichier rapatrié
    /// de Pulse : ses écritures restent sérialisées avec les passes et avec la purge,
    /// sans jamais retenir la base longtemps.
    static func runBetween<T>(_ work: () async throws -> T) async rethrows -> T {
        let (value, dropped) = try await gate.runInterleaved(work)
        if dropped { ingestIfNeeded() }
        return value
    }

    static func ingestIfNeeded() {
        guard StorageModeStore.current != .pulse else { return }
        gate.request { runPass() }
    }

    /// Corps d'une passe : ingestion incrémentale, rétro-remplissage Body Battery,
    /// purge si due, puis notifications. Synchrone, exécuté par `gate`.
    ///
    /// Les paramètres sont les coutures des tests (défauts = production). `reporter` :
    /// la passe se déclare à la bannière d'activité dès qu'elle commence réellement
    /// (après la garde de mode) et se libère par `defer`, quelle que soit la sortie
    /// (base indisponible, rien à notifier, fin normale). Une passe écartée par
    /// `runExclusively` (purge) ne démarre jamais : elle ne déclare rien.
    static func runPass(
        mode: () -> StorageMode = { StorageModeStore.current },
        stores: () -> (spool: SpoolStore, db: LocalDb)? = {
            guard let spool = try? SpoolStore(), let db = try? LocalDb() else { return nil }
            return (spool, db)
        },
        reporter: SyncWorkReporting = MainSyncWorkReporter(),
        defaults: UserDefaults = .standard
    ) {
        // Le mode a pu repasser à Pulse entre la demande et l'exécution.
        guard mode() != .pulse else { return }
        reporter.ingestBegan()
        defer {
            reporter.ingestEnded()
            // Fin de passe : réveille la reprise de l'échange des saisies, si elle
            // attendait la fin de l'ingestion (base occupée) — cf. `SaisieSyncService`.
            DispatchQueue.main.async { NotificationCenter.default.post(name: .localIngestPassDidEnd, object: nil) }
        }
        guard let (spool, db) = stores() else {
            log.error("ingestIfNeeded: SpoolStore/LocalDb indisponible, ingestion sautée")
            return
        }
        let report = ingestPending(from: spool, into: db, progress: { reporter.ingestProgress(remaining: $0) })
        let failures = report.results.filter { if case .error = $0.kind { return true }; return false }.count
        let storageErrors = report.results.filter { if case .storageError = $0.kind { return true }; return false }.count
        if !report.results.isEmpty {
            log.info("ingestIfNeeded: \(report.results.count, privacy: .public) entrée(s) traitée(s), \(report.marked, privacy: .public) journalisée(s), \(failures, privacy: .public) fichier(s) en échec, \(storageErrors, privacy: .public) à retenter")
        }
        let bbBackfilled = backfillBodyBatteryIfNeeded(spool: spool, db: db)
        // Fin de passe, donc jamais en parallèle d'une ingestion (même `gate`).
        SpoolPurger.runIfDue(spool: spool, db: db, pulseConfigured: PulseConfig.baseURL != nil, defaults: defaults)

        // N'avertir les écrans QUE si quelque chose a réellement changé —
        // éviter un rechargement pour rien (la plupart des passes n'ont rien à
        // traiter).
        let dataChanged = hasNewInsertion(report.results) || bbBackfilled
        let advanced = report.marked > 0
        guard dataChanged || advanced else { return }
        DispatchQueue.main.async {
            if dataChanged {
                // Passe par le MÊME coalesceur que la livraison Pulse
                // (`DataRefreshNotifier`) : en mode « Les deux », ingestion locale
                // ET livraison Pulse arrivent quasi en même temps — sans coalescer,
                // ça faisait DEUX rechargements d'écran au lieu d'un.
                DataRefreshNotifier.postDataDidChangeDebounced()
            }
            if advanced {
                NotificationCenter.default.post(name: .spoolIngestDidAdvance, object: nil)
            }
        }
    }

    // MARK: - Rétro-remplissage Body Battery (`docs/duree-ideale-sommeil.md` §1)

    private static let bodyBatteryBackfillVersion = "1"
    private static let bodyBatteryBackfillSettingKey = "bb_backfill_version"

    /// Rétro-remplissage UNIQUE de la Body Battery RÉELLE (`metric = 'bb'`)
    /// dans les fichiers wellness déjà importés AVANT que
    /// `FitWellnessExtractor.extractWellness` l'en extraie — `ingest(fileURL:)`
    /// ne les relit jamais spontanément (dédup par hash, `db.isImported`, qui
    /// renvoie `.duplicate` avant même de décoder). Même patron que
    /// `reparseCounters` (TS, `ingest.service.ts`) : clé de version dans
    /// `settings`, relecture une seule fois (gardée par `LocalDb.settingValue`),
    /// n'insère QUE les échantillons `bb` — aucune autre table retouchée.
    /// S'appuie sur `imported_files WHERE kind = 'wellness'` (les hashes déjà
    /// connus) plutôt que de redécoder tout le spool : seuls les fichiers
    /// wellness sont relus. Retourne `true` si au moins un échantillon a été
    /// inséré (pour notifier les écrans comme `ingestIfNeeded`).
    @discardableResult
    static func backfillBodyBatteryIfNeeded(spool: SpoolStore, db: LocalDb) -> Bool {
        guard (try? db.settingValue(key: bodyBatteryBackfillSettingKey)) != bodyBatteryBackfillVersion else {
            return false
        }
        let wellnessHashes = Set((try? db.importedFiles(kind: "wellness"))?.map(\.hash) ?? [])
        var insertedAny = false
        if !wellnessHashes.isEmpty {
            // Un fichier purgé est ignoré d'office (déjà absent du disque) ; un fichier
            // absent pour une autre raison est de toute façon toléré par le `try?`.
            for entry in spool.entries.values where entry.purgedAt == nil {
                let url = spool.fileURL(for: entry)
                guard let hash = try? PulseUploader.sha256Hex(ofFileAt: url), wellnessHashes.contains(hash),
                      let data = try? Data(contentsOf: url), let file = try? FitDecoder.decode(data)
                else { continue }
                let bbSamples = FitWellnessExtractor.extractWellness(messages: file.messages)
                    .samples.filter { $0.metric == "bb" }
                guard !bbSamples.isEmpty else { continue }
                if (try? db.insertBodyBatterySamples(bbSamples)) != nil { insertedAny = true }
            }
        }
        // Version posée même si `wellnessHashes` est vide ou si tout a échoué :
        // une relecture ultérieure du MÊME spool ne produirait rien de plus
        // (même logique que `reparseSleep`, qui pose la version même sur un
        // spool vide) — un spool qui grossit ensuite est couvert par
        // l'extraction `bb` désormais intégrée à `extractWellness` pour tout
        // NOUVEL import, pas par ce rétro-remplissage.
        try? db.setSetting(key: bodyBatteryBackfillSettingKey, value: bodyBatteryBackfillVersion)
        log.info("Rétro-remplissage Body Battery (v\(bodyBatteryBackfillVersion, privacy: .public)) : \(wellnessHashes.count, privacy: .public) fichier(s) wellness connus")
        return insertedAny
    }
}
