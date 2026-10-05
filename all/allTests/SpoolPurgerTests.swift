//
//  SpoolPurgerTests.swift
//  allTests
//
//  Purge du spool (`Spool/SpoolPurger.swift`) : sélection pure (chaque condition
//  prise isolément empêche la purge), exécuteur (dernière vérification disque +
//  base avant suppression) et cadence de 24 h. Fichiers FIT synthétiques
//  (`syntheticFit`, cf. `SpoolIngestProofTests.swift`), spool et base temporaires.
//

import Testing
import Foundation
@testable import all

// MARK: - Sélection pure

struct SpoolPurgerSelectionTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let old = Date(timeIntervalSince1970: 1_800_000_000 - 25 * 3600)
    private let recent = Date(timeIntervalSince1970: 1_800_000_000 - 23 * 3600)

    /// Entrée qui satisfait TOUTES les conditions ; chaque test en dégrade une.
    private func purgeable(
        type: Int = GarminFileType.monitor.watchFileType, state: SpoolState = .archived,
        archivedAt: Date? = nil, ingest: SpoolIngestOutcome? = nil, pushed: Bool = true,
        purgedAt: Date? = nil, index: Int = 1
    ) -> SpoolEntry {
        SpoolEntry(
            id: WatchFileID(fileType: type, index: index, name: "f\(index).fit"), state: state,
            acquiredAt: old, deliveredAt: old, archivedAt: archivedAt ?? old, relativePath: "T/f\(index).fit",
            pushedToPulse: pushed,
            ingest: ingest ?? SpoolIngestOutcome(status: .ingested, hash: "h", at: old), purgedAt: purgedAt)
    }

    private func select(_ entries: [SpoolEntry], pulseConfigured: Bool = true) -> [Int] {
        SpoolPurger.selectPurgeable(from: entries, now: now, pulseConfigured: pulseConfigured).map(\.id.index)
    }

    @Test func aFullyEligibleEntryIsSelected() {
        #expect(select([purgeable()]) == [1])
        #expect(select([purgeable(type: GarminFileType.sleep.watchFileType)]) == [1])
    }

    @Test func condition1_anAlreadyPurgedEntryIsNotSelectedAgain() {
        #expect(select([purgeable(purgedAt: old)]).isEmpty)
    }

    @Test func condition2_onlyMonitorAndSleepAreInTheWhitelist() {
        #expect(select([purgeable(type: GarminFileType.activity.watchFileType)]).isEmpty, "une activité n'est JAMAIS purgée")
        #expect(select([purgeable(type: GarminFileTypeKey(dataType: 128, subType: 28).watchFileType)]).isEmpty, "MONITOR_DAILY hors liste blanche")
        #expect(select([purgeable(type: GarminFileTypeKey(dataType: 255, subType: 244).watchFileType)]).isEmpty)
        #expect(select([purgeable(type: 99_999)]).isEmpty, "type inconnu")
    }

    @Test func condition3_mustBeArchivedForAtLeast24h() {
        #expect(select([purgeable(state: .delivered)]).isEmpty)
        #expect(select([purgeable(state: .acquired)]).isEmpty)
        #expect(select([purgeable(archivedAt: recent)]).isEmpty)
        // Pile 24 h : suffisant.
        #expect(select([purgeable(archivedAt: now.addingTimeInterval(-24 * 3600))]) == [1])
        // Archivée mais sans horodatage : pas de preuve d'ancienneté.
        var noDate = purgeable()
        noDate.archivedAt = nil
        #expect(select([noDate]).isEmpty)
    }

    @Test func condition4_theProofMustExistBeIngestedOrSkippedAndOldEnough() {
        var noProof = purgeable()
        noProof.ingest = nil
        #expect(select([noProof]).isEmpty)
        #expect(select([purgeable(ingest: SpoolIngestOutcome(status: .failed, hash: "h", at: old))]).isEmpty, "jamais un échec")
        #expect(select([purgeable(ingest: SpoolIngestOutcome(status: .skipped, hash: "h", at: old))]) == [1])
        #expect(select([purgeable(ingest: SpoolIngestOutcome(status: .ingested, hash: "h", at: recent))]).isEmpty)
        #expect(select([purgeable(ingest: SpoolIngestOutcome(status: .skipped, hash: "h", at: recent))]).isEmpty)
    }

    @Test func condition5_pushedToPulseOrNoPulseConfigured() {
        #expect(select([purgeable(pushed: false)], pulseConfigured: true).isEmpty)
        #expect(select([purgeable(pushed: false)], pulseConfigured: false) == [1])
        #expect(select([purgeable(pushed: true)], pulseConfigured: true) == [1])
    }

    @Test func selectionKeepsOnlyTheEligibleOnesInAcquisitionOrder() {
        let entries = [
            purgeable(index: 3),
            purgeable(state: .delivered, index: 2),
            purgeable(index: 1),
        ]
        #expect(select(entries) == [1, 3])
    }

    @Test func theWhitelistIsExactlyMonitorAndSleep() {
        #expect(SpoolPurger.purgeableFileTypes == [GarminFileType.monitor.watchFileType, GarminFileType.sleep.watchFileType])
        #expect(GarminFileType.monitor.watchFileType == (128 << 8) | 32)
        #expect(GarminFileType.sleep.watchFileType == (128 << 8) | 49)
    }
}

