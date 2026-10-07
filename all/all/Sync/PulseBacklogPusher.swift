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
//  `SpoolStore` plutôt que de recevoir celle de `BLEManager` (hors main actor,
//  on ne veut pas dépendre d'une instance possédée ailleurs, ni la garder
//  vivante). Ouvrir une deuxième instance est SÛR : le journal est relu et
//  fusionné sur disque à chaque transition, sous un verrou commun à toutes les
//  instances (cf. `Spool/SpoolStore.swift`) — `markPushedToPulse` ne peut donc
//  ni écraser une entrée ou un état plus récent écrit par l'instance de
//  `BLEManager`, ni être gênée par elle ; le cache `entries` est lu sous ce même
//  verrou. L'instantané d'ouverture sert seulement à choisir QUOI pousser.
//
//  N'utilise PAS `RoutingSpoolUploader` : ce type est un pousseur DIRECT vers
//  Pulse (`PulseSpoolUploader`), déclenché seulement après que son propre
//  garde de mode (`pushIfNeeded`) a vérifié qu'on est en `.pulse`/`.both` —
//  passer par le routeur ajouterait une indirection sans bénéfice (il n'y a
//  plus de branche `.phone` à filtrer ici).
//
//  Un rejet définitif de Pulse (`.quarantine`) met l'entrée en quarantaine
//  (`SpoolEntry.pulseRejectedAt`) : le rattrapage ne la retente plus, sauf sur
//  « Renvoyer » (`resendRejected()`).
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

    /// Sélection PURE (aucune E/S) — entrées à pousser : jamais poussées, NON
    /// rejetées par Pulse (`pulseRejectedAt` : les rejouer ne change rien, elles
    /// ne repartent que sur « Renvoyer », cf. `resendRejected()`) ET dont le
    /// fichier existe encore sur disque (une entrée dont le fichier a disparu ne
    /// peut de toute façon pas être relue ; on ne la retente pas indéfiniment). Extraite pour être testable sans `SpoolStore` réel ni
    /// disque, cf. `allTests/PulseBacklogPusherTests.swift`.
    static func backlog(from entries: [SpoolEntry], fileExists: (SpoolEntry) -> Bool) -> [SpoolEntry] {
        entries.filter { !$0.pushedToPulse && $0.pulseRejectedAt == nil && fileExists($0) }
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
            await pushBacklog(due, spool: spool, uploader: uploader, health: PulseUploadHealth.observeFromAnyThread, reporter: MainSyncWorkReporter())
        }
    }

    /// Pousse `due` un à un et déclare le reste à la bannière d'activité
    /// (`SyncWork`) sous une source PROPRE à ce rattrapage (deux rattrapages
    /// simultanés — lancement + changement de mode — s'additionnent sans se
    /// piétiner). Le `defer` libère le compte quelle que soit la sortie : un
    /// décompte coincé afficherait la bannière pour toujours.
    static func pushBacklog(
        _ due: [SpoolEntry], spool: SpoolStore, uploader: SpoolUploading,
        health: ((PulseUploadOutcome) -> Void)? = nil, reporter: SyncWorkReporting
    ) async {
        let source = "backlog-\(UUID().uuidString)"
        reporter.uploads(source: source, remaining: due.count)
        defer { reporter.uploads(source: source, remaining: 0) }
        for (index, entry) in due.enumerated() {
            await push(entry, spool: spool, uploader: uploader, health: health)
            reporter.uploads(source: source, remaining: due.count - index - 1)
        }
    }

    /// « Renvoyer » (écran Montre) : efface les rejets du journal puis relance le
    /// rattrapage, qui reprend ces fichiers (`pushedToPulse == false`) ; un
    /// nouveau rejet les remet en quarantaine. Ouvre sa propre `SpoolStore`
    /// (journal fusionné sur disque : la session BLE verra l'effacement à sa
    /// prochaine transition ou relecture). Fire-and-forget, comme `pushIfNeeded()`.
    static func resendRejected() {
        Task.detached(priority: .utility) {
            guard let spool = try? SpoolStore() else {
                log.error("resendRejected: SpoolStore indisponible")
                return
            }
            let cleared = spool.clearPulseRejections()
            log.info("resendRejected: \(cleared, privacy: .public) fichier(s) remis en file")
            let remaining = spool.pulseRejectedCount()
            await MainActor.run { PulseUploadHealth.shared.setRejectedCount(remaining) }
            pushIfNeeded()
        }
    }

    /// Pousse une entrée et marque `pushedToPulse` sur un accusé réel —
    /// jamais `markDelivered`/`markArchived` : ce type ne touche QUE
    /// `pushedToPulse` (cf. en-tête de fichier, `SpoolEntry.pushedToPulse`) ;
    /// l'archivage montre reste entièrement le ressort de `GarminSession`, et
    /// ce rattrapage n'a de toute façon aucun lien BLE actif à disposition.
    /// `uploader` est injectable (protocole `SpoolUploading`) : les tests y
    /// passent un factice qui ne touche jamais le réseau, jamais
    /// `PulseSpoolUploader` réel (règle immuable du dépôt). `health` reçoit chaque
    /// issue réelle de Pulse (cf. `PulseUploadHealth`) ; `nil` en test, pour ne
    /// jamais toucher le singleton global.
    static func push(
        _ entry: SpoolEntry, spool: SpoolStore, uploader: SpoolUploading,
        health: ((PulseUploadOutcome) -> Void)? = nil
    ) async {
        let fileURL = spool.fileURL(for: entry)
        await withCheckedContinuation { continuation in
            uploader.upload(fileURL: fileURL, watchFilename: entry.id.name) { outcome in
                health?(outcome)
                switch outcome {
                case .delivered:
                    // Jeton de l'acquisition poussée : si le fichier a été relu
                    // (taille changée) pendant l'envoi, le nouveau contenu n'a
                    // PAS été poussé et ne doit pas être marqué.
                    spool.markPushedToPulse(entry.id, expectedAcquiredAt: entry.acquiredAt)
                    log.info("Rattrapage Pulse : fichier poussé (\(entry.relativePath, privacy: .public))")
                case .quarantine:
                    // Rejet définitif : en quarantaine dans le journal (sans quoi
                    // chaque lancement le renverrait en vain). N'ajoute pas de
                    // transition d'état à une entrée déjà `delivered`/`archived` —
                    // seul `pulseRejectedAt` change ; `pushedToPulse` reste `false`.
                    spool.markPulseRejected(entry.id, expectedAcquiredAt: entry.acquiredAt)
                    log.error("Rattrapage Pulse : \(entry.relativePath, privacy: .public) rejeté, mis en quarantaine")
                case .keepConfigError, .keepRetryLater, .keepRetry:
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
