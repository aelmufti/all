//
//  LocalDataPurgeTests.swift
//  allTests
//
//  Purge des données de l'iPhone (Paramètres › Stockage) : décisions pures
//  (`Spool/LocalPurgePlanner.swift`), exécuteur (`Spool/LocalDataPurge.swift`) et
//  vidage de la base (`LocalDb.purgeAllData`). Bases et spools TEMPORAIRES, fichiers
//  FIT synthétiques (`syntheticFit`, cf. `SpoolIngestProofTests.swift`) ; aucun
//  réseau, jamais les vraies données de l'app.
//

import Testing
import Foundation
@testable import all

// MARK: - Aides

private let monitorType = GarminFileType.monitor.watchFileType
private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func tempPath() -> String {
    FileManager.default.temporaryDirectory.appendingPathComponent("local-purge-tests-\(UUID().uuidString).sqlite").path
}

private func scalar(_ db: LocalDb, _ sql: String, _ params: [SQLiteValue] = []) throws -> Double {
    var value = 0.0
    try db.db.run(sql, params) { r in value = r.double(0) ?? 0 }
    return value
}

private func count(_ db: LocalDb, _ table: String) throws -> Int {
    Int(try scalar(db, "SELECT COUNT(*) FROM \"\(table)\""))
}

private func tableNames(_ db: LocalDb) throws -> [String] {
    var names: [String] = []
    try db.db.run("SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'") { r in
        if let name = r.text(0) { names.append(name) }
    }
    return names
}

/// Marque tout le journal des saisies comme accusé (comme un échange réussi).
private func acknowledgeAllSaisies(_ db: LocalDb) throws {
    let batch = try db.collectSaisieChanges(afterRev: 0, limit: 100_000)
    _ = try db.applySaisieResponse(cursor: 7, changes: [], sentMaxRev: batch.maxRev, markInitialDone: true)
}

private func seededFoodId(_ db: LocalDb, name: String) throws -> Int {
    var id = 0
    try db.db.run("SELECT id FROM foods WHERE name = ?", [.text(name)]) { r in id = Int(r.double(0) ?? 0) }
    return id
}

private func saisie(_ resource: String, _ key: String = "k", deleted: Bool = false, food: LocalPurgePlanner.FoodSignature? = nil) -> LocalPurgePlanner.PendingSaisie {
    LocalPurgePlanner.PendingSaisie(resource: resource, key: key, deleted: deleted, food: food)
}

private func signature(_ name: String, kcal: Double? = 100) -> LocalPurgePlanner.FoodSignature {
    LocalPurgePlanner.FoodSignature(
        name: name, kcal: kcal, protein: 1, carbs: 2, fiber: 3, fat: 4, unitLabel: "pot", unitGrams: 100)
}

private func entry(
    _ index: Int, state: SpoolState = .delivered, pushed: Bool = true, rejected: Bool = false, purged: Bool = false,
    ingest: SpoolIngestOutcome? = nil
) -> SpoolEntry {
    SpoolEntry(
        id: WatchFileID(fileType: monitorType, index: index, name: "f\(index).fit"), state: state,
        acquiredAt: t0.addingTimeInterval(Double(index)), deliveredAt: t0, archivedAt: state == .archived ? t0 : nil,
        relativePath: "MONITOR/f\(index).fit", pushedToPulse: pushed, ingest: ingest,
        purgedAt: purged ? t0 : nil, pulseRejectedAt: rejected ? t0 : nil)
}

// MARK: - Décisions pures

struct LocalPurgePlannerTests {
    @Test func unmodifiedSeedFoodsDoNotCountButEverythingElseDoes() {
        let seeds: Set = [signature("Skyr"), signature("Banane")]
        let pending = [
            saisie("food", "a", food: signature("Skyr")),
            saisie("food", "b", food: signature("Banane")),
            saisie("food", "c", food: signature("Skyr", kcal: 99)),   // modifié
            saisie("food", "d", food: signature("Pain maison")),       // créé par l'utilisateur
            saisie("food", "e", deleted: true),                        // supprimé : pierre tombale
            saisie("food", "f", food: nil),                            // scanné (code-barres) ou ligne absente
            saisie("foodLog"), saisie("weight"), saisie("setting"), saisie("programme"), saisie("programmeDone"),
        ]
        #expect(LocalPurgePlanner.blockingSaisieCount(pending: pending, seeds: seeds) == 4 + 5)
        #expect(LocalPurgePlanner.blockingSaisieCount(pending: [], seeds: seeds) == 0)
        #expect(LocalPurgePlanner.blockingSaisieCount(pending: Array(pending.prefix(2)), seeds: seeds) == 0)
    }

