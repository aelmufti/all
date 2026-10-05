//
//  SpoolStore.swift
//  all (bridge-connect)
//
//  Spool local. Gère le répertoire de spool, la protection au repos et le
//  journal à trois états. `recordAcquired`, `markDelivered` et `markArchived`
//  sont branchés (`markArchived` seulement sur accusé appliqué de la montre). Aucune logique réseau ici : `markDelivered` est appelé par
//  l'appelant (incrément de câblage futur) après un 2xx effectif de Pulse
//  (`PulseUploader`, cf. `Sync/PulseUploader.swift`) — ce fichier ne fait que
//  tenir le journal, il ne décide jamais lui-même qu'un fichier est livré.
//
//  Source de vérité du journal : le FICHIER `journal.json`, pas la mémoire. Plusieurs
//  instances sur la même racine coexistent (BLEManager, PulseBacklogPusher,
//  LocalIngestor, LocalPulseBackend) ; chaque transition relit donc le fichier,
//  applique SA modification à l'entrée concernée puis réécrit, le tout sous un
//  verrou unique du processus (`journalLock`). Aucune instance ne réécrit jamais
//  son instantané en mémoire : une instance périmée ne peut ni perdre une entrée
//  ni faire régresser un état. `entries` n'est qu'un cache, rafraîchi à chaque
//  transition.
//

import Foundation
import os

/// Sort un dossier (et son contenu) des sauvegardes iCloud/Finder de l'appareil :
/// les `.fit` et la base locale sont des données de santé, gardées sur l'iPhone
/// seulement (décision 2026-10-05). Reposé à chaque ouverture : l'attribut peut
/// sauter quand le dossier est recréé.
func excludeFromBackup(_ directory: URL) {
    var url = directory
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try? url.setResourceValues(values)
}

/// Spool local des `.fit` récupérés, conservés **jusqu'au 2xx de Pulse** (garantie
/// de livraison, CADRAGE §5). Journal à trois états (`acquired`/`delivered`/`archived`)
/// calqué sur `AcquiredFiles` du pont ; protection au repos `completeUnlessOpen`
/// pour permettre l'écriture d'un download en arrière-plan sur appareil verrouillé
/// (décision §12.9).
final class SpoolStore {
    private let filesDir: URL
    private let journalURL: URL
    private let log = Logger(subsystem: "CleanYourRoom.all", category: "spool")

    /// Verrou UNIQUE du processus, partagé par toutes les instances (donc par tous
    /// les `journal.json`, ce qui est sans conséquence : fichiers minuscules,
    /// sections critiques de quelques ms). Il sérialise relecture-fusion-écriture
    /// du fichier ET l'accès au cache `cache` : `markPushedToPulse(forFileAt:)`
    /// arrive du fil de rappel d'URLSession pendant que le main lit `entries`.
    /// Non récursif : aucune méthode ne rappelle `entries` ni `mutateJournal`
    /// depuis une section critique.
    private static let journalLock = NSLock()

    /// Dernier état connu du journal (chargé à l'init, rafraîchi à chaque
    /// transition). Jamais réécrit tel quel sur disque. Protégé par `journalLock`.
    private var cache: [WatchFileID: SpoolEntry] = [:]

    /// État courant du journal, indexé par identité de fichier montre — copie
    /// (valeur) du cache, sûre à lire depuis n'importe quel fil. Peut être en
    /// retard sur les transitions d'une AUTRE instance tant qu'on n'a pas fait
    /// soi-même une transition ; les transitions, elles, partent toujours du
    /// fichier.
    var entries: [WatchFileID: SpoolEntry] {
        SpoolStore.journalLock.lock()
        defer { SpoolStore.journalLock.unlock() }
        return cache
    }

