//
//  SyncActivity.swift
//  all (bridge-connect)
//
//  Résumé d'activité de synchro pour la bannière globale
//  (`SyncStatusBanner.swift`, posée dans `PulseShellView`) — une projection
//  pure de l'état déjà publié par `BLEManager`/`GarminSession`
//  (`BLEConnectionState`, `GarminHandshakeState`, `GarminSyncState`), sans
//  dupliquer leur logique métier ni ajouter de nouvel état source de vérité.
//
//  Le mapping vit dans une fonction statique pure (`from`), volontairement
//  indépendante de `BLEManager`/`GarminSession` eux-mêmes (juste leurs enums
//  publiés) — testable sans CoreBluetooth, cf. `allTests/SyncActivityTests.swift`.
//  `BLEManager.syncActivity` ne fait que l'appeler avec son état courant.
//
//  Le travail du TÉLÉPHONE (envoi vers Pulse, ingestion locale, échange des saisies)
//  vient d'un autre état, `Sync/SyncWork.swift` : `fromWork` le projette de la même
//  façon, `resolve` l'assemble avec la synchro montre.
//

import Foundation

/// Résumé de l'activité de synchro en cours, pour affichage global (bannière
/// visible sur tous les écrans natifs). Ordre de priorité du mapping (`from`) :
/// un téléchargement de fichier en cours prime sur un listing en cours, qui
/// prime lui-même sur une simple connexion — cas normalement disjoints dans le
/// déroulé réel de `GarminSession` (le listing est terminé, `state == .listed`,
/// avant que `syncState` ne passe à `.downloading`), mais l'ordre reste
/// explicite pour rester correct même si un futur changement les faisait
/// se chevaucher.
enum SyncActivity: Equatable {
    case idle
    case connecting
    case listing
    case downloading(done: Int)
    // Travail du téléphone hors lien montre — décidé par `fromWork` (état de
    // `Sync/SyncWork.swift`), jamais par `from`.
    /// Envoi de `.fit` vers Pulse ; `remaining` = envois en file ou en vol.
    case uploading(remaining: Int)
    /// Rapatriement des `.fit` depuis Pulse ; `remaining` = fichiers restant à récupérer,
    /// `nil` tant que le manifeste est en lecture.
    case pulling(remaining: Int?)
    /// Ingestion locale ; `remaining` = entrées restant à traiter dans la passe,
    /// `nil` si le décompte n'est pas fiable (étape sans progression).
    case ingesting(remaining: Int?)
    /// Échange des saisies avec Pulse.
    case exchanging

    /// Libellé court de la bannière.
    var label: String {
        switch self {
        case .idle:
            return ""
        case .connecting:
            return "Connexion à la montre…"
        case .listing:
            return "Lecture de la montre…"
        case .downloading(let done):
            return done == 1
                ? "Synchronisation… (1 fichier)"
                : "Synchronisation… (\(done) fichiers)"
        case .uploading(let remaining):
            return Self.counted("Envoi vers Pulse", remaining)
        case .pulling(let remaining):
            return Self.counted("Récupération depuis Pulse", remaining ?? 0)
        case .ingesting(let remaining):
            return Self.counted("Mise à jour de la base", remaining ?? 0)
        case .exchanging:
            return "Échange des saisies"
        }
    }

    /// « Titre · N restants » ; sans nombre quand il n'y a rien de fiable à dire (≤ 0).
    private static func counted(_ title: String, _ remaining: Int) -> String {
        guard remaining > 0 else { return title }
        return remaining == 1 ? "\(title) · 1 restant" : "\(title) · \(remaining) restants"
    }

    // MARK: - Travail du téléphone (envoi, ingestion, saisies)

    /// Décision PURE du travail à montrer, à partir de l'état brut de `SyncWork` et du
    /// mode Stockage. Priorité : envoi > récupération > ingestion > échange. Une seule ligne, courte :
    /// les combiner (« Envoi · Base · Saisies ») ne tiendrait pas dans une capsule sur
    /// un petit écran, et chaque activité retombe à son tour, donc la suivante
    /// s'affiche ensuite. L'envoi vient en tête parce que c'est le seul à porter un
    /// décompte parlant pour l'utilisateur et le plus long en pratique (réseau).
    ///
    /// Le mode filtre ce qui n'a pas lieu d'être : en Téléphone rien ne part vers
    /// Pulse (ni envoi, ni échange) ; en Pulse il n'y a pas de base locale à alimenter ;
    /// l'échange des saisies et la récupération des fichiers de Pulse n'existent qu'en
    /// « Les deux ». La récupération passe avant l'ingestion : c'est elle qui dure.
    static func fromWork(_ work: SyncWorkSnapshot, mode: StorageMode) -> SyncActivity {
        if mode != .phone, work.uploads > 0 {
            return .uploading(remaining: work.uploads)
        }
        if mode == .both, work.pullRunning {
            return .pulling(remaining: work.pullRemaining)
        }
        if mode != .pulse, work.ingestRunning {
            return .ingesting(remaining: work.ingestRemaining)
        }
        if mode == .both, work.exchangeRunning {
            return .exchanging
        }
        return .idle
    }

    /// Ce que la bannière affiche : la synchro MONTRE existante garde la priorité
    /// (connexion, listing, téléchargement), le travail du téléphone ne passe qu'une
    /// fois le lien calme.
    static func resolve(watch: SyncActivity, work: SyncActivity) -> SyncActivity {
        watch != .idle ? watch : work
    }

    /// Mapping pur des états bruts vers un résumé unique.
    ///
    /// - Parameters:
    ///   - connection: `BLEManager.connectionState`.
    ///   - handshake: `GarminSession.state`, `nil` si aucune session GFDI
    ///     n'existe encore sur ce lien (repli générique de l'incrément 1, ou
    ///     pas de lien du tout).
    ///   - sync: `GarminSession.syncState`, `nil` dans les mêmes conditions.
    ///   - deliveredCount: `GarminSession.deliveredFileIndexes.count` —
    ///     fichiers déjà livrés à Pulse durant la traversée en cours.
    static func from(
        connection: BLEConnectionState,
        handshake: GarminHandshakeState?,
        sync: GarminSyncState?,
        deliveredCount: Int
    ) -> SyncActivity {
        if case .downloading = sync {
            return .downloading(done: deliveredCount)
        }
        if case .listingDirectory = handshake {
            return .listing
        }
        switch handshake {
        case .gfdiChannelOpen, .initialized:
            return .connecting
        default:
            break // .idle / .listed / .failed / nil : pas de raison GFDI de se dire "connecting"
        }
        switch connection {
        case .scanning, .connecting, .reconnecting:
            // `.reconnecting` : lien présumé mais pas encore prouvé exploitable
            // (cf. `BLEManager.isLinkProvenLive`) — toujours "en train de se
            // connecter" du point de vue utilisateur, même texte que `.connecting`.
            return .connecting
        case .disconnected, .connected:
            return .idle
        }
    }
}