    @Test func aDeletedSeedIsNeverTreatedAsAnUnmodifiedSeed() {
        // Même si une empreinte accompagnait la pierre tombale, la suppression est un acte de l'utilisateur.
        let seeds: Set = [signature("Skyr")]
        #expect(LocalPurgePlanner.blockingSaisieCount(pending: [saisie("food", deleted: true, food: signature("Skyr"))], seeds: seeds) == 1)
    }

    @Test func onlyDeliveredNonQuarantinedPushedFilesAreDeletable() {
        let all = [
            entry(1),                               // poussé → effacé
            entry(2, state: .archived),             // poussé, archivé → effacé
            entry(3, pushed: false),                // jamais reçu par Pulse → gardé
            entry(4, pushed: false, rejected: true), // quarantaine → gardé
            entry(5, rejected: true),               // poussé mais en quarantaine → gardé
            entry(6, state: .acquired),             // livraison pas terminée → gardé
            entry(7, purged: true),                 // déjà effacé
        ]
        #expect(LocalPurgePlanner.selectDeletable(from: all).map(\.id.index) == [1, 2])
        #expect(LocalPurgePlanner.keptFileCount(in: all) == 4)
    }

    @Test func selectionIsInAcquisitionOrder() {
        #expect(LocalPurgePlanner.selectDeletable(from: [entry(3), entry(1), entry(2)]).map(\.id.index) == [1, 2, 3])
    }

    @Test func keptFilesLoseTheirProofButDeletedAndPurgedOnesAreLeftAlone() {
        let proof = SpoolIngestOutcome(status: .ingested, hash: "h", at: t0)
        let all = [
            entry(1, ingest: proof),                              // effacé : pas concerné
            entry(2, pushed: false, ingest: proof),               // gardé avec preuve → à ré-ingérer
            entry(3, pushed: false),                              // gardé sans preuve → rien à effacer
            entry(4, rejected: true, ingest: proof),              // quarantaine → à ré-ingérer
            entry(5, pushed: false, purged: true, ingest: proof), // déjà purgé : jamais ré-ingéré
        ]
        #expect(LocalPurgePlanner.selectKeptNeedingReingest(from: all).map(\.id.index) == [2, 4])
    }

