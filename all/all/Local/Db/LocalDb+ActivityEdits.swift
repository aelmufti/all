//
//  LocalDb+ActivityEdits.swift
//  all (bridge-connect)
//
//  Côté base locale de la modification et de la fusion d'activités — contrat
//  `custom-connect/docs/activity-edits-contract.md` (§2 stockage, §3 résolution
//  d'une principale). Quatre parties :
//   1. la MIGRATION (`activityEditsMigration`) : `activity_edits`, `activities_merged`,
//      colonnes de `activities`, triggers du journal des saisies (§7) ;
//   2. les modifications (`ActivityEdit`) et leur graphe de fusion ;
//   3. les lignes `activities` / `activities_merged` (déplacement, mise à jour) ;
//   4. l'invalidation Body Battery (équivalent de `invalidateBodyBatteryFrom`, TS).
//
//  Le calcul lui-même vit dans `Fit/FitActivityEdit.swift` (pur), l'orchestration dans
//  `Local/ActivityEditMaterializer.swift`.
//

import Foundation

// MARK: - Temps ISO des fenêtres

enum ActivityEditTime {
    private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let plain = ISO8601DateFormatter()

    /// ISO 8601 → secondes Unix ; `nil` si illisible.
    static func parse(_ s: String) -> Double? {
        (fractional.date(from: s) ?? plain.date(from: s))?.timeIntervalSince1970
    }

    /// Secondes Unix → `yyyy-MM-ddTHH:mm:ss.SSSZ` (même format que `startTime`).
    static func format(_ unix: Double) -> String {
        FitActivityExtractor.isoDateTime(unix - FitWellnessExtractor.fitEpochS)
    }
}

// MARK: - Migration (contrat §2)

extension LocalDb {
    /// 3 : modifications d'activités. `activities_merged` est créée APRÈS les colonnes
    /// ajoutées à `activities` : mêmes colonnes, dans le même ordre (`activityColumns`).
    /// Les triggers journalisent `activity_edits` comme ressource `activityEdit` (§7).
    static var activityEditsMigration: String {
        [
            """
            CREATE TABLE activity_edits (
              file_hash   TEXT PRIMARY KEY,
              start_at    TEXT,
              end_at      TEXT,
              sport       TEXT,
              sub_sport   TEXT,
              name        TEXT,
              note        TEXT,
              merged_into TEXT,
              updated_at  TEXT NOT NULL DEFAULT (datetime('now'))
            );
            """,
            "ALTER TABLE activities ADD COLUMN name TEXT;",
            "ALTER TABLE activities ADD COLUMN note TEXT;",
            "ALTER TABLE activities ADD COLUMN edited INTEGER NOT NULL DEFAULT 0;",
            "ALTER TABLE activities ADD COLUMN merged_count INTEGER NOT NULL DEFAULT 0;",
            "CREATE TABLE activities_merged AS SELECT * FROM activities WHERE 0;",
            "CREATE UNIQUE INDEX idx_activities_merged_hash ON activities_merged(file_hash);",
            "CREATE INDEX idx_activity_edits_merged_into ON activity_edits(merged_into);",
            trigger("saisie_activity_edit_ai", "INSERT", on: "activity_edits", when: "1", "activityEdit", key: "NEW.file_hash", deleted: "0"),
            trigger("saisie_activity_edit_au", "UPDATE", on: "activity_edits", when: "1", "activityEdit", key: "NEW.file_hash", deleted: "0"),
            trigger("saisie_activity_edit_ad", "DELETE", on: "activity_edits", when: "1", "activityEdit", key: "OLD.file_hash", deleted: "1"),
        ].joined(separator: "\n")
    }

    /// Colonnes communes à `activities` et `activities_merged`, dans l'ordre.
    fileprivate static let activityColumns =
        "id, file_hash, file_name, sport, sub_sport, start_time, duration_s, distance_m, calories, avg_hr, max_hr, created_at, name, note, edited, merged_count"
}