    convenience init() throws {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)
        let root = base.appendingPathComponent("spool", isDirectory: true)
        try self.init(root: root)
        excludeFromBackup(root)
    }

    /// Init interne testable : pointe vers une racine arbitraire (répertoire
    /// temporaire en test) plutôt que de forcer Application Support. N'affaiblit
    /// pas l'init public : celui-ci délègue simplement ici avec la racine réelle.
    init(root: URL) throws {
        filesDir = root.appendingPathComponent("files", isDirectory: true)
        journalURL = root.appendingPathComponent("journal.json")
        try SpoolStore.ensureDirectory(filesDir)
        loadJournal()
    }

    // MARK: - Répertoires / protection au repos

    private static func ensureDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUnlessOpen])
    }

    // MARK: - Journal (persistance JSON)

    private func loadJournal() {
        SpoolStore.journalLock.lock()
        cache = mergedWithDisk()
        SpoolStore.journalLock.unlock()
        backfillListedSizes()
    }

    /// Journal lu sur disque, `nil` si le fichier est absent ou illisible.
    private func readJournalFromDisk() -> [WatchFileID: SpoolEntry]? {
        guard let data = try? Data(contentsOf: journalURL),
              let decoded = try? JSONDecoder().decode([SpoolEntry].self, from: data) else { return nil }
        return Dictionary(decoded.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
    }

    /// Base de toute transition : le FICHIER fait foi pour chaque identité qu'il
    /// contient ; le cache ne sert que de repli pour une identité absente du
    /// fichier (fichier effacé/illisible, ou écriture précédente échouée — le
    /// journal ne supprime jamais d'entrée, donc rien n'est ressuscité à tort).
    /// À appeler sous `journalLock`.
    private func mergedWithDisk() -> [WatchFileID: SpoolEntry] {
        var journal = cache
        if let disk = readJournalFromDisk() {
            journal.merge(disk) { _, fromDisk in fromDisk }
        }
        return journal
    }

    /// Seule porte d'écriture du journal : sous `journalLock`, relit le fichier,
    /// laisse `body` modifier l'entrée concernée de CET instantané frais (et lui
    /// seul — jamais le cache), puis réécrit si `body` rend `true` ; le cache est
    /// rafraîchi dans tous les cas. Un `body` qui lève ne persiste rien.
    @discardableResult
    private func mutateJournal<T>(_ body: (inout [WatchFileID: SpoolEntry]) throws -> (changed: Bool, result: T)) rethrows -> T {
        SpoolStore.journalLock.lock()
        defer { SpoolStore.journalLock.unlock() }
        var journal = mergedWithDisk()
        cache = journal
        let outcome = try body(&journal)
        if outcome.changed {
            cache = journal
            persist(journal)
        }
        return outcome.result
    }

    /// Entrées antérieures à `SpoolEntry.listedSize` : on leur donne pour taille
    /// de référence celle du fichier sur disque (un téléchargement n'est accepté
    /// que complet, donc c'est la taille que la montre annonçait alors). Sans
    /// ça, un fichier acquis par une ancienne version et dans lequel la montre a
    /// continué d'écrire resterait « tenu » pour toujours. Coût borné : au pire
    /// une relecture, une fois, des anciens fichiers encore listés dont la
    /// taille diffère. Fichier absent du disque → inchangé (tenu).
    ///
    /// Ne complète QUE `listedSize`, et seulement là où le fichier du journal
    /// (pas le cache) n'en a toujours pas : jamais d'écriture d'un instantané
    /// périmé (internal pour être rejoué en test sur une instance périmée).
    func backfillListedSizes() {
        mutateJournal { journal in
            var changed = false
            for (id, entry) in journal where entry.listedSize == nil {
                let url = filesDir.appendingPathComponent(entry.relativePath)
                guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber else { continue }
                journal[id]?.listedSize = size.intValue
                changed = true
            }
            return (changed, ())
        }
    }

    /// Écrit le journal COMPLET fusionné fourni par `mutateJournal` (jamais un
    /// instantané arbitraire). À appeler sous `journalLock`.
    private func persist(_ journal: [WatchFileID: SpoolEntry]) {
        do {
            let data = try JSONEncoder().encode(Array(journal.values))
            try data.write(to: journalURL, options: [.atomic, .completeFileProtectionUnlessOpen])
        } catch {
            log.error("échec écriture journal: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Point de reprise (§5.2 — pas de curseur, on filtre chaque listing)

    /// Filtre un listing montre contre le journal : rend ce qui reste **dû**
    /// (fichiers jamais `acquired`). Parcours récent→ancien à décider par l'appelant.
    func pendingAcquisition(from listing: [WatchFileID]) -> [WatchFileID] {
        let held = entries
        return listing.filter { held[$0] == nil }
    }

    /// Livrés mais **pas encore archivés** → action due sur la montre
    /// (`SET_FILE_FLAG(ARCHIVE)`, `GarminSession`) ; l'état `archived` n'est posé
    /// qu'à l'accusé appliqué de la montre. À filtrer contre le manifeste
    /// courant avant toute émission (`ArchivePlanner.plan`) : l'index seul n'est
    /// pas une identité sûre d'une session à l'autre.
    func pendingArchive() -> [SpoolEntry] {
        entries.values.filter { $0.state == .delivered }
    }

    /// Nombre d'entrées dont l'ingestion locale a échoué (`ingest.status ==
    /// .failed`) — la seule chose que l'écran montre du dispositif de preuve.
    /// Relit d'abord le journal sur disque : la preuve est posée par une AUTRE
    /// instance (la passe d'ingestion), le cache de celle-ci serait périmé.
    func failedIngestCount() -> Int {
        refreshFromDisk()
        return entries.values.filter { $0.ingest?.status == .failed }.count
    }

    // MARK: - Nommage canonique (porte `GarminUtils.buildExportPath` côté pont,
    // AGPL-3.0 — service/devices/garmin/GarminUtils.java)

    /// `yyyy-MM-dd_HH-mm-ss`, UTC, locale `en_US_POSIX` — nom de fichier stable
    /// quel que soit le fuseau de l'iPhone au moment du download. DIVERGENCE
    /// volontaire vs le pont : `GarminUtils.FILENAME_TIMESTAMP_FORMAT` formate
    /// dans `ZoneId.systemDefault()`, ici on fixe UTC pour que deux téléphones
    /// dans des fuseaux différents nomment le même fichier montre à l'identique.
    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return formatter
    }()

    private static let yearFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy"
        return formatter
    }()

    /// Chemin relatif canonique d'une entrée directory dans le spool :
    /// `<TYPE>/<yyyy>/<TYPE>_<yyyy-MM-dd_HH-mm-ss>_<index>.fit` si l'entrée porte
    /// une date, `<TYPE>/<TYPE>_<index>.fit` sinon (sentinelle « pas de date » de
    /// la montre, cf. `GarminDirectoryEntry.date`). Extension `.fit` : les types
    /// tirés de la Venu 2 sont des FIT ; on ne parse jamais le contenu ici (cf.
    /// CLAUDE.md, « ne pas parser le FIT sur le collecteur »).
    static func canonicalRelativePath(for entry: GarminDirectoryEntry) -> String {
        let type = entry.typeName
        guard let date = entry.date else {
            return "\(type)/\(type)_\(entry.fileIndex).fit"
        }
        let year = yearFormatter.string(from: date)
        let timestamp = timestampFormatter.string(from: date)
        return "\(type)/\(year)/\(type)_\(timestamp)_\(entry.fileIndex).fit"
    }

    /// Identité stable (`WatchFileID`) + chemin canonique pour une entrée
    /// directory tout juste téléchargée. `id.name` porte le nom de fichier
    /// canonique SEUL (dernier composant du chemin, pas les sous-dossiers
    /// `<TYPE>/<yyyy>/`) — cf. le commentaire de `WatchFileID` dans
    /// `SpooledFile.swift` : c'est la source de vérité de l'identité.
    static func identity(for entry: GarminDirectoryEntry) -> (id: WatchFileID, relativePath: String) {
        let relativePath = canonicalRelativePath(for: entry)
        let name = (relativePath as NSString).lastPathComponent
        let fileType = (Int(entry.dataType) << 8) | Int(entry.subType)
        return (WatchFileID(fileType: fileType, index: entry.fileIndex, name: name), relativePath)
    }

    // MARK: - Transitions (à brancher aux incréments suivants)

    /// Après download BLE réussi (`GarminSession.finishDownload`, cible fichier) :
    /// écrit `data` sous `filesDir/<relativePath>` (sous-dossiers créés au
    /// besoin, protection `.completeUnlessOpen` comme `persistJournal`), puis
    /// enregistre l'entrée `acquired` dans le journal et persiste. `id` et
    /// `relativePath` viennent typiquement de `identity(for:)`. `listedSize` =
    /// taille annoncée par le manifeste pour cette entrée (cf.
    /// `SpoolEntry.listedSize`).
    ///
    /// Si l'identité est DÉJÀ journalisée (fichier relu parce que sa taille
    /// listée a changé, cf. `SyncPlanner.filesDue`), le fichier du spool est
    /// REMPLACÉ (même chemin canonique, écriture atomique) et l'entrée repart
    /// à `acquired` avec un `acquiredAt` neuf, `pushedToPulse=false`, sans
    /// `deliveredAt`/`archivedAt` : contenu nouveau → nouvel envoi à Pulse
    /// (dédup par hash côté serveur), nouvel archivage. `acquiredAt` sert aussi
    /// de jeton d'acquisition aux `mark*` (cf. `expectedAcquiredAt`).
    @discardableResult
    func recordAcquired(_ id: WatchFileID, relativePath: String, data: Data, listedSize: Int? = nil) throws -> SpoolEntry {
        let fileURL = filesDir.appendingPathComponent(relativePath)
        // Octets ET journal dans la même section critique : une autre instance
        // ne voit jamais un fichier remplacé avec l'ancienne entrée.
        let (entry, previous) = try mutateJournal { journal -> (changed: Bool, result: (SpoolEntry, SpoolEntry?)) in
            try SpoolStore.ensureDirectory(fileURL.deletingLastPathComponent())
            try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUnlessOpen])

            // `previous` vient du FICHIER du journal, pas du cache de l'instance.
            let previous = journal[id]
            // `acquiredAt` strictement postérieur à celui de l'acquisition remplacée
            // (jeton d'acquisition : deux relectures dans la même milliseconde
            // doivent rester distinguables par `expectedAcquiredAt`).
            var acquiredAt = Date()
            if let previous, acquiredAt <= previous.acquiredAt {
                acquiredAt = previous.acquiredAt.addingTimeInterval(0.001)
            }
            let entry = SpoolEntry(id: id, state: .acquired, acquiredAt: acquiredAt, relativePath: relativePath, listedSize: listedSize)
            journal[id] = entry
            return (true, (entry, previous))
        }
        if let previous {
            log.info("Fichier RE-acquis (contenu remplacé) : \(relativePath, privacy: .public), était \(previous.state.rawValue, privacy: .public), taille listée \(previous.listedSize.map(String.init) ?? "inconnue", privacy: .public) → \(listedSize.map(String.init) ?? "inconnue", privacy: .public), \(data.count, privacy: .public) o reçus")
        } else {
            log.info("Fichier acquis : \(relativePath, privacy: .public) (\(data.count, privacy: .public) o)")
        }
        return entry
    }

    /// Vrai si le jeton d'acquisition fourni correspond à l'acquisition COURANTE
    /// de l'entrée (ou si aucun jeton n'est exigé). Un résultat asynchrone
    /// (upload Pulse, accusé d'archivage) qui concerne un contenu REMPLACÉ
    /// depuis par `recordAcquired` ne doit jamais faire avancer l'état du
    /// nouveau contenu.
    private func matchesAcquisition(_ entry: SpoolEntry, _ expectedAcquiredAt: Date?, caller: String) -> Bool {
        guard let expectedAcquiredAt else { return true }
        guard entry.acquiredAt == expectedAcquiredAt else {
            log.info("\(caller, privacy: .public) ignoré : \(entry.id.name, privacy: .public) a été relu depuis (résultat périmé)")
            return false
        }
        return true
    }

    /// Jeton d'acquisition (`acquiredAt`) de l'entrée correspondant à une URL de
    /// fichier du spool — pour qu'un appelant qui ne connaît que l'URL
    /// (`RoutingSpoolUploader`) capture le jeton AVANT un upload asynchrone.
    func acquiredAt(forFileAt url: URL) -> Date? {
        entries.values.first(where: { fileURL(for: $0) == url })?.acquiredAt
    }

    /// Après un **2xx** reçu de Pulse (`PulseUploader`, contrat §6 : toute
    /// classe 2xx — `imported`/`wellness`/`duplicate`/`skipped` — vaut accusé).
    /// Ne fait rien si l'entrée est absente ou déjà au-delà de `acquired` :
    /// idempotent, pour qu'un appel en double (retransmission côté appelant)
    /// ne régresse jamais un état déjà `delivered`/`archived`.
    func markDelivered(_ id: WatchFileID, expectedAcquiredAt: Date? = nil) {
        mutateJournal { journal in
            guard var entry = journal[id] else {
                log.warning("markDelivered ignoré : entrée inconnue (\(id.name, privacy: .public))")
                return (false, ())
            }
            guard matchesAcquisition(entry, expectedAcquiredAt, caller: "markDelivered") else { return (false, ()) }
            guard entry.state == .acquired else {
                log.debug("markDelivered ignoré : \(id.name, privacy: .public) déjà \(entry.state.rawValue, privacy: .public)")
                return (false, ())
            }
            entry.state = .delivered
            entry.deliveredAt = Date()
            journal[id] = entry
            log.info("Fichier livré à Pulse : \(entry.relativePath, privacy: .public)")
            return (true, ())
        }
    }

    /// Après réception de l'accusé **appliqué** de la montre pour un
    /// `SET_FILE_FLAG(ARCHIVE)` (`GarminSession.handleSetFileFlagStatus`) —
    /// JAMAIS à la simple émission de la commande : une commande perdue ou
    /// refusée laisse l'entrée `delivered`, retentée à la session suivante.
    /// Même garde d'idempotence que `markDelivered` : n'agit que sur une entrée
    /// `delivered`.
    func markArchived(_ id: WatchFileID, expectedAcquiredAt: Date? = nil) {
        mutateJournal { journal in
            guard var entry = journal[id] else {
                log.warning("markArchived ignoré : entrée inconnue (\(id.name, privacy: .public))")
                return (false, ())
            }
            guard matchesAcquisition(entry, expectedAcquiredAt, caller: "markArchived") else { return (false, ()) }
            guard entry.state == .delivered else {
                log.debug("markArchived ignoré : \(id.name, privacy: .public) au stade \(entry.state.rawValue, privacy: .public), pas `delivered`")
                return (false, ())
            }
            entry.state = .archived
            entry.archivedAt = Date()
            journal[id] = entry
            log.info("Fichier archivé sur la montre : \(entry.relativePath, privacy: .public)")
            return (true, ())
        }
    }

    /// Marque `pushedToPulse=true` après un accusé **réel** de Pulse (2xx) —
    /// jamais après la livraison locale du mode Téléphone. Appelée par
    /// `RoutingSpoolUploader` (branche `pulse`/`both` uniquement, cf.
    /// `Sync/PulseUploader.swift`) et par `Sync/PulseBacklogPusher.swift`.
    /// Idempotente (pas de garde d'état contrairement à `markDelivered`/
    /// `markArchived` : `pushedToPulse` n'est pas une transition d'état
    /// séquentielle, juste un fait qui devient vrai une fois pour toutes) ;
    /// ignore silencieusement une entrée inconnue, même logique défensive que
    /// les deux autres `mark*`. Sûre depuis n'importe quel fil (fil de rappel
    /// d'URLSession compris).
    func markPushedToPulse(_ id: WatchFileID, expectedAcquiredAt: Date? = nil) {
        mutateJournal { journal in
            guard let entry = journal[id] else {
                log.warning("markPushedToPulse ignoré : entrée inconnue (\(id.name, privacy: .public))")
                return (false, ())
            }
            return (applyPushed(entry, in: &journal, expectedAcquiredAt: expectedAcquiredAt), ())
        }
    }

    /// Variante par URL de fichier plutôt que par identité — pour
    /// `RoutingSpoolUploader`, qui ne connaît que `fileURL`/`watchFilename`
    /// (pas le `WatchFileID` complet, propriété de `GarminSession`). Retrouve
    /// l'entrée par correspondance de `fileURL(for:)` dans le journal (relu,
    /// donc y compris une entrée ajoutée par une autre instance) ; ignore
    /// silencieusement si rien ne correspond (défensif — ne devrait jamais
    /// arriver puisque `fileURL` vient toujours de `fileURL(for:)` sur une
    /// entrée du spool).
    func markPushedToPulse(forFileAt url: URL, expectedAcquiredAt: Date? = nil) {
        mutateJournal { journal in
            guard let entry = journal.values.first(where: { fileURL(for: $0) == url }) else {
                log.warning("markPushedToPulse(forFileAt:) ignoré : aucune entrée pour \(url.lastPathComponent, privacy: .public)")
                return (false, ())
            }
            return (applyPushed(entry, in: &journal, expectedAcquiredAt: expectedAcquiredAt), ())
        }
    }

    /// Pose la preuve de traitement local (`SpoolEntry.ingest`) — appelée par la
    /// passe d'ingestion (`LocalIngestor`) avec le jeton d'acquisition capturé
    /// AVANT de hacher/décoder : si le fichier a été relu entre-temps, la preuve
    /// concernerait l'ancien contenu et est ignorée (l'entrée repart sans preuve).
    /// Écrase une preuve existante (ré-ingestion après `clearIngest`). Ignorée
    /// pour une entrée inconnue ou déjà purgée.
    func markIngest(_ id: WatchFileID, outcome: SpoolIngestOutcome, expectedAcquiredAt: Date? = nil) {
        mutateJournal { journal in
            guard var entry = journal[id] else {
                log.warning("markIngest ignoré : entrée inconnue (\(id.name, privacy: .public))")
                return (false, ())
            }
            guard matchesAcquisition(entry, expectedAcquiredAt, caller: "markIngest") else { return (false, ()) }
            guard entry.purgedAt == nil else { return (false, ()) }
            entry.ingest = outcome
            journal[id] = entry
            log.info("Fichier traité localement (\(outcome.status.rawValue, privacy: .public)) : \(entry.relativePath, privacy: .public)")
            return (true, ())
        }
    }

    /// Efface la preuve de traitement : l'entrée sera ré-ingérée au prochain
    /// passage et ne peut plus être archivée sur la montre d'ici là. Appelée quand
    /// une vérification de dernière minute (archivage, purge) ne retrouve pas en
    /// base ce que la preuve affirmait. Ne fait rien sans preuve.
    func clearIngest(_ id: WatchFileID, expectedAcquiredAt: Date? = nil) {
        mutateJournal { journal in
            guard var entry = journal[id] else { return (false, ()) }
            guard matchesAcquisition(entry, expectedAcquiredAt, caller: "clearIngest") else { return (false, ()) }
            guard entry.ingest != nil else { return (false, ()) }
            entry.ingest = nil
            journal[id] = entry
            log.warning("Preuve de traitement effacée, ré-ingestion due : \(entry.relativePath, privacy: .public)")
            return (true, ())
        }
    }

    /// Le `.fit` a été supprimé du disque (`SpoolPurger`). L'entrée est CONSERVÉE
    /// (elle empêche un re-téléchargement) ; seul `purgedAt` change. Idempotente.
    func markPurged(_ id: WatchFileID, expectedAcquiredAt: Date? = nil) {
        mutateJournal { journal in
            guard var entry = journal[id] else { return (false, ()) }
            guard matchesAcquisition(entry, expectedAcquiredAt, caller: "markPurged") else { return (false, ()) }
            guard entry.purgedAt == nil else { return (false, ()) }
            entry.purgedAt = Date()
            journal[id] = entry
            log.info("Fichier purgé du spool (entrée conservée) : \(entry.relativePath, privacy: .public)")
            return (true, ())
        }
    }

    /// Supprime le `.fit` d'une entrée ET pose `purgedAt`, d'un seul geste sous le
    /// verrou du journal. Le jeton d'acquisition est exigé : `recordAcquired`
    /// remplace le fichier sous ce même verrou en changeant `acquiredAt`, donc un
    /// jeton qui correspond garantit que les octets supprimés sont ceux que
    /// l'appelant vient de vérifier (hash) — jamais un contenu relu entre la
    /// vérification et la suppression. Rend vrai si le fichier est parti (ou
    /// était déjà absent) et que l'entrée est marquée purgée.
    @discardableResult
    func purgeFile(_ id: WatchFileID, expectedAcquiredAt: Date) -> Bool {
        mutateJournal { journal -> (changed: Bool, result: Bool) in
            guard var entry = journal[id], entry.purgedAt == nil,
                  matchesAcquisition(entry, expectedAcquiredAt, caller: "purgeFile") else { return (false, false) }
            let url = fileURL(for: entry)
            do {
                if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                }
            } catch {
                log.error("purge: suppression impossible (\(entry.relativePath, privacy: .public)) : \(error.localizedDescription, privacy: .public)")
                return (false, false)
            }
            entry.purgedAt = Date()
            journal[id] = entry
            log.info("Fichier purgé du spool (entrée conservée) : \(entry.relativePath, privacy: .public)")
            return (true, true)
        }
    }

    /// Relit le journal sur disque dans le cache de CETTE instance (aucune
    /// écriture). Pour une instance de longue durée dont le cache a pu prendre du
    /// retard sur les transitions d'une autre (la passe d'ingestion, qui ne traite
    /// que les entrées sans preuve, veut l'état frais du journal).
    func refreshFromDisk() {
        mutateJournal { _ in (false, ()) }
    }

    /// Corps commun des deux `markPushedToPulse`, sur l'entrée du journal frais.
    /// Rend vrai si le journal a changé.
    private func applyPushed(_ entry: SpoolEntry, in journal: inout [WatchFileID: SpoolEntry], expectedAcquiredAt: Date?) -> Bool {
        guard matchesAcquisition(entry, expectedAcquiredAt, caller: "markPushedToPulse") else { return false }
        guard !entry.pushedToPulse else { return false }
        var updated = entry
        updated.pushedToPulse = true
        journal[entry.id] = updated
        log.info("Fichier effectivement poussé vers Pulse : \(entry.relativePath, privacy: .public)")
        return true
    }

    /// URL disque d'une entrée du spool — pour que `PulseUploader` lise le
    /// `.fit` sans connaître la structure interne de `filesDir` (racine du
    /// spool, privée à ce type).
    func fileURL(for entry: SpoolEntry) -> URL {
        filesDir.appendingPathComponent(entry.relativePath)
    }
}