    @Test func aDeletedEntryEndsUpWithAProofTheArchiveCheckAccepts() {
        let ingested = SpoolIngestOutcome(status: .ingested, hash: "h", at: t0)
        let failed = SpoolIngestOutcome(status: .failed, hash: "h", at: t0)
        let skipped = SpoolIngestOutcome(status: .skipped, hash: "h", at: t0)
        let now = t0.addingTimeInterval(60)

        // Pas encore archivée sur la montre : `ingested` serait infirmée par la base vidée.
        let replaced = LocalPurgePlanner.proofBeforeDeletion(for: entry(1, state: .delivered, ingest: ingested), now: now)
        #expect(replaced == SpoolIngestOutcome(status: .skipped, hash: "h", at: now))
        // Sans preuve : il en faut une, sinon l'archivage attend une ingestion qui n'aura jamais lieu.
        #expect(LocalPurgePlanner.proofBeforeDeletion(for: entry(2, state: .delivered), now: now)
                == SpoolIngestOutcome(status: .skipped, hash: "", at: now))
        #expect(LocalPurgePlanner.proofBeforeDeletion(for: entry(3, state: .delivered, ingest: failed), now: now)?.status == .skipped)
        // Déjà `skipped`, ou archivée avec une preuve non fautive : rien à changer.
        #expect(LocalPurgePlanner.proofBeforeDeletion(for: entry(4, state: .delivered, ingest: skipped), now: now) == nil)
        #expect(LocalPurgePlanner.proofBeforeDeletion(for: entry(5, state: .archived, ingest: ingested), now: now) == nil)
        // Archivée mais en échec : le compteur d'échecs ne doit pas garder un fichier disparu.
        #expect(LocalPurgePlanner.proofBeforeDeletion(for: entry(6, state: .archived, ingest: failed), now: now)?.status == .skipped)
    }

    @Test func measuresOnlyInTheDatabaseAreEntriesPurgedWithoutPulse() {
        let all = [
            entry(1, pushed: false, purged: true),                  // effacé sans passer par Pulse
            entry(2, pushed: true, purged: true),                   // Pulse l'a
            entry(3, pushed: false),                                // encore sur disque
            entry(4, pushed: false, rejected: true, purged: true),  // quarantaine : n'est jamais purgé, par prudence on l'exclut
        ]
        #expect(LocalPurgePlanner.measuresOnlyInDatabaseCount(in: all) == 1)
    }

    @Test func blockersListSaisiesFirstAndPhraseThemShort() {
        let seeds: Set = [signature("Skyr")]
        let none = LocalPurgePlanner.blockers(entries: [entry(1)], pending: [saisie("food", food: signature("Skyr"))], seeds: seeds)
        #expect(none.isEmpty)

        let both = LocalPurgePlanner.blockers(
            entries: [entry(1, pushed: false, purged: true)], pending: [saisie("weight"), saisie("weight", "x")], seeds: seeds)
        #expect(both == [.unsentSaisies(2), .measuresOnlyOnPhone(1)])
        #expect(LocalPurgePlanner.Blocker.unsentSaisies(1).message == "1 saisie pas encore sur Pulse")
        #expect(LocalPurgePlanner.Blocker.unsentSaisies(3).message == "3 saisies pas encore sur Pulse")
        #expect(LocalPurgePlanner.Blocker.measuresOnlyOnPhone(1).message == "1 fichier de la montre seulement sur l'iPhone")
        #expect(LocalPurgePlanner.reason(for: both) == "2 saisies pas encore sur Pulse · 1 fichier de la montre seulement sur l'iPhone")
    }

    /// Les empreintes de départ sont celles des lignes réellement semées : une base
    /// neuve, dont tout le journal est « en attente », ne compte aucune saisie.
    @Test func aFreshDatabaseHasPendingChangesButNoUserSaisie() throws {
        let db = try LocalDb(path: tempPath())
        let pending = try db.pendingSaisies()
        #expect(pending.count > 50, "le piège existe : tout le journal est en attente")
        #expect(pending.allSatisfy { $0.resource == "food" && !$0.deleted && $0.food != nil })
        #expect(LocalPurgePlanner.blockingSaisieCount(pending: pending, seeds: LocalDb.seedFoodSignatures) == 0)
    }
}

// MARK: - Blocage sur de vraies bases

struct LocalDataPurgeBlockingTests {
    private struct Rig {
        let spool: SpoolStore
        let root: URL
        let db: LocalDb
    }

    private func makeRig() throws -> Rig {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bridge-connect-local-purge-\(UUID().uuidString)", isDirectory: true)
        return Rig(spool: try SpoolStore(root: root), root: root, db: try LocalDb(path: tempPath()))
    }

    private func blockers(_ rig: Rig) throws -> [LocalPurgePlanner.Blocker] {
        try LocalDataPurge.blockers(spool: rig.spool, db: rig.db)
    }

    @Test func onlyTheSeedFoodsDoNotBlock() throws {
        let rig = try makeRig()
        defer { try? FileManager.default.removeItem(at: rig.root) }
        #expect(try rig.db.hasPendingSaisieChanges(), "tout est « en attente » avant le premier échange")
        #expect(try blockers(rig).isEmpty)
    }

