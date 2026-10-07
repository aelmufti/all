//
//  PulseRejectionTests.swift
//  allTests
//
//  Quarantaine des fichiers rejetés par Pulse (`SpoolEntry.pulseRejectedAt`,
//  `SpoolStore.markPulseRejected`/`clearPulseRejections`) et santé de l'envoi
//  (`PulseUploadHealth`). Aucun réseau : uploaders factices, `SpoolStore` sur un
//  répertoire temporaire, `UserDefaults` d'une suite jetable. Le pilotage de
//  `GarminSession` sur un rejet vit dans `TransferResilienceTests.swift`
//  (`GarminSessionPulseRejectionTests`).
//

import Testing
import Foundation
@testable import all

// MARK: - Fixtures

private func makeSpool() throws -> (store: SpoolStore, root: URL) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("bridge-connect-pulse-rejection-tests-\(UUID().uuidString)", isDirectory: true)
    return (try SpoolStore(root: root), root)
}

private func directoryEntry(_ fileIndex: Int, dataType: UInt8 = 128, subType: UInt8 = 4) -> GarminDirectoryEntry {
    GarminDirectoryEntry(fileIndex: fileIndex, dataType: dataType, subType: subType, fileNumber: fileIndex, sizeBytes: 6, garminTimestamp: 0)!
}

@discardableResult
private func acquire(_ store: SpoolStore, index: Int, dataType: UInt8 = 128, subType: UInt8 = 4) throws -> WatchFileID {
    let entry = directoryEntry(index, dataType: dataType, subType: subType)
    let (id, path) = SpoolStore.identity(for: entry)
    try store.recordAcquired(id, relativePath: path, data: Data("x".utf8), listedSize: entry.sizeBytes)
    return id
}

/// Uploader factice : renvoie `outcome` tout de suite, ne touche jamais le réseau.
private final class FixedOutcomeUploader: SpoolUploading {
    var outcome: PulseUploadOutcome
    private(set) var calls = 0
    init(_ outcome: PulseUploadOutcome) { self.outcome = outcome }
    func upload(fileURL: URL, watchFilename: String, completion: @escaping (PulseUploadOutcome) -> Void) {
        calls += 1
        completion(outcome)
    }
}

// MARK: - Journal : décodage

struct SpoolEntryPulseRejectedCodableTests {
    private func sample(rejectedAt: Date?) -> SpoolEntry {
        SpoolEntry(
            id: WatchFileID(fileType: (128 << 8) | 4, index: 3, name: "ACTIVITY_3.fit"),
            state: .delivered, acquiredAt: Date(timeIntervalSince1970: 1_700_000_000),
            deliveredAt: Date(timeIntervalSince1970: 1_700_000_100),
            relativePath: "ACTIVITY/ACTIVITY_3.fit", pulseRejectedAt: rejectedAt)
    }

    @Test func roundTripsThePulseRejectionDate() throws {
        let rejectedAt = Date(timeIntervalSince1970: 1_700_000_500)
        let decoded = try JSONDecoder().decode(SpoolEntry.self, from: JSONEncoder().encode(sample(rejectedAt: rejectedAt)))
        #expect(decoded.pulseRejectedAt == rejectedAt)
    }

    /// Un journal écrit avant ce champ n'a pas la clé : il se décode toujours, en
    /// entier, avec `pulseRejectedAt == nil`.
    @Test func aJournalWrittenBeforeTheFieldStillDecodesEntirely() throws {
        let json = """
        [{"id":{"fileType":32800,"index":1,"name":"a.fit"},"state":"delivered","acquiredAt":1000,\
        "relativePath":"MONITOR/a.fit","pushedToPulse":true},\
        {"id":{"fileType":32800,"index":2,"name":"b.fit"},"state":"acquired","acquiredAt":2000,\
        "relativePath":"MONITOR/b.fit"}]
        """
        let entries = try JSONDecoder().decode([SpoolEntry].self, from: Data(json.utf8))
        #expect(entries.count == 2)
        #expect(entries.allSatisfy { $0.pulseRejectedAt == nil })
        #expect(entries.first(where: { $0.id.index == 1 })?.pushedToPulse == true)
    }
}

// MARK: - SpoolStore.markPulseRejected

