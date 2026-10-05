//
//  LocalDbMigrationTests.swift
//  allTests
//
//  Valide le socle de la base locale : migrations de schéma ordonnées
//  (`LocalDb.migrate`, `PRAGMA user_version`) et attente entre deux connexions
//  vers le même fichier (`busy_timeout`, `SQLiteDatabase.init`).
//

import Testing
import Foundation
@testable import all

struct LocalDbMigrationTests {
    private func tempPath() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("localdb-migration-tests-\(UUID().uuidString).sqlite").path
    }

    private func columns(_ db: SQLiteDatabase, table: String) throws -> [String] {
        var names: [String] = []
        try db.run("PRAGMA table_info(\(table))") { r in
            if let name = r.text(1) { names.append(name) }
        }
        return names
    }

    @Test func migrationsApplyInOrderAndOnlyOnce() throws {
        let path = tempPath()
        let db = try SQLiteDatabase(path: path)
        try db.execute("CREATE TABLE t (id INTEGER PRIMARY KEY)")
        let first = ["ALTER TABLE t ADD COLUMN a TEXT"]
        try LocalDb.migrate(db, migrations: first)
        #expect(try LocalDb.schemaVersion(db) == 1)

        // Rouvrir avec une migration de plus : seule la nouvelle est appliquée
        // (rejouer la première lèverait « duplicate column name »).
        let reopened = try SQLiteDatabase(path: path)
        try LocalDb.migrate(reopened, migrations: first + ["ALTER TABLE t ADD COLUMN b TEXT"])
        #expect(try LocalDb.schemaVersion(reopened) == 2)
        #expect(try columns(reopened, table: "t") == ["id", "a", "b"])

        try LocalDb.migrate(reopened, migrations: first + ["ALTER TABLE t ADD COLUMN b TEXT"])
        #expect(try LocalDb.schemaVersion(reopened) == 2)
    }

    @Test func failedMigrationLeavesVersionUntouched() throws {
        let db = try SQLiteDatabase(path: tempPath())
        try db.execute("CREATE TABLE t (id INTEGER PRIMARY KEY)")
        let migrations = ["ALTER TABLE t ADD COLUMN a TEXT", "ALTER TABLE absente ADD COLUMN x TEXT"]
        #expect(throws: (any Error).self) { try LocalDb.migrate(db, migrations: migrations) }
        #expect(try LocalDb.schemaVersion(db) == 1)
        #expect(try columns(db, table: "t") == ["id", "a"])
    }

    @Test func freshLocalDbIsAtCurrentSchemaVersion() throws {
        let path = tempPath()
        _ = try LocalDb(path: path)
        let db = try SQLiteDatabase(path: path)
        #expect(try LocalDb.schemaVersion(db) == LocalDb.migrations.count)
    }

    /// Une écriture attend la fin de la transaction d'une AUTRE connexion au
    /// lieu d'échouer en « database is locked ».
    @Test func writeWaitsForAnotherConnectionsTransaction() async throws {
        let path = tempPath()
        let first = try SQLiteDatabase(path: path)
        try first.execute("CREATE TABLE t (id INTEGER PRIMARY KEY)")
        let second = try SQLiteDatabase(path: path)

        try first.execute("BEGIN IMMEDIATE")
        try first.run("INSERT INTO t (id) VALUES (1)")
        let release = Task.detached {
            try await Task.sleep(for: .milliseconds(300))
            try first.execute("COMMIT")
        }
        try second.run("INSERT INTO t (id) VALUES (2)")
        try await release.value

        var count = 0
        try second.run("SELECT COUNT(*) FROM t") { r in count = Int(r.double(0) ?? 0) }
        #expect(count == 2)
    }
}
