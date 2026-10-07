//
//  UploadDispatchQueueTests.swift
//  allTests
//
//  File d'envoi PURE (`Sync/UploadDispatchQueue.swift`, défaut 6) : borne de
//  concurrence, ordre, absence de double envoi, fichier relu, fin de session —
//  sans BLE ni réseau — et préparation d'un envoi hors du fil principal
//  (`PulseSpoolUploader`, transport factice : jamais d'`URLSession`). Le pilotage
//  de `GarminSession` par cette file vit dans `TransferResilienceTests.swift`
//  (`GarminSessionUploadQueueTests`).
//

import Testing
import CryptoKit
import Foundation
@testable import all

// MARK: - Fixtures

private func entry(_ index: Int, acquiredAt: Double = 1_700_000_000, state: SpoolState = .acquired) -> SpoolEntry {
    SpoolEntry(
        id: WatchFileID(fileType: (128 << 8) | 4, index: index, name: "ACTIVITY_\(index).fit"),
        state: state, acquiredAt: Date(timeIntervalSince1970: acquiredAt + Double(index)),
        relativePath: "ACTIVITY/ACTIVITY_\(index).fit")
}

private func key(_ entry: SpoolEntry) -> UploadDispatchQueue.Key {
    UploadDispatchQueue.Key(id: entry.id, acquiredAt: entry.acquiredAt)
}

// MARK: - Borne et ordre

struct UploadDispatchQueueLimitTests {
    @Test func neverStartsMoreThanTheLimitAtOnce() {
        var queue = UploadDispatchQueue(maxConcurrent: 2)
        for index in 1...5 { queue.enqueue(entry(index)) }

        let first = queue.next(), second = queue.next(), third = queue.next()
        #expect(first != nil)
        #expect(second != nil)
        #expect(third == nil, "borne atteinte : le troisième attend")
        #expect(queue.inFlight.count == 2)
        #expect(queue.queued.count == 3)
    }

    @Test func theQueueDrainsInOrderAsSlotsFree() {
        var queue = UploadDispatchQueue(maxConcurrent: 2)
        let entries = (1...5).map { entry($0) }
        entries.forEach { queue.enqueue($0) }

        var started: [Int] = []
        let first = queue.next()!, second = queue.next()!
        started += [first.id.index, second.id.index]
        let blocked = queue.next()
        #expect(blocked == nil)

        queue.finish(second) // un créneau libre → le suivant, dans l'ordre
        let third = queue.next()!
        started.append(third.id.index)
        let blockedAgain = queue.next()
        #expect(blockedAgain == nil)

        queue.finish(first)
        queue.finish(third)
        while let next = queue.next() {
            started.append(next.id.index)
            queue.finish(next)
        }
        #expect(started == [1, 2, 3, 4, 5])
        #expect(queue.isIdle)
    }

    @Test func theLimitIsAtLeastOne() {
        var queue = UploadDispatchQueue(maxConcurrent: 0)
        queue.enqueue(entry(1))
        let started = queue.next()
        #expect(started != nil, "une borne nulle bloquerait tout envoi")
    }

    @Test func outstandingCountsQueuedAndInFlight() {
        var queue = UploadDispatchQueue(maxConcurrent: 1)
        #expect(queue.isIdle)
        queue.enqueue(entry(1))
        queue.enqueue(entry(2))
        #expect(queue.outstanding == 2, "en file = pas retombé")
        let started = queue.next()!
        #expect(queue.outstanding == 2, "en vol + en file")
        queue.finish(started)
        #expect(queue.outstanding == 1)
        #expect(!queue.isIdle, "le suivant n'est pas encore parti")
        queue.finish(queue.next()!)
        #expect(queue.isIdle)
    }
}

// MARK: - Pas de double envoi, fichier relu

struct UploadDispatchQueueDedupTests {
    @Test func theSameContentQueuedOrInFlightIsNeverAcceptedTwice() {
        var queue = UploadDispatchQueue(maxConcurrent: 1)
        let one = entry(1), two = entry(2)
        let acceptedOne = queue.enqueue(one), acceptedTwo = queue.enqueue(two), acceptedTwoAgain = queue.enqueue(two)
        #expect(acceptedOne)
        #expect(acceptedTwo)
        #expect(!acceptedTwoAgain, "déjà en file")

        let started = queue.next()! // `one` part
        #expect(started == key(one))
        let acceptedInFlight = queue.enqueue(one)
        #expect(!acceptedInFlight, "déjà en vol")
        #expect(queue.outstanding == 2)
    }