struct SpoolStorePulseRejectionTests {
    @Test func anAcquiredEntryBecomesDeliveredWithoutBeingPushed() throws {
        let (store, root) = try makeSpool()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = try acquire(store, index: 1)
        let token = try #require(store.entries[id]).acquiredAt

        store.markPulseRejected(id, expectedAcquiredAt: token)

        let entry = try #require(store.entries[id])
        #expect(entry.state == .delivered)
        #expect(entry.deliveredAt != nil)
        #expect(entry.pulseRejectedAt != nil)
        #expect(entry.pushedToPulse == false, "Pulse n'a pas le fichier")
        #expect(store.pendingArchive().map(\.id) == [id], "ouvre l'archivage montre")
    }

    @Test func aStaleAcquisitionTokenChangesNothing() throws {
        let (store, root) = try makeSpool()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = try acquire(store, index: 1)
        let staleToken = try #require(store.entries[id]).acquiredAt
        // Relecture : l'entrée repart `acquired` avec un nouveau jeton.
        let (_, path) = SpoolStore.identity(for: directoryEntry(1))
        try store.recordAcquired(id, relativePath: path, data: Data("nouveau".utf8))

        store.markPulseRejected(id, expectedAcquiredAt: staleToken)

        let entry = try #require(store.entries[id])
        #expect(entry.state == .acquired)
        #expect(entry.pulseRejectedAt == nil)
    }

    /// Entrée déjà `delivered`/`archived` (rattrapage d'un fichier collecté en mode
    /// Téléphone) : seul `pulseRejectedAt` change.
    @Test func anAlreadyArchivedEntryOnlyGainsTheRejectionDate() throws {
        let (store, root) = try makeSpool()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = try acquire(store, index: 1)
        store.markDelivered(id)
        store.markArchived(id)
        let before = try #require(store.entries[id])

        store.markPulseRejected(id, expectedAcquiredAt: before.acquiredAt)

        let after = try #require(store.entries[id])
        #expect(after.state == .archived)
        #expect(after.deliveredAt == before.deliveredAt)
        #expect(after.archivedAt == before.archivedAt)
        #expect(after.pushedToPulse == false)
        #expect(after.pulseRejectedAt != nil)
    }

    @Test func rejectingTwiceKeepsTheFirstDate() throws {
        let (store, root) = try makeSpool()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = try acquire(store, index: 1)
        store.markPulseRejected(id)
        let first = try #require(store.entries[id]?.pulseRejectedAt)

        store.markPulseRejected(id)

        #expect(store.entries[id]?.pulseRejectedAt == first)
    }

    @Test func rejectingAnUnknownEntryIsIgnored() throws {
        let (store, root) = try makeSpool()
        defer { try? FileManager.default.removeItem(at: root) }
        store.markPulseRejected(WatchFileID(fileType: 1, index: 9, name: "inconnu.fit"))
        #expect(store.entries.isEmpty)
        #expect(store.pulseRejectedCount() == 0)
    }

    @Test func theByURLVariantFindsTheEntryAndHonoursTheToken() throws {
        let (store, root) = try makeSpool()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = try acquire(store, index: 1)
        let entry = try #require(store.entries[id])
        let url = store.fileURL(for: entry)

        store.markPulseRejected(forFileAt: url, expectedAcquiredAt: entry.acquiredAt.addingTimeInterval(-1))
        #expect(store.entries[id]?.pulseRejectedAt == nil, "jeton périmé")

        store.markPulseRejected(forFileAt: url, expectedAcquiredAt: entry.acquiredAt)
        #expect(store.entries[id]?.pulseRejectedAt != nil)
        #expect(store.entries[id]?.state == .delivered)
    }

    /// Relire le fichier (`recordAcquired` crée une entrée neuve) repart sans rejet.
    @Test func aReacquiredFileStartsWithoutRejection() throws {
        let (store, root) = try makeSpool()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = try acquire(store, index: 1)
        store.markPulseRejected(id)
        #expect(store.entries[id]?.pulseRejectedAt != nil)

        let (_, path) = SpoolStore.identity(for: directoryEntry(1))
        try store.recordAcquired(id, relativePath: path, data: Data("nouveau".utf8))

        #expect(store.entries[id]?.pulseRejectedAt == nil)
        #expect(store.entries[id]?.state == .acquired)
    }

    @Test func theRejectionPersistsAcrossAFreshSpoolStoreInstance() throws {
        let (store, root) = try makeSpool()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = try acquire(store, index: 1)
        store.markPulseRejected(id)

        let reloaded = try SpoolStore(root: root)
        #expect(reloaded.entries[id]?.pulseRejectedAt != nil)
        #expect(reloaded.entries[id]?.state == .delivered)
    }

