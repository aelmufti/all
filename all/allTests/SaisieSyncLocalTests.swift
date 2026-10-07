//
//  SaisieSyncLocalTests.swift
//  allTests
//
//  Synchro des saisies téléphone ↔ Pulse, côté base locale : migration (`uid`,
//  journal `saisie_changes`), triggers, collecte/sérialisation, application d'une
//  réponse (contrat `custom-connect/docs/pulse-saisies-sync-contract.md` §2-§5).
//  Bases temporaires, aucun réseau.
//

import Testing
import Foundation
@testable import all

// MARK: - Aides

private func tempPath() -> String {
    FileManager.default.temporaryDirectory.appendingPathComponent("saisie-sync-tests-\(UUID().uuidString).sqlite").path
}

private func makeDb() throws -> LocalDb { try LocalDb(path: tempPath()) }

struct JournalEntry: Equatable {
    var updatedAt: Int
    var deleted: Bool
    var rev: Int
}

/// Journal complet, clé « ressource|clé ».
private func journal(_ db: LocalDb) throws -> [String: JournalEntry] {
    var out: [String: JournalEntry] = [:]
    try db.db.run("SELECT resource, key, updated_at, deleted, rev FROM saisie_changes") { r in
        out["\(r.text(0) ?? "")|\(r.text(1) ?? "")"] = JournalEntry(
            updatedAt: Int(r.double(2) ?? 0), deleted: (r.double(3) ?? 0) != 0, rev: Int(r.double(4) ?? 0))
    }
    return out
}

private func scalar(_ db: LocalDb, _ sql: String, _ params: [SQLiteValue] = []) throws -> Double? {
    var value: Double?
    try db.db.run(sql, params) { r in value = r.double(0) }
    return value
}

private func text(_ db: LocalDb, _ sql: String, _ params: [SQLiteValue] = []) throws -> String? {
    var value: String?
    try db.db.run(sql, params) { r in value = r.text(0) }
    return value
}

private func uid(of db: LocalDb, food id: Int) throws -> String {
    try text(db, "SELECT uid FROM foods WHERE id = ?", [.int(id)]) ?? ""
}

private func isHex32(_ s: String) -> Bool {
    s.count == 32 && s.allSatisfy { "0123456789abcdef".contains($0) }
}

private func insertLog(_ db: LocalDb, date: String = "2026-10-01", foodId: Int? = nil, name: String = "Skyr", grams: Double = 150) throws -> Int {
    try db.insertLog(
        date: date, foodId: foodId, name: name, grams: grams, kcal: 95, protein: 16, carbs: 6, fiber: 0, fat: 0.3,
        unitLabel: "pot", unitQty: 1, ts: 1_790_000_000)
}

private func change(
    _ resource: String, _ key: String, at updatedAt: Int, deleted: Bool = false, _ data: [String: SaisieJSON]? = nil
) -> SaisieChange {
    SaisieChange(resource: resource, key: key, updatedAt: updatedAt, deleted: deleted, data: deleted ? nil : data)
}

private let foodData: [String: SaisieJSON] = [
    "barcode": .null, "name": .string("Pain de seigle"), "kcal": .double(250), "protein": .double(8),
    "carbs": .double(48), "fiber": .double(6), "fat": .double(1.5), "unitLabel": .string("tranche"), "unitGrams": .int(40),
]

private func foodLogData(foodUid: String?, name: String = "Pain de seigle", grams: Double = 80) -> [String: SaisieJSON] {
    [
        "date": .string("2026-10-02"), "foodUid": foodUid.map(SaisieJSON.string) ?? .null, "name": .string(name),
        "grams": .double(grams), "kcal": .double(200), "protein": .double(6.4), "carbs": .double(38.4), "fiber": .double(4.8),
        "fat": .double(1.2), "unitLabel": .string("tranche"), "unitQty": .double(2), "ts": .int(1_790_000_100),
    ]
}

// MARK: - Migration

