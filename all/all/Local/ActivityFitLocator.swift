//
//  ActivityFitLocator.swift
//  all (bridge-connect)
//
//  Retrouve les octets d'un `.fit` d'activité par son hash : fichiers rapatriés de
//  Pulse (nommés par hash, accès direct), puis spool (indexé par identité MONTRE, donc
//  hachage des entrées — fait une seule fois par fichier, mémorisé). Sert au détail
//  d'activité (`RealLocalPulseBackend`) et à la matérialisation des modifications
//  (`ActivityEditMaterializer`), qui relit plusieurs `.fit` d'une même fusion.
//
//  Le spool n'est ouvert qu'au premier besoin : une ingestion qui ne touche aucune
//  modification ne l'ouvre jamais.
//

import Foundation

final class ActivityFitLocator: @unchecked Sendable {
    private let lock = NSLock()
    private var known: [String: URL]
    private var scanned = Set<String>()
    private let spoolProvider: () -> SpoolStore?
    private let pulledProvider: () -> PulseFilesStore?
    private var spoolLoaded = false
    private var spool: SpoolStore?
    private var pulledLoaded = false
    private var pulled: PulseFilesStore?

    init(
        spool: @escaping () -> SpoolStore?, pulledFiles: @escaping () -> PulseFilesStore?,
        known: [String: URL] = [:]
    ) {
        spoolProvider = spool
        pulledProvider = pulledFiles
        self.known = known
    }

    convenience init(spool: SpoolStore?, pulledFiles: PulseFilesStore?, known: [String: URL] = [:]) {
        self.init(spool: { spool }, pulledFiles: { pulledFiles }, known: known)
    }

    /// Production : le vrai spool et le dossier des fichiers rapatriés, ouverts à la demande.
    static func standard(known: [String: URL] = [:]) -> ActivityFitLocator {
        ActivityFitLocator(
            spool: { try? SpoolStore() }, pulledFiles: { try? PulseFilesStore.standard() }, known: known)
    }

    /// Mémorise un fichier dont le hash vient d'être calculé (passe d'ingestion).
    func register(hash: String, url: URL) {
        lock.lock()
        known[hash] = url
        lock.unlock()
    }

    func url(hash: String) -> URL? {
        lock.lock()
        defer { lock.unlock() }
        if let url = known[hash], FileManager.default.fileExists(atPath: url.path) { return url }
        if !pulledLoaded {
            pulled = pulledProvider()
            pulledLoaded = true
        }
        if let url = pulled?.activityURL(hash: hash) { return url }
        if !spoolLoaded {
            spool = spoolProvider()
            spoolLoaded = true
        }
        guard let spool else { return nil }
        // Entrée purgée = `.fit` supprimé : inutile de tenter de le hacher.
        for entry in spool.entries.values where entry.purgedAt == nil {
            let url = spool.fileURL(for: entry)
            guard scanned.insert(url.path).inserted else { continue }
            guard let entryHash = try? PulseUploader.sha256Hex(ofFileAt: url) else {
                scanned.remove(url.path)
                continue
            }
            known[entryHash] = url
        }
        return known[hash]
    }

    /// Messages FIT décodés du fichier de ce hash ; `nil` s'il est introuvable ou illisible.
    func messages(hash: String) -> [FitMessage]? {
        guard let url = url(hash: hash), let data = try? Data(contentsOf: url),
              let file = try? FitDecoder.decode(data) else { return nil }
        return file.messages
    }
}