    @Test func clearPulseRejectionsReturnsTheCountAndKeepsStateAndPushedFlag() throws {
        let (store, root) = try makeSpool()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try acquire(store, index: 1)
        let b = try acquire(store, index: 2)
        let c = try acquire(store, index: 3)
        store.markPulseRejected(a)
        store.markDelivered(b)
        store.markArchived(b)
        store.markPulseRejected(b)
        #expect(store.pulseRejectedCount() == 2)

        let cleared = store.clearPulseRejections()

        #expect(cleared == 2)
        #expect(store.pulseRejectedCount() == 0)
        #expect(store.entries[a]?.state == .delivered)
        #expect(store.entries[b]?.state == .archived)
        #expect(store.entries[c]?.state == .acquired)
        #expect(store.entries.values.allSatisfy { !$0.pushedToPulse })
        #expect(store.clearPulseRejections() == 0, "rien à effacer la seconde fois")
    }

    /// La session BLE et le pousseur ont chacun leur `SpoolStore` : le compteur
    /// relit le disque, et l'effacement d'une instance est vu par l'autre.
    @Test func theCountAndTheClearingAreSeenAcrossInstances() throws {
        let (sessionStore, root) = try makeSpool()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = try acquire(sessionStore, index: 1)
        let pusherStore = try SpoolStore(root: root)

        pusherStore.markPulseRejected(id)
        #expect(sessionStore.pulseRejectedCount() == 1, "le rejet posé par une autre instance est vu")

        sessionStore.clearPulseRejections()
        #expect(pusherStore.pulseRejectedCount() == 0, "l'effacement aussi")
    }
}

// MARK: - Archivage, purge, rattrapage

