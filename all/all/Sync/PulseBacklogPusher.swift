//
//  PulseBacklogPusher.swift
//  all (bridge-connect)
//
//  Rattrapage Pulse : au basculement Téléphone → Pulse/Les deux (ou si un tel
//  basculement a eu lieu hors ligne lors d'une session précédente), pousse les
//  `.fit` retenus dans le Spool qui n'ont JAMAIS atteint Pulse
//  (`SpoolEntry.pushedToPulse == false`, cf. `Spool/SpooledFile.swift`) — la
//  livraison locale du mode Téléphone (`RoutingSpoolUploader`, branche
//  `.phone`) marque `delivered`/`archived` sans jamais parler au réseau, donc
//  ces fichiers restent SUR LE DISQUE (rien ne les purge) mais jamais poussés.
//
//  Miroir structurel de `Local/LocalIngestor.swift` (`ingestIfNeeded`) : un
//  `static func`, garde de mode, `Task.detached` qui ouvre sa PROPRE
//  `SpoolStore` plutôt que de réutiliser celle, vivante, de `BLEManager`
//  (même raison : `SpoolStore.entries` est un dictionnaire mutable lu/écrit
//  ailleurs sur le main actor — une deuxième instance relit `journal.json`,
//  petit fichier, coût négligeable, et élimine la course plutôt que de la
//  gérer).
//
//  N'utilise PAS `RoutingSpoolUploader` : ce type est un pousseur DIRECT vers
//  Pulse (`PulseSpoolUploader`), déclenché seulement après que son propre
//  garde de mode (`pushIfNeeded`) a vérifié qu'on est en `.pulse`/`.both` —
//  passer par le routeur ajouterait une indirection sans bénéfice (il n'y a
//  plus de branche `.phone` à filtrer ici).
//
//  ÉMISSION RÉSEAU : réutilise `PulseSpoolUploader` (même couture
//  `SpoolUploading`/`PulseUploadTransport` que le flux GFDI normal), donc
//  couverte par la même autorisation utilisateur datée 2026-09-22 — ce n'est
//  qu'un second appelant du même chemin d'upload, pas un nouveau canal réseau.
//

import Foundation
import os

enum PulseBacklogPusher {
    private static let log = Logger(subsystem: "CleanYourRoom.all", category: "pulse-backlog")

    /// Sélection PURE (aucune E/S) — entrées à pousser : jamais poussées ET
    /// dont le fichier existe encore sur disque (une entrée dont le fichier a
    /// disparu ne peut de toute façon pas être relue ; on ne la retente pas
    /// indéfiniment). Extraite pour être testable sans `SpoolStore` réel ni
    /// disque, cf. `allTests/PulseBacklogPusherTests.swift`.
    static func backlog(from entries: [SpoolEntry], fileExists: (SpoolEntry) -> Bool) -> [SpoolEntry] {
        entries.filter { !$0.pushedToPulse && fileExists($0) }
    }

    /// Garde PURE (aucune E/S) — décide si `pushIfNeeded()` doit seulement
    /// tenter quelque chose, indépendamment de ce qu'il y a réellement à
    /// pousser (ça, c'est `backlog(from:fileExists:)`, après ouverture du
    /// Spool). Extraite pour être testable sans toucher `StorageModeStore`/
    /// `PulseConfig` (globaux `UserDefaults`/Keychain), cf.
    /// `allTests/PulseBacklogPusherTests.swift`. Mêmes conditions que
    /// `PulseSpoolUploader.upload` (`.keepConfigError` si `baseURL`/token
    /// absent) — pas de raison de lancer une tâche détachée pour obtenir la
    /// même issue négative fichier par fichier.
    static func shouldAttemptPush(mode: StorageMode, baseURLConfigured: Bool, token: String?) -> Bool {
        guard mode != .phone else { return false }
        guard baseURLConfigured, let token, !token.isEmpty else { return false }
        return true
    }

    /// Point d'entrée, appelé aux deux coutures retenues : lancement
    /// (`ContentView.task`, à côté de `LocalIngestor.ingestIfNeeded()`) et
    /// changement de mode vers `.pulse`/`.both` (`ContentView.onChange(of:
    /// storageMode.mode)`). Ne fait rien en mode `.phone` (rien à pousser :
    /// personne ne doit jamais partir vers Pulse dans ce mode) ni si Pulse
    /// n'est pas configuré (`baseURL`/`ingestToken` absents — on ne peut pas
    /// savoir où pousser, et `PulseSpoolUploader` répondrait de toute façon
    /// `.keepConfigError` à chaque fichier). Fire-and-forget, comme
    /// `LocalIngestor.ingestIfNeeded()` : jamais attendue par l'appelant.
    static func pushIfNeeded() {
        guard shouldAttemptPush(mode: StorageModeStore.current, baseURLConfigured: PulseConfig.baseURL != nil, token: PulseConfig.ingestToken) else {
            log.debug("pushIfNeeded: rien à tenter (mode Téléphone, ou Pulse non configuré) — rattrapage sauté")
            return
        }
        Task.detached(priority: .utility) {
            guard let spool = try? SpoolStore() else {
                log.error("pushIfNeeded: SpoolStore indisponible, rattrapage sauté")
                return
            }
            let uploader = PulseSpoolUploader()
            let due = backlog(from: Array(spool.entries.values)) { entry in
                FileManager.default.fileExists(atPath: spool.fileURL(for: entry).path)
            }
            guard !due.isEmpty else {
                log.info("pushIfNeeded: rien à rattraper")
                return
            }
            log.info("pushIfNeeded: \(due.count, privacy: .public) fichier(s) en attente de rattrapage Pulse")
            for entry in due {
                await push(entry, spool: spool, uploader: uploader)
            }
        }
    }

    /// Pousse une entrée et marque `pushedToPulse` sur un accusé réel —
    /// jamais `markDelivered`/`markArchived` : ce type ne touche QUE
    /// `pushedToPulse` (cf. en-tête de fichier, `SpoolEntry.pushedToPulse`) ;
    /// l'archivage montre reste entièrement le ressort de `GarminSession`, et
    /// ce rattrapage n'a de toute façon aucun lien BLE actif à disposition.
    /// `uploader` est injectable (protocole `SpoolUploading`) : les tests y
    /// passent un factice qui ne touche jamais le réseau, jamais
    /// `PulseSpoolUploader` réel (règle immuable du dépôt).
    static func push(_ entry: SpoolEntry, spool: SpoolStore, uploader: SpoolUploading) async {
        let fileURL = spool.fileURL(for: entry)
        await withCheckedContinuation { continuation in
            uploader.upload(fileURL: fileURL, watchFilename: entry.id.name) { outcome in
                switch outcome {
                case .delivered:
                    spool.markPushedToPulse(entry.id)
                    log.info("Rattrapage Pulse : fichier poussé (\(entry.relativePath, privacy: .public))")
                case .keepConfigError, .keepRetryLater, .keepRetry, .quarantine:
                    // Laisse `pushedToPulse=false` : retenté au prochain
                    // `pushIfNeeded()` (lancement suivant, ou nouveau
                    // basculement de mode). Jamais fatal — un fichier qui ne
                    // part pas cette fois ne doit pas interrompre les suivants.
                    log.warning("Rattrapage Pulse : \(entry.relativePath, privacy: .public) resté en attente")
                }
                continuation.resume()
            }
        }
    }
}
