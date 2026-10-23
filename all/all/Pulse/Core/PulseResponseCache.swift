//
//  PulseResponseCache.swift
//  all (bridge-connect)
//
//  Cache des réponses JSON de LECTURE (GET) de `PulseAPIClient`, pour afficher
//  aussitôt les dernières valeurs connues (stale-while-revalidate) — même après
//  une relance — pendant que la lecture fraîche part en arrière-plan.
//
//  - Clé = mode Stockage + identité du serveur (adresse Pulse, hors mode
//    Téléphone) + chemin + requête triée : le cache ne montre jamais les
//    données d'un autre mode ou d'un autre serveur.
//  - Valeur = corps JSON brut de la réponse.
//  - Mémoire (dictionnaire borné) + disque dans `Library/Caches/<sous-dossier>`
//    avec `FileProtectionType.complete`, dossier exclu de la sauvegarde. Rien
//    hors du conteneur de l'app, rien dans les logs (données de santé).
//  - Taille bornée : éviction du moins récemment utilisé (mémoire et disque).
//  - Invalidation totale (`invalidateAll`) : changement de mode Stockage,
//    déconnexion, purge locale, changement d'adresse Pulse, écriture.
//

import CryptoKit
import Foundation

final class PulseResponseCache: @unchecked Sendable {
    /// Cache de l'app (disque dans `Library/Caches/PulseResponseCache`).
    static let shared = PulseResponseCache()

    private struct Entry {
        var size: Int
        var lastUse: UInt64
    }

    private let lock = NSLock()
    private let directory: URL?
    private let memoryLimit: Int
    private let diskLimit: Int
    private var memory: [String: Data] = [:]
    private var memoryBytes = 0
    /// Index disque : nom de fichier (SHA-256 hex de la clé) → taille + usage.
    private var index: [String: Entry] = [:]
    private var diskBytes = 0
    private var tick: UInt64 = 0
    private var generation: UInt64 = 0
    private var directoryReady = false

    /// - Parameters:
    ///   - directory: dossier disque ; `nil` = mémoire seule. Par défaut
    ///     `Library/Caches/PulseResponseCache`.
    ///   - memoryLimit / diskLimit: plafonds en octets.
    init(
        directory: URL? = PulseResponseCache.defaultDirectory(),
        memoryLimit: Int = 4 * 1_024 * 1_024,
        diskLimit: Int = 24 * 1_024 * 1_024
    ) {
        self.directory = directory
        self.memoryLimit = memoryLimit
        self.diskLimit = diskLimit
        loadIndex()
    }

    static func defaultDirectory() -> URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("PulseResponseCache", isDirectory: true)
    }

    // MARK: - Clé

    /// Clé stable d'une lecture. `identity` : adresse du serveur (`nil` en mode
    /// Téléphone, où aucun serveur n'est en jeu).
    static func key(mode: StorageMode, identity: String?, path: String, query: [String: String]) -> String {
        let normalized = path.hasPrefix("/") ? String(path.dropFirst()) : path
        let q = query.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "&")
        return [mode.rawValue, identity ?? "-", normalized, q].joined(separator: "\n")
    }

    // MARK: - Lecture / écriture

    /// Numéro d'invalidation courant : une écriture lancée avant une
    /// invalidation (`store(..., ifGeneration:)`) est ignorée.
    var currentGeneration: UInt64 {
        lock.withLock { generation }
    }

    func data(forKey key: String) -> Data? {
        lock.withLock {
            tick += 1
            if let hit = memory[key] {
                touch(key)
                return hit
            }
            guard let directory else { return nil }
            let name = Self.fileName(for: key)
            guard index[name] != nil,
                  let data = try? Data(contentsOf: directory.appendingPathComponent(name))
            else { return nil }
            index[name]?.lastUse = tick
            rememberInMemory(key, data)
            return data
        }
    }

    func store(_ data: Data, forKey key: String, ifGeneration expected: UInt64? = nil) {
        lock.withLock {
            if let expected, expected != generation { return }
            tick += 1
            rememberInMemory(key, data)
            guard let directory else { return }
            prepareDirectory(directory)
            let name = Self.fileName(for: key)
            let url = directory.appendingPathComponent(name)
            do {
                try data.write(to: url, options: [.atomic, .completeFileProtection])
            } catch {
                return
            }
            diskBytes -= index[name]?.size ?? 0
            index[name] = Entry(size: data.count, lastUse: tick)
            diskBytes += data.count
            evictDiskIfNeeded()
        }
    }

    /// Vide mémoire ET disque.
    func invalidateAll() {
        lock.withLock {
            generation &+= 1
            memory.removeAll()
            memoryUse.removeAll()
            memoryBytes = 0
            index.removeAll()
            diskBytes = 0
            if let directory { try? FileManager.default.removeItem(at: directory) }
            directoryReady = false
        }
    }

    /// Nombre d'entrées sur disque (tests / diagnostic).
    var diskEntryCount: Int { lock.withLock { index.count } }
    var memoryEntryCount: Int { lock.withLock { memory.count } }

    // MARK: - Interne (verrou tenu)

    private func touch(_ key: String) {
        index[Self.fileName(for: key)]?.lastUse = tick
        memoryUse[key] = tick
    }

    private var memoryUse: [String: UInt64] = [:]

    private func rememberInMemory(_ key: String, _ data: Data) {
        memoryBytes -= memory[key]?.count ?? 0
        memory[key] = data
        memoryUse[key] = tick
        memoryBytes += data.count
        while memoryBytes > memoryLimit, memory.count > 1,
              let oldest = memoryUse.filter({ memory[$0.key] != nil && $0.key != key }).min(by: { $0.value < $1.value })?.key {
            memoryBytes -= memory[oldest]?.count ?? 0
            memory[oldest] = nil
            memoryUse[oldest] = nil
        }
        // Une valeur seule plus grosse que le plafond n'est pas gardée en mémoire.
        if memoryBytes > memoryLimit {
            memory[key] = nil
            memoryUse[key] = nil
            memoryBytes = memory.values.reduce(0) { $0 + $1.count }
        }
    }

    private func evictDiskIfNeeded() {
        guard let directory else { return }
        while diskBytes > diskLimit, let oldest = index.min(by: { $0.value.lastUse < $1.value.lastUse }) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(oldest.key))
            diskBytes -= oldest.value.size
            index[oldest.key] = nil
        }
    }

    private func prepareDirectory(_ directory: URL) {
        guard !directoryReady else { return }
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var url = directory
        try? url.setResourceValues(values)
        directoryReady = true
    }

    private func loadIndex() {
        guard let directory,
              let urls = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])
        else { return }
        directoryReady = true
        let sorted = urls.compactMap { url -> (String, Int, Date)? in
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                  let size = values.fileSize else { return nil }
            return (url.lastPathComponent, size, values.contentModificationDate ?? .distantPast)
        }.sorted { $0.2 < $1.2 }
        for (name, size, _) in sorted {
            tick += 1
            index[name] = Entry(size: size, lastUse: tick)
            diskBytes += size
        }
    }

    private static func fileName(for key: String) -> String {
        SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