    @Test func aRealSaisieBlocksAndTheRunTouchesNothing() throws {
        let rig = try makeRig()
        defer { try? FileManager.default.removeItem(at: rig.root) }
        try rig.db.upsertWeight(date: "2026-10-01", kg: 72.4)
        let fileId = WatchFileID(fileType: monitorType, index: 1, name: "f1.fit")
        try rig.spool.recordAcquired(fileId, relativePath: "MONITOR/f1.fit", data: syntheticFit(fileType: 32))
        rig.spool.markDelivered(fileId)
        rig.spool.markPushedToPulse(fileId)

        #expect(try blockers(rig) == [.unsentSaisies(1)])
        #expect(throws: LocalDataPurge.Blocked.self) { try LocalDataPurge.run(spool: rig.spool, db: rig.db) }
        #expect(try count(rig.db, "weight_log") == 1, "la base est intacte")
        #expect(FileManager.default.fileExists(atPath: rig.spool.fileURL(for: try #require(rig.spool.entries[fileId])).path))
        #expect(rig.spool.entries[fileId]?.purgedAt == nil)
    }

    @Test func eachKindOfSaisieBlocks() throws {
        let rig = try makeRig()
        defer { try? FileManager.default.removeItem(at: rig.root) }
        try rig.db.setSetting(key: "birthYear", value: "1990")
        #expect(try blockers(rig) == [.unsentSaisies(1)])
        _ = try rig.db.insertLog(
            date: "2026-10-01", foodId: nil, name: "Skyr", grams: 150, kcal: 95, protein: 16, carbs: 6, fiber: 0, fat: 0.3,
            unitLabel: "pot", unitQty: 1, ts: 1_790_000_000)
        #expect(try blockers(rig) == [.unsentSaisies(2)])
        try rig.db.debugActivateProgramme(programmeId: "p1", kind: "nutrition", startedOn: "2026-10-01", days: nil)
        #expect(try blockers(rig) == [.unsentSaisies(3)])
        _ = try rig.db.insertFood(barcode: nil, name: "Pain maison", kcal: 250, protein: 8, carbs: 48, fiber: 6, fat: 1.5, unitLabel: nil, unitGrams: nil)
        #expect(try blockers(rig) == [.unsentSaisies(4)])
    }

    @Test func aModifiedOrDeletedSeedFoodBlocksButRewritingItIdenticallyDoesNot() throws {
        let rig = try makeRig()
        defer { try? FileManager.default.removeItem(at: rig.root) }
        let skyr = try seededFoodId(rig.db, name: "Skyr nature")
        // Mêmes valeurs que la graine : le trigger journalise, mais ce n'est pas une saisie.
        _ = try rig.db.updateFood(
            id: skyr, barcode: nil, name: "Skyr nature", kcal: 63, protein: 11, carbs: 4, fiber: 0, fat: 0.2, unitLabel: "pot", unitGrams: 150)
        #expect(try blockers(rig).isEmpty)

        _ = try rig.db.updateFood(
            id: skyr, barcode: nil, name: "Skyr nature", kcal: 70, protein: 11, carbs: 4, fiber: 0, fat: 0.2, unitLabel: "pot", unitGrams: 150)
        #expect(try blockers(rig) == [.unsentSaisies(1)])

        let banane = try seededFoodId(rig.db, name: "Banane")
        try rig.db.db.run("DELETE FROM foods WHERE id = ?", [.int(banane)])
        #expect(try blockers(rig) == [.unsentSaisies(2)], "la suppression d'un aliment de départ est une saisie")
    }

    @Test func acknowledgedSaisiesNoLongerBlock() throws {
        let rig = try makeRig()
        defer { try? FileManager.default.removeItem(at: rig.root) }
        try rig.db.upsertWeight(date: "2026-10-01", kg: 72.4)
        try rig.db.setSetting(key: "heightCm", value: "180")
        #expect(try blockers(rig) == [.unsentSaisies(2)])
        try acknowledgeAllSaisies(rig.db)
        #expect(try blockers(rig).isEmpty)
        // Une saisie faite APRÈS l'accusé bloque de nouveau.
        try rig.db.upsertWeight(date: "2026-10-02", kg: 72.0)
        #expect(try blockers(rig) == [.unsentSaisies(1)])
    }