    @Test func aFinishedContentCanBeEnqueuedAgainForALaterRetry() {
        var queue = UploadDispatchQueue(maxConcurrent: 1)
        let one = entry(1)
        queue.enqueue(one)
        queue.finish(queue.next()!) // issue `keepRetry` : gardé, réessai au manifeste suivant
        let accepted = queue.enqueue(one)
        #expect(accepted)
    }

    @Test func aReReadFileInFlightCanBeSentAgainUnderItsNewContent() {
        var queue = UploadDispatchQueue(maxConcurrent: 2)
        let old = entry(1)
        queue.enqueue(old)
        let started = queue.next()!
        #expect(started == key(old))

        let reread = SpoolEntry(id: old.id, state: .acquired, acquiredAt: old.acquiredAt.addingTimeInterval(0.001), relativePath: old.relativePath)
        let accepted = queue.enqueue(reread)
        #expect(accepted, "nouvel acquiredAt = autre contenu")
        let startedReread = queue.next()
        #expect(startedReread == key(reread))
        #expect(queue.inFlight.count == 2, "l'ancien reste en vol : son issue sera ignorée par le jeton")
    }

    @Test func aReReadFileStillQueuedReplacesItsStaleContent() {
        var queue = UploadDispatchQueue(maxConcurrent: 1)
        let blocker = entry(9), old = entry(1)
        queue.enqueue(blocker)
        _ = queue.next() // occupe l'unique créneau
        queue.enqueue(old)

        let reread = SpoolEntry(id: old.id, state: .acquired, acquiredAt: old.acquiredAt.addingTimeInterval(0.001), relativePath: old.relativePath)
        let accepted = queue.enqueue(reread)
        #expect(accepted)
        #expect(queue.queued == [key(reread)], "l'ancien contenu, jamais parti, est écarté")
    }
}

// MARK: - Fin de session

struct UploadDispatchQueueCancelTests {
    @Test func cancelDropsWhatWaitsAndKeepsWhatIsInFlight() {
        var queue = UploadDispatchQueue(maxConcurrent: 1)
        let entries = (1...3).map { entry($0) }
        entries.forEach { queue.enqueue($0) }
        let started = queue.next()!

        let dropped = queue.cancelQueued()

        #expect(dropped == [key(entries[1]), key(entries[2])])
        let none = queue.next()
        #expect(none == nil)
        #expect(queue.outstanding == 1, "l'envoi en vol n'est pas interrompu")
        queue.finish(started)
        #expect(queue.isIdle, "rien ne reste bloqué")
    }
}

// MARK: - Sélection

struct UploadDispatchQueuePendingTests {
    private func raw(_ index: Int, at seconds: Double, _ state: SpoolState) -> SpoolEntry {
        SpoolEntry(
            id: WatchFileID(fileType: (128 << 8) | 4, index: index, name: "ACTIVITY_\(index).fit"),
            state: state, acquiredAt: Date(timeIntervalSince1970: 1_700_000_000 + seconds),
            relativePath: "ACTIVITY/ACTIVITY_\(index).fit")
    }

    @Test func pendingKeepsOnlyAcquiredEntriesInAcquisitionThenIndexOrder() {
        let entries = [
            raw(7, at: 100, .acquired), raw(3, at: 100, .acquired), raw(4, at: 100, .acquired),
            raw(1, at: 300, .delivered), raw(5, at: 0, .archived), raw(2, at: 0, .acquired),
        ]
        let pending = UploadDispatchQueue.pending(from: entries)

        // Ancien d'abord ; à date égale, index croissant ; jamais un état ≠ acquired.
        #expect(pending.map(\.id.index) == [2, 3, 4, 7])
    }
}

// MARK: - Préparation hors du fil principal

