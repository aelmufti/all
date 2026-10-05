//
//  SyncPlanner.swift
//  all (bridge-connect)
//
//  Traversée/diff PURS du manifeste directory : quels fichiers de contenu
//  restent dus (jamais acquis, OU dont la taille listée a changé depuis
//  l'acquisition), dans quel ordre. Extrait de `GarminSession` en un type sans
//  dépendance à CoreBluetooth (même schéma que `GFDI/FileTransferReassembler.swift`
//  pour la reprise de fragment) afin de rester testable sans `CBPeripheral`/
//  `CommunicatorV2` — cf. `GarminSession.syncNewFiles()`, seul appelant.
//
//  Porté de gadgetbridge/garmin-bridge, AGPL-3.0 —
//  net.garminbridge.session.GarminSession (session/GarminSession.java) :
//  le comparateur `NEWEST_FIRST` (~121) et le filtre « déjà tenu » d'
//  `absorbListing`/`nextStillWanted` (~899-1050). Simplifié à dessein : un seul
//  listing passé en argument (le manifeste déjà reçu, `GarminSession.files`),
//  pas un flux de listings ré-absorbés au fil d'un lien qui peut durer toute
//  une nuit — ce dépôt a pivoté vers une synchro premier-plan, déclenchée à
//  l'ouverture (cf. SESSION-NOTES 2026-09-22, « pivot premier-plan »), donc un
//  seul manifeste par appel de `syncNewFiles()` suffit.
//

import Foundation

enum SyncPlanner {
    /// Statut d'une entrée listée vis-à-vis du journal du Spool.
    enum Retention: Equatable {
        /// Identité (type + index + nom) absente du journal : jamais acquise.
        case new
        /// Journalisée, et rien n'indique que la montre ait écrit depuis
        /// (taille listée identique, ou aucune taille enregistrée — entrée
        /// antérieure à `SpoolEntry.listedSize`, tenue par défaut : pas de
        /// re-téléchargement massif à la mise à jour de l'app).
        case held
        /// Journalisée avec une taille enregistrée DIFFÉRENTE de la taille
        /// actuellement listée : la montre a continué d'écrire dans ce fichier
        /// (HYPOTHÈSE, preuve = le journal `info` de `GarminSession.syncNewFiles`).
        /// Porte l'ancienne taille.
        case resized(recordedSize: Int)
    }

    /// Décision PURE pour une entrée du listing — l'identité reste
    /// `SpoolStore.identity(for:)` (type + index + nom, SANS la taille : la
    /// taille n'est pas dans l'identité, sinon un fichier qui grossit serait
    /// pris pour un nouveau fichier et le journal garderait deux entrées pour
    /// le même fichier montre). Toute progression d'état (`acquired`/
    /// `delivered`/`archived`) vaut « tenu » tant que la taille ne bouge pas.
    static func retention(of entry: GarminDirectoryEntry, journal: [WatchFileID: SpoolEntry]) -> Retention {
        guard let held = journal[SpoolStore.identity(for: entry).id] else { return .new }
        guard let recorded = held.listedSize, recorded != entry.sizeBytes else { return .held }
        return .resized(recordedSize: recorded)
    }

    /// Entrées de contenu candidates, avant tout filtre « déjà tenu » :
    /// - filtre les entrées DIRECTORY (jamais une cible de téléchargement de
    ///   contenu, cf. `GarminDirectoryEntry.isDirectory` — c'est le manifeste
    ///   lui-même, pas un fichier) ;
    /// - ne garde QUE les types que la montre sert sur DOWNLOAD_REQUEST (flag
    ///   `pull` du pont). Sans ça, on demandait aussi les types non-`pull`
    ///   (SETTINGS, SPORTS, DEVICE, GOALS…) que la Venu 2 refuse
    ///   (`downloadStatus=3`), d'où une traversée qui échouait fichier après
    ///   fichier sans rien acquérir. Cf. `GarminDirectoryEntry.isPullable`.
    private static func candidates(from listing: [GarminDirectoryEntry]) -> [GarminDirectoryEntry] {
        listing.filter { !$0.isDirectory && $0.isPullable }
    }

    /// Fichiers dus, triés récent→ancien (`NEWEST_FIRST`) : une entrée listée
    /// est due si elle est absente du journal (`.new`) OU si elle y figure avec
    /// une taille enregistrée différente de la taille listée (`.resized`) — la
    /// montre a écrit depuis, le contenu du spool est périmé. Une entrée sans
    /// taille enregistrée est tenue. Pur : la file est figée par appel, donc un
    /// fichier dont la taille ne se stabilise jamais est relu AU PLUS UNE FOIS
    /// par manifeste reçu (la taille enregistrée à l'acquisition est celle du
    /// manifeste, pas celle du fichier reçu).
    static func filesDue(from listing: [GarminDirectoryEntry], journal: [WatchFileID: SpoolEntry]) -> [GarminDirectoryEntry] {
        candidates(from: listing)
            .filter { retention(of: $0, journal: journal) != .held }
            .sorted(by: isNewerFirst)
    }

    /// Sous-ensemble de `filesDue(from:journal:)` dû à un CHANGEMENT DE TAILLE
    /// (et non à une première acquisition), avec l'ancienne taille — pour que
    /// l'appelant journalise chaque re-téléchargement de ce type (la preuve de
    /// l'hypothèse « la montre continue d'écrire dans un fichier déjà lu »).
    static func resizedSinceAcquisition(from listing: [GarminDirectoryEntry], journal: [WatchFileID: SpoolEntry]) -> [(entry: GarminDirectoryEntry, recordedSize: Int)] {
        candidates(from: listing).sorted(by: isNewerFirst).compactMap { entry in
            if case .resized(let recorded) = retention(of: entry, journal: journal) { return (entry, recorded) }
            return nil
        }
    }

    /// Variante historique, sans tailles : « déjà tenu » = identité présente
    /// dans `alreadyAcquired`, quel que soit son état (`acquired`/`delivered`/
    /// `archived`, comme `AcquiredFiles.holds` côté pont, qui ne distingue pas
    /// non plus) — équivalent pur de `SpoolStore.pendingAcquisition(from:)`.
    /// Ne détecte PAS un fichier qui a grossi ; `GarminSession` utilise
    /// `filesDue(from:journal:)`.
    static func filesDue(from listing: [GarminDirectoryEntry], alreadyAcquired: Set<WatchFileID>) -> [GarminDirectoryEntry] {
        candidates(from: listing)
            .filter { !alreadyAcquired.contains(SpoolStore.identity(for: $0).id) }
            .sorted(by: isNewerFirst)
    }

    /// `NEWEST_FIRST` côté pont : date décroissante, les entrées sans date
    /// (sentinelle horodatage=0, cf. `GarminDirectoryEntry.date`) passant en
    /// dernier (`nullsLast`) ; à date égale (y compris deux entrées sans date),
    /// index de fichier décroissant (`thenComparing(getFileIndex, reverseOrder())`)
    /// — un simple bris d'égalité déterministe, l'index n'a pas de sens métier.
    private static func isNewerFirst(_ a: GarminDirectoryEntry, _ b: GarminDirectoryEntry) -> Bool {
        if a.date != b.date {
            guard let dateA = a.date else { return false } // a sans date -> après b
            guard let dateB = b.date else { return true }  // b sans date -> a avant b
            return dateA > dateB
        }
        return a.fileIndex > b.fileIndex
    }
}
