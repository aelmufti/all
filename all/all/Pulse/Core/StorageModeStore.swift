//
//  StorageModeStore.swift
//  all (bridge-connect)
//
//  Réglage « Stockage » (cf. `docs/stockage-local.md`) : où vivent les
//  données de l'app — `pulse` (serveur, comportement historique), `phone`
//  (téléphone seul, aucun réseau) ou `both` (Pulse en primaire, repli local
//  si Pulse est injoignable). Persisté en `UserDefaults`, modelé sur
//  `ThemeStore.swift` (même forme `@MainActor @Observable` + `didSet`).
//
//  Distinct de `SettingsSyncSourceKind` (`Screens/Settings/SettingsModels.swift`,
//  valeurs `legacy`/`bridge`/`phone`) : cet autre réglage dit **qui collecte**
//  sur la montre côté `SyncGateService` (source active `PUT api/sync/source`).
//  Celui-ci dit **où vivent les données** côté app. Les deux partagent le mot
//  « phone »/« téléphone » par coïncidence de vocabulaire — aucun lien entre
//  les deux réglages, aucune synchronisation automatique de l'un vers l'autre.
//
//  Lecture non-UI : `GarminSession`/`PulseAPIClient`/`PulseLiveHrPusher`
//  doivent relire le mode courant à **chaque appel**, jamais le capturer à
//  l'init (l'utilisateur peut basculer le mode en cours de session, depuis
//  Paramètres) — et depuis du code qui ne tourne pas forcément sur le main
//  actor. `shared` (comme `ThemeStore.shared`) reste `@MainActor`-isolé pour
//  le binding SwiftUI ; `current` est la lecture non-isolée équivalente,
//  directement depuis `UserDefaults` (même idée que `PulseConfig.baseURL`,
//  qui n'est pas non plus isolé à un acteur).
//

import Foundation
import Observation

enum StorageMode: String, CaseIterable, Identifiable {
    case pulse
    case phone
    case both

    var id: String { rawValue }

    var label: String {
        switch self {
        case .pulse: return "Pulse"
        case .phone: return "Téléphone"
        case .both: return "Les deux"
        }
    }
}

@MainActor
@Observable
final class StorageModeStore {
    static let shared = StorageModeStore()

    /// `nonisolated(unsafe)` : constante immuable (`String`), jamais mutée
    /// après déclaration — sûre à lire depuis `current` (non-isolé), sans quoi
    /// le vérificateur de concurrence exigerait un accès isolé au main actor
    /// même pour ce simple littéral (même idiome que `StubURLProtocol.handler`
    /// dans les tests, pour une raison différente : ici c'est un `let`, pas un
    /// état mutable partagé).
    nonisolated(unsafe) private static let key = "storage-mode"

    /// Conservé (contrairement à `ThemeStore`, qui écrit toujours vers
    /// `.standard` en dur dans son `didSet`) pour que le `defaults` injecté à
    /// l'init serve aussi à l'écriture — sinon une instance construite avec un
    /// `UserDefaults` de test écrirait silencieusement dans `.standard`
    /// (bogue constaté en test : `persistsAcrossInstancesOfTheSameDefaults`
    /// relisait `.pulse` au lieu de la valeur tout juste écrite).
    private let defaults: UserDefaults

    var mode: StorageMode {
        didSet {
            defaults.set(mode.rawValue, forKey: Self.key)
            // Changement réel de source de données → prévenir les écrans
            // ouverts pour qu'ils rechargent immédiatement depuis la NOUVELLE
            // source (Pulse ↔ local), sans redémarrage de l'app. Posté sur le
            // main actor (ce `didSet` y tourne, classe `@MainActor`), donc reçu
            // sur le main actor par les écrans. Garde `mode != oldValue` : le
            // picker segmenté ne déclenche que sur vrai changement, mais on
            // évite une notif superflue si quelqu'un réassigne la même valeur.
            if mode != oldValue {
                NotificationCenter.default.post(name: .storageModeDidChange, object: nil)
            }
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.string(forKey: Self.key).flatMap(StorageMode.init(rawValue:))
        mode = stored ?? .pulse
    }

    /// Lecture synchrone depuis du code non-UI, à chaque appel (jamais
    /// capturée) — cf. en-tête de fichier. Relit `UserDefaults.standard`
    /// directement plutôt que de passer par `shared` (`@MainActor`), pour
    /// rester appelable sans changement d'acteur depuis `GarminSession`,
    /// `PulseAPIClient`, `PulseLiveHrPusher`. Reflète toujours la même valeur
    /// que `shared.mode` (même clé `UserDefaults`).
    nonisolated static var current: StorageMode {
        let stored = UserDefaults.standard.string(forKey: key).flatMap(StorageMode.init(rawValue:))
        return stored ?? .pulse
    }
}

extension Notification.Name {
    /// Postée par `StorageModeStore.mode.didSet` quand le mode change vraiment.
    /// Signal pour que les écrans de données rechargent leur sélection courante
    /// depuis la nouvelle source (`.reloadsOnStorageModeChange`, cf.
    /// `LocalDataRefresh.swift`). Distincte de `.allLocalDataDidChange`
    /// (ingestion locale, `LocalIngestor`) : ici toute la source bascule, donc
    /// le rechargement est un `load()` complet — y compris sur un jour passé,
    /// là où le reload d'ingestion se contente d'un garde-fou « jour du jour ».
    static let storageModeDidChange = Notification.Name("storageModeDidChange")
}
