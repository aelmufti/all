//
//  SpoolJournalSharedTests.swift
//  allTests
//
//  Le journal du spool (`journal.json`) a UNE source de vérité : le fichier.
//  Plusieurs `SpoolStore(root:)` vivent en même temps en production (celle de
//  `BLEManager`, celle de `PulseBacklogPusher`, celle de `LocalIngestor`, celle de
//  `LocalPulseBackend`) ; avant correctif, chacune réécrivait SON instantané
//  complet à chaque transition, et une instance chargée plus tôt écrasait les
//  entrées/états plus récents des autres. Ces tests rejouent les séquences
//  d'écrasement à deux (ou trois) instances sur la même racine — ils échouaient
//  avant le correctif — et prouvent qu'aucune entrée n'est perdue, qu'aucun état
//  ne régresse, et qu'une relecture volontaire (fichier grossi) survit.
//
//  Tout est synthétique (répertoire temporaire, octets factices, aucun réseau,
//  aucune donnée de santé).
//

import Testing
import Foundation
@testable import all

private func listed(fileIndex: Int, size: Int = 10) -> GarminDirectoryEntry {
    GarminDirectoryEntry(
        fileIndex: fileIndex, dataType: 128, subType: 4,
        fileNumber: fileIndex, sizeBytes: size, garminTimestamp: 0)!
}

private func makeRoot() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("bridge-connect-sharedjournal-tests-\(UUID().uuidString)", isDirectory: true)
}

@discardableResult
private func acquire(_ fileIndex: Int, in store: SpoolStore, size: Int = 10, content: String = "x") throws -> SpoolEntry {
    let (id, path) = SpoolStore.identity(for: listed(fileIndex: fileIndex, size: size))
    return try store.recordAcquired(id, relativePath: path, data: Data(content.utf8), listedSize: size)
}

private func id(_ fileIndex: Int) -> WatchFileID {
    SpoolStore.identity(for: listed(fileIndex: fileIndex)).id
}

struct SpoolJournalSharedTests {
    /// Entrée ajoutée par A, puis `markPushedToPulse` par B (chargée AVANT cet
    /// ajout) : l'entrée de A survit dans le fichier.
    @Test func anEntryAddedByASurvivesAWriteFromAnEarlierLoadedB() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try SpoolStore(root: root)
        try acquire(2, in: a)
        let b = try SpoolStore(root: root) // chargée ici : ne connaît pas l'entrée 1
        try acquire(1, in: a)

        b.markPushedToPulse(id(2))

