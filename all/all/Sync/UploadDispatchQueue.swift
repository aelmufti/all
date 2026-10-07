//
//  UploadDispatchQueue.swift
//  all (bridge-connect)
//
//  File d'attente PURE des envois vers Pulse lancés par `GarminSession` — même
//  schéma que `ArchiveRequestTracker` (`Sync/ArchivePlanner.swift`) : une valeur
//  sans E/S, sans BLE ni réseau, testable seule, détenue par la session (une
//  instance par lien : session remplacée = file perdue, les entrées restent
//  `acquired` dans le journal et repartent à la session suivante).
//
//  Trois garanties, qui corrigent le « défaut 6 » (docs/organisateur-de-vie.md,
//  A.2) :
//  - BORNE : au plus `maxConcurrent` envois simultanés ; les suivants attendent
//    ici et partent à mesure que les précédents se terminent (`next`/`finish`).
//    Avant, tous les fichiers en attente étaient lancés d'un coup (un
//    arriéré de plusieurs dizaines de .fit = autant de requêtes parallèles) ;
//  - PAS DE DOUBLE ENVOI : une entrée déjà en file ou en vol pour le MÊME
//    contenu (identité + jeton d'acquisition `acquiredAt`) n'est jamais
//    ré-acceptée — un second manifeste, qui repasse sur toutes les entrées
//    `acquired`, ne la relance donc pas ;
//  - FICHIER RELU = AUTRE CONTENU : un nouvel `acquiredAt` est une clé
//    différente, il repart. S'il attend encore en file, l'ancien contenu (jamais
//    parti) est écarté au profit du nouveau (`enqueue`) ; s'il est déjà en vol,
//    son issue sera ignorée par la garde de jeton de `GarminSession` et le
//    nouveau contenu part à son tour.
//
//  « Retombé » (`isIdle`) inclut les envois EN FILE : c'est ce qui permet à
//  `GarminSession.maybePostDataRefreshIfSettled` de ne poster qu'UN
//  rafraîchissement d'écrans une fois tout parti ET accusé.
//

import Foundation

struct UploadDispatchQueue {
    /// Nombre d'envois simultanés vers Pulse par session. Petite borne fixe :
    /// 2 suffit à recouvrir la latence réseau d'un petit fichier (MONITOR, SLEEP)
    /// pendant qu'une grosse activité part, sans saturer le lien Tailscale ni le
    /// serveur (SQLite mono-écrivain côté Pulse) ni la file de préparation
    /// (hachage sérialisé, cf. `PulseSpoolUploader`). Plus haut n'accélère pas un
    /// arriéré borné par la bande montante, et rouvrirait la rafale du défaut 6.
    static let defaultMaxConcurrent = 2

    /// Un contenu précis d'une entrée : identité + jeton d'acquisition.
    struct Key: Hashable {
        let id: WatchFileID
        let acquiredAt: Date
    }

    let maxConcurrent: Int
    /// En attente d'un créneau, dans l'ordre de départ.
    private(set) var queued: [Key] = []
    /// Partis, issue pas encore reçue.
    private(set) var inFlight: Set<Key> = []

    init(maxConcurrent: Int = UploadDispatchQueue.defaultMaxConcurrent) {
        self.maxConcurrent = max(1, maxConcurrent)
    }

    /// Envois non terminés (en file + en vol) — remplace l'ancien compteur
    /// `outstandingUploads` de `GarminSession`.
    var outstanding: Int { queued.count + inFlight.count }
    var isIdle: Bool { outstanding == 0 }

    /// Entrées `acquired` à pousser, dans un ordre DÉTERMINISTE (acquisition, puis
    /// index — le journal est un dictionnaire, son ordre d'itération ne l'est pas,
    /// et l'ordre de départ doit être reproductible). PURE.
    static func pending(from entries: [SpoolEntry]) -> [SpoolEntry] {
        entries
            .filter { $0.state == .acquired }
            .sorted { ($0.acquiredAt, $0.id.index) < ($1.acquiredAt, $1.id.index) }
    }

    /// Met `entry` en file. `false` (rien ne change) si CE contenu est déjà en
    /// file ou en vol. Un contenu plus ancien de la même entrée encore en file
    /// est remplacé (il n'est jamais parti : inutile de l'envoyer puis de jeter
    /// son issue).
    @discardableResult
    mutating func enqueue(_ entry: SpoolEntry) -> Bool {
        let key = Key(id: entry.id, acquiredAt: entry.acquiredAt)
        guard !inFlight.contains(key), !queued.contains(key) else { return false }
        queued.removeAll { $0.id == key.id }
        queued.append(key)
        return true
    }

    /// Prochain envoi à lancer, ou `nil` si la file est vide ou si la borne est
    /// atteinte. Le retour passe EN VOL : l'appelant doit le lancer (ou, s'il
    /// décide de ne pas l'envoyer, appeler `finish`).
    mutating func next() -> Key? {
        guard inFlight.count < maxConcurrent, !queued.isEmpty else { return nil }
        let key = queued.removeFirst()
        inFlight.insert(key)
        return key
    }

    /// L'envoi `key` est terminé (toute issue) : libère son créneau et l'autorise
    /// à être remis en file (retenté à un prochain manifeste). Sans effet si
    /// inconnu.
    mutating func finish(_ key: Key) {
        inFlight.remove(key)
    }

    /// Fin de session : jette ce qui attend encore (rien n'est parti, l'entrée
    /// reste `acquired` dans le journal) et le rend. Les envois en vol ne sont pas
    /// touchés — leur issue arrivera, et `finish` les libérera.
    @discardableResult
    mutating func cancelQueued() -> [Key] {
        let dropped = queued
        queued = []
        return dropped
    }
}