struct SaisieMigrationTests {
    /// Schéma d'AVANT la migration (copie des tables concernées) + des lignes.
    private func makePreExistingBase() throws -> String {
        let path = tempPath()
        let raw = try SQLiteDatabase(path: path)
        try raw.execute("""
        CREATE TABLE activities (id INTEGER PRIMARY KEY AUTOINCREMENT, file_hash TEXT NOT NULL UNIQUE, file_name TEXT NOT NULL,
          sport TEXT, sub_sport TEXT, start_time TEXT, duration_s REAL, distance_m REAL, calories INTEGER, avg_hr INTEGER,
          max_hr INTEGER, created_at TEXT NOT NULL DEFAULT (datetime('now')));
        CREATE TABLE weight_log (date TEXT PRIMARY KEY, kg REAL NOT NULL, created_at TEXT NOT NULL DEFAULT (datetime('now')));
        CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);
        CREATE TABLE foods (id INTEGER PRIMARY KEY AUTOINCREMENT, barcode TEXT UNIQUE, name TEXT NOT NULL, kcal REAL, protein REAL,
          carbs REAL, fiber REAL, fat REAL, unit_label TEXT, unit_grams REAL, created_at TEXT NOT NULL DEFAULT (datetime('now')));
        CREATE TABLE food_log (id INTEGER PRIMARY KEY AUTOINCREMENT, date TEXT NOT NULL, food_id INTEGER, name TEXT NOT NULL,
          grams REAL NOT NULL, kcal REAL, protein REAL, carbs REAL, fiber REAL, fat REAL, unit_label TEXT, unit_qty REAL, ts INTEGER,
          created_at TEXT NOT NULL DEFAULT (datetime('now')));
        CREATE TABLE programme_state (programme_id TEXT PRIMARY KEY, kind TEXT NOT NULL DEFAULT 'nutrition', started_on TEXT NOT NULL,
          active INTEGER NOT NULL DEFAULT 1, days TEXT);
        CREATE TABLE programme_plan (programme_id TEXT NOT NULL, week INTEGER NOT NULL, session TEXT NOT NULL, date TEXT NOT NULL,
          PRIMARY KEY (programme_id, week, session)) WITHOUT ROWID;
        CREATE TABLE programme_done (programme_id TEXT NOT NULL, week INTEGER NOT NULL, session TEXT NOT NULL, date TEXT NOT NULL,
          activity_id INTEGER, PRIMARY KEY (programme_id, week, session)) WITHOUT ROWID;
        INSERT INTO foods (name, created_at) VALUES ('Riz', '2026-01-02 03:04:05'), ('Lait', '2026-01-03 00:00:00');
        INSERT INTO food_log (date, food_id, name, grams, created_at) VALUES ('2026-01-02', 1, 'Riz', 150, '2026-01-02 12:00:00');
        INSERT INTO weight_log (date, kg, created_at) VALUES ('2026-01-02', 71.5, '2026-01-02 07:00:00');
        INSERT INTO settings (key, value) VALUES ('birthYear', '1990'), ('weightKg', '71.5'), ('wakeSchedule', '{"1":420}'),
          ('syncSource', 'phone'), ('ingestToken', 'secret-ne-doit-pas-sortir');
        INSERT INTO programme_state (programme_id, kind, started_on, active, days) VALUES ('p1', 'training', '2026-01-05', 1, '1,3');
        INSERT INTO programme_plan (programme_id, week, session, date) VALUES ('p1', 1, 'A', '2026-01-05'), ('p1', 1, 'B', '2026-01-07');
        INSERT INTO programme_done (programme_id, week, session, date) VALUES ('p1', 1, 'A', '2026-01-05');
        """)
        return path
    }

    @Test func existingRowsGetUidsAndEnterTheJournal() throws {
        let path = try makePreExistingBase()
        let db = try LocalDb(path: path)

        #expect(try LocalDb.schemaVersion(db.db) == LocalDb.migrations.count)
        let foodUids = try ["Riz", "Lait"].map { try text(db, "SELECT uid FROM foods WHERE name = ?", [.text($0)]) ?? "" }
        #expect(foodUids.allSatisfy(isHex32))
        #expect(Set(foodUids).count == 2)
        let logUid = try text(db, "SELECT uid FROM food_log") ?? ""
        #expect(isHex32(logUid))

        let entries = try journal(db)
        let expectedMs = Int(ISO8601DateFormatter().date(from: "2026-01-02T03:04:05Z")!.timeIntervalSince1970 * 1000)
        #expect(entries["food|\(foodUids[0])"]?.updatedAt == expectedMs)
        #expect(entries["food|\(foodUids[1])"] != nil)
        #expect(entries["foodLog|\(logUid)"]?.updatedAt == Int(ISO8601DateFormatter().date(from: "2026-01-02T12:00:00Z")!.timeIntervalSince1970 * 1000))
        #expect(entries["weight|2026-01-02"] != nil)
        // Sans `created_at` : 0.
        #expect(entries["programme|p1"]?.updatedAt == 0)
        #expect(entries["programmeDone|p1|1|A"]?.updatedAt == 0)
        #expect(entries["setting|birthYear"]?.updatedAt == 0)
        // Liste blanche : ni la source de synchro ni le jeton ne sont journalisés.
        #expect(entries["setting|syncSource"] == nil)
        #expect(entries["setting|ingestToken"] == nil)
        #expect(entries.keys.filter { $0.hasPrefix("setting|") }.count == 3)
        // Le plan voyage avec le programme : pas d'entrée propre.
        #expect(entries.keys.filter { $0.hasPrefix("programme|") }.count == 1)
        #expect(entries.values.allSatisfy { !$0.deleted })

        // `rev` distincts et contigus (le découpage en lots en dépend).
        let revs = entries.values.map(\.rev).sorted()
        #expect(revs == Array(1...revs.count))
    }

    @Test func reopeningDoesNotRepeatTheMigration() throws {
        let path = try makePreExistingBase()
        let first = try LocalDb(path: path)
        let before = try journal(first)
        let uidBefore = try text(first, "SELECT uid FROM foods WHERE name = 'Riz'")
        let second = try LocalDb(path: path)
        #expect(try journal(second) == before)
        #expect(try text(second, "SELECT uid FROM foods WHERE name = 'Riz'") == uidBefore)
        #expect(try LocalDb.schemaVersion(second.db) == LocalDb.migrations.count)
    }

