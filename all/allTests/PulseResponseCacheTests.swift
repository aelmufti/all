//
//  PulseResponseCacheTests.swift
//  allTests
//
//  Cache des lectures (stale-while-revalidate) : clé, aller-retour disque,
//  éviction, invalidation (écriture, changement de mode, déconnexion, purge,
//  adresse Pulse). Dossiers TEMPORAIRES, données SYNTHÉTIQUES, aucun réseau.
//

import Testing
import Foundation
@testable import all

private func tempDir() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("pulse-cache-tests-\(UUID().uuidString)", isDirectory: true)
}

private func bytes(_ n: Int, _ fill: UInt8 = 0x61) -> Data { Data(repeating: fill, count: n) }

struct PulseResponseCacheKeyTests {
    @Test func keyDependsOnModeIdentityPathAndQuery() {
        let base = PulseResponseCache.key(mode: .pulse, identity: "https://a", path: "api/x", query: ["a": "1"])
        #expect(base != PulseResponseCache.key(mode: .phone, identity: "https://a", path: "api/x", query: ["a": "1"]))
        #expect(base != PulseResponseCache.key(mode: .both, identity: "https://a", path: "api/x", query: ["a": "1"]))
        #expect(base != PulseResponseCache.key(mode: .pulse, identity: "https://b", path: "api/x", query: ["a": "1"]))
        #expect(base != PulseResponseCache.key(mode: .pulse, identity: "https://a", path: "api/y", query: ["a": "1"]))
        #expect(base != PulseResponseCache.key(mode: .pulse, identity: "https://a", path: "api/x", query: ["a": "2"]))
    }

    @Test func queryOrderAndLeadingSlashDoNotMatter() {
        let a = PulseResponseCache.key(mode: .pulse, identity: nil, path: "/api/x", query: ["a": "1", "b": "2"])
        let b = PulseResponseCache.key(mode: .pulse, identity: nil, path: "api/x", query: ["b": "2", "a": "1"])
        #expect(a == b)
    }
}

struct PulseResponseCacheStorageTests {
    @Test func memoryRoundTrip() {
        let cache = PulseResponseCache(directory: nil)
        #expect(cache.data(forKey: "k") == nil)
        cache.store(Data("{}".utf8), forKey: "k")
        #expect(cache.data(forKey: "k") == Data("{}".utf8))
    }

    @Test func diskRoundTripSurvivesANewInstance() {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        PulseResponseCache(directory: dir).store(Data(#"{"a":1}"#.utf8), forKey: "k")

        let reopened = PulseResponseCache(directory: dir)
        #expect(reopened.diskEntryCount == 1)
        #expect(reopened.data(forKey: "k") == Data(#"{"a":1}"#.utf8))
        #expect(reopened.data(forKey: "other") == nil)
    }

    @Test func diskDirectoryIsExcludedFromBackup() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        PulseResponseCache(directory: dir).store(bytes(10), forKey: "k")
        let values = try dir.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
    }

    @Test func diskEvictsTheLeastRecentlyUsedEntry() {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = PulseResponseCache(directory: dir, memoryLimit: 10, diskLimit: 1_000)
        cache.store(bytes(400), forKey: "a")
        cache.store(bytes(400), forKey: "b")
        _ = cache.data(forKey: "a")  // « a » redevient le plus récent
        cache.store(bytes(400), forKey: "c")  // dépasse 1000 : « b » part

        let reopened = PulseResponseCache(directory: dir, memoryLimit: 10, diskLimit: 1_000)
        #expect(reopened.data(forKey: "b") == nil)
        #expect(reopened.data(forKey: "a") != nil)
        #expect(reopened.data(forKey: "c") != nil)
        #expect(cache.diskEntryCount == 2)
    }

    @Test func memoryIsBounded() {
        let cache = PulseResponseCache(directory: nil, memoryLimit: 1_000, diskLimit: 10_000)
        for i in 0..<5 { cache.store(bytes(400), forKey: "k\(i)") }
        #expect(cache.memoryEntryCount <= 2)
        cache.store(bytes(5_000), forKey: "big")
        #expect(cache.data(forKey: "big") == nil || cache.memoryEntryCount <= 1)
    }

    @Test func invalidateAllClearsMemoryAndDisk() {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = PulseResponseCache(directory: dir)
        cache.store(bytes(10), forKey: "k")
        cache.invalidateAll()
        #expect(cache.data(forKey: "k") == nil)
        #expect(PulseResponseCache(directory: dir).data(forKey: "k") == nil)
        // Toujours utilisable après invalidation.
        cache.store(bytes(10), forKey: "k2")
        #expect(PulseResponseCache(directory: dir).data(forKey: "k2") != nil)
    }

    @Test func aStoreStartedBeforeAnInvalidationIsDropped() {
        let cache = PulseResponseCache(directory: nil)
        let generation = cache.currentGeneration
        cache.invalidateAll()
        cache.store(bytes(10), forKey: "k", ifGeneration: generation)
        #expect(cache.data(forKey: "k") == nil)
    }
}

// MARK: - Intégration au client

private final class CacheBackend: LocalPulseBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var body = #"{"v":1}"#
    private var failing = false
    func setBody(_ s: String) { lock.withLock { body = s } }
    func setFailing(_ f: Bool) { lock.withLock { failing = f } }
    func handle(method: String, path: String, query: [String: String], body _: Data?) async throws -> Data {
        let (b, f) = lock.withLock { (body, failing) }
        if f { throw LocalPulseUnavailableError() }
        return Data(b.utf8)
    }
}