// MARK: - Exécuteur

struct SpoolPurgerExecutionTests {
    private let future = Date().addingTimeInterval(48 * 3600)

    private struct Rig {
        let store: SpoolStore
        let root: URL
        let db: LocalDb
    }

    private func makeRig() throws -> Rig {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bridge-connect-purge-\(UUID().uuidString)", isDirectory: true)
        let dbPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("purge-\(UUID().uuidString).sqlite").path
        return Rig(store: try SpoolStore(root: root), root: root, db: try LocalDb(path: dbPath))
    }

    /// Acquiert, livre, ingère puis archive un fichier — l'état d'une entrée prête
    /// à être purgée (une fois `future` écoulé).
    private func archivedAndIngested(_ rig: Rig, data: Data, type: Int = GarminFileType.monitor.watchFileType, index: Int = 1) throws -> SpoolEntry {
        let id = WatchFileID(fileType: type, index: index, name: "f\(index).fit")
        try rig.store.recordAcquired(id, relativePath: "T/f\(index).fit", data: data)
        rig.store.markDelivered(id)
        rig.store.markPushedToPulse(id)
        rig.store.markArchived(id)
        _ = LocalIngestor.ingestPending(from: rig.store, into: rig.db)
        return try #require(rig.store.entries[id])
    }

    private func candidates(_ rig: Rig) -> [SpoolEntry] {
        SpoolPurger.selectPurgeable(from: Array(rig.store.entries.values), now: future, pulseConfigured: true)
    }

    @Test func nominalCaseDeletesTheFileKeepsTheEntryAndNeverRedownloadsIt() throws {
        let rig = try makeRig()
        defer { try? FileManager.default.removeItem(at: rig.root) }
        let entry = try archivedAndIngested(rig, data: syntheticFit(fileType: 32))
        let url = rig.store.fileURL(for: entry)
        #expect(entry.ingest?.status == .ingested)
        #expect(FileManager.default.fileExists(atPath: url.path))

        let report = SpoolPurger.execute(candidates(rig), spool: rig.store, db: rig.db)

        #expect(report.purged == 1)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        let kept = try #require(rig.store.entries[entry.id])
        #expect(kept.purgedAt != nil)
        #expect(kept.state == .archived)
        #expect(kept.ingest?.status == .ingested)
        #expect(rig.store.pendingAcquisition(from: [entry.id]).isEmpty, "l'entrée empêche un re-téléchargement")
        // Plus jamais candidate ni retraitée.
        #expect(candidates(rig).isEmpty)
        #expect(LocalIngestor.ingestPending(from: rig.store, into: rig.db).results.isEmpty)
    }

    @Test func aDifferentFileHashDeletesNothingAndClearsTheProof() throws {
        let rig = try makeRig()
        defer { try? FileManager.default.removeItem(at: rig.root) }
        let entry = try archivedAndIngested(rig, data: syntheticFit(fileType: 32))
        let url = rig.store.fileURL(for: entry)
        try syntheticFit(fileType: 32, salt: 7).write(to: url) // octets différents de ceux qui ont été ingérés

        let report = SpoolPurger.execute(candidates(rig), spool: rig.store, db: rig.db)

        #expect(report.purged == 0)
        #expect(report.reingestDue == 1)
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(rig.store.entries[entry.id]?.ingest == nil, "sera ré-ingérée")
        #expect(rig.store.entries[entry.id]?.purgedAt == nil)
    }

    @Test func aHashMissingFromTheDatabaseDeletesNothingAndClearsTheProof() throws {
        let rig = try makeRig()
        defer { try? FileManager.default.removeItem(at: rig.root) }
        let entry = try archivedAndIngested(rig, data: syntheticFit(fileType: 32))
        let url = rig.store.fileURL(for: entry)
        let emptyDb = try LocalDb(path: FileManager.default.temporaryDirectory.appendingPathComponent("empty-\(UUID().uuidString).sqlite").path)

        let report = SpoolPurger.execute(candidates(rig), spool: rig.store, db: emptyDb)

        #expect(report.purged == 0)
        #expect(report.reingestDue == 1)
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(rig.store.entries[entry.id]?.ingest == nil)
    }