    @Test func seedFoodsOfAFreshBaseReceiveUids() throws {
        let db = try makeDb()
        #expect(try scalar(db, "SELECT COUNT(*) FROM foods")! > 50)
        #expect(try scalar(db, "SELECT COUNT(*) FROM foods WHERE uid IS NULL") == 0)
        #expect(try scalar(db, "SELECT COUNT(DISTINCT uid) FROM foods") == scalar(db, "SELECT COUNT(*) FROM foods"))
        #expect(try scalar(db, "SELECT COUNT(*) FROM saisie_changes WHERE resource = 'food'") == scalar(db, "SELECT COUNT(*) FROM foods"))
        let uid = try text(db, "SELECT uid FROM foods LIMIT 1") ?? ""
        #expect(isHex32(uid))
    }

    @Test func uidIsUniqueByIndex() throws {
        let db = try makeDb()
        let uid = try text(db, "SELECT uid FROM foods LIMIT 1") ?? ""
        #expect(throws: (any Error).self) {
            try db.db.run("INSERT INTO foods (name, uid) VALUES ('Doublon', ?)", [.text(uid)])
        }
    }
}

// MARK: - Triggers

struct SaisieTriggerTests {
    @Test func foodInsertUpdateDelete() throws {
        let db = try makeDb()
        let row = try db.insertFood(barcode: "123", name: "Test", kcal: 100, protein: 1, carbs: 2, fiber: 3, fat: 4, unitLabel: nil, unitGrams: nil)
        let uid = try uid(of: db, food: row.id)
        #expect(isHex32(uid))
        let created = try #require(try journal(db)["food|\(uid)"])
        #expect(!created.deleted)
        #expect(abs(created.updatedAt - Int(Date().timeIntervalSince1970 * 1000)) < 5_000)

        _ = try db.updateFood(id: row.id, barcode: "123", name: "Test 2", kcal: 1, protein: 1, carbs: 2, fiber: 3, fat: 4, unitLabel: nil, unitGrams: nil)
        let updated = try #require(try journal(db)["food|\(uid)"])
        #expect(updated.rev > created.rev)

        try db.db.run("DELETE FROM foods WHERE id = ?", [.int(row.id)])
        let tomb = try #require(try journal(db)["food|\(uid)"])
        #expect(tomb.deleted)
        #expect(tomb.rev > updated.rev)
    }

    @Test func foodLogInsertUpdateDelete() throws {
        let db = try makeDb()
        let id = try insertLog(db)
        let uid = try text(db, "SELECT uid FROM food_log WHERE id = ?", [.int(id)]) ?? ""
        #expect(isHex32(uid))
        let created = try #require(try journal(db)["foodLog|\(uid)"])

        try db.updateLog(id: id, name: "Skyr 2", grams: 100, kcal: 1, protein: 1, carbs: 1, fiber: 1, fat: 1, unitLabel: nil, unitQty: nil, ts: 1)
        let updated = try #require(try journal(db)["foodLog|\(uid)"])
        #expect(updated.rev > created.rev && !updated.deleted)

        try db.deleteLog(id: id)
        let tomb = try #require(try journal(db)["foodLog|\(uid)"])
        #expect(tomb.deleted && tomb.rev > updated.rev)
    }

    @Test func weightInsertUpdateDelete() throws {
        let db = try makeDb()
        try db.upsertWeight(date: "2026-10-03", kg: 72)
        let created = try #require(try journal(db)["weight|2026-10-03"])
        try db.upsertWeight(date: "2026-10-03", kg: 72.4)
        let updated = try #require(try journal(db)["weight|2026-10-03"])
        #expect(updated.rev > created.rev && !updated.deleted)
        try db.deleteWeight(date: "2026-10-03")
        let tomb = try #require(try journal(db)["weight|2026-10-03"])
        #expect(tomb.deleted && tomb.rev > updated.rev)
    }

    @Test func onlyWhitelistedSettingsAreJournaled() throws {
        let db = try makeDb()
        for key in ["birthYear", "sex", "weightKg", "heightCm", "wakeSchedule"] {
            try db.setSetting(key: key, value: key == "sex" ? "male" : "1")
            #expect(try journal(db)["setting|\(key)"] != nil, "\(key) doit être journalisée")
        }
        let before = try journal(db)
        for key in ["syncSource", "ingestToken", "nutritionKcal", "foodsSeedVersion"] {
            try db.setSetting(key: key, value: "secret")
            try db.setSetting(key: key, value: "autre")
            try db.db.run("DELETE FROM settings WHERE key = ?", [.text(key)])
        }
        #expect(try journal(db) == before)

        try db.db.run("DELETE FROM settings WHERE key = 'sex'")
        #expect(try journal(db)["setting|sex"]?.deleted == true)
    }

    @Test func programmePlanMarksTheParentProgramme() throws {
        let db = try makeDb()
        try db.debugActivateProgramme(programmeId: "p1", kind: "training", startedOn: "2026-10-05", days: "1,3")
        let created = try #require(try journal(db)["programme|p1"])
        try db.debugInsertProgrammePlan(programmeId: "p1", week: 1, session: "A", date: "2026-10-05")
        let afterPlan = try #require(try journal(db)["programme|p1"])
        #expect(afterPlan.rev > created.rev && !afterPlan.deleted)
        try db.db.run("DELETE FROM programme_plan WHERE programme_id = 'p1'")
        let afterDelete = try #require(try journal(db)["programme|p1"])
        #expect(afterDelete.rev > afterPlan.rev && !afterDelete.deleted)
        // Aucune entrée pour la table du plan elle-même.
        #expect(try journal(db).keys.filter { $0.contains("plan") }.isEmpty)
    }

