//
//  ResizeAndArchiveAckTests.swift
//  allTests
//
//  Deux garde-fous contre les trous de données :
//   1. un fichier que la montre a continué d'écrire (même type/index/nom, taille
//      listée différente) est RELU — `SyncPlanner.retention`/`filesDue(journal:)`,
//      `SpoolEntry.listedSize`, `SpoolStore.recordAcquired` (remplacement) ;
//   2. l'archivage montre n'est marqué qu'à l'accusé APPLIQUÉ de la montre, une
//      demande à la fois, et jamais pour une entrée absente du manifeste ou dont
//      la taille listée a changé — `ArchivePlanner`, `ArchiveRequestTracker`,
//      `SetFileFlagStatus`.
//
//  Tout est synthétique et PUR (aucun CoreBluetooth, aucun réseau, aucune donnée
//  de santé) ; le pilotage de bout en bout par `GarminSession` vit dans
//  `TransferResilienceTests.swift` (`GarminSessionArchiveAckTests`).
//

import Testing
import Foundation
@testable import all

// MARK: - Fixtures

private func listed(fileIndex: Int, size: Int, garminTimestamp: UInt32 = 0, dataType: UInt8 = 128, subType: UInt8 = 4) -> GarminDirectoryEntry {
    GarminDirectoryEntry(
        fileIndex: fileIndex, dataType: dataType, subType: subType,
        fileNumber: fileIndex, sizeBytes: size, garminTimestamp: garminTimestamp)!
}

private func makeStore() throws -> (store: SpoolStore, root: URL) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("bridge-connect-resize-tests-\(UUID().uuidString)", isDirectory: true)
    return (try SpoolStore(root: root), root)
}

/// Acquiert (et fait avancer jusqu'à `state`) une entrée du manifeste dans un
/// vrai `SpoolStore(root:)`, comme le fait `GarminSession.finishDownload`.
@discardableResult
private func hold(_ entry: GarminDirectoryEntry, in store: SpoolStore, upTo state: SpoolState = .acquired, listedSize: Int? = nil, content: String = "x") throws -> SpoolEntry {
    let (id, path) = SpoolStore.identity(for: entry)
    try store.recordAcquired(id, relativePath: path, data: Data(content.utf8), listedSize: listedSize)
    if state != .acquired { store.markDelivered(id) }
    if state == .archived { store.markArchived(id) }
    return store.entries[id]!
}

// MARK: - SyncPlanner : un fichier qui a grossi est dû

struct SyncPlannerResizeTests {
    @Test func aFileThatGrewIsDue() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        try hold(listed(fileIndex: 5, size: 100), in: store, listedSize: 100)

        let due = SyncPlanner.filesDue(from: [listed(fileIndex: 5, size: 160)], journal: store.entries)

        #expect(due.map(\.fileIndex) == [5])
        #expect(SyncPlanner.resizedSinceAcquisition(from: [listed(fileIndex: 5, size: 160)], journal: store.entries).map(\.recordedSize) == [100])
    }

    @Test func anUnchangedSizeIsHeld() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        try hold(listed(fileIndex: 5, size: 100), in: store, listedSize: 100)

        let due = SyncPlanner.filesDue(from: [listed(fileIndex: 5, size: 100)], journal: store.entries)

        #expect(due.isEmpty)
        #expect(SyncPlanner.resizedSinceAcquisition(from: [listed(fileIndex: 5, size: 100)], journal: store.entries).isEmpty)
    }

    /// Entrée antérieure à `listedSize` : tenue (pas de re-téléchargement massif
    /// à la mise à jour de l'app), même si la taille listée est quelconque.
    @Test func anOldEntryWithoutRecordedSizeIsHeld() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        try hold(listed(fileIndex: 5, size: 100), in: store, listedSize: nil)

        let due = SyncPlanner.filesDue(from: [listed(fileIndex: 5, size: 999)], journal: store.entries)

        #expect(due.isEmpty)
    }

    /// La taille ne change pas l'identité : le fichier grossi retombe sur la même
    /// entrée du journal, dans n'importe quel état d'avancement.
    @Test func aGrownFileIsDueWhateverItsStateInTheJournal() throws {
        for state in [SpoolState.acquired, .delivered, .archived] {
            let (store, root) = try makeStore()
            defer { try? FileManager.default.removeItem(at: root) }
            try hold(listed(fileIndex: 8, size: 10), in: store, upTo: state, listedSize: 10)

            let due = SyncPlanner.filesDue(from: [listed(fileIndex: 8, size: 11)], journal: store.entries)

            #expect(due.map(\.fileIndex) == [8], "état \(state.rawValue)")
        }
    }

    @Test func newFilesAreStillDueAndNonPullableOrDirectoryEntriesNever() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = listed(fileIndex: 0, size: 100, dataType: 0, subType: 0)
        let fresh = listed(fileIndex: 3, size: 10)

        let due = SyncPlanner.filesDue(from: [directory, fresh], journal: store.entries)

        #expect(due.map(\.fileIndex) == [3])
    }

    /// Garde-fou anti-boucle : la taille enregistrée à l'acquisition est celle du
    /// MANIFESTE ; relire le même manifeste ne redemande donc rien, et un fichier
    /// dont la taille bouge à chaque manifeste n'est relu qu'une fois par manifeste.
    @Test func aFileIsReReadAtMostOncePerManifest() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        try hold(listed(fileIndex: 5, size: 100), in: store, listedSize: 100)

        let manifest2 = [listed(fileIndex: 5, size: 130)]
        #expect(SyncPlanner.filesDue(from: manifest2, journal: store.entries).count == 1)

        // Relecture : enregistre la taille du manifeste 2.
        let (id, path) = SpoolStore.identity(for: manifest2[0])
        try store.recordAcquired(id, relativePath: path, data: Data("y".utf8), listedSize: 130)
        #expect(SyncPlanner.filesDue(from: manifest2, journal: store.entries).isEmpty, "même manifeste : rien à redemander")

        // Un manifeste ultérieur à taille encore différente : relu, une fois.
        let manifest3 = [listed(fileIndex: 5, size: 150)]
        #expect(SyncPlanner.filesDue(from: manifest3, journal: store.entries).count == 1)
    }
}

