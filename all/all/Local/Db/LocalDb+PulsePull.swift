//
//  LocalDb+PulsePull.swift
//  all (bridge-connect)
//
//  Côté base locale du rapatriement des `.fit` depuis Pulse
//  (`Sync/PulseFilesPull.swift`, contrat `custom-connect/docs/pulse-files-pull-contract.md`) :
//  la MIGRATION de la table des fichiers écartés, et les deux lectures/écritures dont
//  la passe a besoin (hash déjà connus, mémorisation d'un échec ou d'un « ignoré »).
//
//  Pas de table des fichiers ingérés : `imported_files` (wellness/sommeil) et
//  `activities.file_hash` portent déjà le hash, avec la MÊME forme que Pulse (SHA-256 des
//  octets du `.fit`, hexadécimal minuscule — `PulseUploader.sha256Hex`).
//

import Foundation

extension LocalDb {
    /// Issue mémorisée d'un fichier rapatrié qu'il ne faut plus redemander.
    enum PulledMark: String {
        /// Hash reçu ≠ hash demandé, ou FIT indécodable : le fichier est en cause.
        case failed
        /// Type reconnu mais sans donnée à retenir (`LocalIngestKind.skipped`).
        case ignored
    }

    /// Migration : fichiers que la passe de rapatriement ne doit plus télécharger. Une
    /// table (jamais une colonne d'`imported_files`) : un fichier en échec n'a aucune
    /// ligne de données. `purgeAllData` la vide avec le reste (tables lues dans
    /// `sqlite_master`) : après une purge, la passe suivante retente tout, échecs compris.
    static let pulsePullMigration = """
    CREATE TABLE IF NOT EXISTS pulse_pull_marks (
      hash TEXT PRIMARY KEY,
      outcome TEXT NOT NULL,
      detail TEXT,
      created_at TEXT NOT NULL DEFAULT (datetime('now'))
    ) WITHOUT ROWID;
    """

    /// Tout hash que la passe n'a pas à télécharger : déjà ingéré (wellness/sommeil,
    /// activités) ou déjà écarté (`pulse_pull_marks`).
    func pulledKnownHashes() throws -> Set<String> {
        var known = Set<String>()
        try db.run(
            """
            SELECT hash FROM imported_files
            UNION SELECT file_hash FROM activities
            UNION SELECT hash FROM pulse_pull_marks
            """) { r in
            if let hash = r.text(0) { known.insert(hash) }
        }
        return known
    }

    func markPulled(hash: String, as mark: PulledMark, detail: String?) throws {
        try db.run(
            "INSERT OR REPLACE INTO pulse_pull_marks (hash, outcome, detail) VALUES (?, ?, ?)",
            [.text(hash), .text(mark.rawValue), detail.map { SQLiteValue.text($0) } ?? .null])
    }

    func pulledMarkCount(_ mark: PulledMark? = nil) throws -> Int {
        var count = 0
        if let mark {
            try db.run("SELECT COUNT(*) FROM pulse_pull_marks WHERE outcome = ?", [.text(mark.rawValue)]) { r in
                count = Int(r.double(0) ?? 0)
            }
        } else {
            try db.run("SELECT COUNT(*) FROM pulse_pull_marks") { r in count = Int(r.double(0) ?? 0) }
        }
        return count
    }
}