    @Test func deletingTheProgrammeLeavesATombstoneThatPlanDeletionDoesNotRevive() throws {
        let db = try makeDb()
        try db.debugActivateProgramme(programmeId: "p1", kind: "training", startedOn: "2026-10-05", days: nil)
        try db.debugInsertProgrammePlan(programmeId: "p1", week: 1, session: "A", date: "2026-10-05")
        try db.db.run("DELETE FROM programme_state WHERE programme_id = 'p1'")
        try db.db.run("DELETE FROM programme_plan WHERE programme_id = 'p1'")
        #expect(try journal(db)["programme|p1"]?.deleted == true)
        // Plan orphelin : aucune entrée parasite.
        try db.debugInsertProgrammePlan(programmeId: "orphelin", week: 1, session: "A", date: "2026-10-05")
        #expect(try journal(db)["programme|orphelin"] == nil)
    }

    @Test func programmeDoneKeyAndTombstone() throws {
        let db = try makeDb()
        try db.debugInsertProgrammeDone(programmeId: "p1", week: 2, session: "B", date: "2026-10-12", activityId: nil)
        let created = try #require(try journal(db)["programmeDone|p1|2|B"])
        try db.programmeSessionUpsert(programmeId: "p1", week: 2, session: "B", date: "2026-10-13", activityId: nil)
        let updated = try #require(try journal(db)["programmeDone|p1|2|B"])
        #expect(updated.rev > created.rev)
        try db.programmeSessionDelete(programmeId: "p1", week: 2, session: "B")
        #expect(try journal(db)["programmeDone|p1|2|B"]?.deleted == true)
    }

    @Test func revIsStrictlyIncreasing() throws {
        let db = try makeDb()
        try db.upsertWeight(date: "2026-10-03", kg: 72)
        try db.setSetting(key: "sex", value: "male")
        _ = try insertLog(db)
        let revs = try journal(db).values.map(\.rev)
        #expect(Set(revs).count == revs.count)
    }

    @Test func weightProfileResyncDoesNotRewriteAnUpToDateSetting() throws {
        let db = try makeDb()
        try db.upsertWeight(date: "2026-10-03", kg: 72)
        try db.syncWeightProfile()
        let first = try #require(try journal(db)["setting|weightKg"])
        try db.syncWeightProfile()
        #expect(try journal(db)["setting|weightKg"] == first)
    }
}

// MARK: - Collecte

