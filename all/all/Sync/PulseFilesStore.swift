//
//  PulseFilesStore.swift
//  all (bridge-connect)
//
//  Dossier des `.fit` RAPATRIÉS de Pulse (`Sync/PulseFilesPull.swift`) :
//   - `activities/<hash>.fit` : le `.fit` d'une ACTIVITÉ est gardé (le détail est relu
//     depuis le fichier, `RealLocalPulseBackend`), comme celui du spool ;
//   - `incoming/<hash>` : fichier en cours de téléchargement/ingestion. Les mesures
//     continues et le sommeil n'y restent jamais une fois ingérés.
//
//  Hors du spool, exprès : ces fichiers n'ont pas d'identité montre, n'entrent pas dans
//  son journal, ne sont jamais renvoyés à Pulse ni archivés sur la montre. Même politique
//  que le spool et la base : protection `completeUnlessOpen`, hors sauvegarde iCloud
//  (`excludeFromBackup`). Nommés par hash (SHA-256 hexadécimal minuscule) : jamais un nom
//  venu du serveur dans un chemin.
//

import Foundation

struct PulseFilesStore: Sendable {
    let root: URL

    init(root: URL) {
        self.root = root
    }

    /// `Application Support/pulse-files`, créé au besoin.
    static func standard() throws -> PulseFilesStore {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let store = PulseFilesStore(root: base.appendingPathComponent("pulse-files", isDirectory: true))
        try store.prepare()
        return store
    }

    var activitiesDir: URL { root.appendingPathComponent("activities", isDirectory: true) }
    var incomingDir: URL { root.appendingPathComponent("incoming", isDirectory: true) }

    /// Forme d'un hash de Pulse : 64 caractères hexadécimaux minuscules. Barrière avant
    /// tout chemin ou toute URL construits depuis un hash.
    static func isHash(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }
    }

    /// Crée les dossiers (protégés) et les sort des sauvegardes. Idempotent.
    func prepare() throws {
        for dir in [root, activitiesDir, incomingDir] {
            try FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.completeUnlessOpen])
        }
        excludeFromBackup(root)
    }

    /// `.fit` d'activité gardé pour ce hash, s'il existe.
    func activityURL(hash: String) -> URL? {
        guard Self.isHash(hash) else { return nil }
        let url = activitiesDir.appendingPathComponent("\(hash).fit")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Emplacement où un fichier de ce hash est reçu.
    func incomingURL(hash: String) -> URL {
        incomingDir.appendingPathComponent(hash)
    }

    /// Emplacement définitif d'un `.fit` d'activité (le fichier n'y est pas forcément).
    func keptURL(hash: String) -> URL {
        activitiesDir.appendingPathComponent("\(hash).fit")
    }

    /// Place le fichier reçu parmi les activités gardées (remplace un éventuel reste).
    @discardableResult
    func keep(_ source: URL, hash: String) throws -> URL {
        try prepare()
        let destination = keptURL(hash: hash)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: source, to: destination)
        return destination
    }

    func removeKept(hash: String) {
        try? FileManager.default.removeItem(at: keptURL(hash: hash))
    }

    /// Vide `incoming/` : restes d'une passe interrompue (jamais utilisés tels quels,
    /// le hash est revérifié de toute façon).
    func clearIncoming() {
        let urls = (try? FileManager.default.contentsOfDirectory(at: incomingDir, includingPropertiesForKeys: nil)) ?? []
        for url in urls { try? FileManager.default.removeItem(at: url) }
    }

    /// Purge des données de l'iPhone : tout ce qui a été rapatrié est sur Pulse par
    /// définition. Rend le nombre de `.fit` d'activité effacés.
    @discardableResult
    func removeAll() -> Int {
        let kept = (try? FileManager.default.contentsOfDirectory(at: activitiesDir, includingPropertiesForKeys: nil)) ?? []
        var removed = 0
        for url in kept where (try? FileManager.default.removeItem(at: url)) != nil { removed += 1 }
        clearIncoming()
        return removed
    }
}