// MARK: - SpoolEntry / SpoolStore : taille enregistrée, rétrocompatibilité, remplacement

struct SpoolRedownloadTests {
    @Test func recordAcquiredStoresTheListedSize() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let saved = try hold(listed(fileIndex: 1, size: 42), in: store, listedSize: 42)

        #expect(saved.listedSize == 42)
        // Persisté : une seconde instance relit la taille.
        let reopened = try SpoolStore(root: root)
        #expect(reopened.entries[saved.id]?.listedSize == 42)
    }

    /// Journal écrit avant `listedSize` (et avant `pushedToPulse`) : toujours
    /// décodable, jamais « journal entier perdu ».
    @Test func anOldJournalWithoutListedSizeStillDecodes() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bridge-connect-oldjournal-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let oldJournal = """
        [{"id":{"fileType":32772,"index":9,"name":"ACTIVITY_9.fit"},"state":"delivered",\
        "acquiredAt":0,"deliveredAt":1,"relativePath":"ACTIVITY/ACTIVITY_9.fit"}]
        """
        try Data(oldJournal.utf8).write(to: root.appendingPathComponent("journal.json"))

        let store = try SpoolStore(root: root)

        let entry = try #require(store.entries.values.first)
        #expect(entry.state == .delivered)
        #expect(entry.listedSize == nil)
        #expect(entry.pushedToPulse == false)
    }

    @Test func reAcquiringReplacesTheFileAndResetsTheEntryToAcquired() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = listed(fileIndex: 6, size: 10)
        let before = try hold(first, in: store, upTo: .archived, listedSize: 10, content: "avant")
        store.markPushedToPulse(before.id)
        #expect(store.entries[before.id]?.state == .archived)
        #expect(store.entries[before.id]?.pushedToPulse == true)

        let (id, path) = SpoolStore.identity(for: listed(fileIndex: 6, size: 25))
        #expect(id == before.id, "la taille ne fait pas partie de l'identité")
        let after = try store.recordAcquired(id, relativePath: path, data: Data("après, plus long".utf8), listedSize: 25)

        #expect(after.state == .acquired)
        #expect(after.deliveredAt == nil)
        #expect(after.archivedAt == nil)
        #expect(after.pushedToPulse == false)
        #expect(after.listedSize == 25)
        #expect(after.acquiredAt > before.acquiredAt)
        #expect(try Data(contentsOf: store.fileURL(for: after)) == Data("après, plus long".utf8))
        #expect(store.entries.count == 1, "une seule entrée pour le même fichier montre")

        // Le nouvel état est persisté, et progresse de nouveau normalement.
        store.markDelivered(id)
        #expect(try SpoolStore(root: root).entries[id]?.state == .delivered)
    }

    /// Un résultat asynchrone (upload, accusé d'archivage) lié à un contenu
    /// REMPLACÉ depuis ne fait pas avancer le nouveau contenu.
    @Test func aStaleAcquisitionTokenNeverAdvancesTheReplacedContent() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let old = try hold(listed(fileIndex: 6, size: 10), in: store, listedSize: 10)
        let (id, path) = SpoolStore.identity(for: listed(fileIndex: 6, size: 20))
        try store.recordAcquired(id, relativePath: path, data: Data("nouveau".utf8), listedSize: 20)

        store.markDelivered(id, expectedAcquiredAt: old.acquiredAt)
        #expect(store.entries[id]?.state == .acquired, "2xx de l'ancien contenu ignoré")
        store.markPushedToPulse(id, expectedAcquiredAt: old.acquiredAt)
        #expect(store.entries[id]?.pushedToPulse == false)

        let current = try #require(store.entries[id]?.acquiredAt)
        store.markDelivered(id, expectedAcquiredAt: current)
        #expect(store.entries[id]?.state == .delivered)
        store.markArchived(id, expectedAcquiredAt: old.acquiredAt)
        #expect(store.entries[id]?.state == .delivered, "accusé d'archivage de l'ancien contenu ignoré")
        store.markArchived(id, expectedAcquiredAt: current)
        #expect(store.entries[id]?.state == .archived)
    }
}

