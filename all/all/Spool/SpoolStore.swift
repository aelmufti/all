//
//  SpoolStore.swift
//  all (bridge-connect)
//
//  Spool local. Gère le répertoire de spool, la protection au repos et le
//  journal à trois états. `recordAcquired`, `markDelivered` et `markArchived`
//  sont branchés. Aucune logique réseau ici : `markDelivered` est appelé par
//  l'appelant (incrément de câblage futur) après un 2xx effectif de Pulse
//  (`PulseUploader`, cf. `Sync/PulseUploader.swift`) — ce fichier ne fait que
//  tenir le journal, il ne décide jamais lui-même qu'un fichier est livré.
//

import Foundation
import os

/// Spool local des `.fit` récupérés, conservés **jusqu'au 2xx de Pulse** (garantie
/// de livraison, CADRAGE §5). Journal à trois états (`acquired`/`delivered`/`archived`)
/// calqué sur `AcquiredFiles` du pont ; protection au repos `completeUnlessOpen`
/// pour permettre l'écriture d'un download en arrière-plan sur appareil verrouillé
/// (décision §12.9).
final class SpoolStore {
    private let filesDir: URL
    private let journalURL: URL
    private let log = Logger(subsystem: "CleanYourRoom.all", category: "spool")

    /// État courant du journal, indexé par identité de fichier montre.
    private(set) var entries: [WatchFileID: SpoolEntry] = [:]

    convenience init() throws {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)
        try self.init(root: base.appendingPathComponent("spool", isDirectory: true))
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
        guard let data = try? Data(contentsOf: journalURL),
              let decoded = try? JSONDecoder().decode([SpoolEntry].self, from: data) else { return }
        entries = Dictionary(uniqueKeysWithValues: decoded.map { ($0.id, $0) })
    }

    private func persistJournal() {
        let snapshot = Array(entries.values)
        do {
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: journalURL, options: [.atomic, .completeFileProtectionUnlessOpen])
        } catch {
            log.error("échec écriture journal: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Point de reprise (§5.2 — pas de curseur, on filtre chaque listing)

    /// Filtre un listing montre contre le journal : rend ce qui reste **dû**
    /// (fichiers jamais `acquired`). Parcours récent→ancien à décider par l'appelant.
    func pendingAcquisition(from listing: [WatchFileID]) -> [WatchFileID] {
        listing.filter { entries[$0] == nil }
    }

    /// Livrés mais **pas encore archivés** → action due sur la montre à la prochaine
    /// fenêtre BLE (`SetFileFlagsMessage ARCHIVE`, incrément 7).
    func pendingArchive() -> [SpoolEntry] {
        entries.values.filter { $0.state == .delivered }
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
    /// `relativePath` viennent typiquement de `identity(for:)`.
    @discardableResult
    func recordAcquired(_ id: WatchFileID, relativePath: String, data: Data) throws -> SpoolEntry {
        let fileURL = filesDir.appendingPathComponent(relativePath)
        try SpoolStore.ensureDirectory(fileURL.deletingLastPathComponent())
        try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUnlessOpen])

        let entry = SpoolEntry(id: id, state: .acquired, acquiredAt: Date(), relativePath: relativePath)
        entries[id] = entry
        persistJournal()
        log.info("Fichier acquis : \(relativePath, privacy: .public) (\(data.count, privacy: .public) o)")
        return entry
    }

    /// Après un **2xx** reçu de Pulse (`PulseUploader`, contrat §6 : toute
    /// classe 2xx — `imported`/`wellness`/`duplicate`/`skipped` — vaut accusé).
    /// Ne fait rien si l'entrée est absente ou déjà au-delà de `acquired` :
    /// idempotent, pour qu'un appel en double (retransmission côté appelant)
    /// ne régresse jamais un état déjà `delivered`/`archived`.
    func markDelivered(_ id: WatchFileID) {
        guard var entry = entries[id] else {
            log.warning("markDelivered ignoré : entrée inconnue (\(id.name, privacy: .public))")
            return
        }
        guard entry.state == .acquired else {
            log.debug("markDelivered ignoré : \(id.name, privacy: .public) déjà \(entry.state.rawValue, privacy: .public)")
            return
        }
        entry.state = .delivered
        entry.deliveredAt = Date()
        entries[id] = entry
        persistJournal()
        log.info("Fichier livré à Pulse : \(entry.relativePath, privacy: .public)")
    }

    /// Après `SetFileFlags(ARCHIVE)` émis vers la montre
    /// (`GarminSession.archivePendingDeliveries`). Même garde d'idempotence que
    /// `markDelivered` : n'agit que sur une entrée `delivered`.
    func markArchived(_ id: WatchFileID) {
        guard var entry = entries[id] else {
            log.warning("markArchived ignoré : entrée inconnue (\(id.name, privacy: .public))")
            return
        }
        guard entry.state == .delivered else {
            log.debug("markArchived ignoré : \(id.name, privacy: .public) au stade \(entry.state.rawValue, privacy: .public), pas `delivered`")
            return
        }
        entry.state = .archived
        entry.archivedAt = Date()
        entries[id] = entry
        persistJournal()
        log.info("Fichier archivé sur la montre : \(entry.relativePath, privacy: .public)")
    }

    /// URL disque d'une entrée du spool — pour que `PulseUploader` lise le
    /// `.fit` sans connaître la structure interne de `filesDir` (racine du
    /// spool, privée à ce type).
    func fileURL(for entry: SpoolEntry) -> URL {
        filesDir.appendingPathComponent(entry.relativePath)
    }
}
