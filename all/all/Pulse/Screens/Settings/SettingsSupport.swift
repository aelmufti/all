//
//  SettingsSupport.swift
//  all (bridge-connect)
//
//  Logique pure partagée par les pages de second niveau des Paramètres :
//  debounce des enregistrements automatiques, libellés humains de l'état du lien
//  BLE, comparaison des jetons, options des sélecteurs. Rien de réseau ici.
//

import SwiftUI

// MARK: - Debounce

/// Regroupe des déclenchements rapprochés en un seul : seule la dernière action
/// programmée part, une fois `delay` écoulé sans nouveau déclenchement. Sert aux
/// réglages enregistrés au fil de l'eau (profil, heure d'un réveil) pour ne pas
/// émettre une requête par cran de sélecteur.
@MainActor
final class SettingsDebouncer {
    private var task: Task<Void, Never>?
    private let delay: Duration

    init(delay: Duration = .milliseconds(600)) {
        self.delay = delay
    }

    var isPending: Bool { task != nil }

    func schedule(_ action: @escaping @MainActor () async -> Void) {
        task?.cancel()
        task = Task { [weak self, delay] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.task = nil
            await action()
        }
    }

    /// Annule l'action en attente ; `true` s'il y en avait une (à exécuter alors
    /// immédiatement par l'appelant, ex. en quittant la page).
    @discardableResult
    func cancelPending() -> Bool {
        let wasPending = task != nil
        task?.cancel()
        task = nil
        return wasPending
    }
}

// MARK: - État du lien BLE, en clair

enum SettingsWatchStatus {
    static func label(for state: BLEConnectionState) -> String {
        switch state {
        case .disconnected: return "Déconnectée"
        case .scanning: return "Recherche…"
        case .connecting: return "Connexion…"
        case .reconnecting: return "Reconnexion…"
        case .connected: return "Connectée"
        }
    }

    static func color(for state: BLEConnectionState) -> Color {
        switch state {
        case .connected: return .pulseSuccess
        case .disconnected: return .pulseAbsent
        case .scanning, .connecting, .reconnecting: return .pulseAccent
        }
    }
}

// MARK: - Jeton d'envoi

enum SettingsIngestTokenStatus: Equatable {
    case ok
    case needsUpdate

    /// `nil` quand le jeton du serveur n'est pas connu (rien à comparer).
    static func compare(device: String?, server: String?) -> SettingsIngestTokenStatus? {
        guard let server = server?.trimmingCharacters(in: .whitespacesAndNewlines), !server.isEmpty else { return nil }
        let local = device?.trimmingCharacters(in: .whitespacesAndNewlines)
        return local == server ? .ok : .needsUpdate
    }
}

// MARK: - Options des sélecteurs du profil

enum SettingsProfileOptions {
    /// Années proposées : de (année courante − 100) à (année courante − 10), la
    /// plus récente en premier. La valeur déjà enregistrée y est ajoutée si elle
    /// sort de la plage, pour que le sélecteur ne perde jamais la sélection.
    static func birthYears(currentYear: Int, including value: Int?) -> [Int] {
        options(range: (currentYear - 100)...(currentYear - 10), including: value, descending: true)
    }

    /// Tailles proposées : 100 à 230 cm.
    static func heights(including value: Int?) -> [Int] {
        options(range: 100...230, including: value, descending: false)
    }

    private static func options(range: ClosedRange<Int>, including value: Int?, descending: Bool) -> [Int] {
        var all = Array(range)
        if let value, !range.contains(value) { all.append(value) }
        all.sort(by: descending ? (>) : (<))
        return all
    }
}

// MARK: - Réveil

enum SettingsWakeDefaults {
    static let fallbackMinutes = 7 * 60

    /// Heure proposée à l'activation d'un jour : la dernière réglée dans la
    /// session, à défaut celle du premier jour réglé (Lun → Dim), sinon 07:00.
    static func minutes(lastSet: Int?, schedule: [Int: Int], order: [Int]) -> Int {
        if let lastSet { return lastSet }
        for weekday in order { if let minutes = schedule[weekday] { return minutes } }
        return fallbackMinutes
    }
}
