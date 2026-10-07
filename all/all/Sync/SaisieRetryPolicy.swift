//
//  SaisieRetryPolicy.swift
//  all (bridge-connect)
//
//  Décision PURE de la reprise automatique de l'échange des saisies
//  (`SaisieSyncService`). Avant : un échange en échec (base occupée par l'ingestion,
//  Pulse injoignable, erreur serveur) n'était retenté que sur un NOUVEL événement
//  (premier plan, lancement, saisie, lecture d'écran) — un utilisateur qui attendait
//  sur un autre écran ne voyait rien repartir.
//
//  Règle : tant que l'app est au premier plan, en mode « Les deux », et qu'il reste
//  quelque chose à échanger (changements locaux non accusés OU premier échange jamais
//  abouti), un échec ou un résultat incomplet programme UNE nouvelle tentative, après
//  un délai croissant (15 s, 30 s, 1 min, 2 min, plafond 4 min).
//
//  Jamais de reprise automatique pour :
//   - un 401 (jeton refusé) : erreur de CONFIGURATION, déjà signalée par
//     `PulseUploadHealth` — la boucler n'y changerait rien ;
//   - l'absence de configuration (adresse ou jeton) : rien à joindre.
//  Les erreurs de transport, 4xx/5xx autres que 401, réponse illisible et pannes de
//  base se retentent (le plafond borne le trafic même pour une erreur durable).
//
//  Aucune horloge ni E/S ici : le service fournit les faits, la minuterie
//  (`WakeTimer`) est injectable — cf. `allTests/SaisieRetryTests.swift`.
//

import Foundation

/// Issue d'UNE passe d'échange, réduite à ce qui décide de la reprise.
enum SaisieSyncPassOutcome: Equatable {
    /// L'échange est allé au bout.
    case succeeded
    /// Adresse de Pulse ou jeton absents.
    case notConfigured
    /// 401.
    case unauthorized
    /// Échec avant ou après la réponse (transport, 4xx/5xx, réponse illisible).
    case networkOrServerFailure
    /// La base locale a échoué (occupée par l'ingestion au-delà du `busy_timeout`, ou
    /// autre erreur SQLite). Seul cas où la fin d'une passe d'ingestion vaut mieux que
    /// le seul minuteur.
    case storageFailure
    /// La passe n'a rien tenté (mode ≠ « Les deux », pas de base).
    case skipped
}

enum SaisieRetryPolicy {
    /// Délais successifs après le 1er, 2e… échec consécutif ; le dernier sert de plafond.
    static let delays: [TimeInterval] = [15, 30, 60, 120, 240]

    /// Délai avant la tentative qui suit le `attempt`-ième échec consécutif (≥ 1).
    static func delay(afterAttempt attempt: Int) -> TimeInterval {
        delays[min(max(attempt, 1), delays.count) - 1]
    }

    enum Decision: Equatable {
        /// Reprise programmée ; `attempt` = nombre de tentatives consécutives sans
        /// aboutissement complet, à mémoriser pour le délai suivant.
        case retry(after: TimeInterval, attempt: Int)
        /// Rien à reprogrammer : compteur remis à zéro, minuterie annulée.
        case stop
    }

    /// - Parameters:
    ///   - attempt: tentatives consécutives déjà comptées (0 après un aboutissement).
    ///   - stillNeeded: reste-t-il des changements locaux à envoyer, ou le premier
    ///     échange n'a-t-il jamais abouti ?
    static func decide(
        outcome: SaisieSyncPassOutcome, foreground: Bool, mode: StorageMode, stillNeeded: Bool, attempt: Int
    ) -> Decision {
        guard foreground, mode == .both else { return .stop }
        switch outcome {
        case .notConfigured, .unauthorized, .skipped:
            return .stop
        case .succeeded, .networkOrServerFailure, .storageFailure:
            // Même règle pour un succès et un échec : tant qu'il reste quelque chose,
            // délai croissant. Le compteur ne retombe qu'avec `.stop` (tout est parti) :
            // un succès qui laisse des changements (écrits pendant l'échange) ne remet
            // pas à 15 s, sans quoi une anomalie durable bouclerait toutes les 15 s.
            guard stillNeeded else { return .stop }
            return .retry(after: delay(afterAttempt: attempt + 1), attempt: attempt + 1)
        }
    }
}