struct SaisieCollectTests {
    @Test func serializesEachResourceAsStored() throws {
        let db = try makeDb()
        let food = try db.insertFood(
            barcode: "3017620422003", name: "Pâte", kcal: 539, protein: 6.3, carbs: 57.5, fiber: nil, fat: 30.9,
            unitLabel: "c. à soupe", unitGrams: 15)
        let foodUid = try uid(of: db, food: food.id)
        let logId = try insertLog(db, foodId: food.id, name: "Pâte", grams: 30)
        let logUid = try text(db, "SELECT uid FROM food_log WHERE id = ?", [.int(logId)]) ?? ""
        let orphanId = try insertLog(db, name: "Sans aliment")
        let orphanUid = try text(db, "SELECT uid FROM food_log WHERE id = ?", [.int(orphanId)]) ?? ""
        try db.upsertWeight(date: "2026-10-03", kg: 72.4)
        try db.setSetting(key: "heightCm", value: "181")
        try db.debugActivateProgramme(programmeId: "p1", kind: "training", startedOn: "2026-10-05", days: "1,3")
        try db.debugInsertProgrammePlan(programmeId: "p1", week: 1, session: "A", date: "2026-10-05")
        try db.debugInsertProgrammePlan(programmeId: "p1", week: 1, session: "B", date: "2026-10-07")
        try db.db.run("INSERT INTO activities (file_hash, file_name) VALUES ('hash-act', 'a.fit')")
        try db.debugInsertProgrammeDone(programmeId: "p1", week: 1, session: "A", date: "2026-10-05", activityId: 1)
        try db.debugInsertProgrammeDone(programmeId: "p1", week: 1, session: "B", date: "2026-10-07", activityId: nil)

        let batch = try db.collectSaisieChanges(afterRev: 0, limit: 10_000)
        func find(_ resource: String, _ key: String) throws -> SaisieChange {
            try #require(batch.changes.first { $0.resource == resource && $0.key == key })
        }

        let foodChange = try find("food", foodUid)
        #expect(foodChange.deleted == false)
        #expect(foodChange.data == [
            "barcode": .string("3017620422003"), "name": .string("Pâte"), "kcal": .double(539), "protein": .double(6.3),
            "carbs": .double(57.5), "fiber": .null, "fat": .double(30.9), "unitLabel": .string("c. à soupe"), "unitGrams": .double(15),
        ])

        let logChange = try find("foodLog", logUid)
        #expect(logChange.data?["foodUid"] == .string(foodUid))
        #expect(logChange.data?["grams"] == .double(30))
        #expect(logChange.data?["ts"] == .int(1_790_000_000))
        #expect(logChange.data?["unitQty"] == .double(1))
        #expect(logChange.data?["date"] == .string("2026-10-01"))
        // Valeurs STOCKÉES (déjà à l'échelle), et aliment absent → `foodUid` nul.
        #expect(try find("foodLog", orphanUid).data?["foodUid"] == .null)

        #expect(try find("weight", "2026-10-03").data == ["kg": .double(72.4)])
        #expect(try find("setting", "heightCm").data == ["value": .string("181")])

        let programme = try find("programme", "p1")
        #expect(programme.data?["kind"] == .string("training"))
        #expect(programme.data?["startedOn"] == .string("2026-10-05"))
        #expect(programme.data?["active"] == .bool(true))
        #expect(programme.data?["days"] == .string("1,3"))
        #expect(programme.data?["plan"] == .array([
            .object(["week": .int(1), "session": .string("A"), "date": .string("2026-10-05")]),
            .object(["week": .int(1), "session": .string("B"), "date": .string("2026-10-07")]),
        ]))

        #expect(try find("programmeDone", "p1|1|A").data == ["date": .string("2026-10-05"), "activityFileHash": .string("hash-act")])
        #expect(try find("programmeDone", "p1|1|B").data?["activityFileHash"] == .null)
    }

    @Test func tombstonesCarryNoData() throws {
        let db = try makeDb()
        try db.upsertWeight(date: "2026-10-03", kg: 72)
        try db.deleteWeight(date: "2026-10-03")
        let change = try #require(try db.collectSaisieChanges(afterRev: 0, limit: 10_000).changes.first { $0.key == "2026-10-03" })
        #expect(change.deleted)
        #expect(change.data == nil)
        let json = String(decoding: try SaisieSyncWire.encoder.encode(change), as: UTF8.self)
        #expect(!json.contains("\"data\""))
        #expect(json.contains("\"deleted\":true"))
    }

    @Test func collectsOnlyAfterTheAckedRevInRevOrderAndSplitsInBatches() throws {
        let db = try makeDb()
        let all = try db.collectSaisieChanges(afterRev: 0, limit: 10_000)
        #expect(all.changes.count == (try journal(db).count))
        #expect(!all.hasMore)

        let first = try db.collectSaisieChanges(afterRev: 0, limit: 40)
        #expect(first.changes.count == 40)
        #expect(first.hasMore)
        let second = try db.collectSaisieChanges(afterRev: first.maxRev!, limit: 40)
        #expect(second.changes.count == 40)
        let third = try db.collectSaisieChanges(afterRev: second.maxRev!, limit: 40)
        #expect(!third.hasMore)
        let keys = (first.changes + second.changes + third.changes).map { "\($0.resource)|\($0.key)" }
        #expect(keys.count == all.changes.count)
        #expect(Set(keys).count == keys.count)
        #expect(try db.collectSaisieChanges(afterRev: all.maxRev!, limit: 10).changes.isEmpty)
    }

    @Test func pendingFollowsTheAckedRev() throws {
        let db = try makeDb()
        #expect(try db.hasPendingSaisieChanges())
        let batch = try db.collectSaisieChanges(afterRev: 0, limit: 10_000)
        _ = try db.applySaisieResponse(cursor: 1, changes: [], sentMaxRev: batch.maxRev, markInitialDone: true)
        #expect(try !db.hasPendingSaisieChanges())
        try db.upsertWeight(date: "2026-10-03", kg: 72)
        #expect(try db.hasPendingSaisieChanges())
    }
}

// MARK: - Application

struct SaisieApplyTests {
    private func apply(_ db: LocalDb, _ changes: [SaisieChange], cursor: Int = 7) throws -> LocalDb.SaisieApplyResult {
        try db.applySaisieResponse(cursor: cursor, changes: changes, sentMaxRev: nil, markInitialDone: false)
    }