// MARK: - Modifications (§2)

/// Une ligne `activity_edits`. Les dates sont des ISO 8601 UTC normalisés
/// (`ActivityEditTime.format`).
struct ActivityEdit: Equatable {
    var fileHash: String
    var startAt: String?
    var endAt: String?
    var sport: String?
    var subSport: String?
    var name: String?
    var note: String?
    var mergedInto: String?

    init(fileHash: String) { self.fileHash = fileHash }

    /// Fenêtre posée (recalcul nécessaire).
    var hasWindow: Bool { startAt != nil || endAt != nil }
    /// Aucune valeur non nulle (hors `file_hash`) : la ligne est supprimée.
    var isEmpty: Bool { !hasWindow && sport == nil && subSport == nil && name == nil && note == nil && mergedInto == nil }

    var window: FitActivityEdit.Window {
        FitActivityEdit.Window(start: startAt.flatMap(ActivityEditTime.parse), end: endAt.flatMap(ActivityEditTime.parse))
    }
}

/// Graphe des fusions (§3) : `merged_into` de chaque activité modifiée.
struct ActivityEditGraph {
    private let parents: [String: String]

    init(_ edits: [ActivityEdit]) {
        var map: [String: String] = [:]
        for edit in edits {
            if let parent = edit.mergedInto, parent != edit.fileHash { map[edit.fileHash] = parent }
        }
        parents = map
    }

    /// Racine de la chaîne `merged_into` ; un cycle annule la fusion (activité autonome).
    func root(of hash: String) -> String {
        var seen: Set<String> = [hash]
        var current = hash
        while let parent = parents[current] {
            if !seen.insert(parent).inserted { return hash }
            current = parent
        }
        return current
    }

    /// Toutes les activités dont la racine est `root` (hors `root`), triées par hash
    /// pour un ordre stable (l'ordre chronologique se décide au calcul).
    func members(of root: String) -> [String] {
        parents.keys.filter { $0 != root && self.root(of: $0) == root }.sorted()
    }
}

extension LocalDb {
    private static let editColumns = "file_hash, start_at, end_at, sport, sub_sport, name, note, merged_into"

    private static func edit(from r: SQLiteRow) -> ActivityEdit {
        var e = ActivityEdit(fileHash: r.text(0) ?? "")
        e.startAt = r.text(1)
        e.endAt = r.text(2)
        e.sport = r.text(3)
        e.subSport = r.text(4)
        e.name = r.text(5)
        e.note = r.text(6)
        e.mergedInto = r.text(7)
        return e
    }

    func activityEdit(hash: String) throws -> ActivityEdit? {
        var out: ActivityEdit?
        try db.run("SELECT \(Self.editColumns) FROM activity_edits WHERE file_hash = ?", [.text(hash)]) { out = Self.edit(from: $0) }
        return out
    }

    /// Y a-t-il la moindre modification ou activité absorbée ? (Court-circuit de l'ingestion.)
    func hasAnyActivityEdits() throws -> Bool {
        var found = false
        try db.run("SELECT 1 FROM activity_edits UNION ALL SELECT 1 FROM activities_merged LIMIT 1") { _ in found = true }
        return found
    }

    func allActivityEdits() throws -> [ActivityEdit] {
        var out: [ActivityEdit] = []
        try db.run("SELECT \(Self.editColumns) FROM activity_edits ORDER BY file_hash") { out.append(Self.edit(from: $0)) }
        return out
    }

