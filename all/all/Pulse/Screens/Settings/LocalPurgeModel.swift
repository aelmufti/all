//
//  LocalPurgeModel.swift
//  all (bridge-connect)
//
//  État du bouton « Purger les données de l'iPhone » (Paramètres › Stockage) : peut-on
//  purger (`LocalPurgePlanner.Blocker`), purge en cours, échec. Les trois dépendances
//  sont injectables : les tests passent des factices et ne touchent ni la vraie base
//  ni le vrai spool. La purge n'envoie JAMAIS rien à Pulse (cf. `LocalDataPurge`).
//

import Foundation
import Observation

@MainActor
@Observable
final class LocalPurgeModel {
    enum Availability: Equatable {
        /// Contrôle en cours (ou pas encore fait) : bouton désactivé, sans raison.
        case checking
        case allowed
        /// Raison courte, affichée sous le bouton.
        case blocked(String)
        /// Base ou spool illisibles : on ne sait pas, on ne purge pas.
        case unknown
    }

    private(set) var availability: Availability = .checking
    private(set) var isPurging = false
    /// Dernière purge échouée (pas un blocage : une panne d'E/S).
    private(set) var failed = false

    /// `nil` = illisible ; `[]` = rien ne bloque.
    private let assess: @Sendable () async -> [LocalPurgePlanner.Blocker]?
    private let run: @Sendable () async throws -> LocalDataPurge.Report
    /// Après une purge réussie : réveil, écrans, ré-ingestion (cf. `live`).
    private let afterPurge: @MainActor () async -> Void

    init(
        assess: @escaping @Sendable () async -> [LocalPurgePlanner.Blocker]?,
        run: @escaping @Sendable () async throws -> LocalDataPurge.Report,
        afterPurge: @escaping @MainActor () async -> Void
    ) {
        self.assess = assess
        self.run = run
        self.afterPurge = afterPurge
    }

    /// Branché sur les vraies données. Après la purge : cache et rappels du réveil
    /// (`WakeScheduleStore.clearForLocalPurge`, puis relecture du backend courant) —
    /// seulement en Téléphone/« Les deux » : en mode Pulse le cache reflète Pulse, que
    /// la purge ne touche pas —, rafraîchissement des écrans, et, hors mode Pulse,
    /// ré-ingestion des fichiers gardés pour reconstruire la base.
    static func live() -> LocalPurgeModel {
        LocalPurgeModel(
            assess: { await Task.detached(priority: .utility) { LocalDataPurge.assessInApp() }.value },
            run: { try await LocalDataPurge.performInApp() },
            afterPurge: {
                if StorageModeStore.current != .pulse {
                    WakeScheduleStore.shared.clearForLocalPurge()
                    await WakeScheduleStore.shared.load()
                }
                DataRefreshNotifier.postDataDidChangeDebounced()
                LocalIngestor.ingestIfNeeded()
                // Ce qui a été rapatrié de Pulse est parti avec la base : on le reprend.
                PulseFilesPullService.shared.requestPass()
            })
    }

    var canPurge: Bool { availability == .allowed && !isPurging }

    /// Raison du blocage, sous le bouton ; `nil` sinon.
    var blockedReason: String? {
        if case .blocked(let reason) = availability { return reason }
        return nil
    }

    /// Relit ce qui bloque (à l'ouverture de la page, après une purge).
    func refresh() async {
        guard !isPurging else { return }
        guard let blockers = await assess() else {
            availability = .unknown
            return
        }
        availability = blockers.isEmpty ? .allowed : .blocked(LocalPurgePlanner.reason(for: blockers))
    }

    /// Purge, puis relit l'état. Sans effet si elle n'est pas permise : le bouton
    /// désactivé n'est pas la seule garde (`LocalDataPurge.run` re-contrôle). Rend
    /// vrai si la purge a eu lieu.
    @discardableResult
    func purge() async -> Bool {
        guard canPurge else { return false }
        isPurging = true
        failed = false
        defer { isPurging = false }
        do {
            _ = try await run()
        } catch let blocked as LocalDataPurge.Blocked {
            // L'état affiché était périmé : un blocage est apparu depuis.
            availability = .blocked(LocalPurgePlanner.reason(for: blocked.blockers))
            return false
        } catch {
            failed = true
            return false
        }
        await afterPurge()
        isPurging = false
        await refresh()
        return true
    }
}