    @Test func createsEveryResourceAndRewritesUpdatedAt() throws {
        let db = try makeDb()
        try db.db.run("INSERT INTO activities (file_hash, file_name) VALUES ('hash-act', 'a.fit')")
        let revBefore = try journal(db).values.map(\.rev).max() ?? 0
        let result = try apply(db, [
            // Ordre volontairement inversé : `foodLog` arrive avant son aliment.
            change("foodLog", "bbbb", at: 1_700_000_002_000, foodLogData(foodUid: "aaaa")),
            change("food", "aaaa", at: 1_700_000_001_000, foodData),
            change("weight", "2026-09-30", at: 1_700_000_003_000, ["kg": .double(70.5)]),
            change("setting", "sex", at: 1_700_000_004_000, ["value": .string("female")]),
            change("programme", "p9", at: 1_700_000_005_000, [
                "kind": .string("training"), "startedOn": .string("2026-10-05"), "active": .bool(true), "days": .string("2,4"),
                "plan": .array([.object(["week": .int(1), "session": .string("A"), "date": .string("2026-10-06")])]),
            ]),
            change("programmeDone", "p9|1|A", at: 1_700_000_006_000, ["date": .string("2026-10-06"), "activityFileHash": .string("hash-act")]),
        ])
        #expect(result.applied == 6 && result.skipped == 0)
        #expect(result.weightChanged)
        #expect(!result.wakeScheduleChanged)

        let foodId = try Int(scalar(db, "SELECT id FROM foods WHERE uid = 'aaaa'") ?? 0)
        #expect(foodId > 0)
        // `foodUid` résolu vers l'`id` local.
        #expect(try scalar(db, "SELECT food_id FROM food_log WHERE uid = 'bbbb'") == Double(foodId))
        #expect(try scalar(db, "SELECT unit_grams FROM foods WHERE uid = 'aaaa'") == 40)
        #expect(try scalar(db, "SELECT ts FROM food_log WHERE uid = 'bbbb'") == 1_790_000_100)
        #expect(try scalar(db, "SELECT kg FROM weight_log WHERE date = '2026-09-30'") == 70.5)
        #expect(try text(db, "SELECT value FROM settings WHERE key = 'sex'") == "female")
        #expect(try text(db, "SELECT days FROM programme_state WHERE programme_id = 'p9'") == "2,4")
        #expect(try scalar(db, "SELECT active FROM programme_state WHERE programme_id = 'p9'") == 1)
        #expect(try text(db, "SELECT date FROM programme_plan WHERE programme_id = 'p9' AND week = 1 AND session = 'A'") == "2026-10-06")
        #expect(try scalar(db, "SELECT activity_id FROM programme_done WHERE programme_id = 'p9'") == 1)

        // `updated_at` d'origine réécrit ; `rev` local avancé normalement.
        let entries = try journal(db)
        #expect(entries["food|aaaa"]?.updatedAt == 1_700_000_001_000)
        #expect(entries["foodLog|bbbb"]?.updatedAt == 1_700_000_002_000)
        #expect(entries["weight|2026-09-30"]?.updatedAt == 1_700_000_003_000)
        #expect(entries["setting|sex"]?.updatedAt == 1_700_000_004_000)
        #expect(entries["programme|p9"]?.updatedAt == 1_700_000_005_000)
        #expect(entries["programmeDone|p9|1|A"]?.updatedAt == 1_700_000_006_000)
        #expect(entries["food|aaaa"]!.rev > revBefore)
        #expect(try db.saisieSyncState().cursor == 7)
    }

    @Test func unknownFoodUidAndUnknownActivityHashResolveToNull() throws {
        let db = try makeDb()
        _ = try apply(db, [
            change("foodLog", "cccc", at: 10, foodLogData(foodUid: "inconnue")),
            change("programme", "p9", at: 10, ["kind": .string("training"), "startedOn": .string("2026-10-05"), "active": .bool(true), "days": .null, "plan": .array([])]),
            change("programmeDone", "p9|1|A", at: 10, ["date": .string("2026-10-06"), "activityFileHash": .string("jamais-vu")]),
        ])
        #expect(try scalar(db, "SELECT COUNT(*) FROM food_log WHERE uid = 'cccc'") == 1)
        #expect(try scalar(db, "SELECT food_id FROM food_log WHERE uid = 'cccc'") == nil)
        #expect(try scalar(db, "SELECT COUNT(*) FROM programme_done WHERE programme_id = 'p9'") == 1)
        #expect(try scalar(db, "SELECT activity_id FROM programme_done WHERE programme_id = 'p9'") == nil)
    }

    @Test func strictlyNewerAppliesOlderAndEqualAreIgnored() throws {
        let db = try makeDb()
        try db.upsertWeight(date: "2026-10-03", kg: 72)
        let local = try #require(try journal(db)["weight|2026-10-03"])

        // Égalité : le téléphone gagne.
        var result = try apply(db, [change("weight", "2026-10-03", at: local.updatedAt, ["kg": .double(80)])])
        #expect(result.applied == 0 && result.skipped == 1)
        #expect(try scalar(db, "SELECT kg FROM weight_log WHERE date = '2026-10-03'") == 72)

        // Plus ancien : ignoré.
        result = try apply(db, [change("weight", "2026-10-03", at: local.updatedAt - 1, ["kg": .double(80)])])
        #expect(result.applied == 0 && result.skipped == 1)
        #expect(try scalar(db, "SELECT kg FROM weight_log WHERE date = '2026-10-03'") == 72)
        #expect(try journal(db)["weight|2026-10-03"] == local)

        // Strictement plus récent : appliqué, `updated_at` reçu.
        result = try apply(db, [change("weight", "2026-10-03", at: local.updatedAt + 1, ["kg": .double(80)])])
        #expect(result.applied == 1 && result.skipped == 0)
        #expect(try scalar(db, "SELECT kg FROM weight_log WHERE date = '2026-10-03'") == 80)
        #expect(try journal(db)["weight|2026-10-03"]?.updatedAt == local.updatedAt + 1)
    }