        let reopened = try SpoolStore(root: root)
        #expect(reopened.entries[id(1)] != nil, "l'entrée acquise par A ne doit pas disparaître du fichier")
        #expect(reopened.entries[id(2)]?.pushedToPulse == true)
        #expect(a.entries[id(1)] != nil)
    }

    /// Même scénario par l'URL du fichier (variante appelée depuis le fil de
    /// rappel d'URLSession par `RoutingSpoolUploader`).
    @Test func markPushedByFileURLFromAStaleInstanceKeepsNewerEntries() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try SpoolStore(root: root)
        let first = try acquire(2, in: a)
        let b = try SpoolStore(root: root)
        try acquire(1, in: a)

        b.markPushedToPulse(forFileAt: b.fileURL(for: first))

        let reopened = try SpoolStore(root: root)
        #expect(reopened.entries.count == 2)
        #expect(reopened.entries[id(2)]?.pushedToPulse == true)
    }

    /// État avancé par A (`acquired → delivered → archived`), écriture de B qui
    /// avait chargé `acquired` : pas de régression, et les transitions périmées de
    /// B ne défont rien.
    @Test func anAdvancedStateIsNeverRegressedByAStaleInstance() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try SpoolStore(root: root)
        try acquire(1, in: a)
        let b = try SpoolStore(root: root) // voit 1 à `acquired`
        a.markDelivered(id(1))
        a.markArchived(id(1))
        #expect(a.entries[id(1)]?.state == .archived)

        b.markPushedToPulse(id(1)) // écriture « périmée »
        try acquire(2, in: b)      // autre écriture de B
        b.markDelivered(id(1))     // transition rejouée par B : sans effet

        let reopened = try SpoolStore(root: root)
        #expect(reopened.entries[id(1)]?.state == .archived, "archived ne redevient ni delivered ni acquired")
        #expect(reopened.entries[id(1)]?.archivedAt != nil)
        #expect(reopened.entries[id(1)]?.pushedToPulse == true)
        #expect(reopened.entries[id(2)] != nil)
        #expect(reopened.pendingArchive().isEmpty)
    }

    /// Relecture volontaire par A (fichier grossi → repart à `acquired`, nouvel
    /// `acquiredAt`), écriture de B : la relecture survit. Un jeton périmé que
    /// B croit encore valable (son instantané porte l'ancien `acquiredAt`) ne
    /// marque pas le nouveau contenu.
    @Test func aDeliberateReReadSurvivesAWriteFromAStaleInstance() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try SpoolStore(root: root)
        let old = try acquire(1, in: a, size: 10, content: "avant")
        try acquire(2, in: a)
        a.markDelivered(id(1))
        a.markArchived(id(1))
        let b = try SpoolStore(root: root) // voit 1 `archived`, ancien acquiredAt

        let reread = try acquire(1, in: a, size: 25, content: "après, plus long")
        #expect(reread.state == .acquired)

        b.markPushedToPulse(id(2))                                    // écriture de B
        b.markPushedToPulse(id(1), expectedAcquiredAt: old.acquiredAt) // jeton de l'ancien contenu
        b.markArchived(id(1), expectedAcquiredAt: old.acquiredAt)

        let reopened = try SpoolStore(root: root)
        let entry = try #require(reopened.entries[id(1)])
        #expect(entry.state == .acquired, "la relecture ne doit pas être écrasée par l'instantané périmé de B")
        #expect(entry.acquiredAt == reread.acquiredAt)
        #expect(entry.acquiredAt > old.acquiredAt)
        #expect(entry.listedSize == 25)
        #expect(entry.archivedAt == nil)
        #expect(entry.pushedToPulse == false)
        #expect(try Data(contentsOf: reopened.fileURL(for: entry)) == Data("après, plus long".utf8))
        #expect(reopened.entries[id(2)]?.pushedToPulse == true)
    }

    /// La relecture elle-même, faite par une instance qui a un instantané périmé,
    /// repart bien à `acquired` avec un `acquiredAt` strictement postérieur à
    /// celui du FICHIER (pas à celui de son cache).
    @Test func aReReadFromAStaleInstanceStaysStrictlyNewerThanTheJournal() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try SpoolStore(root: root)
        try acquire(1, in: a)
        let b = try SpoolStore(root: root)
        let second = try acquire(1, in: a, size: 20, content: "deux")

        let third = try acquire(1, in: b, size: 30, content: "trois") // B ne connaît que la 1re acquisition

        #expect(third.acquiredAt > second.acquiredAt)
        #expect(try SpoolStore(root: root).entries[id(1)]?.acquiredAt == third.acquiredAt)
    }

    /// `backfillListedSizes` (ex-`loadJournal`) sur une instance périmée ne
    /// régresse aucun état : il ne complète que `listedSize` d'entrées qui en
    /// manquent encore SUR LE FICHIER.
    @Test func backfillFromAStaleInstanceDoesNotOverwriteANewerState() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("files/ACTIVITY/ACTIVITY_9.fit")
        // Journal d'avant `listedSize`, fichier du spool ABSENT au chargement de B
        // (pas de rétro-remplissage possible, l'entrée reste « sans taille »).
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let oldJournal = """
        [{"id":{"fileType":32772,"index":9,"name":"ACTIVITY_9.fit"},"state":"acquired",\
        "acquiredAt":1,"relativePath":"ACTIVITY/ACTIVITY_9.fit"}]
        """
        try Data(oldJournal.utf8).write(to: root.appendingPathComponent("journal.json"))
        let b = try SpoolStore(root: root)
        let watchID = WatchFileID(fileType: 32772, index: 9, name: "ACTIVITY_9.fit")
        #expect(b.entries[watchID]?.listedSize == nil)

        // Le fichier apparaît ; A (neuve) rétro-remplit puis fait avancer l'état.
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("12345".utf8).write(to: fileURL)
        let a = try SpoolStore(root: root)
        #expect(a.entries[watchID]?.listedSize == 5)
        a.markDelivered(watchID)
        a.markArchived(watchID)

        // B (instantané périmé : `acquired`, sans taille) relance le rétro-remplissage.
        b.backfillListedSizes()

        let reopened = try SpoolStore(root: root)
        #expect(reopened.entries[watchID]?.state == .archived, "le rétro-remplissage ne doit pas ressusciter un état plus ancien")
        #expect(reopened.entries[watchID]?.listedSize == 5)
    }

    /// Deux instances écrivent en parallèle (fils différents) des entrées
    /// distinctes : aucune n'est perdue, et la lecture concurrente de `entries`
    /// (main vs. fil de rappel URLSession) reste sûre.
    @Test func concurrentWritesFromTwoInstancesLoseNothing() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try SpoolStore(root: root)
        let b = try SpoolStore(root: root)
        let count = 40

        DispatchQueue.concurrentPerform(iterations: count) { i in
            let store = i % 2 == 0 ? a : b
            _ = try? acquire(i, in: store)
            _ = store.entries.count
            store.markDelivered(id(i))
            _ = store.pendingArchive()
        }

        let reopened = try SpoolStore(root: root)
        #expect(reopened.entries.count == count)
        #expect(reopened.entries.values.allSatisfy { $0.state == .delivered })
    }
}
