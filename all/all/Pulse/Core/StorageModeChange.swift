//
//  StorageModeChange.swift
//  all (bridge-connect)
//
//  Confirmation d'un changement de mode Stockage depuis Paramètres › Stockage : le
//  sélecteur ne change plus le mode lui-même, il DEMANDE (`request`) ; le mode ne
//  change qu'à la confirmation (`confirm`). « Annuler » ne touche à rien.
//
//  Le flux de connexion à Pulse (`SettingsView.pendingServerMode`) vient APRÈS la
//  confirmation : choisir Pulse ou « Les deux » sans session ne bascule pas le mode,
//  `confirm()` rend `.needsLogin` et la vue ouvre la feuille de connexion, qui
//  applique le mode une fois connecté. L'onboarding ne passe pas ici : son premier
//  choix n'a rien à perdre.
//

import Foundation
import Observation

extension StorageMode {
    /// Une phrase, propre au mode CHOISI, vérifiée contre le code :
    ///  - Pulse : l'envoi des fichiers (`RoutingSpoolUploader`) et les saisies
    ///    (`PulseAPIClient`) vont à Pulse ; `LocalIngestor.ingestIfNeeded` ne fait
    ///    rien, la base de l'iPhone n'est plus alimentée ;
    ///  - Téléphone : livraison locale sans réseau, saisies dans la base locale, ni
    ///    rattrapage (`PulseBacklogPusher`), ni échange (`SaisieSyncService`), ni
    ///    fréquence cardiaque en direct ne partent vers Pulse ;
    ///  - Les deux : fichiers envoyés à Pulse ET ingérés en local, ceux que Pulse détient
    ///    et pas l'iPhone récupérés (`PulseFilesPullService`, premier plan seulement),
    ///    saisies échangées (`SaisieSyncService`) — en Pulse/Téléphone elles ne partaient
    ///    pas.
    var changeConfirmation: String {
        switch self {
        case .pulse: return "Les fichiers de la montre et les saisies vont sur Pulse ; la base de l'iPhone n'est plus mise à jour."
        case .phone: return "L'iPhone stocke les nouvelles données ; rien ne part vers Pulse."
        case .both: return "Les fichiers de la montre vont sur Pulse et dans l'iPhone, qui récupère aussi ceux de Pulse ; les saisies sont échangées."
        }
    }

    var changeConfirmationTitle: String { "Stockage : \(label) ?" }
}

@MainActor
@Observable
final class StorageModeChangeController {
    enum Outcome: Equatable {
        /// Le mode vient d'être appliqué.
        case applied(StorageMode)
        /// Mode serveur sans session : rien n'est appliqué, la vue présente la
        /// connexion (qui applique le mode une fois connecté).
        case needsLogin(StorageMode)
        /// Rien en attente.
        case none
    }

    /// Mode demandé, en attente de confirmation (`nil` : aucune demande).
    private(set) var pending: StorageMode?

    private let store: StorageModeStore
    private let hasSession: @MainActor () -> Bool

    init(store: StorageModeStore = .shared, hasSession: @escaping @MainActor () -> Bool = { AuthStore.shared.username != nil }) {
        self.store = store
        self.hasSession = hasSession
    }

    /// Le sélecteur demande `mode`. Le mode courant n'est pas modifié ; redemander le
    /// mode déjà actif n'ouvre aucune confirmation.
    func request(_ mode: StorageMode) {
        pending = mode == store.mode ? nil : mode
    }

    func cancel() {
        pending = nil
    }

    /// Applique le mode demandé, sauf s'il exige un serveur auquel on n'est pas
    /// connecté (`.needsLogin`).
    @discardableResult
    func confirm() -> Outcome {
        guard let mode = pending else { return .none }
        pending = nil
        if (mode == .pulse || mode == .both) && !hasSession() { return .needsLogin(mode) }
        store.mode = mode
        return .applied(mode)
    }
}
