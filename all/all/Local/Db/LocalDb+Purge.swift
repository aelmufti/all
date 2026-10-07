//
//  LocalDb+Purge.swift
//  all (bridge-connect)
//
//  Purge des données de l'iPhone (Paramètres › Stockage), côté base locale :
//  lecture des saisies que Pulse n'a pas encore reçues (ce qui BLOQUE la purge) et
//  vidage complet de la base. La décision (quoi compter, quoi effacer côté spool)
//  est PURE et vit dans `Spool/LocalPurgePlanner.swift` ; l'exécution dans
//  `Spool/LocalDataPurge.swift`.
//

import Foundation

extension LocalDb {
    /// Changements du journal des saisies que Pulse n'a pas accusés (`rev` au-delà du
    /// dernier `rev` accusé) — SANS filtre : c'est `LocalPurgePlanner` qui écarte les
    /// aliments de départ. Un aliment est accompagné de l'empreinte de ses valeurs
    /// tant que la ligne existe et n'a pas de code-barres (un aliment scanné n'est
    /// jamais un aliment de départ).
    func pendingSaisies() throws -> [LocalPurgePlanner.PendingSaisie] {
        let acked = try saisieSyncState().ackedRev
        var out: [LocalPurgePlanner.PendingSaisie] = []
        try db.run(
            """
            SELECT c.resource, c.key, c.deleted, f.id, f.barcode, f.name, f.kcal, f.protein, f.carbs, f.fiber, f.fat,
                   f.unit_label, f.unit_grams
            FROM saisie_changes c
            LEFT JOIN foods f ON c.resource = 'food' AND f.uid = c.key
            WHERE c.rev > ?
            """,
            [.int(acked)]) { r in
            guard let resource = r.text(0), let key = r.text(1), let deleted = r.double(2) else { return }
            var signature: LocalPurgePlanner.FoodSignature?
            if resource == "food", r.double(3) != nil, r.text(4) == nil, let name = r.text(5) {
                signature = LocalPurgePlanner.FoodSignature(
                    name: name, kcal: r.double(6), protein: r.double(7), carbs: r.double(8), fiber: r.double(9),
                    fat: r.double(10), unitLabel: r.text(11), unitGrams: r.double(12))
            }
            out.append(LocalPurgePlanner.PendingSaisie(resource: resource, key: key, deleted: deleted != 0, food: signature))
        }
        return out
    }

    /// Vide TOUTES les tables de la base, dans UNE transaction, sans toucher au
    /// fichier (d'autres connexions — ingestion, écrans, échange des saisies — le
    /// tiennent ouvert) :
    ///  - les `DELETE` déclenchent les triggers de saisies, qui journalisent des
    ///    pierres tombales : envoyées au prochain échange, elles SUPPRIMERAIENT les
    ///    saisies sur Pulse. Le journal et l'état d'échange sont donc vidés APRÈS
    ///    les tables de données, dans la même transaction ;
    ///  - les compteurs d'`AUTOINCREMENT` repartent de zéro ;
    ///  - les aliments de départ sont re-semés (ils entrent au journal comme sur une
    ///    base neuve) ; `initialDone` retombe à faux, donc le prochain échange est le
    ///    premier (`initial`, contrat §6).
    /// Les tables sont lues dans `sqlite_master` : une table ajoutée plus tard par
    /// une migration est vidée sans qu'il faille penser à cette fonction.
    /// Ensuite, au mieux : `VACUUM` + checkpoint du WAL pour que la taille affichée
    /// redescende (sans effet si une autre connexion lit à cet instant).
    func purgeAllData() throws {
        let journalTables = ["saisie_changes", "saisie_sync_state"]
        try db.transaction {
            var tables: [String] = []
            try db.run("SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'") { r in
                if let name = r.text(0) { tables.append(name) }
            }
            for table in tables where !journalTables.contains(table) {
                try db.execute("DELETE FROM \"\(table)\"")
            }
            for table in journalTables where tables.contains(table) {
                try db.execute("DELETE FROM \"\(table)\"")
            }
            try db.execute("DELETE FROM sqlite_sequence")
            try insertSeedFoods()
        }
        try? db.execute("VACUUM")
        try? db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    }
}
