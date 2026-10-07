//
//  LocalDb+Saisies.swift
//  all (bridge-connect)
//
//  Journal de changements des SAISIES (nutrition, poids, profil, réveil,
//  programme) et accès SQL de l'échange avec Pulse (`Sync/SaisieSync.swift`).
//  Référence : `custom-connect/docs/pulse-saisies-sync-contract.md` (§2 ressources,
//  §3 journal, §4/§5 application) — le contrat prime sur ce fichier.
//
//  Trois parties :
//   1. la MIGRATION (`saisieSyncMigration`) : colonnes `uid`, table
//      `saisie_changes`, triggers, entrée au journal des lignes existantes ;
//   2. la COLLECTE des changements locaux depuis le dernier `rev` accusé
//      (`collectSaisieChanges`) ;
//   3. l'APPLICATION d'une réponse du serveur (`applySaisieResponse`), en une
//      transaction, avec la mémorisation du `cursor`/`rev` accusé.
//
//  État d'échange (`cursor` serveur, `rev` accusé, `initialDone`) : table DÉDIÉE
//  `saisie_sync_state`, pas la table `settings`. `settings` est une ressource
//  synchronisée (liste blanche) et porte, côté serveur, des secrets ; y glisser
//  des curseurs obligerait à une exception de plus dans les triggers et exposerait
//  l'état à la route `profile`. Une table à part s'écrit dans la MÊME transaction
//  que l'application de la réponse (curseur jamais en avance sur les données).
//

import Foundation

// MARK: - JSON des `data` du contrat

