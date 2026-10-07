//
//  PulseUploadHealth.swift
//  all (bridge-connect)
//
//  Santé de l'envoi vers Pulse, observable par l'interface. Avant ce fichier, un
//  jeton refusé (401), une source mal réglée (403) ou des fichiers rejetés
//  (400/413/415/422) ne laissaient qu'une ligne de log : rien à l'écran.
//
//  Deux informations, de nature différente :
//  - le dernier problème de CONFIGURATION observé (`ConfigProblem` : 401 ou 403),
//    persisté et effacé au prochain envoi RÉUSSI (`.delivered` venu de Pulse, pas
//    la livraison locale du mode Téléphone) ;
//  - le nombre de fichiers en quarantaine (`rejectedCount`), relu du journal du
//    spool (`SpoolEntry.pulseRejectedAt`).
//  Les erreurs réseau / 5xx (`.keepRetry`) ne signalent RIEN et n'effacent rien :
//  être loin du serveur est normal.
//
//  Alimenté depuis les seuls endroits qui parlent réellement à Pulse
//  (`RoutingSpoolUploader`, branche `.pulse`/`.both`, et `PulseBacklogPusher.push`),
//  via `observeFromAnyThread` (les complétions arrivent hors main). Les tests
//  injectent leur propre instance (`defaults` dédié) et n'utilisent jamais
//  `shared`.
//

import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class PulseUploadHealth {
    static let shared = PulseUploadHealth()

    /// Problème de configuration retenu entre deux lancements.
    enum ConfigProblem: String {
        /// 401 — jeton absent ou invalide (`PulseUploadOutcome.keepConfigError`).
        case invalidToken
        /// 403 — la source de synchro de Pulse n'est pas `phone`
        /// (`PulseUploadOutcome.keepRetryLater`).
        case wrongSource
    }

    /// Ce que l'interface affiche, par ordre de priorité décroissante.
    enum Issue: Equatable {
        case invalidToken
        case wrongSource
        case rejectedFiles(Int)

        /// Libellé court, sans phrase d'explication (le détail vit dans l'aide).
        var label: String {
            switch self {
            case .invalidToken: return "Jeton Pulse absent ou refusé"
            case .wrongSource: return "Pulse n'accepte pas l'iPhone comme source"
            case .rejectedFiles(let count):
                return count == 1 ? "1 fichier refusé par Pulse" : "\(count) fichiers refusés par Pulse"
            }
        }
    }

    private static let key = "pulse-upload-config-problem"

    @ObservationIgnored private let defaults: UserDefaults

    /// Dernier problème de configuration observé, `nil` après un envoi réussi.
    private(set) var configProblem: ConfigProblem? {
        didSet {
            guard configProblem != oldValue else { return }
            if let configProblem {
                defaults.set(configProblem.rawValue, forKey: Self.key)
            } else {
                defaults.removeObject(forKey: Self.key)
            }
        }
    }

    /// Fichiers en quarantaine (rejetés par Pulse), tel que lu du journal au
    /// dernier rafraîchissement (`refreshRejectedCount`).
    private(set) var rejectedCount = 0

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        configProblem = defaults.string(forKey: Self.key).flatMap(ConfigProblem.init(rawValue:))
    }

    /// Problème à signaler : jeton invalide > mauvaise source > fichiers rejetés >
    /// rien.
    var issue: Issue? {
        switch configProblem {
        case .invalidToken: return .invalidToken
        case .wrongSource: return .wrongSource
        case nil: return rejectedCount > 0 ? .rejectedFiles(rejectedCount) : nil
        }
    }

    /// Retient l'issue d'un envoi réel vers Pulse. PURE (aucune E/S hors
    /// `UserDefaults`). Le NOMBRE de rejets, lui, se lit dans le journal
    /// (`rejectedCount`).
    func record(_ outcome: PulseUploadOutcome) {
        switch outcome {
        case .keepConfigError: configProblem = .invalidToken
        case .keepRetryLater: configProblem = .wrongSource
        // Un rejet (4xx de contenu) prouve autant qu'un 2xx que le jeton et la
        // source sont acceptés : il lève lui aussi le problème de configuration.
        case .delivered, .quarantine: configProblem = nil
        case .keepRetry: break
        }
    }

    /// Le jeton ou l'adresse viennent d'être ressaisis : le constat précédent ne
    /// vaut plus (sans cela il resterait affiché jusqu'au prochain envoi, qui
    /// peut ne jamais venir s'il n'y a rien à envoyer).
    func clearConfigProblem() {
        configProblem = nil
    }

    func setRejectedCount(_ count: Int) {
        rejectedCount = max(0, count)
    }

    /// Relit le nombre de rejets dans le journal du spool, hors main (lecture et
    /// décodage du journal). `count` est injectable pour les tests ; par défaut une
    /// `SpoolStore` propre, le rejet étant posé par une AUTRE instance (session BLE,
    /// rattrapage).
    func refreshRejectedCount(count: @escaping @Sendable () -> Int = { (try? SpoolStore())?.pulseRejectedCount() ?? 0 }) {
        Task.detached(priority: .utility) { [weak self] in
            let value = count()
            await self?.setRejectedCount(value)
        }
    }

    /// Point d'entrée des couches réseau : les complétions d'upload arrivent hors
    /// main, on saute sur le `MainActor` avant de toucher l'état observable.
    nonisolated static func observeFromAnyThread(_ outcome: PulseUploadOutcome) {
        Task { @MainActor in shared.record(outcome) }
    }
}

extension View {
    /// Tient `health.rejectedCount` à jour pour un écran qui l'affiche : à
    /// l'apparition, et à chaque rejet ou « Renvoyer » (`.spoolPulseRejectionsDidChange`,
    /// posté sur le main par `SpoolStore`).
    func refreshesPulseRejectedCount(_ health: PulseUploadHealth) -> some View {
        onAppear { health.refreshRejectedCount() }
            .onReceive(NotificationCenter.default.publisher(for: .spoolPulseRejectionsDidChange)) { _ in
                health.refreshRejectedCount()
            }
    }
}