/// Transport factice : enregistre sur quel fil `send` est appelé (donc où la
/// préparation — hachage compris — s'est exécutée) et répond tout de suite.
private final class ThreadRecordingTransport: PulseUploadTransport {
    private(set) var sendWasOnMainThread: Bool?
    private(set) var sentHash: String?
    func send(_ request: URLRequest, fileURL: URL, completion: @escaping (Result<Int, Error>) -> Void) {
        sendWasOnMainThread = Thread.isMainThread
        sentHash = request.value(forHTTPHeaderField: "X-Content-SHA256")
        completion(.success(200))
    }
}

struct PulseSpoolUploaderOffMainThreadTests {
    private func makeFile(bytes: Int) throws -> (url: URL, data: Data) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pulse-offmain-\(UUID().uuidString).fit")
        let data = Data((0..<bytes).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
        try data.write(to: url)
        return (url, data)
    }

    private let config: () -> (baseURL: URL, token: String)? = { (URL(string: "https://pulse.example.ts.net")!, "t") }

    /// Le hachage (et la construction de requête) n'ont pas lieu dans le fil de
    /// l'appelant : `send` n'est jamais appelé depuis le main, et l'issue arrive
    /// de façon asynchrone. Appelé DEPUIS le main (`@MainActor`) comme
    /// `GarminSession`.
    @MainActor
    @Test func hashingAndRequestPreparationRunOffTheMainThread() async throws {
        let (url, data) = try makeFile(bytes: 600_000) // > 2 blocs de lecture
        defer { try? FileManager.default.removeItem(at: url) }
        let transport = ThreadRecordingTransport()
        let uploader = PulseSpoolUploader(transport: transport, configuration: config)

        let outcome: PulseUploadOutcome = await withCheckedContinuation { continuation in
            uploader.upload(fileURL: url, watchFilename: "x.fit") { continuation.resume(returning: $0) }
        }

        #expect(outcome == .delivered)
        #expect(transport.sendWasOnMainThread == false)
        #expect(transport.sentHash == SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), "hachage par blocs = hachage d'un seul tenant")
    }

    @MainActor
    @Test func theCallerIsNotBlockedUntilThePreparationIsDone() async throws {
        let (url, _) = try makeFile(bytes: 1_000)
        defer { try? FileManager.default.removeItem(at: url) }
        // File de préparation bloquée : si `upload` hachait dans le fil de
        // l'appelant, la complétion arriverait avant le retour.
        let gate = DispatchSemaphore(value: 0)
        let queue = DispatchQueue(label: "test.prep")
        queue.async { gate.wait() }
        let transport = ThreadRecordingTransport()
        let uploader = PulseSpoolUploader(transport: transport, prepQueue: queue, configuration: config)

        var completed = false
        let outcome: PulseUploadOutcome = await withCheckedContinuation { continuation in
            uploader.upload(fileURL: url, watchFilename: "x.fit") { completed = true; continuation.resume(returning: $0) }
            #expect(!completed, "upload a rendu la main avant toute préparation")
            #expect(transport.sendWasOnMainThread == nil)
            gate.signal()
        }
        #expect(outcome == .delivered)
    }

    @MainActor
    @Test func missingConfigurationAnswersKeepConfigErrorWithoutHashing() async throws {
        let transport = ThreadRecordingTransport()
        let uploader = PulseSpoolUploader(transport: transport, configuration: { nil })
        let outcome: PulseUploadOutcome = await withCheckedContinuation { continuation in
            uploader.upload(fileURL: URL(fileURLWithPath: "/nonexistent.fit"), watchFilename: "x.fit") { continuation.resume(returning: $0) }
        }
        #expect(outcome == .keepConfigError)
        #expect(transport.sentHash == nil)
    }

    @MainActor
    @Test func anUnreadableFileKeepsTheEntryForRetry() async throws {
        let transport = ThreadRecordingTransport()
        let uploader = PulseSpoolUploader(transport: transport, configuration: config)
        let outcome: PulseUploadOutcome = await withCheckedContinuation { continuation in
            uploader.upload(fileURL: URL(fileURLWithPath: "/nonexistent.fit"), watchFilename: "x.fit") { continuation.resume(returning: $0) }
        }
        #expect(outcome == .keepRetry)
    }
}
