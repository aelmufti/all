//
//  LocalStorageUsage.swift
//  all (bridge-connect)
//
//  Place occupée sur l'iPhone par ce que l'app y garde : les `.fit` de la montre
//  (spool) et la base locale. Affichée dans Paramètres › Stockage. Lecture des
//  tailles seulement — aucun contenu n'est ouvert.
//

import Foundation

struct LocalStorageUsage: Equatable {
    /// `.fit` présents dans le spool (les fichiers purgés n'y sont plus) ET `.fit`
    /// d'activité rapatriés de Pulse (comptés avec les activités).
    var watchFileCount = 0
    var watchFileBytes: Int64 = 0
    /// Taille des `.fit` par dossier de premier niveau du spool, c'est-à-dire par
    /// type de fichier montre (`ACTIVITY`, `MONITOR`, `SLEEP`…, cf.
    /// `SpoolStore.canonicalRelativePath`).
    var watchFileBytesByType: [String: Int64] = [:]
    /// Base locale, journaux SQLite compris (`-wal`, `-shm`).
    var databaseBytes: Int64 = 0

    /// Contenu de la base locale ; `nil` si elle n'a pas pu être lue.
    var counts: LocalDb.ContentCounts?

    var totalBytes: Int64 { watchFileBytes + databaseBytes }

    /// Mesure les dossiers réels de l'app (mêmes racines que `SpoolStore()` et
    /// `LocalDb()`). Parcourt le disque : à appeler hors main actor.
    static func measure() -> LocalStorageUsage {
        guard let base = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
        else { return LocalStorageUsage() }
        var usage = measure(
            spoolRoot: base.appendingPathComponent("spool", isDirectory: true),
            databaseRoot: base.appendingPathComponent("local-pulse", isDirectory: true),
            pulledFilesRoot: base.appendingPathComponent("pulse-files", isDirectory: true))
        usage.counts = try? LocalDb().contentCounts()
        return usage
    }

    static func measure(spoolRoot: URL, databaseRoot: URL, pulledFilesRoot: URL? = nil) -> LocalStorageUsage {
        let filesDir = spoolRoot.appendingPathComponent("files", isDirectory: true)
        var usage = LocalStorageUsage(databaseBytes: contents(of: databaseRoot).bytes)
        let typeFolders = (try? FileManager.default.contentsOfDirectory(
            at: filesDir, includingPropertiesForKeys: nil)) ?? []
        for folder in typeFolders {
            let measured = contents(of: folder)
            guard measured.count > 0 else { continue }
            usage.watchFileCount += measured.count
            usage.watchFileBytes += measured.bytes
            usage.watchFileBytesByType[folder.lastPathComponent] = measured.bytes
        }
        // Activités rapatriées : seulement `activities/` (jamais `incoming/`, transitoire).
        if let pulledFilesRoot {
            let kept = contents(of: PulseFilesStore(root: pulledFilesRoot).activitiesDir)
            if kept.count > 0 {
                usage.watchFileCount += kept.count
                usage.watchFileBytes += kept.bytes
                usage.watchFileBytesByType["ACTIVITY", default: 0] += kept.bytes
            }
        }
        return usage
    }

    /// Nombre et taille cumulée des fichiers d'un dossier, sous-dossiers compris.
    /// Dossier absent : zéro.
    private static func contents(of directory: URL) -> (count: Int, bytes: Int64) {
        guard let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey])
        else { return (0, 0) }
        var count = 0
        var bytes: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true else { continue }
            count += 1
            bytes += Int64(values.fileSize ?? 0)
        }
        return (count, bytes)
    }

    static func formatted(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
