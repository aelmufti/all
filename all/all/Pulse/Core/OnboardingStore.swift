//
//  OnboardingStore.swift
//  all (bridge-connect)
//
//  Réglage « onboarding terminé » — déclenche `OnboardingView` (cf.
//  `Pulse/Onboarding/OnboardingView.swift`) au premier lancement, et à chaque
//  lancement suivant tant que l'utilisateur n'est pas allé au bout du
//  parcours. Persisté en `UserDefaults`, modelé sur `StorageModeStore.swift`
//  (même forme `@MainActor @Observable`, même raison de conserver le
//  `defaults` injecté pour l'écriture — cf. son en-tête, notamment le bogue
//  de test qu'un `didSet` écrivant en dur vers `.standard` provoquerait).
//
//  `ContentView` observe `shared` et gate l'affichage EN PREMIER, avant la
//  logique storageMode/auth : tant que `completed == false`, `OnboardingView`
//  remplace la coquille — cf. commentaire d'en-tête de `ContentView.swift`.
//

import Foundation
import Observation

@MainActor
@Observable
final class OnboardingStore {
    static let shared = OnboardingStore()

    /// `nonisolated(unsafe)` : constante immuable, jamais mutée après
    /// déclaration — même idiome que `StorageModeStore.key`.
    nonisolated(unsafe) private static let key = "onboarding-completed"

    /// Conservé (comme `StorageModeStore.defaults`) pour que le `defaults`
    /// injecté à l'init serve aussi à l'écriture — sinon une instance
    /// construite avec un `UserDefaults` de test écrirait silencieusement
    /// dans `.standard`.
    private let defaults: UserDefaults

    var completed: Bool {
        didSet {
            defaults.set(completed, forKey: Self.key)
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // `UserDefaults.bool(forKey:)` renvoie `false` quand la clé est
        // absente — exactement le défaut voulu (jamais complété tant que rien
        // n'est persisté), pas besoin d'un flatMap façon `StorageMode`.
        completed = defaults.bool(forKey: Self.key)
    }

    /// Termine l'onboarding (dernière étape du parcours) — plus jamais
    /// réaffiché ensuite, cf. en-tête de fichier.
    func markCompleted() {
        completed = true
    }

    /// Lecture non-UI, au cas où un futur appelant ne tournerait pas sur le
    /// main actor (même idée que `StorageModeStore.current`) — `ContentView`,
    /// lui, lit via `shared` (`@MainActor`), pas ce point d'entrée.
    nonisolated static var completed: Bool {
        UserDefaults.standard.bool(forKey: key)
    }
}
