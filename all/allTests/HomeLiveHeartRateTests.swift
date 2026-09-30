//
//  HomeLiveHeartRateTests.swift
//  allTests
//
//  Bug : en mode Téléphone, `HomeViewModel.refreshLive/startLive/stopLive`
//  interrogeaient encore `api/live/hr[/start|/stop]` — route absente du
//  backend local (pas de serveur à interroger en arrière-plan) — la FC en
//  direct ne s'affichait donc jamais et le bouton « Reprendre la mesure »
//  restait inerte. Couvre :
//  - `HomeViewModel.mapPhoneLiveHeartRate` (fonction PURE) : bpm valide →
//    `heartRate` renseigné, `enabled`/`broadcasting` vrais ; bpm absent →
//    pas de diffusion.
//  - qu'en mode Téléphone, `refreshLive`/`startLive`/`stopLive` ne touchent
//    JAMAIS le client réseau — via une session qui enregistre tout appel
//    reçu, comme l'écriture du poids bascule sur `BLEManager` plutôt que le
//    socle réseau (`HealthViewModel.saveWeight`).
//
//  La mesure BLE réelle (`BLEManager.liveHeartRate`, alimentée par
//  `handleRealtimeHeartRate` depuis la FC GFDI temps réel) est HARDWARE-ONLY
//  (Venu 2 requise) — non couverte ici, cf. rapport d'incrément.
//

import Testing
import Foundation
@testable import all

// MARK: - mapPhoneLiveHeartRate — mapping PUR

struct HomeLiveHeartRateMappingTests {
    @Test func validReadingMapsToBroadcastingHeartRate() {
        let reading = LiveHeartRate.Reading(
            enabled: true, broadcasting: true, heartRate: 74,
            measuredAt: Date(timeIntervalSince1970: 1_700_000_000), stale: false, hint: nil
        )

        let mapped = HomeViewModel.mapPhoneLiveHeartRate(reading: reading, connected: true, wantsRealtime: true)

        #expect(mapped.reachable == true)
        #expect(mapped.enabled == true)
        #expect(mapped.broadcasting == true)
        #expect(mapped.heartRate == 74)
        #expect(mapped.stale == false)
        #expect(mapped.measuredAt != nil)
    }

    @Test func nilReadingMeansNotBroadcasting() {
        let mapped = HomeViewModel.mapPhoneLiveHeartRate(reading: nil, connected: true, wantsRealtime: true)

        #expect(mapped.broadcasting == false)
        #expect(mapped.heartRate == nil)
        #expect(mapped.measuredAt == nil)
        // « activé » reflète l'intention (`wantsRealtime`), pas la présence
        // d'un bpm : en attente de la première trame GFDI (~1 s) après
        // `startRealtime()`, le bouton doit déjà avoir basculé.
        #expect(mapped.enabled == true)
    }

    @Test func notWantingRealtimeMeansNotEnabledEvenWithAReading() {
        let reading = LiveHeartRate.Reading(
            enabled: true, broadcasting: true, heartRate: 60, measuredAt: Date(), stale: false, hint: nil)

        let mapped = HomeViewModel.mapPhoneLiveHeartRate(reading: reading, connected: true, wantsRealtime: false)

        #expect(mapped.enabled == false)
        // Le dernier bpm connu reste affiché — seul `enabled` bascule
        // (`stopRealtime()` efface par ailleurs `BLEManager.liveHeartRate`
        // lui-même, donc ce cas ne survient pas en pratique via `BLEManager`,
        // mais le mapping ne doit pas en dépendre pour rester correct isolément).
        #expect(mapped.broadcasting == true)
    }

    @Test func notConnectedMeansNotReachable() {
        let mapped = HomeViewModel.mapPhoneLiveHeartRate(reading: nil, connected: false, wantsRealtime: false)

        #expect(mapped.reachable == false)
    }
}

// MARK: - Mode Téléphone : aucune requête réseau

/// Session d'interception qui échoue systématiquement ET compte les requêtes
/// reçues — l'assertion porte sur ce compteur (0 en mode Téléphone), pas
/// seulement sur l'absence de crash, pour distinguer « le code n'a jamais
/// tenté d'appeler le serveur » de « l'appel a échoué silencieusement ».
private final class RecordingFailingURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requestCount = 0

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requestCount += 1
        client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
    }

    override func stopLoading() {}
}

private func failingClient() -> PulseAPIClient {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [RecordingFailingURLProtocol.self]
    let session = URLSession(configuration: config)
    return PulseAPIClient(session: session, baseURLProvider: { URL(string: "https://pulse.invalid") })
}

/// `.serialized` : mute `StorageModeStore.shared` (donc `UserDefaults
/// .standard`, singleton global partagé par tout le process de test — même
/// prudence que `StorageModeStoreTests`, cf. `StorageModeTests.swift`) et le
/// compteur statique `RecordingFailingURLProtocol.requestCount` ; restaurés
/// dans `defer`/réinitialisés à chaque test pour ne jamais dépendre de
/// l'ordre d'exécution.
@Suite(.serialized)
struct HomeViewModelPhoneModeTests {
    @Test @MainActor func refreshLiveInPhoneModeNeverTouchesTheNetwork() async {
        let previous = StorageModeStore.shared.mode
        defer { StorageModeStore.shared.mode = previous }
        StorageModeStore.shared.mode = .phone
        RecordingFailingURLProtocol.requestCount = 0

        let viewModel = HomeViewModel(client: failingClient())
        await viewModel.refreshLive()
        await viewModel.startLive()
        await viewModel.stopLive()

        #expect(RecordingFailingURLProtocol.requestCount == 0)
    }

    /// Contre-épreuve : le harnais lui-même sollicite bien le réseau en mode
    /// Pulse (sinon le zéro ci-dessus ne prouverait rien) — l'appel échoue
    /// via `RecordingFailingURLProtocol`, capturé par le `catch` existant de
    /// `refreshLive` (`live = nil`), sans crash.
    @Test @MainActor func refreshLiveInPulseModeDoesTouchTheNetwork() async {
        let previous = StorageModeStore.shared.mode
        defer { StorageModeStore.shared.mode = previous }
        StorageModeStore.shared.mode = .pulse
        RecordingFailingURLProtocol.requestCount = 0

        let viewModel = HomeViewModel(client: failingClient())
        await viewModel.refreshLive()

        #expect(RecordingFailingURLProtocol.requestCount > 0)
        #expect(viewModel.live == nil)
    }
}