    @Test func tombstonesFollowTheSameRule() throws {
        let db = try makeDb()
        try db.upsertWeight(date: "2026-10-03", kg: 72)
        let local = try #require(try journal(db)["weight|2026-10-03"])

        var result = try apply(db, [change("weight", "2026-10-03", at: local.updatedAt - 5, deleted: true)])
        #expect(result.applied == 0)
        #expect(try scalar(db, "SELECT COUNT(*) FROM weight_log WHERE date = '2026-10-03'") == 1)

        result = try apply(db, [change("weight", "2026-10-03", at: local.updatedAt + 5, deleted: true)])
        #expect(result.applied == 1)
        #expect(try scalar(db, "SELECT COUNT(*) FROM weight_log WHERE date = '2026-10-03'") == 0)
        let tomb = try #require(try journal(db)["weight|2026-10-03"])
        #expect(tomb.deleted && tomb.updatedAt == local.updatedAt + 5)

        // Une création plus ancienne que la pierre tombale ne ressuscite rien.
        result = try apply(db, [change("weight", "2026-10-03", at: local.updatedAt + 1, ["kg": .double(90)])])
        #expect(result.applied == 0)
        #expect(try scalar(db, "SELECT COUNT(*) FROM weight_log WHERE date = '2026-10-03'") == 0)

        // Pierre tombale d'une clé INCONNUE : rien à supprimer, mais elle est
        // journalisée (une création plus ancienne ne doit pas ressusciter la ligne).
        result = try apply(db, [change("weight", "2020-01-01", at: 500, deleted: true)])
        #expect(result.applied == 1)
        #expect(try journal(db)["weight|2020-01-01"]?.deleted == true)
        #expect(try journal(db)["weight|2020-01-01"]?.updatedAt == 500)
        result = try apply(db, [change("weight", "2020-01-01", at: 400, ["kg": .double(70)])])
        #expect(result.applied == 0)
        #expect(try scalar(db, "SELECT COUNT(*) FROM weight_log WHERE date = '2020-01-01'") == 0)
        // Clé mal formée : ignorée, rien au journal.
        result = try apply(db, [change("weight", "n'importe quoi", at: 5, deleted: true), change("setting", "ingestToken", at: 5, deleted: true)])
        #expect(result.applied == 0 && result.skipped == 2)
        #expect(try journal(db)["setting|ingestToken"] == nil)
    }

    @Test func modifiesAnExistingFoodAndLog() throws {
        let db = try makeDb()
        let food = try db.insertFood(barcode: nil, name: "Avant", kcal: 1, protein: 1, carbs: 1, fiber: 1, fat: 1, unitLabel: nil, unitGrams: nil)
        let foodUid = try uid(of: db, food: food.id)
        let local = try #require(try journal(db)["food|\(foodUid)"])
        var edited = foodData
        edited["name"] = .string("Après")
        _ = try apply(db, [change("food", foodUid, at: local.updatedAt + 10, edited)])
        #expect(try text(db, "SELECT name FROM foods WHERE id = ?", [.int(food.id)]) == "Après")
        #expect(try scalar(db, "SELECT COUNT(*) FROM foods WHERE uid = ?", [.text(foodUid)]) == 1)
        // Même ligne locale : l'`id` est conservé.
        #expect(try scalar(db, "SELECT id FROM foods WHERE uid = ?", [.text(foodUid)]) == Double(food.id))
    }

    @Test func programmeReplacesStateAndWholePlan() throws {
        let db = try makeDb()
        try db.debugActivateProgramme(programmeId: "p1", kind: "training", startedOn: "2026-10-05", days: "1,3")
        try db.debugInsertProgrammePlan(programmeId: "p1", week: 1, session: "A", date: "2026-10-05")
        try db.debugInsertProgrammePlan(programmeId: "p1", week: 1, session: "OLD", date: "2026-10-06")
        let local = try #require(try journal(db)["programme|p1"])

        _ = try apply(db, [change("programme", "p1", at: local.updatedAt + 100, [
            "kind": .string("training"), "startedOn": .string("2026-11-02"), "active": .bool(false), "days": .array([.int(2), .int(5)]),
            "plan": .array([
                .object(["week": .int(1), "session": .string("X"), "date": .string("2026-11-03")]),
                .object(["week": .int(2), "session": .string("Y"), "date": .string("2026-11-10")]),
            ]),
        ])])
        #expect(try text(db, "SELECT started_on FROM programme_state WHERE programme_id = 'p1'") == "2026-11-02")
        #expect(try scalar(db, "SELECT active FROM programme_state WHERE programme_id = 'p1'") == 0)
        #expect(try text(db, "SELECT days FROM programme_state WHERE programme_id = 'p1'") == "2,5")
        var sessions: [String] = []
        try db.db.run("SELECT session FROM programme_plan WHERE programme_id = 'p1' ORDER BY session") { r in sessions.append(r.text(0) ?? "") }
        #expect(sessions == ["X", "Y"])
        #expect(try journal(db)["programme|p1"]?.updatedAt == local.updatedAt + 100)
    }

    @Test func invalidOrForbiddenRowsAreSkippedWithoutFailingTheExchange() throws {
        let db = try makeDb()
        let result = try apply(db, [
            change("weight", "2026-10-03", at: 10, ["kg": .double(500)]),                      // hors bornes
            change("weight", "pas-une-date", at: 10, ["kg": .double(70)]),
            change("setting", "syncSource", at: 10, ["value": .string("phone")]),               // hors liste blanche
            change("setting", "ingestToken", at: 10, ["value": .string("x")]),
            change("setting", "sex", at: 10, ["value": .string("autre")]),                      // valeur invalide
            change("setting", "wakeSchedule", at: 10, ["value": .string("{\"9\":100}")]),
            change("food", "dddd", at: 10, ["name": .string("")]),
            change("ressourceInconnue", "k", at: 10, [:]),
            change("weight", "2026-10-04", at: 10, ["kg": .double(71)]),                        // celle-ci passe
        ])
        #expect(result.applied == 1)
        #expect(result.skipped == 8)
        #expect(try scalar(db, "SELECT COUNT(*) FROM weight_log") == 1)
        #expect(try text(db, "SELECT value FROM settings WHERE key = 'syncSource'") == nil)
        #expect(try text(db, "SELECT value FROM settings WHERE key = 'ingestToken'") == nil)
        #expect(try journal(db)["setting|syncSource"] == nil)
    }