    /// Écrit la ligne ; supprimée si elle n'a plus aucune valeur (§2). Rien si elle
    /// n'existait pas et reste vide. À appeler dans une transaction.
    func saveActivityEdit(_ edit: ActivityEdit) throws {
        if edit.isEmpty {
            try db.run("DELETE FROM activity_edits WHERE file_hash = ?", [.text(edit.fileHash)])
            return
        }
        func text(_ s: String?) -> SQLiteValue { s.map(SQLiteValue.text) ?? .null }
        try db.run(
            """
            INSERT INTO activity_edits (file_hash, start_at, end_at, sport, sub_sport, name, note, merged_into, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, datetime('now'))
            ON CONFLICT(file_hash) DO UPDATE SET start_at = excluded.start_at, end_at = excluded.end_at,
              sport = excluded.sport, sub_sport = excluded.sub_sport, name = excluded.name, note = excluded.note,
              merged_into = excluded.merged_into, updated_at = excluded.updated_at
            """,
            [.text(edit.fileHash), text(edit.startAt), text(edit.endAt), text(edit.sport), text(edit.subSport),
             text(edit.name), text(edit.note), text(edit.mergedInto)])
    }
}

// MARK: - Lignes d'activité (actives et absorbées)

/// Une ligne `activities` / `activities_merged` complète.
struct StoredActivity {
    let id: Int
    let fileHash: String
    let fileName: String
    let sport: String?
    let subSport: String?
    let startTime: String?
    let durationS: Double?
    let distanceM: Double?
    let calories: Double?
    let avgHr: Double?
    let maxHr: Double?
    let name: String?
    let note: String?
    let edited: Bool
    let mergedCount: Int
}

extension LocalDb {
    private static let storedColumns =
        "id, file_hash, file_name, sport, sub_sport, start_time, duration_s, distance_m, calories, avg_hr, max_hr, name, note, edited, merged_count"

    private static func stored(from r: SQLiteRow) -> StoredActivity {
        StoredActivity(
            id: Int(r.double(0) ?? 0), fileHash: r.text(1) ?? "", fileName: r.text(2) ?? "", sport: r.text(3),
            subSport: r.text(4), startTime: r.text(5), durationS: r.double(6), distanceM: r.double(7),
            calories: r.double(8), avgHr: r.double(9), maxHr: r.double(10), name: r.text(11), note: r.text(12),
            edited: (r.double(13) ?? 0) != 0, mergedCount: Int(r.double(14) ?? 0))
    }

    /// Ligne ACTIVE (visible) de ce hash.
    func storedActivity(hash: String) throws -> StoredActivity? {
        var out: StoredActivity?
        try db.run("SELECT \(Self.storedColumns) FROM activities WHERE file_hash = ?", [.text(hash)]) { out = Self.stored(from: $0) }
        return out
    }

    func storedActivity(id: Int) throws -> StoredActivity? {
        var out: StoredActivity?
        try db.run("SELECT \(Self.storedColumns) FROM activities WHERE id = ?", [.int(id)]) { out = Self.stored(from: $0) }
        return out
    }

    /// Ligne ABSORBÉE par une fusion (`activities_merged`).
    func mergedActivity(hash: String) throws -> StoredActivity? {
        var out: StoredActivity?
        try db.run("SELECT \(Self.storedColumns) FROM activities_merged WHERE file_hash = ?", [.text(hash)]) { out = Self.stored(from: $0) }
        return out
    }

    func mergedActivity(id: Int) throws -> StoredActivity? {
        var out: StoredActivity?
        try db.run("SELECT \(Self.storedColumns) FROM activities_merged WHERE id = ?", [.int(id)]) { out = Self.stored(from: $0) }
        return out
    }

    func mergedActivityHashes() throws -> [String] {
        var out: [String] = []
        try db.run("SELECT file_hash FROM activities_merged ORDER BY id") { if let h = $0.text(0) { out.append(h) } }
        return out
    }

    /// Un hash est « connu » s'il est actif OU absorbé (jamais réingéré ni rapatrié, §2).
    func isActivityKnown(hash: String) throws -> Bool {
        var found = false
        try db.run(
            "SELECT 1 FROM activities WHERE file_hash = ? UNION ALL SELECT 1 FROM activities_merged WHERE file_hash = ?",
            [.text(hash), .text(hash)]) { _ in found = true }
        return found
    }

