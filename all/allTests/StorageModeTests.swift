//
//  StorageModeTests.swift
//  allTests
//
//  Réglage « Stockage » (incrément L0, `docs/stockage-local.md`) :
//  persistance (`StorageModeStore`) et routage de l'upload Spool
//  (`RoutingSpoolUploader`). Aucun réseau réel — `RoutingSpoolUploader` est
//  testé avec un `SpoolUploading` factice qui enregistre ses appels, jamais
//  `PulseSpoolUploader`/`URLSessionPulseUploadTransport` (règle immuable du
//  dépôt).
//

import Testing
import Foundation
@testable import all

// MARK: - StorageModeStore — persistance

/// `.serialized` : `currentReflectsSharedLiveWithoutCapturingAStaleValue`
/// mute le singleton global `StorageModeStore.shared` (donc `UserDefaults
/// .standard` partagé par tout le process de test) — comme
/// `PulseLiveHrPusherTests` avec `PulseConfig` (cf. `LiveHeartRatePushTests.swift`).
/// Les deux autres tests utilisent une `UserDefaults(suiteName:)` dédiée,
/// donc ne pourraient de toute façon pas entrer en course avec lui — mais on
/// garde tout le fichier dans une seule suite `.serialized` pour rester simple
/// et ne jamais avoir à ré-justifier cette distinction plus tard.
@Suite(.serialized)
struct StorageModeStoreTests {
    @Test @MainActor func newInstanceDefaultsToPulseWhenNothingPersisted() {
        let suiteName = "storage-mode-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = StorageModeStore(defaults: defaults)

        #expect(store.mode == .pulse)
    }

    @Test @MainActor func persistsAcrossInstancesOfTheSameDefaults() {
        let suiteName = "storage-mode-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = StorageModeStore(defaults: defaults)
        store.mode = .both

        let reloaded = StorageModeStore(defaults: defaults)
        #expect(reloaded.mode == .both)
    }

    /// `.current` (lecture non-isolée, cf. en-tête de `StorageModeStore.swift`)
    /// doit refléter la même valeur que `.shared`, en LIVE — jamais une valeur
    /// figée — puisque c'est ce que `GarminSession`/`PulseAPIClient`/
    /// `PulseLiveHrPusher` relisent à chaque appel.
    @Test @MainActor func currentReflectsSharedLiveWithoutCapturingAStaleValue() {
        let previous = StorageModeStore.current
        defer { StorageModeStore.shared.mode = previous }

        StorageModeStore.shared.mode = .phone
        #expect(StorageModeStore.current == .phone)

        StorageModeStore.shared.mode = .both
        #expect(StorageModeStore.current == .both)

        StorageModeStore.shared.mode = .pulse
        #expect(StorageModeStore.current == .pulse)
    }
}

// MARK: - RoutingSpoolUploader — routage de l'upload selon le mode

/// Uploader factice — enregistre chaque appel, ne touche jamais le réseau ni
/// le disque.
private final class RecordingSpoolUploading: SpoolUploading {
    private(set) var calls: [(fileURL: URL, watchFilename: String)] = []
    var outcomeToReturn: PulseUploadOutcome = .delivered

    func upload(fileURL: URL, watchFilename: String, completion: @escaping (PulseUploadOutcome) -> Void) {
        calls.append((fileURL, watchFilename))
        completion(outcomeToReturn)
    }
}

struct RoutingSpoolUploaderTests {
    /// N'a pas besoin d'exister sur disque : ni `RoutingSpoolUploader` ni
    /// `RecordingSpoolUploading` ne lisent le fichier, ils ne font que router
    /// l'appel — contrairement à `PulseUploader.sha256Hex` (hors périmètre ici).
    private let fixtureURL = URL(fileURLWithPath: "/tmp/routing-uploader-fixture.fit")

    @Test func phoneModeDeliversImmediatelyWithoutCallingTheInnerUploader() {
        let inner = RecordingSpoolUploading()
        let router = RoutingSpoolUploader(pulseUploader: inner, mode: { .phone })

        var captured: PulseUploadOutcome?
        router.upload(fileURL: fixtureURL, watchFilename: "x.fit") { captured = $0 }

        #expect(captured == .delivered, "livraison locale = même issue qu'un 2xx Pulse, pour déclencher l'archivage montre")
        #expect(inner.calls.isEmpty, "le mode Téléphone ne doit JAMAIS toucher l'uploader Pulse (aucune requête réseau)")
    }

    @Test func pulseModeDelegatesToTheInnerUploaderUnchanged() {
        let inner = RecordingSpoolUploading()
        inner.outcomeToReturn = .keepRetry
        let router = RoutingSpoolUploader(pulseUploader: inner, mode: { .pulse })

        var captured: PulseUploadOutcome?
        router.upload(fileURL: fixtureURL, watchFilename: "x.fit") { captured = $0 }

        #expect(captured == .keepRetry)
        #expect(inner.calls.count == 1)
        #expect(inner.calls.first?.watchFilename == "x.fit")
    }

    @Test func bothModeAlsoDelegatesToTheInnerUploaderUnchanged() {
        let inner = RecordingSpoolUploading()
        inner.outcomeToReturn = .quarantine
        let router = RoutingSpoolUploader(pulseUploader: inner, mode: { .both })

        var captured: PulseUploadOutcome?
        router.upload(fileURL: fixtureURL, watchFilename: "y.fit") { captured = $0 }

        #expect(captured == .quarantine)
        #expect(inner.calls.count == 1)
        #expect(inner.calls.first?.watchFilename == "y.fit")
    }

    /// Le mode est relu à CHAQUE appel (jamais capturé) — un `RoutingSpoolUploader`
    /// construit une fois doit voir un changement de mode d'un appel à l'autre.
    @Test func rereadsTheModeOnEachCallRatherThanCapturingItAtInit() {
        var mode = StorageMode.pulse
        let inner = RecordingSpoolUploading()
        let router = RoutingSpoolUploader(pulseUploader: inner, mode: { mode })

        var firstOutcome: PulseUploadOutcome?
        router.upload(fileURL: fixtureURL, watchFilename: "a.fit") { firstOutcome = $0 }
        #expect(firstOutcome == .delivered)
        #expect(inner.calls.count == 1)

        mode = .phone
        var secondOutcome: PulseUploadOutcome?
        router.upload(fileURL: fixtureURL, watchFilename: "b.fit") { secondOutcome = $0 }
        #expect(secondOutcome == .delivered)
        #expect(inner.calls.count == 1, "toujours 1 : le second appel (mode phone) n'a pas dû retoucher l'uploader Pulse")
    }
}
