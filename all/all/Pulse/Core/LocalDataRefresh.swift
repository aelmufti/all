//
//  LocalDataRefresh.swift
//  all (bridge-connect)
//
//  Rafraîchissement des écrans sans redémarrage de l'app, sur deux signaux :
//
//  - `.reloadsOnLocalDataChange` ← `.allLocalDataDidChange`, posté par
//    `LocalIngestor.ingestIfNeeded` dès qu'au moins un fichier du spool a été
//    réellement inséré en base (fin de traversée BLE en mode Téléphone/Les
//    deux, cf. `GarminSession.advanceDownloadQueue`). Sans ce pont, un écran
//    déjà ouvert pendant une synchro n'affichait la nouvelle donnée qu'au
//    redémarrage.
//  - `.reloadsOnStorageModeChange` ← `.storageModeDidChange`, posté par
//    `StorageModeStore` au changement de source (Pulse ↔ Téléphone ↔ Les deux).
//
//  Chaque écran fournit la fermeture qui recharge SA sélection courante. Là où
//  l'écran a un garde-fou « jour du jour » (`reloadForNewDay`), on le réutilise
//  pour l'ingestion (la nouvelle donnée concerne aujourd'hui) ; au changement
//  de SOURCE, en revanche, on passe la fermeture complète (`load()`) car toute
//  la source bascule — cf. l'appelant.
//
//  Réception via `.onReceive(NotificationCenter.publisher(for:))` et NON via
//  `for await … in NotificationCenter.notifications(named:)` dans un `.task` :
//  cette seconde forme ratait en pratique les notifications (l'écran ne se
//  mettait à jour qu'après avoir tué puis rouvert l'app — bug constaté en mode
//  Téléphone, synchro reçue pendant qu'on regardait un graph). `.onReceive`
//  (Combine) est le canal SwiftUI fiable et idiomatique pour ça.
//

import SwiftUI

/// Poste `.allLocalDataDidChange` (signal « tes données ont changé, recharge »)
/// en **coalescant** les demandes rapprochées : une synchro Pulse pousse N
/// fichiers d'affilée, chacun livré (2xx) à quelques dizaines de ms d'écart —
/// on ne veut pas N rechargements complets, mais UN seul peu après le dernier.
///
/// Pourquoi ce signal est nécessaire en mode Pulse : `LocalIngestor` (le seul
/// autre émetteur de `.allLocalDataDidChange`) est un no-op en `.pulse`. Sans
/// ce pont, une fois les `.fit` ingérés CÔTÉ PULSE, rien ne disait aux écrans
/// de re-fetch — ils restaient figés jusqu'au redémarrage de l'app.
enum DataRefreshNotifier {
    /// Accès sérialisé sur le main : toutes les méthodes dispatchent sur
    /// `DispatchQueue.main`, donc pas de course malgré `unsafe`.
    nonisolated(unsafe) private static var pending: DispatchWorkItem?

    /// À appeler dès qu'une donnée visible par les écrans est devenue
    /// disponible (ex. fichier livré/ingéré côté Pulse, ou inséré en local).
    /// Reporte le post de ~0,8 s et annule le report précédent : plusieurs
    /// appels rapprochés (synchro multi-fichiers, ingestion locale + livraison
    /// Pulse en mode « Les deux ») fusionnent en UN seul rechargement.
    static func postDataDidChangeDebounced() {
        DispatchQueue.main.async {
            pending?.cancel()
            let work = DispatchWorkItem {
                NotificationCenter.default.post(name: .allLocalDataDidChange, object: nil)
            }
            pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
        }
    }
}

extension View {
    func reloadsOnLocalDataChange(_ onChange: @escaping () async -> Void) -> some View {
        modifier(NotificationReloadModifier(name: .allLocalDataDidChange, onChange: onChange))
    }

    /// Recharge l'écran quand la SOURCE de données change (`Stockage` :
    /// Pulse ↔ Téléphone ↔ Les deux) — cf. `.storageModeDidChange`. À la
    /// différence de `reloadsOnLocalDataChange` (qui réutilise le garde-fou
    /// « jour du jour » des écrans), on passe ici la fermeture de rechargement
    /// **complète** (`load()`) : la source bascule entièrement, donc même une
    /// sélection sur un jour passé doit être re-tirée du nouveau backend.
    func reloadsOnStorageModeChange(_ onChange: @escaping () async -> Void) -> some View {
        modifier(NotificationReloadModifier(name: .storageModeDidChange, onChange: onChange))
    }
}

/// Déclenche `onChange` à la réception d'une `Notification.Name`. `.onReceive`
/// (publisher Combine) plutôt que l'AsyncSequence `.notifications(named:)` dans
/// un `.task` — cf. en-tête de fichier pour la raison (notifications ratées).
private struct NotificationReloadModifier: ViewModifier {
    let name: Notification.Name
    let onChange: () async -> Void

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: name)) { _ in
                // La notification est postée sur le main actor (cf.
                // `LocalIngestor`/`StorageModeStore`) ; `onChange` cible un
                // view-model `@MainActor`. Pas de debounce : chaque notification
                // correspond déjà à un événement discret (fin de traversée,
                // changement de mode), pas à une rafale.
                Task { await onChange() }
            }
    }
}