    /// `skipped` : rien en base à confirmer, seule l'identité du fichier compte.
    @Test func aSkippedFileIsPurgedWithoutADatabaseCheck() throws {
        let rig = try makeRig()
        defer { try? FileManager.default.removeItem(at: rig.root) }
        let entry = try archivedAndIngested(rig, data: syntheticFit(fileType: 49), type: GarminFileType.sleep.watchFileType)
        #expect(entry.ingest?.status == .skipped)
        let emptyDb = try LocalDb(path: FileManager.default.temporaryDirectory.appendingPathComponent("empty-\(UUID().uuidString).sqlite").path)

        let report = SpoolPurger.execute(candidates(rig), spool: rig.store, db: emptyDb)

        #expect(report.purged == 1)
        #expect(!FileManager.default.fileExists(atPath: rig.store.fileURL(for: entry).path))
    }

    @Test func anAlreadyMissingFileJustGetsMarkedPurged() throws {
        let rig = try makeRig()
        defer { try? FileManager.default.removeItem(at: rig.root) }
        let entry = try archivedAndIngested(rig, data: syntheticFit(fileType: 32))
        try FileManager.default.removeItem(at: rig.store.fileURL(for: entry))

        let report = SpoolPurger.execute(candidates(rig), spool: rig.store, db: rig.db)

        #expect(report.purged == 1)
        #expect(rig.store.entries[entry.id]?.purgedAt != nil)
        #expect(rig.store.entries[entry.id]?.ingest?.status == .ingested, "la preuve n'est pas touchée")
    }

    /// Un fichier relu entre la sélection et la suppression est un autre contenu :
    /// le jeton d'acquisition l'empêche d'être supprimé.
    @Test func aFileReadAgainAfterSelectionIsNotDeleted() throws {
        let rig = try makeRig()
        defer { try? FileManager.default.removeItem(at: rig.root) }
        let entry = try archivedAndIngested(rig, data: syntheticFit(fileType: 32))
        let selected = candidates(rig)
        let id = WatchFileID(fileType: entry.id.fileType, index: 1, name: entry.id.name)
        try rig.store.recordAcquired(id, relativePath: entry.relativePath, data: syntheticFit(fileType: 32, salt: 3))

        #expect(rig.store.purgeFile(entry.id, expectedAcquiredAt: selected[0].acquiredAt) == false)
        #expect(FileManager.default.fileExists(atPath: rig.store.fileURL(for: entry).path))
        #expect(rig.store.entries[entry.id]?.purgedAt == nil)
    }

    @Test func anActivityIsNeverTouchedEvenWhenEverythingElseIsMet() throws {
        let rig = try makeRig()
        defer { try? FileManager.default.removeItem(at: rig.root) }
        let entry = try archivedAndIngested(rig, data: syntheticFit(fileType: 4), type: GarminFileType.activity.watchFileType)

        #expect(candidates(rig).isEmpty)
        let report = SpoolPurger.runIfDue(spool: rig.store, db: rig.db, pulseConfigured: true, now: future, defaults: UserDefaults(suiteName: "purge-\(UUID().uuidString)")!)
        #expect(report?.purged == 0)
        #expect(FileManager.default.fileExists(atPath: rig.store.fileURL(for: entry).path))
    }
}

// MARK: - Cadence

struct SpoolPurgerCadenceTests {
    private func defaults() -> UserDefaults {
        let suite = "bridge-connect-purge-cadence-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test func isDueOnlyEvery24Hours() {
        let defaults = defaults()
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(SpoolPurger.isDue(now: t0, defaults: defaults), "jamais lancée")

        defaults.set(t0, forKey: SpoolPurger.lastRunDefaultsKey)
        #expect(!SpoolPurger.isDue(now: t0.addingTimeInterval(3600), defaults: defaults))
        #expect(!SpoolPurger.isDue(now: t0.addingTimeInterval(24 * 3600 - 1), defaults: defaults))
        #expect(SpoolPurger.isDue(now: t0.addingTimeInterval(24 * 3600), defaults: defaults))
        #expect(SpoolPurger.isDue(now: t0.addingTimeInterval(-3600), defaults: defaults), "horloge reculée : pas de blocage")
    }

    @Test func runIfDueRunsOncePer24Hours() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bridge-connect-purge-cadence-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SpoolStore(root: root)
        let db = try LocalDb(path: FileManager.default.temporaryDirectory.appendingPathComponent("cadence-\(UUID().uuidString).sqlite").path)
        let defaults = defaults()
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)

        #expect(SpoolPurger.runIfDue(spool: store, db: db, pulseConfigured: true, now: t0, defaults: defaults) != nil)
        #expect(SpoolPurger.runIfDue(spool: store, db: db, pulseConfigured: true, now: t0.addingTimeInterval(3600), defaults: defaults) == nil)
        #expect(SpoolPurger.runIfDue(spool: store, db: db, pulseConfigured: true, now: t0.addingTimeInterval(25 * 3600), defaults: defaults) != nil)
    }
}