struct PulseRejectedEntryFlowTests {
    private func rejectedEntry(index: Int, state: SpoolState = .delivered, ingest: SpoolIngestOutcome? = nil) -> SpoolEntry {
        SpoolEntry(
            id: WatchFileID(fileType: (128 << 8) | 4, index: index, name: "ACTIVITY_\(index).fit"),
            state: state, acquiredAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(index)),
            deliveredAt: Date(timeIntervalSince1970: 1_700_000_100), relativePath: "ACTIVITY/ACTIVITY_\(index).fit",
            pushedToPulse: false, ingest: ingest, pulseRejectedAt: Date(timeIntervalSince1970: 1_700_000_200))
    }

    private func listing(for entry: SpoolEntry) -> [GarminDirectoryEntry] {
        [GarminDirectoryEntry(fileIndex: entry.id.index, dataType: 128, subType: 4, fileNumber: entry.id.index, sizeBytes: 6, garminTimestamp: 0)!]
    }

    @Test func aRejectedEntryIsEligibleForArchivingInPulseMode() throws {
        let (store, root) = try makeSpool()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = try acquire(store, index: 7)
        store.markPulseRejected(id)

        let plan = ArchivePlanner.plan(delivered: store.pendingArchive(), listing: [directoryEntry(7)], requiresIngest: false)

        #expect(plan.eligible.map(\.id) == [id])
    }

    @Test func inPhoneOrBothModeItNeedsTheIngestProofLikeAnyOtherEntry() {
        let waiting = rejectedEntry(index: 1)
        let proven = rejectedEntry(index: 2, ingest: SpoolIngestOutcome(status: .ingested, hash: "h", at: Date()))

        let plan = ArchivePlanner.plan(delivered: [waiting, proven], listing: listing(for: waiting) + listing(for: proven), requiresIngest: true)

        #expect(plan.awaitingIngest.map(\.id) == [waiting.id])
        #expect(plan.eligible.map(\.id) == [proven.id])
    }

    @Test func aRejectedEntryIsNeverPurged() {
        let now = Date()
        let old = now.addingTimeInterval(-3 * 24 * 3600)
        let proof = SpoolIngestOutcome(status: .ingested, hash: "h", at: old)
        func archived(index: Int, rejected: Bool) -> SpoolEntry {
            SpoolEntry(
                id: WatchFileID(fileType: GarminFileType.monitor.watchFileType, index: index, name: "m\(index).fit"),
                state: .archived, acquiredAt: old, archivedAt: old, relativePath: "MONITOR/m\(index).fit",
                pushedToPulse: true, ingest: proof, pulseRejectedAt: rejected ? old : nil)
        }

        let purgeable = SpoolPurger.selectPurgeable(
            from: [archived(index: 1, rejected: true), archived(index: 2, rejected: false)], now: now, pulseConfigured: true)
        #expect(purgeable.map(\.id.index) == [2])

        // Même Pulse non configuré : un fichier rejeté reste, pour pouvoir le renvoyer.
        let unconfigured = SpoolPurger.selectPurgeable(from: [archived(index: 1, rejected: true)], now: now, pulseConfigured: false)
        #expect(unconfigured.isEmpty)
    }

    @Test func theBacklogSkipsRejectedEntries() {
        let rejected = rejectedEntry(index: 1)
        var other = rejectedEntry(index: 2)
        other.pulseRejectedAt = nil

        let due = PulseBacklogPusher.backlog(from: [rejected, other]) { _ in true }

        #expect(due.map(\.id.index) == [2])
    }

    @Test func clearingTheRejectionPutsTheEntryBackInTheBacklog() throws {
        let (store, root) = try makeSpool()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = try acquire(store, index: 1)
        store.markPulseRejected(id)
        func due() -> [WatchFileID] {
            PulseBacklogPusher.backlog(from: Array(store.entries.values)) { FileManager.default.fileExists(atPath: store.fileURL(for: $0).path) }.map(\.id)
        }
        #expect(due().isEmpty)

        store.clearPulseRejections()

        #expect(due() == [id], "pushedToPulse == false et plus de rejet : le rattrapage la reprend")
    }

    // MARK: PulseBacklogPusher.push

    @Test func aQuarantineOutcomeInTheBacklogPushQuarantinesTheEntry() async throws {
        let (store, root) = try makeSpool()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = try acquire(store, index: 1)
        store.markDelivered(id)
        store.markArchived(id)

        await PulseBacklogPusher.push(store.entries[id]!, spool: store, uploader: FixedOutcomeUploader(.quarantine))

        let entry = try #require(store.entries[id])
        #expect(entry.pulseRejectedAt != nil)
        #expect(entry.state == .archived, "aucune re-livraison d'état incohérente")
        #expect(entry.pushedToPulse == false)
        #expect(PulseBacklogPusher.backlog(from: [entry]) { _ in true }.isEmpty, "plus retentée à chaque lancement")
    }

    @Test(arguments: [PulseUploadOutcome.keepRetry, .keepRetryLater, .keepConfigError])
    func otherFailuresDoNotQuarantine(outcome: PulseUploadOutcome) async throws {
        let (store, root) = try makeSpool()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = try acquire(store, index: 1)
        store.markDelivered(id)

        await PulseBacklogPusher.push(store.entries[id]!, spool: store, uploader: FixedOutcomeUploader(outcome))

        #expect(store.entries[id]?.pulseRejectedAt == nil)
    }

    @Test func theBacklogPushReportsEveryOutcomeToTheHealthHook() async throws {
        let (store, root) = try makeSpool()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = try acquire(store, index: 1)
        store.markDelivered(id)
        var seen: [PulseUploadOutcome] = []

        await PulseBacklogPusher.push(store.entries[id]!, spool: store, uploader: FixedOutcomeUploader(.keepConfigError), health: { seen.append($0) })
        await PulseBacklogPusher.push(store.entries[id]!, spool: store, uploader: FixedOutcomeUploader(.delivered), health: { seen.append($0) })

        #expect(seen == [.keepConfigError, .delivered])
    }

    // MARK: RoutingSpoolUploader

    @Test func routingReportsRealPulseOutcomesButNotTheLocalPhoneDelivery() {
        var seen: [PulseUploadOutcome] = []
        let url = URL(fileURLWithPath: "/tmp/routing-health-fixture.fit")

        let pulse = RoutingSpoolUploader(pulseUploader: FixedOutcomeUploader(.keepRetryLater), mode: { .pulse }, health: { seen.append($0) })
        pulse.upload(fileURL: url, watchFilename: "a.fit") { _ in }
        let both = RoutingSpoolUploader(pulseUploader: FixedOutcomeUploader(.keepConfigError), mode: { .both }, health: { seen.append($0) })
        both.upload(fileURL: url, watchFilename: "b.fit") { _ in }
        let phone = RoutingSpoolUploader(pulseUploader: FixedOutcomeUploader(.keepConfigError), mode: { .phone }, health: { seen.append($0) })
        phone.upload(fileURL: url, watchFilename: "c.fit") { _ in }

        #expect(seen == [.keepRetryLater, .keepConfigError], "le mode Téléphone (livraison locale) ne dit rien de Pulse")
    }
}