    /// Absorbe : la ligne passe dans `activities_merged` (même id), ses tables dérivées
    /// sont vidées et les `programme_done` qui la visaient passent sur la principale.
    func absorbActivity(_ row: StoredActivity, into principalId: Int) throws {
        try db.run(
            "INSERT OR REPLACE INTO activities_merged (\(Self.activityColumns)) SELECT \(Self.activityColumns) FROM activities WHERE id = ?",
            [.int(row.id)])
        try db.run("DELETE FROM activity_zones WHERE activity_id = ?", [.int(row.id)])
        try db.run("DELETE FROM activities WHERE id = ?", [.int(row.id)])
        try db.run("UPDATE programme_done SET activity_id = ? WHERE activity_id = ?", [.int(principalId), .int(row.id)])
    }

    /// Rétablit une activité absorbée (même id).
    func restoreActivity(hash: String) throws {
        try db.run(
            "INSERT OR REPLACE INTO activities (\(Self.activityColumns)) SELECT \(Self.activityColumns) FROM activities_merged WHERE file_hash = ?",
            [.text(hash)])
        try db.run("DELETE FROM activities_merged WHERE file_hash = ?", [.text(hash)])
    }

    /// Réécrit tout le résumé d'une ligne active, plus nom/note/drapeaux.
    func writeActivitySummary(
        id: Int, _ s: FitActivityExtractor.Summary, name: String?, note: String?, edited: Bool, mergedCount: Int
    ) throws {
        try db.run(
            """
            UPDATE activities SET sport = ?, sub_sport = ?, start_time = ?, duration_s = ?, distance_m = ?, calories = ?,
              avg_hr = ?, max_hr = ?, name = ?, note = ?, edited = ?, merged_count = ? WHERE id = ?
            """,
            [sqliteOptionalText(s.sport), sqliteOptionalText(s.subSport), sqliteOptionalText(s.startTime),
             sqliteOptional(s.durationS), sqliteOptional(s.distanceM), sqliteOptional(s.calories), sqliteOptional(s.avgHr),
             sqliteOptional(s.maxHr), sqliteOptionalText(name), sqliteOptionalText(note), .int(edited ? 1 : 0),
             .int(mergedCount), .int(id)])
    }

    /// Change seulement sport (si fourni), nom, note et drapeaux — sans recalcul (§4).
    func writeActivityLabels(
        id: Int, sport: (String?, String?)?, name: String?, note: String?, edited: Bool, mergedCount: Int
    ) throws {
        if let sport {
            try db.run("UPDATE activities SET sport = ?, sub_sport = ? WHERE id = ?",
                       [sqliteOptionalText(sport.0), sqliteOptionalText(sport.1), .int(id)])
        }
        try db.run("UPDATE activities SET name = ?, note = ?, edited = ?, merged_count = ? WHERE id = ?",
                   [sqliteOptionalText(name), sqliteOptionalText(note), .int(edited ? 1 : 0), .int(mergedCount), .int(id)])
    }

    /// Zones FC matérialisées d'une activité modifiée (`activity_zones`).
    func replaceActivityZones(id: Int, _ zones: [FitActivityExtractor.HrZoneRow]) throws {
        try db.run("DELETE FROM activity_zones WHERE activity_id = ?", [.int(id)])
        for zone in zones {
            try db.run("INSERT INTO activity_zones (activity_id, zone, seconds) VALUES (?, ?, ?)",
                       [.int(id), .int(zone.zone), .double(zone.seconds)])
        }
    }

    /// Équivalent local de `DbService.invalidateBodyBatteryFrom` : les états de départ
    /// d'une date au-delà d'une activité modifiée sont à recalculer. `nil` : tout.
    func invalidateBodyBatteryFrom(date: String?) throws {
        if let date {
            try db.run("DELETE FROM body_battery_state WHERE date >= ?", [.text(date)])
        } else {
            try db.run("DELETE FROM body_battery_state")
        }
    }
}