// MARK: - ArchivePlanner

struct ArchivePlannerTests {
    @Test func aDeliveredEntryListedWithTheSameSizeIsEligible() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        try hold(listed(fileIndex: 4, size: 50), in: store, upTo: .delivered, listedSize: 50)

        let plan = ArchivePlanner.plan(delivered: store.pendingArchive(), listing: [listed(fileIndex: 4, size: 50)])

        #expect(plan.eligible.map(\.id.index) == [4])
        #expect(plan.absentFromManifest.isEmpty)
        #expect(plan.resizedSinceAcquisition.isEmpty)
    }

    @Test func anEntryAbsentFromTheManifestIsLeftDeliveredNotArchivedByIndex() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        try hold(listed(fileIndex: 4, size: 50), in: store, upTo: .delivered, listedSize: 50)

        let plan = ArchivePlanner.plan(delivered: store.pendingArchive(), listing: [])

        #expect(plan.eligible.isEmpty)
        #expect(plan.absentFromManifest.map(\.id.index) == [4])
    }

    /// L'index a été réattribué à un AUTRE fichier (autre date → autre nom) : la
    /// seule correspondance d'index ne suffit pas, l'identité complète est exigée.
    @Test func aReassignedIndexWithAnotherNameIsNotMatched() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        try hold(listed(fileIndex: 4, size: 50, garminTimestamp: 1_000_000_000), in: store, upTo: .delivered, listedSize: 50)

        let other = listed(fileIndex: 4, size: 50, garminTimestamp: 1_000_100_000)
        let plan = ArchivePlanner.plan(delivered: store.pendingArchive(), listing: [other])

        #expect(plan.eligible.isEmpty, "même index, autre fichier : jamais archivé")
        #expect(plan.absentFromManifest.count == 1)
    }

    @Test func aFileWhoseListedSizeChangedIsNeverArchivedUntilReRead() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        try hold(listed(fileIndex: 4, size: 50), in: store, upTo: .delivered, listedSize: 50)

        let plan = ArchivePlanner.plan(delivered: store.pendingArchive(), listing: [listed(fileIndex: 4, size: 80)])

        #expect(plan.eligible.isEmpty)
        #expect(plan.resizedSinceAcquisition.map(\.recordedSize) == [50])
        #expect(plan.resizedSinceAcquisition.map(\.listedSize) == [80])
    }

    /// Entrée ancienne sans taille enregistrée : archivable (comme `filesDue` la
    /// tient) dès que son identité figure au manifeste.
    @Test func anOldEntryWithoutRecordedSizeIsEligibleWhenListed() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        try hold(listed(fileIndex: 4, size: 50), in: store, upTo: .delivered, listedSize: nil)

        let plan = ArchivePlanner.plan(delivered: store.pendingArchive(), listing: [listed(fileIndex: 4, size: 999)])

        #expect(plan.eligible.map(\.id.index) == [4])
    }

    @Test func onlyDeliveredEntriesAreConsidered() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = listed(fileIndex: 1, size: 5), b = listed(fileIndex: 2, size: 5), c = listed(fileIndex: 3, size: 5)
        try hold(a, in: store, upTo: .acquired, listedSize: 5)
        try hold(b, in: store, upTo: .delivered, listedSize: 5)
        try hold(c, in: store, upTo: .archived, listedSize: 5)

        let plan = ArchivePlanner.plan(delivered: Array(store.entries.values), listing: [a, b, c])

        #expect(plan.eligible.map(\.id.index) == [2])
    }
}