// MARK: - PulseUploadHealth

@MainActor
struct PulseUploadHealthTests {
    private func makeDefaults() -> UserDefaults {
        let suite = "pulse-upload-health-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test func startsWithNoIssue() {
        let health = PulseUploadHealth(defaults: makeDefaults())
        #expect(health.issue == nil)
        #expect(health.configProblem == nil)
        #expect(health.rejectedCount == 0)
    }

    @Test func a401SignalsAnInvalidToken() {
        let health = PulseUploadHealth(defaults: makeDefaults())
        health.record(.keepConfigError)
        #expect(health.issue == .invalidToken)
        #expect(health.issue?.label == "Jeton Pulse absent ou refusé")
    }

    @Test func a403SignalsAWrongSource() {
        let health = PulseUploadHealth(defaults: makeDefaults())
        health.record(.keepRetryLater)
        #expect(health.issue == .wrongSource)
        #expect(health.issue?.label == "Pulse n'accepte pas l'iPhone comme source")
    }

    @Test func aRealDeliveryClearsTheConfigProblem() {
        let health = PulseUploadHealth(defaults: makeDefaults())
        health.record(.keepConfigError)
        health.record(.delivered)
        #expect(health.issue == nil)
        health.record(.keepRetryLater)
        health.record(.delivered)
        #expect(health.configProblem == nil)
    }

    /// Être loin du serveur est normal : ni signalement, ni effacement.
    @Test func networkErrorsAreNeutral() {
        let health = PulseUploadHealth(defaults: makeDefaults())
        health.record(.keepRetry)
        #expect(health.issue == nil)

        health.record(.keepConfigError)
        health.record(.keepRetry)
        #expect(health.issue == .invalidToken, "une erreur réseau n'efface pas le problème de jeton")
    }

    @Test func aQuarantineProvesTheConfigurationIsAccepted() {
        let health = PulseUploadHealth(defaults: makeDefaults())
        health.record(.quarantine)
        #expect(health.configProblem == nil)
        #expect(health.issue == nil, "le nombre de rejets se lit dans le journal")

        health.record(.keepConfigError)
        health.record(.quarantine)
        #expect(health.configProblem == nil, "Pulse a lu le fichier : jeton et source sont acceptés")
    }

    @Test func reenteringTheSettingsClearsTheConfigProblem() {
        let health = PulseUploadHealth(defaults: makeDefaults())
        health.record(.keepConfigError)
        health.clearConfigProblem()
        #expect(health.issue == nil)
    }

    @Test func rejectedFilesAreReportedWithAFrenchPlural() {
        let health = PulseUploadHealth(defaults: makeDefaults())
        health.setRejectedCount(1)
        #expect(health.issue == .rejectedFiles(1))
        #expect(health.issue?.label == "1 fichier refusé par Pulse")
        health.setRejectedCount(3)
        #expect(health.issue?.label == "3 fichiers refusés par Pulse")
        health.setRejectedCount(0)
        #expect(health.issue == nil)
    }

    @Test func theIssueIsPrioritised() {
        let health = PulseUploadHealth(defaults: makeDefaults())
        health.setRejectedCount(2)
        #expect(health.issue == .rejectedFiles(2))

        health.record(.keepRetryLater)
        #expect(health.issue == .wrongSource, "mauvaise source > fichiers rejetés")

        health.record(.keepConfigError)
        #expect(health.issue == .invalidToken, "jeton invalide > mauvaise source")

        health.record(.delivered)
        #expect(health.issue == .rejectedFiles(2), "reste les fichiers rejetés tant qu'ils sont en quarantaine")
    }

    @Test func theConfigProblemPersistsAcrossInstancesAndIsClearedOnSuccess() {
        let defaults = makeDefaults()
        let first = PulseUploadHealth(defaults: defaults)
        first.record(.keepRetryLater)

        let second = PulseUploadHealth(defaults: defaults)
        #expect(second.configProblem == .wrongSource)

        second.record(.delivered)
        #expect(PulseUploadHealth(defaults: defaults).configProblem == nil)
    }

    @Test func refreshingTheCountReadsTheInjectedSource() async {
        let health = PulseUploadHealth(defaults: makeDefaults())
        health.refreshRejectedCount(count: { 4 })
        for _ in 0..<100 where health.rejectedCount != 4 {
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(health.rejectedCount == 4)
    }
}