    @Test func measuresOnlyOnThePhoneBlock() throws {
        let rig = try makeRig()
        defer { try? FileManager.default.removeItem(at: rig.root) }
        let id = WatchFileID(fileType: monitorType, index: 1, name: "f1.fit")
        try rig.spool.recordAcquired(id, relativePath: "MONITOR/f1.fit", data: syntheticFit(fileType: 32))
        rig.spool.markDelivered(id)
        // Purgé par la purge quotidienne alors que Pulse n'était pas configuré.
        let url = rig.spool.fileURL(for: try #require(rig.spool.entries[id]))
        #expect(rig.spool.purgeFile(id, expectedAcquiredAt: try #require(rig.spool.entries[id]).acquiredAt))
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(try blockers(rig) == [.measuresOnlyOnPhone(1)])
    }
}

// MARK: - Exécution

struct LocalDataPurgeExecutionTests {
    private struct Rig {
        let spool: SpoolStore
        let root: URL
        let db: LocalDb
        var listing: [GarminDirectoryEntry] = []
    }

    private func makeRig() throws -> Rig {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bridge-connect-local-purge-\(UUID().uuidString)", isDirectory: true)
        return Rig(spool: try SpoolStore(root: root), root: root, db: try LocalDb(path: tempPath()))
    }

    /// Acquiert un MONITOR synthétique et le fait avancer. Les octets diffèrent d'un
    /// fichier à l'autre (`salt`), donc leurs hash aussi.
    @discardableResult
    private func acquire(
        _ rig: inout Rig, _ index: Int, state: SpoolState = .delivered, pushed: Bool = true, rejected: Bool = false
    ) throws -> SpoolEntry {
        let data = syntheticFit(fileType: 32, salt: UInt8(index))
        let listed = GarminDirectoryEntry(
            fileIndex: index, dataType: 128, subType: 32, fileNumber: index, sizeBytes: data.count, garminTimestamp: 0)!
        let (id, path) = SpoolStore.identity(for: listed)
        try rig.spool.recordAcquired(id, relativePath: path, data: data, listedSize: data.count)
        if state != .acquired { rig.spool.markDelivered(id) }
        if state == .archived { rig.spool.markArchived(id) }
        if pushed { rig.spool.markPushedToPulse(id) }
        if rejected { rig.spool.markPulseRejected(id) }
        rig.listing.append(listed)
        return try #require(rig.spool.entries[id])
    }

    private func current(_ rig: Rig, _ index: Int) -> SpoolEntry? {
        rig.spool.entries.values.first { $0.id.index == index }
    }

    private func exists(_ rig: Rig, _ index: Int) -> Bool {
        current(rig, index).map { FileManager.default.fileExists(atPath: rig.spool.fileURL(for: $0).path) } ?? false
    }

    /// Fichiers : 1 archivé+poussé, 2 livré+poussé, 3 livré non poussé, 4 rejeté
    /// (non poussé), 5 poussé ET rejeté, 6 `acquired` mais déjà poussé.
    private func populated() throws -> Rig {
        var rig = try makeRig()
        try acquire(&rig, 1, state: .archived)
        try acquire(&rig, 2)
        try acquire(&rig, 3, pushed: false)
        try acquire(&rig, 4, pushed: false, rejected: true)
        try acquire(&rig, 5, rejected: true)
        try acquire(&rig, 6, state: .acquired)
        let ingested = LocalIngestor.ingestPending(from: rig.spool, into: rig.db)
        #expect(ingested.marked == 6, "précondition : les six fichiers ont une preuve")
        #expect(try count(rig.db, "imported_files") == 6)
        return rig
    }

