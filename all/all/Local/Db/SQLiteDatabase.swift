//
//  SQLiteDatabase.swift
//  all (bridge-connect)
//
//  Encapsulation minimale de l'API C `sqlite3` — SQLite SYSTÈME
//  (`libsqlite3.tbd`, lié via `OTHER_LDFLAGS = -lsqlite3`), PAS de paquet SPM
//  (règle réseau de CLAUDE.md : aucune dépendance qui télécharge). Couvre
//  juste ce dont `LocalDb` a besoin : exécuter du SQL, préparer une requête,
//  lier des paramètres positionnels (`?`), itérer les lignes résultat,
//  transaction. Incrément L1, cf. `docs/stockage-local.md`.
//

import Foundation
import SQLite3

enum SQLiteValue {
    case text(String)
    case double(Double)
    case int(Int)
    case null
}

/// Vue en lecture d'une ligne résultat courante — valide seulement dans le
/// closure `row` de `SQLiteDatabase.run`, jamais conservée au-delà (le
/// pointeur de `sqlite3_stmt` sous-jacent est finalisé juste après).
struct SQLiteRow {
    fileprivate let stmt: OpaquePointer

    func text(_ index: Int32) -> String? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL else { return nil }
        guard let cString = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: cString)
    }

    func double(_ index: Int32) -> Double? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL else { return nil }
        return sqlite3_column_double(stmt, index)
    }
}

final class SQLiteDatabase {
    enum SQLiteError: Error, LocalizedError {
        case open(String)
        case prepare(String)
        case step(String)

        var errorDescription: String? {
            switch self {
            case .open(let m), .prepare(let m), .step(let m): return m
            }
        }
    }

    private let handle: OpaquePointer

    init(path: String) throws {
        var db: OpaquePointer?
        // FULLMUTEX : sérialise l'accès — `LocalIngestor` (tâche de fond) et
        // `RealLocalPulseBackend` (appelé depuis les écrans) peuvent taper la
        // même base depuis des files différentes ; un seul `SQLiteDatabase`
        // partagé suffit à ce stade (L1), SQLite fait le reste.
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(path, &db, flags, nil)
        guard rc == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "sqlite3_open_v2 a échoué (\(rc))"
            if let db { sqlite3_close(db) }
            throw SQLiteError.open(message)
        }
        handle = db
        sqlite3_exec(handle, "PRAGMA journal_mode = WAL;", nil, nil, nil)
    }

    deinit { sqlite3_close(handle) }

    func execute(_ sql: String) throws {
        if sqlite3_exec(handle, sql, nil, nil, nil) != SQLITE_OK {
            throw SQLiteError.step(String(cString: sqlite3_errmsg(handle)))
        }
    }

    /// Prépare, lie les paramètres (dans l'ordre, `?` positionnels), exécute
    /// jusqu'à épuisement des lignes, transmet chaque ligne à `row`. Sert
    /// aussi bien pour un INSERT/UPDATE (aucune ligne) qu'un SELECT.
    @discardableResult
    func run(_ sql: String, _ params: [SQLiteValue] = [], row: ((SQLiteRow) -> Void)? = nil) throws -> Int {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw SQLiteError.prepare(String(cString: sqlite3_errmsg(handle)) + " — SQL: \(sql)")
        }
        defer { sqlite3_finalize(stmt) }

        for (index, value) in params.enumerated() {
            let i = Int32(index + 1)
            switch value {
            case .text(let s):
                sqlite3_bind_text(stmt, i, s, -1, SQLiteDatabase.transientDestructor)
            case .double(let d):
                sqlite3_bind_double(stmt, i, d)
            case .int(let n):
                sqlite3_bind_int64(stmt, i, Int64(n))
            case .null:
                sqlite3_bind_null(stmt, i)
            }
        }

        var rowCount = 0
        let view = SQLiteRow(stmt: stmt)
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW {
                rowCount += 1
                row?(view)
            } else if rc == SQLITE_DONE {
                break
            } else {
                throw SQLiteError.step(String(cString: sqlite3_errmsg(handle)) + " — SQL: \(sql)")
            }
        }
        return rowCount
    }

    /// `body` exécute plusieurs `run` ; rollback automatique si `body` lève.
    func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try body()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    /// `SQLITE_TRANSIENT` : indique à SQLite de copier la chaîne immédiatement
    /// (elle vient d'un `String` Swift éphémère) — idiome standard d'appel de
    /// l'API C sqlite3 depuis Swift.
    private static let transientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}