private struct Payload: Decodable, Equatable { let v: Int }

struct PulseResponseCacheClientTests {
    private func make(mode: @escaping () -> StorageMode = { .phone }) -> (PulseAPIClient, CacheBackend, PulseResponseCache) {
        let backend = CacheBackend()
        let cache = PulseResponseCache(directory: nil)
        let client = PulseAPIClient(baseURLProvider: { nil }, localBackend: backend, modeProvider: mode, cache: cache)
        return (client, backend, cache)
    }

    @Test func getCachedStoresThenStaleValueSurvivesAFailure() async throws {
        let (client, backend, _) = make()
        let first: Payload? = await client.cachedValue("api/x")
        #expect(first == nil)

        let fresh: Payload = try await client.getCached("api/x")
        #expect(fresh == Payload(v: 1))
        backend.setFailing(true)
        let stale: Payload? = await client.cachedValue("api/x")
        #expect(stale == Payload(v: 1))
        await #expect(throws: Error.self) { let _: Payload = try await client.getCached("api/x") }
        let kept: Payload? = await client.cachedValue("api/x")
        #expect(kept == Payload(v: 1))  // l'échec ne vide rien
    }

    @Test func plainGetNeverTouchesTheCache() async throws {
        let (client, _, cache) = make()
        let _: Payload = try await client.get("api/x")
        #expect(cache.memoryEntryCount == 0)
    }

    @Test func aStaleValueThatNoLongerDecodesIsIgnored() async throws {
        let (client, backend, _) = make()
        let _: Payload = try await client.getCached("api/x")
        backend.setBody(#"{"w":2}"#)
        struct Other: Decodable { let w: Int }
        let other: Other? = await client.cachedValue("api/x")
        #expect(other == nil)
    }

    @Test func cacheIsIsolatedPerModeAndPerQuery() async throws {
        let box = ModeBox(.phone)
        let (client, _, _) = make(mode: { box.mode })
        let _: Payload = try await client.getCached("api/x", query: ["d": "1"])
        let sameQuery: Payload? = await client.cachedValue("api/x", query: ["d": "1"])
        #expect(sameQuery != nil)
        let otherQuery: Payload? = await client.cachedValue("api/x", query: ["d": "2"])
        #expect(otherQuery == nil)
        box.mode = .both
        let otherMode: Payload? = await client.cachedValue("api/x", query: ["d": "1"])
        #expect(otherMode == nil)
    }

    @Test func aWriteInvalidatesButAuthAndLiveDoNot() async throws {
        let (client, _, cache) = make()
        let _: Payload = try await client.getCached("api/x")
        let _: Payload = try await client.post("api/live/hr/start")
        #expect(cache.memoryEntryCount == 1)
        let _: Payload = try await client.post("api/nutrition/log")
        #expect(cache.memoryEntryCount == 0)
        let stale: Payload? = await client.cachedValue("api/x")
        #expect(stale == nil)
    }

    @Test func authRoutesAreNeverCached() async {
        let (client, _, cache) = make()
        _ = try? await client.getCached("api/auth/me") as Payload
        #expect(cache.memoryEntryCount == 0)
    }
}

// MARK: - Invalidations globales (cache partagé de l'app)

// Cache PARTAGÉ : d'autres suites peuvent l'invalider en parallèle, donc seules les
// assertions « vidé » sont fiables ici (pas de « toujours présent »).
@MainActor
@Suite(.serialized)
struct PulseResponseCacheInvalidationTests {
    private func seedShared() {
        PulseResponseCache.shared.store(bytes(8), forKey: "test-sentinel")
    }
    private var sharedHasSentinel: Bool { PulseResponseCache.shared.data(forKey: "test-sentinel") != nil }

    @Test func storageModeChangeInvalidates() {
        let defaults = UserDefaults(suiteName: "cache-tests-\(UUID().uuidString)")!
        let store = StorageModeStore(defaults: defaults)
        seedShared()
        store.mode = store.mode == .phone ? .both : .phone
        #expect(!sharedHasSentinel)
    }

    @Test func logoutInvalidates() async {
        let client = PulseAPIClient(baseURLProvider: { nil }, localBackend: StubLocalPulseBackend(), modeProvider: { .pulse })
        let auth = AuthStore(client: client)
        seedShared()
        await auth.logout()
        #expect(!sharedHasSentinel)
    }

    @Test func localPurgeInvalidates() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cache-purge-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let spool = try SpoolStore(root: root)
        let db = try LocalDb(path: FileManager.default.temporaryDirectory.appendingPathComponent("cache-purge-\(UUID().uuidString).sqlite").path)
        // Les saisies d'amorce bloquent tant qu'elles ne sont pas accusées.
        let batch = try db.collectSaisieChanges(afterRev: 0, limit: 100_000)
        _ = try db.applySaisieResponse(cursor: 7, changes: [], sentMaxRev: batch.maxRev, markInitialDone: true)
        seedShared()
        _ = try LocalDataPurge.run(spool: spool, db: db)
        #expect(!sharedHasSentinel)
    }
}