    @Test func pushedFilesAreDeletedAndMarkedPurgedTheOthersKeptWithoutProof() throws {
        let rig = try populated()
        defer { try? FileManager.default.removeItem(at: rig.root) }
        let beforeIds = Set(rig.spool.entries.keys)

        let report = try LocalDataPurge.run(spool: rig.spool, db: rig.db)

        #expect(report == LocalDataPurge.Report(filesDeleted: 2, filesKept: 4, filesSkipped: 0))
        rig.spool.refreshFromDisk()
        #expect(Set(rig.spool.entries.keys) == beforeIds, "TOUTES les entrées du journal sont conservées")
        for index in [1, 2] {
            #expect(!exists(rig, index))
            #expect(current(rig, index)?.purgedAt != nil)
        }
        for index in [3, 4, 5, 6] {
            #expect(exists(rig, index), "fichier \(index) gardé")
            #expect(current(rig, index)?.purgedAt == nil)
            #expect(current(rig, index)?.ingest == nil, "sans preuve : à ré-ingérer")
        }
        #expect(current(rig, 4)?.pulseRejectedAt != nil, "la quarantaine est intacte")
        #expect(current(rig, 5)?.pulseRejectedAt != nil)
        #expect(current(rig, 3)?.pushedToPulse == false)
        // Les entrées effacées gardent un état et une taille listée, pas de preuve à confirmer en base.
        #expect(current(rig, 1)?.state == .archived)
        #expect(current(rig, 1)?.ingest?.status == .ingested)
        #expect(current(rig, 2)?.state == .delivered)
        #expect(current(rig, 2)?.ingest?.status == .skipped)
        #expect(current(rig, 2)?.listedSize != nil)
    }

    @Test func databaseIsEmptiedAndKeptFilesAreIngestedAgain() throws {
        let rig = try populated()
        defer { try? FileManager.default.removeItem(at: rig.root) }

        _ = try LocalDataPurge.run(spool: rig.spool, db: rig.db)
        #expect(try count(rig.db, "imported_files") == 0)

        // Reconstruction : seuls les fichiers gardés sont relus ; les purgés ne le sont jamais.
        let again = LocalIngestor.ingestPending(from: rig.spool, into: rig.db)
        #expect(again.results.count == 4)
        #expect(again.marked == 4)
        #expect(try count(rig.db, "imported_files") == 4)
        #expect(LocalIngestor.ingestPending(from: rig.spool, into: rig.db).results.isEmpty)
    }

    @Test func aPurgedEntryIsNeverAskedAgainOfTheWatch() throws {
        let rig = try populated()
        defer { try? FileManager.default.removeItem(at: rig.root) }
        // Contrôle : un fichier jamais vu serait bien dû.
        let unknown = GarminDirectoryEntry(fileIndex: 99, dataType: 128, subType: 32, fileNumber: 99, sizeBytes: 6, garminTimestamp: 0)!
        #expect(SyncPlanner.filesDue(from: rig.listing + [unknown], journal: rig.spool.entries).map(\.fileIndex) == [99])

        _ = try LocalDataPurge.run(spool: rig.spool, db: rig.db)
        rig.spool.refreshFromDisk()

        #expect(SyncPlanner.filesDue(from: rig.listing + [unknown], journal: rig.spool.entries).map(\.fileIndex) == [99])
        #expect(rig.spool.pendingAcquisition(from: rig.spool.entries.keys.sorted { $0.index < $1.index }).isEmpty)
    }

    /// Le piège de l'index de la montre : une entrée effacée mais pas encore archivée
    /// doit pouvoir l'être, quel que soit le mode, sans attendre une ingestion qui
    /// n'aura jamais lieu (une entrée purgée n'est jamais ré-ingérée).
    @Test func deletedEntriesStayArchivableAndKeptOnesWaitForTheirReingest() throws {
        let rig = try populated()
        defer { try? FileManager.default.removeItem(at: rig.root) }
        _ = try LocalDataPurge.run(spool: rig.spool, db: rig.db)
        rig.spool.refreshFromDisk()

        for requiresIngest in [false, true] {
            let plan = ArchivePlanner.plan(delivered: rig.spool.pendingArchive(), listing: rig.listing, requiresIngest: requiresIngest)
            #expect(plan.eligible.map(\.id.index).contains(2), "le fichier 2, effacé, s'archive (requiresIngest=\(requiresIngest))")
            #expect(plan.awaitingIngest.map(\.id.index).sorted() == (requiresIngest ? [3, 4, 5] : []))
        }
        // Et la vérification de dernière minute ne le contredit pas : `skipped`, rien à confirmer en base.
        #expect(current(rig, 2)?.ingest?.status != .ingested)

        // Une fois les gardés ré-ingérés, ils deviennent archivables à leur tour.
        _ = LocalIngestor.ingestPending(from: rig.spool, into: rig.db)
        rig.spool.refreshFromDisk()
        let plan = ArchivePlanner.plan(delivered: rig.spool.pendingArchive(), listing: rig.listing, requiresIngest: true)
        #expect(plan.awaitingIngest.isEmpty)
        #expect(Set(plan.eligible.map(\.id.index)) == [2, 3, 4, 5])
    }