/// JSON minimal pour le champ `data` des changements (les formes varient par
/// ressource). Distingue entier et flottant : `ts`/`week`/`updatedAt` ne doivent
/// jamais sortir en `72.0`.
enum SaisieJSON: Equatable, Codable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([SaisieJSON])
    case object([String: SaisieJSON])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Int.self) { self = .int(v) }
        else if let v = try? c.decode(Double.self) { self = .double(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([SaisieJSON].self) { self = .array(v) }
        else { self = .object(try c.decode([String: SaisieJSON].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .int(let v): try c.encode(v)
        case .double(let v): try c.encode(v.isFinite ? v : nil)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }

    var stringValue: String? { if case .string(let s) = self { return s } else { return nil } }
    var doubleValue: Double? {
        switch self {
        case .int(let v): return Double(v)
        case .double(let v): return v
        default: return nil
        }
    }
    var intValue: Int? {
        switch self {
        case .int(let v): return v
        case .double(let v): return v == v.rounded() && abs(v) < 1e15 ? Int(v) : nil
        default: return nil
        }
    }
    /// Booléen JSON, ou 0/1 (le contrat ne fixe pas la forme de `active`).
    var boolValue: Bool? {
        switch self {
        case .bool(let v): return v
        case .int(let v) where v == 0 || v == 1: return v == 1
        default: return nil
        }
    }

    static func opt(_ s: String?) -> SaisieJSON { s.map(SaisieJSON.string) ?? .null }
    static func opt(_ d: Double?) -> SaisieJSON { d.map(SaisieJSON.double) ?? .null }
    static func optInt(_ d: Double?) -> SaisieJSON { d.map { SaisieJSON.int(Int($0)) } ?? .null }
}

/// Un changement du contrat §4 (même forme dans la requête et la réponse).
struct SaisieChange: Equatable, Codable {
    var resource: String
    var key: String
    var updatedAt: Int
    var deleted: Bool
    /// Absent si `deleted`.
    var data: [String: SaisieJSON]?
}

// MARK: - Migration (contrat §3)

extension LocalDb {
    /// Ressources, dans l'ordre d'application du contrat §4.
    static let saisieResources = ["food", "foodLog", "weight", "setting", "programme", "programmeDone"]

    /// Liste blanche STRICTE des réglages journalisés (contrat §2) : `settings`
    /// contient d'autres clés (secrets, source de synchro…) qui ne sortent jamais.
    static let saisieSettingKeys: [String] = ["birthYear", "sex", "weightKg", "heightCm", "wakeSchedule"]

    /// `epoch` millisecondes « maintenant », en SQL (`julianday` plutôt que
    /// `unixepoch('subsec')`, absent des SQLite plus anciens).
    private static let sqlNowMs = "CAST(ROUND((julianday('now') - 2440587.5) * 86400000.0) AS INTEGER)"

    /// Corps d'un trigger : upsert dans le journal (`rev = MAX + 1`). `ON CONFLICT DO
    /// UPDATE` et NON `INSERT OR REPLACE` : dans un trigger, la politique de conflit
    /// de l'instruction EXTÉRIEURE (ici l'`ON CONFLICT DO UPDATE` des écritures de
    /// poids/séances) écrase un `OR REPLACE` interne, qui échouait alors sur la clé.
    private static func journalSQL(_ resource: String, key: String, deleted: String) -> String {
        """
        INSERT INTO saisie_changes (resource, key, updated_at, deleted, rev)
        VALUES ('\(resource)', \(key), \(sqlNowMs), \(deleted), (SELECT COALESCE(MAX(rev), 0) + 1 FROM saisie_changes))
        ON CONFLICT(resource, key) DO UPDATE SET updated_at = excluded.updated_at, deleted = excluded.deleted, rev = excluded.rev;
        """
    }

    private static func trigger(
        _ name: String, _ event: String, on table: String, when: String, _ resource: String, key: String, deleted: String
    ) -> String {
        """
        CREATE TRIGGER \(name) AFTER \(event) ON \(table) WHEN \(when) BEGIN
        \(journalSQL(resource, key: key, deleted: deleted))
        END;
        """
    }

    /// Migration unique (une transaction, `LocalDb.migrate`). `sqlite3_exec` traite
    /// plusieurs instructions, triggers compris. Ordre voulu : colonnes → `uid` des
    /// lignes existantes → journal → entrée des lignes existantes → triggers (créés
    /// APRÈS le remplissage, sinon ils journaliseraient deux fois).
    static var saisieSyncMigration: String {
        let uid = "lower(hex(randomblob(16)))"
        let settingsList = saisieSettingKeys.map { "'\($0)'" }.joined(separator: ", ")
        let insideList = { (column: String) in "\(column) IN (\(settingsList))" }
        let planParent = { (id: String) in "EXISTS (SELECT 1 FROM programme_state WHERE programme_id = \(id))" }
        let doneKey = { (row: String) in "\(row).programme_id || '|' || \(row).week || '|' || \(row).session" }

        // Entrée au journal d'une table existante : `rev` distincts (ROW_NUMBER),
        // sinon le découpage en lots pourrait scinder des `rev` égaux.
        func backfill(_ resource: String, key: String, updated: String, from table: String, order: String, whereClause: String = "1") -> String {
            """
            INSERT OR REPLACE INTO saisie_changes (resource, key, updated_at, deleted, rev)
            SELECT '\(resource)', \(key), \(updated), 0,
                   (SELECT COALESCE(MAX(rev), 0) FROM saisie_changes) + ROW_NUMBER() OVER (ORDER BY \(order))
            FROM \(table) WHERE \(whereClause);
            """
        }
        let fromCreatedAt = "COALESCE(CAST(strftime('%s', created_at) AS INTEGER) * 1000, 0)"

        return [
            // 1. Colonnes `uid` (UNIQUE ne s'ajoute pas par ALTER : index unique).
            "ALTER TABLE foods ADD COLUMN uid TEXT;",
            "ALTER TABLE food_log ADD COLUMN uid TEXT;",
            "UPDATE foods SET uid = \(uid) WHERE uid IS NULL;",
            "UPDATE food_log SET uid = \(uid) WHERE uid IS NULL;",
            "CREATE UNIQUE INDEX idx_foods_uid ON foods(uid);",
            "CREATE UNIQUE INDEX idx_food_log_uid ON food_log(uid);",
            // 2. Journal (contrat §3) + état d'échange propre à ce côté.
            """
            CREATE TABLE saisie_changes (
              resource   TEXT NOT NULL,
              key        TEXT NOT NULL,
              updated_at INTEGER NOT NULL,
              deleted    INTEGER NOT NULL DEFAULT 0,
              rev        INTEGER NOT NULL,
              PRIMARY KEY (resource, key)
            ) WITHOUT ROWID;
            """,
            "CREATE INDEX saisie_changes_rev ON saisie_changes(rev);",
            "CREATE TABLE saisie_sync_state (key TEXT PRIMARY KEY, value INTEGER NOT NULL) WITHOUT ROWID;",
            // 3. Lignes existantes → journal (`updated_at` dérivé de `created_at`
            //    quand la table en a un, sinon 0).
            backfill("food", key: "uid", updated: fromCreatedAt, from: "foods", order: "id"),
            backfill("foodLog", key: "uid", updated: fromCreatedAt, from: "food_log", order: "id"),
            backfill("weight", key: "date", updated: fromCreatedAt, from: "weight_log", order: "date"),
            backfill("setting", key: "key", updated: "0", from: "settings", order: "key", whereClause: insideList("key")),
            backfill("programme", key: "programme_id", updated: "0", from: "programme_state", order: "programme_id"),
            backfill("programmeDone", key: "programme_id || '|' || week || '|' || session", updated: "0",
                     from: "programme_done", order: "programme_id, week, session"),
            // 4. Triggers. `uid` attribuée à l'insertion si nulle (l'UPDATE qui la
            //    pose déclenche le trigger d'update, qui journalise : une seule fois).
            "CREATE TRIGGER saisie_foods_uid AFTER INSERT ON foods WHEN NEW.uid IS NULL BEGIN UPDATE foods SET uid = \(uid) WHERE id = NEW.id; END;",
            trigger("saisie_foods_ai", "INSERT", on: "foods", when: "NEW.uid IS NOT NULL", "food", key: "NEW.uid", deleted: "0"),
            trigger("saisie_foods_au", "UPDATE", on: "foods", when: "NEW.uid IS NOT NULL", "food", key: "NEW.uid", deleted: "0"),
            trigger("saisie_foods_ad", "DELETE", on: "foods", when: "OLD.uid IS NOT NULL", "food", key: "OLD.uid", deleted: "1"),
            "CREATE TRIGGER saisie_food_log_uid AFTER INSERT ON food_log WHEN NEW.uid IS NULL BEGIN UPDATE food_log SET uid = \(uid) WHERE id = NEW.id; END;",
            trigger("saisie_food_log_ai", "INSERT", on: "food_log", when: "NEW.uid IS NOT NULL", "foodLog", key: "NEW.uid", deleted: "0"),
            trigger("saisie_food_log_au", "UPDATE", on: "food_log", when: "NEW.uid IS NOT NULL", "foodLog", key: "NEW.uid", deleted: "0"),
            trigger("saisie_food_log_ad", "DELETE", on: "food_log", when: "OLD.uid IS NOT NULL", "foodLog", key: "OLD.uid", deleted: "1"),
            trigger("saisie_weight_ai", "INSERT", on: "weight_log", when: "1", "weight", key: "NEW.date", deleted: "0"),
            trigger("saisie_weight_au", "UPDATE", on: "weight_log", when: "1", "weight", key: "NEW.date", deleted: "0"),
            trigger("saisie_weight_ad", "DELETE", on: "weight_log", when: "1", "weight", key: "OLD.date", deleted: "1"),
            trigger("saisie_settings_ai", "INSERT", on: "settings", when: insideList("NEW.key"), "setting", key: "NEW.key", deleted: "0"),
            trigger("saisie_settings_au", "UPDATE", on: "settings", when: insideList("NEW.key"), "setting", key: "NEW.key", deleted: "0"),
            trigger("saisie_settings_ad", "DELETE", on: "settings", when: insideList("OLD.key"), "setting", key: "OLD.key", deleted: "1"),
            trigger("saisie_programme_ai", "INSERT", on: "programme_state", when: "1", "programme", key: "NEW.programme_id", deleted: "0"),
            trigger("saisie_programme_au", "UPDATE", on: "programme_state", when: "1", "programme", key: "NEW.programme_id", deleted: "0"),
            trigger("saisie_programme_ad", "DELETE", on: "programme_state", when: "1", "programme", key: "OLD.programme_id", deleted: "1"),
            // Le plan voyage avec l'état : une modification du plan marque le
            // `programme` parent (jamais une pierre tombale — si le parent est
            // supprimé, son propre trigger l'a déjà posée, d'où la garde).
            trigger("saisie_plan_ai", "INSERT", on: "programme_plan", when: planParent("NEW.programme_id"), "programme", key: "NEW.programme_id", deleted: "0"),
            trigger("saisie_plan_au", "UPDATE", on: "programme_plan", when: planParent("NEW.programme_id"), "programme", key: "NEW.programme_id", deleted: "0"),
            trigger("saisie_plan_ad", "DELETE", on: "programme_plan", when: planParent("OLD.programme_id"), "programme", key: "OLD.programme_id", deleted: "0"),
            trigger("saisie_done_ai", "INSERT", on: "programme_done", when: "1", "programmeDone", key: doneKey("NEW"), deleted: "0"),
            trigger("saisie_done_au", "UPDATE", on: "programme_done", when: "1", "programmeDone", key: doneKey("NEW"), deleted: "0"),
            trigger("saisie_done_ad", "DELETE", on: "programme_done", when: "1", "programmeDone", key: doneKey("OLD"), deleted: "1"),
        ].joined(separator: "\n")
    }
}

// MARK: - État d'échange et collecte

extension LocalDb {
    struct SaisieSyncState: Equatable {
        /// Dernier `cursor` serveur appliqué (`since` de la prochaine requête).
        var cursor = 0
        /// Plus grand `rev` local dont l'envoi est accusé.
        var ackedRev = 0
        /// Faux tant qu'aucun échange n'est allé jusqu'au bout (contrat §6).
        var initialDone = false
    }

    func saisieSyncState() throws -> SaisieSyncState {
        var state = SaisieSyncState()
        try db.run("SELECT key, value FROM saisie_sync_state") { r in
            guard let key = r.text(0), let value = r.double(1) else { return }
            switch key {
            case "cursor": state.cursor = Int(value)
            case "ackedRev": state.ackedRev = Int(value)
            case "initialDone": state.initialDone = value != 0
            default: break
            }
        }
        return state
    }

    /// Reste-t-il des changements locaux non envoyés ? (§7 : routage en lecture.)
    func hasPendingSaisieChanges() throws -> Bool {
        let acked = try saisieSyncState().ackedRev
        var found = false
        try db.run("SELECT 1 FROM saisie_changes WHERE rev > ? LIMIT 1", [.int(acked)]) { _ in found = true }
        return found
    }

    struct SaisieBatch {
        var changes: [SaisieChange]
        /// `rev` le plus élevé examiné (envoyé ou non, une ligne disparue compte) ;
        /// `nil` si le lot est vide.
        var maxRev: Int?
        /// Il reste des changements au-delà de ce lot.
        var hasMore: Bool
    }

    /// Changements locaux de `rev > afterRev`, par `rev` croissant, `limit` au plus.
    func collectSaisieChanges(afterRev: Int, limit: Int) throws -> SaisieBatch {
        struct Row { let resource: String; let key: String; let updatedAt: Int; let deleted: Bool; let rev: Int }
        var rows: [Row] = []
        try db.run(
            "SELECT resource, key, updated_at, deleted, rev FROM saisie_changes WHERE rev > ? ORDER BY rev ASC LIMIT ?",
            [.int(afterRev), .int(limit + 1)]) { r in
            guard let resource = r.text(0), let key = r.text(1), let updatedAt = r.double(2),
                  let deleted = r.double(3), let rev = r.double(4) else { return }
            rows.append(Row(resource: resource, key: key, updatedAt: Int(updatedAt), deleted: deleted != 0, rev: Int(rev)))
        }
        let hasMore = rows.count > limit
        let batch = Array(rows.prefix(limit))
        var changes: [SaisieChange] = []
        for row in batch where Self.saisieResources.contains(row.resource) {
            if row.deleted {
                changes.append(SaisieChange(resource: row.resource, key: row.key, updatedAt: row.updatedAt, deleted: true, data: nil))
            } else if let data = try saisieData(resource: row.resource, key: row.key) {
                changes.append(SaisieChange(resource: row.resource, key: row.key, updatedAt: row.updatedAt, deleted: false, data: data))
            }
            // Journal « vivant » mais ligne absente : rien à envoyer (ne devrait pas
            // arriver, les triggers couvrent tous les chemins d'écriture).
        }
        return SaisieBatch(changes: changes, maxRev: batch.last?.rev, hasMore: hasMore)
    }

    /// Sérialise la ligne telle que STOCKÉE (§2), jamais le corps de la requête
    /// d'origine. `nil` si la ligne n'existe plus.
    private func saisieData(resource: String, key: String) throws -> [String: SaisieJSON]? {
        var out: [String: SaisieJSON]?
        switch resource {
        case "food":
            try db.run(
                "SELECT barcode, name, kcal, protein, carbs, fiber, fat, unit_label, unit_grams FROM foods WHERE uid = ?",
                [.text(key)]) { r in
                out = [
                    "barcode": .opt(r.text(0)), "name": .string(r.text(1) ?? ""),
                    "kcal": .opt(r.double(2)), "protein": .opt(r.double(3)), "carbs": .opt(r.double(4)),
                    "fiber": .opt(r.double(5)), "fat": .opt(r.double(6)),
                    "unitLabel": .opt(r.text(7)), "unitGrams": .opt(r.double(8)),
                ]
            }
        case "foodLog":
            try db.run(
                """
                SELECT date, (SELECT uid FROM foods WHERE foods.id = food_log.food_id), name, grams,
                       kcal, protein, carbs, fiber, fat, unit_label, unit_qty, ts
                FROM food_log WHERE uid = ?
                """,
                [.text(key)]) { r in
                out = [
                    "date": .string(r.text(0) ?? ""), "foodUid": .opt(r.text(1)), "name": .string(r.text(2) ?? ""),
                    "grams": .opt(r.double(3)), "kcal": .opt(r.double(4)), "protein": .opt(r.double(5)),
                    "carbs": .opt(r.double(6)), "fiber": .opt(r.double(7)), "fat": .opt(r.double(8)),
                    "unitLabel": .opt(r.text(9)), "unitQty": .opt(r.double(10)), "ts": .optInt(r.double(11)),
                ]
            }
        case "weight":
            try db.run("SELECT kg FROM weight_log WHERE date = ?", [.text(key)]) { r in
                out = ["kg": .opt(r.double(0))]
            }
        case "setting":
            try db.run("SELECT value FROM settings WHERE key = ?", [.text(key)]) { r in
                out = ["value": .string(r.text(0) ?? "")]
            }
        case "programme":
            try db.run("SELECT kind, started_on, active, days FROM programme_state WHERE programme_id = ?", [.text(key)]) { r in
                out = [
                    "kind": .string(r.text(0) ?? "nutrition"), "startedOn": .string(r.text(1) ?? ""),
                    "active": .bool((r.double(2) ?? 0) != 0), "days": .opt(r.text(3)),
                ]
            }
            if out != nil {
                var plan: [SaisieJSON] = []
                try db.run(
                    "SELECT week, session, date FROM programme_plan WHERE programme_id = ? ORDER BY week, session",
                    [.text(key)]) { r in
                    plan.append(.object([
                        "week": .int(Int(r.double(0) ?? 0)), "session": .string(r.text(1) ?? ""), "date": .string(r.text(2) ?? ""),
                    ]))
                }
                out?["plan"] = .array(plan)
            }
        case "programmeDone":
            guard let (id, week, session) = Self.splitDoneKey(key) else { return nil }
            try db.run(
                """
                SELECT date, (SELECT file_hash FROM activities WHERE activities.id = programme_done.activity_id)
                FROM programme_done WHERE programme_id = ? AND week = ? AND session = ?
                """,
                [.text(id), .int(week), .text(session)]) { r in
                out = ["date": .string(r.text(0) ?? ""), "activityFileHash": .opt(r.text(1))]
            }
        default:
            return nil
        }
        return out
    }

    /// `programme_id|week|session` (§2). Le premier et le deuxième `|` découpent ;
    /// le reste est la séance.
    static func splitDoneKey(_ key: String) -> (String, Int, String)? {
        let parts = key.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, !parts[0].isEmpty, let week = Int(parts[1]), !parts[2].isEmpty else { return nil }
        return (String(parts[0]), week, String(parts[2]))
    }
}

// MARK: - Application d'une réponse (contrat §4, §5)

extension LocalDb {
    struct SaisieApplyResult: Equatable {
        var applied = 0
        var skipped = 0
        /// Un poids (`weight`) ou le réglage `weightKg` a changé : resynchroniser
        /// le poids du profil (§5).
        var weightChanged = false
        /// `settings.wakeSchedule` a changé : le cache de `WakeScheduleStore` est
        /// à rafraîchir.
        var wakeScheduleChanged = false

        mutating func add(_ other: SaisieApplyResult) {
            applied += other.applied
            skipped += other.skipped
            weightChanged = weightChanged || other.weightChanged
            wakeScheduleChanged = wakeScheduleChanged || other.wakeScheduleChanged
        }
    }

    /// Ligne refusée par validation (comptée dans `skipped`, ne fait pas échouer
    /// l'échange — §5).
    private struct SaisieSkip: Error {}

    /// Applique les `changes` d'une réponse puis mémorise `cursor`/`rev` accusé,
    /// dans UNE transaction : en cas d'échec rien n'est écrit, ni donnée ni curseur.
    ///
    /// - `sentMaxRev` : plus grand `rev` du lot envoyé (`nil` si lot vide).
    /// - `markInitialDone` : dernier lot de l'échange.
    ///
    /// `rev` accusé : si aucun changement local n'est arrivé entre l'envoi et
    /// l'application (aucun `rev` dans `]sentMaxRev, avant application]`), on
    /// avance jusqu'au `rev` d'APRÈS application — les lignes que ce même échange
    /// vient d'écrire ne repartiront pas en écho. Sinon on s'arrête à `sentMaxRev`
    /// (le changement survenu pendant l'échange doit partir au prochain).
    func applySaisieResponse(
        cursor: Int, changes: [SaisieChange], sentMaxRev: Int?, markInitialDone: Bool
    ) throws -> SaisieApplyResult {
        var result = SaisieApplyResult()
        try db.transaction {
            let state = try saisieSyncState()
            let sent = sentMaxRev ?? state.ackedRev
            let before = try maxSaisieRev()

            let ordered = changes.enumerated().sorted { a, b in
                let ia = Self.saisieResources.firstIndex(of: a.element.resource) ?? Int.max
                let ib = Self.saisieResources.firstIndex(of: b.element.resource) ?? Int.max
                return ia != ib ? ia < ib : a.offset < b.offset
            }.map(\.element)

            for change in ordered {
                try db.execute("SAVEPOINT saisie_change")
                do {
                    var one = SaisieApplyResult()
                    if try applyOne(change, into: &one) {
                        one.applied = 1
                    } else {
                        one.skipped = 1
                    }
                    try db.execute("RELEASE saisie_change")
                    result.add(one)
                } catch is SaisieSkip {
                    try db.execute("ROLLBACK TO saisie_change")
                    try db.execute("RELEASE saisie_change")
                    result.skipped += 1
                } catch let error as SQLiteDatabase.SQLiteError where Self.isConstraintFailure(error) {
                    // Contrainte d'intégrité d'UNE ligne (ex. code-barres déjà porté
                    // par un autre aliment) : ligne ignorée, l'échange continue.
                    try db.execute("ROLLBACK TO saisie_change")
                    try db.execute("RELEASE saisie_change")
                    result.skipped += 1
                }
            }

            let after = try maxSaisieRev()
            var unsent = 0
            try db.run(
                "SELECT COUNT(*) FROM saisie_changes WHERE rev > ? AND rev <= ?",
                [.int(sent), .int(before)]) { r in unsent = Int(r.double(0) ?? 0) }
            let acked = max(state.ackedRev, unsent == 0 ? after : sent)

            try setSaisieState("cursor", cursor)
            try setSaisieState("ackedRev", acked)
            if markInitialDone { try setSaisieState("initialDone", 1) }
        }
        return result
    }

    private static func isConstraintFailure(_ error: SQLiteDatabase.SQLiteError) -> Bool {
        guard case .step(let message) = error else { return false }
        return message.localizedCaseInsensitiveContains("constraint")
    }

    private func maxSaisieRev() throws -> Int {
        var rev = 0
        try db.run("SELECT COALESCE(MAX(rev), 0) FROM saisie_changes") { r in rev = Int(r.double(0) ?? 0) }
        return rev
    }

    private func setSaisieState(_ key: String, _ value: Int) throws {
        try db.run(
            "INSERT INTO saisie_sync_state (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            [.text(key), .int(value)])
    }

    /// `true` si appliqué, `false` si ignoré (plus ancien, égal, inconnu à supprimer…).
    private func applyOne(_ change: SaisieChange, into result: inout SaisieApplyResult) throws -> Bool {
        guard Self.saisieResources.contains(change.resource), !change.key.isEmpty else { return false }

        // Règle (§4) : inconnu → appliquer ; connu → le téléphone n'applique que si
        // STRICTEMENT plus récent (à égalité, le téléphone gagne).
        var localUpdatedAt: Int?
        try db.run(
            "SELECT updated_at FROM saisie_changes WHERE resource = ? AND key = ?",
            [.text(change.resource), .text(change.key)]) { r in localUpdatedAt = r.double(0).map { Int($0) } }
        if let localUpdatedAt, change.updatedAt <= localUpdatedAt { return false }

        if change.deleted {
            guard localUpdatedAt != nil else {
                // Pierre tombale d'une clé INCONNUE : rien à supprimer, mais on la
                // journalise (comme le serveur) pour qu'une création plus ancienne
                // qui arriverait ensuite ne ressuscite pas la ligne.
                guard Self.isValidSaisieKey(resource: change.resource, key: change.key) else { return false }
                try db.run(
                    """
                    INSERT OR REPLACE INTO saisie_changes (resource, key, updated_at, deleted, rev)
                    VALUES (?, ?, ?, 1, (SELECT COALESCE(MAX(rev), 0) + 1 FROM saisie_changes))
                    """,
                    [.text(change.resource), .text(change.key), .int(change.updatedAt)])
                return true
            }
            try deleteRow(change)
        } else {
            guard let data = change.data else { throw SaisieSkip() }
            try writeRow(change, data: data)
        }

        // Les triggers ont journalisé avec « maintenant » : on réécrit l'`updated_at`
        // d'origine (§3). Le `rev` local, lui, a avancé normalement.
        try db.run(
            "UPDATE saisie_changes SET updated_at = ? WHERE resource = ? AND key = ?",
            [.int(change.updatedAt), .text(change.resource), .text(change.key)])

        if change.resource == "weight" || (change.resource == "setting" && change.key == "weightKg") {
            result.weightChanged = true
        }
        if change.resource == "setting" && change.key == "wakeSchedule" { result.wakeScheduleChanged = true }
        return true
    }

    /// Forme de la clé d'une ressource (une clé mal formée n'entre jamais au journal).
    private static func isValidSaisieKey(resource: String, key: String) -> Bool {
        switch resource {
        case "weight": return isDateKey(key)
        case "setting": return saisieSettingKeys.contains(key)
        case "programmeDone": return splitDoneKey(key) != nil
        case "food", "foodLog", "programme": return !key.isEmpty
        default: return false
        }
    }

    // MARK: Suppression

    private func deleteRow(_ change: SaisieChange) throws {
        let key = change.key
        switch change.resource {
        case "food": try db.run("DELETE FROM foods WHERE uid = ?", [.text(key)])
        case "foodLog": try db.run("DELETE FROM food_log WHERE uid = ?", [.text(key)])
        case "weight": try db.run("DELETE FROM weight_log WHERE date = ?", [.text(key)])
        case "setting":
            guard Self.saisieSettingKeys.contains(key) else { throw SaisieSkip() }
            try db.run("DELETE FROM settings WHERE key = ?", [.text(key)])
        case "programme":
            // L'état d'abord : les triggers du plan ne journalisent plus (parent absent).
            try db.run("DELETE FROM programme_state WHERE programme_id = ?", [.text(key)])
            try db.run("DELETE FROM programme_plan WHERE programme_id = ?", [.text(key)])
        case "programmeDone":
            guard let (id, week, session) = Self.splitDoneKey(key) else { throw SaisieSkip() }
            try db.run(
                "DELETE FROM programme_done WHERE programme_id = ? AND week = ? AND session = ?",
                [.text(id), .int(week), .text(session)])
        default: throw SaisieSkip()
        }
    }

    // MARK: Écriture (validations des routes de saisie, §5)

    private static let datePattern = try! NSRegularExpression(pattern: #"^\d{4}-\d{2}-\d{2}$"#)

    private static func isDateKey(_ s: String) -> Bool {
        datePattern.firstMatch(in: s, range: NSRange(s.startIndex..<s.endIndex, in: s)) != nil
    }

    private func writeRow(_ change: SaisieChange, data: [String: SaisieJSON]) throws {
        switch change.resource {
        case "food": try writeFood(uid: change.key, data)
        case "foodLog": try writeFoodLog(uid: change.key, data)
        case "weight": try writeWeight(date: change.key, data)
        case "setting": try writeSetting(key: change.key, data)
        case "programme": try writeProgramme(id: change.key, data)
        case "programmeDone": try writeProgrammeDone(key: change.key, data)
        default: throw SaisieSkip()
        }
    }

    /// Nombre optionnel : absent/`null` → `nil` ; présent mais non numérique ou
    /// non fini → ligne refusée.
    private func number(_ data: [String: SaisieJSON], _ key: String) throws -> Double? {
        guard let value = data[key], value != .null else { return nil }
        guard let d = value.doubleValue, d.isFinite else { throw SaisieSkip() }
        return d
    }

    private func text(_ data: [String: SaisieJSON], _ key: String) throws -> String? {
        guard let value = data[key], value != .null else { return nil }
        guard let s = value.stringValue else { throw SaisieSkip() }
        return s
    }

    private func sqlText(_ s: String?) -> SQLiteValue { s.map(SQLiteValue.text) ?? .null }
    private func sqlNumber(_ d: Double?) -> SQLiteValue { d.map(SQLiteValue.double) ?? .null }

    private func rowExists(_ sql: String, _ params: [SQLiteValue]) throws -> Bool {
        var found = false
        try db.run(sql, params) { _ in found = true }
        return found
    }

    private func writeFood(uid: String, _ data: [String: SaisieJSON]) throws {
        guard let name = try text(data, "name"), !name.trimmingCharacters(in: .whitespaces).isEmpty else { throw SaisieSkip() }
        let barcode = try text(data, "barcode").flatMap { $0.isEmpty ? nil : $0 }
        let unitGrams = try number(data, "unitGrams")
        if let unitGrams, !(unitGrams > 0 && unitGrams <= 2000) { throw SaisieSkip() }
        let values: [SQLiteValue] = [
            sqlText(barcode), .text(name), sqlNumber(try number(data, "kcal")), sqlNumber(try number(data, "protein")),
            sqlNumber(try number(data, "carbs")), sqlNumber(try number(data, "fiber")), sqlNumber(try number(data, "fat")),
            sqlText(try text(data, "unitLabel")), sqlNumber(unitGrams),
        ]
        // Code-barres déjà porté par un AUTRE aliment : la contrainte d'unicité
        // l'interdit ; le rapprochement par `uid` se fait côté serveur (§6).
        if let barcode, try rowExists("SELECT 1 FROM foods WHERE barcode = ? AND uid IS NOT ?", [.text(barcode), .text(uid)]) {
            throw SaisieSkip()
        }
        if try rowExists("SELECT 1 FROM foods WHERE uid = ?", [.text(uid)]) {
            try db.run(
                """
                UPDATE foods SET barcode = ?, name = ?, kcal = ?, protein = ?, carbs = ?, fiber = ?, fat = ?,
                                 unit_label = ?, unit_grams = ? WHERE uid = ?
                """, values + [.text(uid)])
        } else {
            try db.run(
                """
                INSERT INTO foods (barcode, name, kcal, protein, carbs, fiber, fat, unit_label, unit_grams, uid)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, values + [.text(uid)])
        }
    }

    private func writeFoodLog(uid: String, _ data: [String: SaisieJSON]) throws {
        guard let date = try text(data, "date"), Self.isDateKey(date) else { throw SaisieSkip() }
        guard let name = try text(data, "name"), !name.isEmpty else { throw SaisieSkip() }
        guard let grams = try number(data, "grams"), grams >= 0 else { throw SaisieSkip() }
        // `foodUid` inconnu → `food_id = NULL` (§2).
        var foodId: SQLiteValue = .null
        if let foodUid = try text(data, "foodUid") {
            try db.run("SELECT id FROM foods WHERE uid = ?", [.text(foodUid)]) { r in
                if let id = r.double(0) { foodId = .int(Int(id)) }
            }
        }
        var ts: SQLiteValue = .null
        if let raw = data["ts"], raw != .null {
            guard let value = raw.intValue else { throw SaisieSkip() }
            ts = .int(value)
        }
        let values: [SQLiteValue] = [
            .text(date), foodId, .text(name), .double(grams), sqlNumber(try number(data, "kcal")),
            sqlNumber(try number(data, "protein")), sqlNumber(try number(data, "carbs")), sqlNumber(try number(data, "fiber")),
            sqlNumber(try number(data, "fat")), sqlText(try text(data, "unitLabel")), sqlNumber(try number(data, "unitQty")), ts,
        ]
        if try rowExists("SELECT 1 FROM food_log WHERE uid = ?", [.text(uid)]) {
            try db.run(
                """
                UPDATE food_log SET date = ?, food_id = ?, name = ?, grams = ?, kcal = ?, protein = ?, carbs = ?,
                                    fiber = ?, fat = ?, unit_label = ?, unit_qty = ?, ts = ? WHERE uid = ?
                """, values + [.text(uid)])
        } else {
            try db.run(
                """
                INSERT INTO food_log (date, food_id, name, grams, kcal, protein, carbs, fiber, fat, unit_label, unit_qty, ts, uid)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, values + [.text(uid)])
        }
    }

    private func writeWeight(date: String, _ data: [String: SaisieJSON]) throws {
        guard Self.isDateKey(date), let kg = try number(data, "kg"), kg >= 25, kg <= 300 else { throw SaisieSkip() }
        try db.run(
            "INSERT INTO weight_log (date, kg) VALUES (?, ?) ON CONFLICT(date) DO UPDATE SET kg = excluded.kg",
            [.text(date), .double(kg)])
    }

    private func writeSetting(key: String, _ data: [String: SaisieJSON]) throws {
        guard Self.saisieSettingKeys.contains(key), let value = data["value"]?.stringValue,
              Self.isValidSetting(key: key, value: value) else { throw SaisieSkip() }
        try db.run(
            "INSERT INTO settings (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            [.text(key), .text(value)])
    }

    /// Mêmes bornes que `ProfileController.update` / `WakeController.update`
    /// (`RealLocalPulseBackend.encodeProfileUpdate`/`encodeWakeScheduleUpdate`).
    static func isValidSetting(key: String, value: String) -> Bool {
        switch key {
        case "birthYear":
            let year = Calendar.current.component(.year, from: Date())
            guard let v = Int(value) else { return false }
            return v >= year - 110 && v <= year - 10
        case "sex":
            return value == "male" || value == "female"
        case "weightKg":
            guard let v = Double(value) else { return false }
            return v.isFinite && v >= 25 && v <= 300
        case "heightCm":
            guard let v = Double(value) else { return false }
            return v.isFinite && v >= 100 && v <= 250
        case "wakeSchedule":
            guard let raw = value.data(using: .utf8),
                  let map = try? JSONDecoder().decode([String: Int].self, from: raw) else { return false }
            return map.allSatisfy { k, v in (Int(k).map { $0 >= 1 && $0 <= 7 } ?? false) && v >= 0 && v <= 1439 }
        default:
            return false
        }
    }

    /// `days` : la forme `programme_state.days` (chaîne `"1,3,5"`) ; un tableau
    /// d'entiers est accepté en entrée (le contrat ne fixe pas la forme).
    private func daysText(_ value: SaisieJSON?) throws -> String? {
        switch value {
        case nil, .some(.null): return nil
        case .some(.string(let s)): return s
        case .some(.array(let items)):
            let ints = items.compactMap(\.intValue)
            guard ints.count == items.count else { throw SaisieSkip() }
            return ints.map(String.init).joined(separator: ",")
        default: throw SaisieSkip()
        }
    }

    private func writeProgramme(id: String, _ data: [String: SaisieJSON]) throws {
        guard let kind = try text(data, "kind"), !kind.isEmpty,
              let startedOn = try text(data, "startedOn"), Self.isDateKey(startedOn),
              let active = data["active"]?.boolValue else { throw SaisieSkip() }
        let days = try daysText(data["days"])
        var plan: [(week: Int, session: String, date: String)] = []
        if let raw = data["plan"], raw != .null {
            guard case .array(let items) = raw else { throw SaisieSkip() }
            for item in items {
                guard case .object(let o) = item, let week = o["week"]?.intValue,
                      let session = o["session"]?.stringValue, !session.isEmpty,
                      let date = o["date"]?.stringValue, Self.isDateKey(date) else { throw SaisieSkip() }
                plan.append((week, session, date))
            }
        }
        // Remplace l'état ET tout le plan (§2) ; le plan n'est jamais recalculé ici.
        try db.run(
            """
            INSERT INTO programme_state (programme_id, kind, started_on, active, days) VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(programme_id) DO UPDATE SET kind = excluded.kind, started_on = excluded.started_on,
                                                     active = excluded.active, days = excluded.days
            """,
            [.text(id), .text(kind), .text(startedOn), .int(active ? 1 : 0), sqlText(days)])
        try db.run("DELETE FROM programme_plan WHERE programme_id = ?", [.text(id)])
        for row in plan {
            try db.run(
                "INSERT OR REPLACE INTO programme_plan (programme_id, week, session, date) VALUES (?, ?, ?, ?)",
                [.text(id), .int(row.week), .text(row.session), .text(row.date)])
        }
    }

    private func writeProgrammeDone(key: String, _ data: [String: SaisieJSON]) throws {
        guard let (id, week, session) = Self.splitDoneKey(key),
              let date = try text(data, "date"), Self.isDateKey(date) else { throw SaisieSkip() }
        // `activityFileHash` → `activity_id` local ; hash inconnu → NULL (§2).
        var activityId: SQLiteValue = .null
        if let hash = try text(data, "activityFileHash") {
            try db.run("SELECT id FROM activities WHERE file_hash = ?", [.text(hash)]) { r in
                if let value = r.double(0) { activityId = .int(Int(value)) }
            }
        }
        try db.run(
            """
            INSERT INTO programme_done (programme_id, week, session, date, activity_id) VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(programme_id, week, session) DO UPDATE SET date = excluded.date, activity_id = excluded.activity_id
            """,
            [.text(id), .int(week), .text(session), .text(date), activityId])
    }
}
