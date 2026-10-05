//
//  LocalStorageUsageTests.swift
//  allTests
//
//  Mesure de la place occupée (Paramètres › Stockage) sur des dossiers
//  temporaires — jamais ceux de l'app.
//

import Testing
import Foundation
@testable import all

struct LocalStorageUsageTests {
    private func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("storage-usage-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func countsWatchFilesInSubfoldersAndDatabaseWithItsJournals() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let spool = root.appendingPathComponent("spool")
        let files = spool.appendingPathComponent("files/MONITOR/2026")
        let database = root.appendingPathComponent("local-pulse")
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: database, withIntermediateDirectories: true)
        try Data(count: 1000).write(to: files.appendingPathComponent("a.fit"))
        try Data(count: 500).write(to: files.appendingPathComponent("b.fit"))
        // Le journal du spool n'est pas un fichier de la montre.
        try Data(count: 70).write(to: spool.appendingPathComponent("journal.json"))
        try Data(count: 4000).write(to: database.appendingPathComponent("pulse-embarque.sqlite"))
        try Data(count: 300).write(to: database.appendingPathComponent("pulse-embarque.sqlite-wal"))

        let usage = LocalStorageUsage.measure(spoolRoot: spool, databaseRoot: database)
        #expect(usage.watchFileCount == 2)
        #expect(usage.watchFileBytes == 1500)
        #expect(usage.databaseBytes == 4300)
        #expect(usage.totalBytes == 5800)
    }

    @Test func freshDatabaseCountsNothing() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let db = try LocalDb(path: root.appendingPathComponent("t.sqlite").path)
        #expect(try db.contentCounts() == LocalDb.ContentCounts())
    }

    @Test func missingFoldersMeasureAsEmpty() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let usage = LocalStorageUsage.measure(
            spoolRoot: root.appendingPathComponent("absent"), databaseRoot: root.appendingPathComponent("absent-aussi"))
        #expect(usage == LocalStorageUsage())
    }
}