    @Test func purgeIsRepeatableAndSecondRunDoesNothingMore() throws {
        let rig = try populated()
        defer { try? FileManager.default.removeItem(at: rig.root) }
        _ = try LocalDataPurge.run(spool: rig.spool, db: rig.db)
        let second = try LocalDataPurge.run(spool: rig.spool, db: rig.db)
        #expect(second.filesDeleted == 0)
        #expect(second.filesKept == 4)
    }

    @Test func aFileReacquiredAfterTheSelectionIsNotDeleted() throws {
        var rig = try makeRig()
        defer { try? FileManager.default.removeItem(at: rig.root) }
        let stale = try acquire(&rig, 1)
        // La montre a réécrit le fichier : l'entrée repart à `acquired`, sans « poussé ».
        let (id, path) = SpoolStore.identity(for: rig.listing[0])
        try rig.spool.recordAcquired(id, relativePath: path, data: syntheticFit(fileType: 32, salt: 77), listedSize: 5)
        #expect(!rig.spool.purgeFile(stale.id, expectedAcquiredAt: stale.acquiredAt), "jeton périmé : rien n'est supprimé")
        let report = try LocalDataPurge.run(spool: rig.spool, db: rig.db)
        #expect(report.filesDeleted == 0)
        #expect(exists(rig, 1))
    }
}

// MARK: - La base

struct LocalDbPurgeAllDataTests {
    private func populatedDb() throws -> LocalDb {
        let db = try LocalDb(path: tempPath())
        try db.upsertWeight(date: "2026-10-01", kg: 72.4)
        try db.setSetting(key: "birthYear", value: "1990")
        try db.setSetting(key: "wakeSchedule", value: "{\"2\":420}")
        _ = try db.insertFood(barcode: "3017620422003", name: "Pâte maison", kcal: 500, protein: 5, carbs: 50, fiber: 2, fat: 30, unitLabel: nil, unitGrams: nil)
        _ = try db.insertLog(
            date: "2026-10-01", foodId: nil, name: "Skyr", grams: 150, kcal: 95, protein: 16, carbs: 6, fiber: 0, fat: 0.3,
            unitLabel: "pot", unitQty: 1, ts: 1_790_000_000)
        try db.debugActivateProgramme(programmeId: "p1", kind: "nutrition", startedOn: "2026-10-01", days: "1,3")
        try db.debugInsertProgrammePlan(programmeId: "p1", week: 1, session: "A", date: "2026-10-02")
        try db.debugInsertProgrammeDone(programmeId: "p1", week: 1, session: "A", date: "2026-10-02", activityId: nil)
        try db.db.run("INSERT INTO imported_files (hash, kind, file_name) VALUES ('h', 'wellness', 'a.fit')")
        try db.db.run("INSERT INTO wellness_days (date, resting_hr) VALUES ('2026-10-01', 55)")
        try db.db.run("INSERT INTO wellness_samples (metric, ts, value) VALUES ('hr', 1790000000, 60)")
        try db.db.run("INSERT INTO activities (file_hash, file_name, sport) VALUES ('ah', 'b.fit', 'running')")
        try db.db.run("INSERT INTO body_battery_state (date, start_value) VALUES ('2026-10-01', 80)")
        return db
    }