    @Test func aBarcodeAlreadyHeldByAnotherFoodSkipsOnlyThatRow() throws {
        let db = try makeDb()
        _ = try db.insertFood(barcode: "999", name: "Local", kcal: nil, protein: nil, carbs: nil, fiber: nil, fat: nil, unitLabel: nil, unitGrams: nil)
        var clash = foodData
        clash["barcode"] = .string("999")
        let result = try apply(db, [
            change("food", "eeee", at: 10, clash),
            change("weight", "2026-10-04", at: 10, ["kg": .double(71)]),
        ])
        #expect(result.applied == 1 && result.skipped == 1)
        #expect(try scalar(db, "SELECT COUNT(*) FROM foods WHERE uid = 'eeee'") == 0)
    }

    @Test func flagsTellWhatToRefresh() throws {
        let db = try makeDb()
        var result = try apply(db, [change("setting", "wakeSchedule", at: 10, ["value": .string("{\"1\":420}")])])
        #expect(result.wakeScheduleChanged && !result.weightChanged)
        result = try apply(db, [change("setting", "weightKg", at: 10, ["value": .string("72")])])
        #expect(result.weightChanged && !result.wakeScheduleChanged)
        result = try apply(db, [change("setting", "heightCm", at: 10, ["value": .string("180")])])
        #expect(!result.weightChanged && !result.wakeScheduleChanged && result.applied == 1)
    }

    @Test func ackedRevSwallowsRowsWrittenByTheExchangeButNotConcurrentLocalEdits() throws {
        let db = try makeDb()
        let batch = try db.collectSaisieChanges(afterRev: 0, limit: 10_000)
        // Aucune édition locale entre l'envoi et l'application : les lignes écrites
        // par l'échange ne repartent pas en écho.
        _ = try db.applySaisieResponse(
            cursor: 3, changes: [change("weight", "2026-09-30", at: 10, ["kg": .double(70)])],
            sentMaxRev: batch.maxRev, markInitialDone: true)
        #expect(try !db.hasPendingSaisieChanges())
        #expect(try db.saisieSyncState() == LocalDb.SaisieSyncState(cursor: 3, ackedRev: try journal(db).values.map(\.rev).max()!, initialDone: true))

        // Une édition locale a eu lieu pendant l'échange (après l'envoi) : elle reste due.
        let sent = try db.collectSaisieChanges(afterRev: try db.saisieSyncState().ackedRev, limit: 10).maxRev
        try db.upsertWeight(date: "2026-10-05", kg: 73)
        _ = try db.applySaisieResponse(
            cursor: 4, changes: [change("weight", "2026-09-29", at: 10, ["kg": .double(69)])],
            sentMaxRev: sent, markInitialDone: true)
        #expect(try db.hasPendingSaisieChanges())
        let pending = try db.collectSaisieChanges(afterRev: try db.saisieSyncState().ackedRev, limit: 100).changes
        #expect(pending.contains { $0.key == "2026-10-05" })
    }

    @Test func aFailureRollsBackDataAndCursorTogether() throws {
        let db = try makeDb()
        try db.db.run("DROP TABLE programme_plan")   // fait échouer la ligne `programme` (hors contrainte)
        #expect(throws: (any Error).self) {
            try self.apply(db, [
                change("weight", "2026-09-30", at: 10, ["kg": .double(70)]),
                change("programme", "p9", at: 10, [
                    "kind": .string("training"), "startedOn": .string("2026-10-05"), "active": .bool(true), "days": .null, "plan": .array([]),
                ]),
            ], cursor: 99)
        }
        #expect(try scalar(db, "SELECT COUNT(*) FROM weight_log") == 0)
        #expect(try db.saisieSyncState().cursor == 0)
        #expect(try db.saisieSyncState().ackedRev == 0)
    }

    @Test func roundTripBetweenTwoBasesConverges() throws {
        let phone = try makeDb()
        let server = try makeDb()
        try phone.upsertWeight(date: "2026-10-03", kg: 72.4)
        try phone.setSetting(key: "wakeSchedule", value: "{\"1\":450}")
        let food = try phone.insertFood(barcode: "42", name: "Unique", kcal: 1, protein: 1, carbs: 1, fiber: 1, fat: 1, unitLabel: nil, unitGrams: nil)
        _ = try insertLog(phone, foodId: food.id, name: "Unique")

        let batch = try phone.collectSaisieChanges(afterRev: 0, limit: 10_000)
        let result = try server.applySaisieResponse(cursor: 0, changes: batch.changes, sentMaxRev: nil, markInitialDone: false)
        #expect(result.skipped == 0 || result.skipped < batch.changes.count)

        #expect(try scalar(server, "SELECT kg FROM weight_log WHERE date = '2026-10-03'") == 72.4)
        #expect(try text(server, "SELECT value FROM settings WHERE key = 'wakeSchedule'") == "{\"1\":450}")
        let logFood = try text(server, "SELECT f.name FROM food_log l JOIN foods f ON f.id = l.food_id WHERE l.name = 'Unique'")
        #expect(logFood == "Unique")
    }
}
