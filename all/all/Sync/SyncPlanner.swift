//
//  SyncPlanner.swift
//  all (bridge-connect)
//
//  Traversée/diff PURS du manifeste directory : quels fichiers de contenu
//  restent dus, dans quel ordre. Extrait de `GarminSession` en un type sans
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
    /// Fichiers dus, triés récent→ancien (`NEWEST_FIRST`) :
    /// - filtre les entrées DIRECTORY (jamais une cible de téléchargement de
    ///   contenu, cf. `GarminDirectoryEntry.isDirectory` — c'est le manifeste
    ///   lui-même, pas un fichier) ;
    /// - filtre celles déjà journalisées dans le Spool, quel que soit leur état
    ///   (`acquired`/`delivered`/`archived` valent tous « déjà tenu », comme
    ///   `AcquiredFiles.holds` côté pont, qui ne distingue pas non plus) —
    ///   équivalent pur de `SpoolStore.pendingAcquisition(from:)`, mais opérant
    ///   sur les entrées complètes plutôt que sur leurs seules identités, pour
    ///   pouvoir ensuite trier par date/index.
    static func filesDue(from listing: [GarminDirectoryEntry], alreadyAcquired: Set<WatchFileID>) -> [GarminDirectoryEntry] {
        listing
            .filter { !$0.isDirectory }
            // Ne mettre en file QUE les types que la montre sert sur DOWNLOAD_REQUEST
            // (flag `pull` du pont). Sans ça, on demandait aussi les types non-`pull`
            // (SETTINGS, SPORTS, DEVICE, GOALS…) que la Venu 2 refuse
            // (`downloadStatus=3`), d'où une traversée qui échouait fichier après
            // fichier sans rien acquérir. Cf. `GarminDirectoryEntry.isPullable`.
            .filter { $0.isPullable }
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