    @Test func everyTableIsEmptiedAndTheSeedFoodsAreSownAgainLikeAFreshDatabase() throws {
        let db = try populatedDb()
        let fresh = try LocalDb(path: tempPath())
        for table in ["weight_log", "settings", "food_log", "programme_state", "programme_plan", "programme_done",
                      "imported_files", "wellness_days", "wellness_samples", "activities", "body_battery_state"] {
            #expect(try count(db, table) > 0, "précondition : \(table)")
        }

        try db.purgeAllData()

        for table in try tableNames(db) where !["foods", "saisie_changes"].contains(table) {
            #expect(try count(db, table) == 0, "\(table) est vide")
        }
        #expect(try count(db, "foods") == count(fresh, "foods"))
        #expect(try count(db, "foods") > 50)
        #expect(try scalar(db, "SELECT COUNT(*) FROM foods WHERE name = 'Pâte maison' OR barcode IS NOT NULL") == 0)
        #expect(try scalar(db, "SELECT MIN(id) FROM foods") == 1, "compteurs d'identifiants remis à zéro")
        #expect(try scalar(db, "SELECT COUNT(*) FROM foods WHERE uid IS NULL") == 0)
        #expect(try db.contentCounts() == LocalDb.ContentCounts())
    }

    /// Le point sensible : des `DELETE` journaliseraient des pierres tombales qui, au
    /// prochain échange, SUPPRIMERAIENT les saisies sur Pulse.
    @Test func noTombstoneSurvivesAndTheExchangeStateStartsOver() throws {
        let db = try populatedDb()
        try acknowledgeAllSaisies(db)
        #expect(try db.saisieSyncState().initialDone)
        #expect(try db.saisieSyncState().cursor == 7)

        try db.purgeAllData()

        #expect(try scalar(db, "SELECT COUNT(*) FROM saisie_changes WHERE deleted != 0") == 0)
        #expect(try scalar(db, "SELECT COUNT(*) FROM saisie_changes WHERE resource != 'food'") == 0)
        #expect(try scalar(db, "SELECT COUNT(*) FROM saisie_changes") == Double(count(db, "foods")), "le journal d'une base neuve")
        #expect(try db.saisieSyncState() == LocalDb.SaisieSyncState(), "curseur 0, rev accusé 0, premier échange à refaire")
        #expect(try count(db, "saisie_sync_state") == 0)
        // Ce que le prochain échange enverrait : uniquement les aliments de départ, aucune suppression.
        let batch = try db.collectSaisieChanges(afterRev: 0, limit: 100_000)
        #expect(!batch.changes.isEmpty)
        #expect(batch.changes.allSatisfy { $0.resource == "food" && !$0.deleted })
        #expect(try db.hasPendingSaisieChanges(), "comme une base neuve : tout est à envoyer au premier échange")
        #expect(LocalPurgePlanner.blockingSaisieCount(pending: try db.pendingSaisies(), seeds: LocalDb.seedFoodSignatures) == 0)
    }

    @Test func theFileIsNotReplacedSoOtherConnectionsKeepWorking() throws {
        let path = tempPath()
        let db = try LocalDb(path: path)
        try db.upsertWeight(date: "2026-10-01", kg: 72.4)
        let other = try LocalDb(path: path)   // l'ingestion, un écran…
        #expect(try count(other, "weight_log") == 1)

        try db.purgeAllData()

        #expect(try count(other, "weight_log") == 0, "l'autre connexion voit la base vidée")
        try other.upsertWeight(date: "2026-10-02", kg: 71.0)
        #expect(try count(db, "weight_log") == 1, "et peut écrire après")
    }

    @Test func theDatabaseShrinksOnDisk() throws {
        let path = tempPath()
        let db = try LocalDb(path: path)
        try db.db.transaction {
            for i in 0..<30_000 {
                try db.db.run("INSERT INTO wellness_samples (metric, ts, value) VALUES ('hr', ?, 60)", [.int(1_790_000_000 + i)])
            }
        }
        func size() -> Int {
            ["", "-wal"].reduce(0) { total, suffix in
                total + ((try? FileManager.default.attributesOfItem(atPath: path + suffix)[.size] as? Int) ?? 0)
            }
        }
        let before = size()
        try db.purgeAllData()
        #expect(size() < before / 2, "avant \(before) o, après \(size()) o")
    }
}