// MARK: - ArchiveRequestTracker / SetFileFlagStatus

struct ArchiveRequestTrackerTests {
    private func deliveredEntries(_ indexes: [Int]) throws -> (entries: [SpoolEntry], root: URL) {
        let (store, root) = try makeStore()
        for index in indexes {
            try hold(listed(fileIndex: index, size: 5), in: store, upTo: .delivered, listedSize: 5)
        }
        return (store.pendingArchive().sorted { $0.id.index < $1.id.index }, root)
    }

    @Test func onlyOneRequestIsInFlightAtATime() throws {
        let (entries, root) = try deliveredEntries([1, 2])
        defer { try? FileManager.default.removeItem(at: root) }
        var tracker = ArchiveRequestTracker()

        let firstMaybe = tracker.next(from: entries)
        let first = try #require(firstMaybe)
        #expect(tracker.next(from: entries) == nil, "pas de double envoi pour une demande déjà en vol")

        #expect(tracker.receive(applied: true) == .applied(first))
        #expect(tracker.inFlight == nil)
    }

    @Test func aRefusedEntryIsNotRetriedOnTheSameLinkButOthersProceed() throws {
        let (entries, root) = try deliveredEntries([1, 2])
        defer { try? FileManager.default.removeItem(at: root) }
        var tracker = ArchiveRequestTracker()

        let firstMaybe = tracker.next(from: entries)
        let first = try #require(firstMaybe)
        #expect(tracker.receive(applied: false) == .refused(first))

        let secondMaybe = tracker.next(from: entries)
        let second = try #require(secondMaybe)
        #expect(second.id != first.id, "l'entrée refusée n'est pas renvoyée en boucle")
        _ = tracker.receive(applied: false)
        #expect(tracker.next(from: entries) == nil, "tout a été tenté sur ce lien")
    }

    @Test func aTimeoutHaltsArchivingOnTheLinkAndALateResponseIsIgnored() throws {
        let (entries, root) = try deliveredEntries([1, 2])
        defer { try? FileManager.default.removeItem(at: root) }
        var tracker = ArchiveRequestTracker()

        let firstMaybe = tracker.next(from: entries)
        let first = try #require(firstMaybe)
        #expect(tracker.timeOut() == first)
        #expect(tracker.halted)
        #expect(tracker.next(from: entries) == nil, "plus aucune demande sur ce lien : une réponse tardive serait prise pour la suivante")
        #expect(tracker.receive(applied: true) == nil, "réponse tardive : rien en vol, jamais attribuée à une entrée")
    }

    @Test func aResponseWithNothingInFlightIsIgnored() {
        var tracker = ArchiveRequestTracker()
        #expect(tracker.receive(applied: true) == nil)
    }

    @Test func aNewSessionRetriesWhatARefusalLeftDelivered() throws {
        let (entries, root) = try deliveredEntries([1])
        defer { try? FileManager.default.removeItem(at: root) }
        var link1 = ArchiveRequestTracker()
        _ = link1.next(from: entries)
        _ = link1.receive(applied: false)

        var link2 = ArchiveRequestTracker() // un lien BLE = un tracker neuf
        #expect(link2.next(from: entries) != nil)
    }
}

struct SetFileFlagStatusTests {
    @Test func ackWithAppliedFlagsIsApplied() throws {
        let status = try #require(SetFileFlagStatus.parse(Data([0, 0, 0x2A, 0x00, 0x10])))
        #expect(status.isApplied)
        #expect(status.fileIdentifierRaw == 42)
        #expect(status.flags == 0x10)
    }

    @Test func flagsErrorIsNotApplied() throws {
        let status = try #require(SetFileFlagStatus.parse(Data([0, 1, 0x2A, 0x00, 0x10])))
        #expect(!status.isApplied)
    }

    @Test func nonAckStatusIsNotApplied() throws {
        let status = try #require(SetFileFlagStatus.parse(Data([1])))
        #expect(!status.isApplied)
    }

    @Test func truncatedAckIsNotApplied() throws {
        let status = try #require(SetFileFlagStatus.parse(Data([0])))
        #expect(!status.isApplied, "ACK sans flagsStatus : pas un accusé exploitable")
    }

    @Test func emptyPayloadDoesNotParse() {
        #expect(SetFileFlagStatus.parse(Data()) == nil)
    }
}
