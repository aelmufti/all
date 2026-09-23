//
//  RealtimeSessionTests.swift
//  allTests
//
//  Pilote `RealtimeSession` avec un communicator FACTICE (`FakeMlCommunicator`,
//  ci-dessous) — jamais de vrai CoreBluetooth/BLE, jamais de vraie donnée de
//  santé (règles immuables CLAUDE.md). Ce fichier ne re-teste PAS les décodeurs
//  purs (déjà couverts par `RealtimeDecodersTests.swift`) : il couvre ce qui
//  n'existe qu'au niveau de la session —
//    1. les toggles (on-demand only, jamais automatique, idempotents) ;
//    2. le routage handle→service et la coexistence GFDI + REALTIME_* : la
//       classe `CommunicatorV2` elle-même n'est pas testable ici (liée à
//       `CBPeripheral`/`CBCharacteristic`, qui ne se simulent pas — même
//       limite que `GarminSession`, testée via le seam `GfdiCommunicating`
//       plutôt que `CommunicatorV2` directement, cf. `TransferResilienceTests.swift`) ;
//       on pilote donc une `GarminSession` ET une `RealtimeSession` depuis LE
//       MÊME communicator factice (qui conforme aux deux protocoles, comme
//       `CommunicatorV2` en production) pour prouver la non-interférence ;
//    3. le calcul stateful du delta de pas (`steps - previousSteps`, doc §3.3,
//       volontairement absent du décodeur pur `RealtimeSteps`) ;
//    4. le mode capture (harnais octets bruts, services opaques) : gardé par
//       toggle explicite, jamais pour une métrique déjà décodée.
//

import Testing
import Foundation
@testable import all

// MARK: - Communicator ML factice (GFDI + temps réel, comme CommunicatorV2)

/// Jamais de vrai CoreBluetooth/BLE en test (règle immuable CLAUDE.md). Conforme
/// aux DEUX seams (`GfdiCommunicating`, `RealtimeMlCommunicating`) — exactement
/// comme `CommunicatorV2` en production, où un seul transport sert les deux
/// familles de service ML. Permet de piloter une `GarminSession` et une
/// `RealtimeSession` depuis la même instance, pour tester leur coexistence.
private final class FakeMlCommunicator: GfdiCommunicating, RealtimeMlCommunicating {
    // GfdiCommunicating
    var onGfdiFrame: ((GfdiFrame) -> Void)?
    var onGfdiChannelReady: (() -> Void)?
    private(set) var sentGfdiFrames: [Data] = []

    func start() {}

    func sendGfdiMessage(_ frame: Data, taskName: String) {
        sentGfdiFrames.append(frame)
    }

    /// Simule une trame GFDI déjà décodée par le transport (COBS + réassemblage
    /// retirés en amont, hors périmètre ici — déjà couvert par
    /// `GfdiTransportTests.swift`).
    func deliverGfdi(messageType: UInt16, payload: Data) {
        onGfdiFrame?(GfdiFrame(messageType: messageType, payload: payload))
    }

    // RealtimeMlCommunicating
    var onRealtimeFrame: ((RealtimeMlService, Data) -> Void)?
    private(set) var enabledServiceCalls: [RealtimeMlService] = []
    private(set) var disabledServiceCalls: [RealtimeMlService] = []

    func enableRealtimeService(_ service: RealtimeMlService) {
        enabledServiceCalls.append(service)
    }

    func disableRealtimeService(_ service: RealtimeMlService) {
        disabledServiceCalls.append(service)
    }

    /// Simule une trame `REALTIME_*` déjà routée par handle (comme le ferait
    /// `CommunicatorV2.handleIncoming` une fois le handle résolu vers son
    /// service) — un seul message par notification, pas de réassemblage (cf.
    /// commentaire de `CommunicatorV2.onRealtimeFrame`).
    func deliverRealtime(_ service: RealtimeMlService, _ data: Data) {
        onRealtimeFrame?(service, data)
    }
}

private func stepsPayload(steps: UInt32, goal: UInt32) -> Data {
    var writer = GarminByteWriter()
    writer.writeUInt32LE(steps)
    writer.writeUInt32LE(goal)
    return writer.data
}

// MARK: - 1) Toggles : on-demand only, idempotents, catégories séparées

struct RealtimeSessionToggleTests {
    @Test func nothingIsRegisteredAtConstruction() throws {
        let fake = FakeMlCommunicator()
        _ = RealtimeSession(communicator: fake)
        #expect(fake.enabledServiceCalls.isEmpty, "activation strictement on-demand — jamais automatique à la construction")
    }

    @Test func enablingAKnownServiceRegistersItOnceAndIsIdempotent() throws {
        let fake = FakeMlCommunicator()
        let session = RealtimeSession(communicator: fake)

        session.setEnabled(true, for: .spo2)
        #expect(fake.enabledServiceCalls == [.spo2])
        #expect(session.enabledServices.contains(.spo2))

        // Idempotent : un second "enable" sur un service déjà actif n'émet pas
        // un second REGISTER_ML_REQ.
        session.setEnabled(true, for: .spo2)
        #expect(fake.enabledServiceCalls == [.spo2])
    }

    @Test func disablingAServiceClosesItsHandleOnceAndIsIdempotent() throws {
        let fake = FakeMlCommunicator()
        let session = RealtimeSession(communicator: fake)

        session.setEnabled(true, for: .respiration)
        session.setEnabled(false, for: .respiration)
        #expect(fake.disabledServiceCalls == [.respiration])
        #expect(!session.enabledServices.contains(.respiration))

        // Idempotent côté désactivation aussi (jamais activé -> rien à fermer).
        session.setEnabled(false, for: .respiration)
        #expect(fake.disabledServiceCalls == [.respiration])
    }

    @Test func setEnabledRefusesAnOpaqueService() throws {
        let fake = FakeMlCommunicator()
        let session = RealtimeSession(communicator: fake)

        session.setEnabled(true, for: .stress)
        #expect(fake.enabledServiceCalls.isEmpty, "stress n'a pas de décodeur connu — setEnabled doit être un no-op, réservé à setCaptureEnabled")
        #expect(!session.enabledServices.contains(.stress))
    }

    @Test func setCaptureEnabledRefusesAKnownService() throws {
        let fake = FakeMlCommunicator()
        let session = RealtimeSession(communicator: fake)

        session.setCaptureEnabled(true, for: .steps)
        #expect(fake.enabledServiceCalls.isEmpty, "pas n'est pas opaque — toujours décodé via setEnabled, jamais capturé")
        #expect(!session.captureEnabled.contains(.steps))
    }

    @Test func disablingAKnownMetricClearsItsLastPublishedValue() throws {
        let fake = FakeMlCommunicator()
        let session = RealtimeSession(communicator: fake)

        session.setEnabled(true, for: .spo2)
        fake.deliverRealtime(.spo2, Data([0x61, 0xE8, 0x03, 0x00, 0x00])) // 97%
        #expect(session.spo2?.rawValue == 97)

        session.setEnabled(false, for: .spo2)
        #expect(session.spo2 == nil, "la dernière valeur ne doit pas rester affichée comme si elle était encore en direct")
    }
}

// MARK: - 2) Routage handle→service, coexistence GFDI + REALTIME_*

struct RealtimeSessionRoutingTests {
    /// Le point délicat de la tâche : GFDI et un ou plusieurs services
    /// `REALTIME_*` enregistrés simultanément ne doivent jamais se marcher
    /// dessus. Pilote une `GarminSession` ET une `RealtimeSession` depuis le
    /// MÊME communicator factice (comme `CommunicatorV2` conforme aux deux
    /// protocoles en production) : une trame GFDI arrivant en plein milieu d'un
    /// flux temps réel ne doit rien perturber côté `RealtimeSession`, et
    /// vice-versa.
    @Test func gfdiAndRealtimeFramesCoexistWithoutInterference() throws {
        let fake = FakeMlCommunicator()
        let garmin = GarminSession(communicator: fake, spoolStore: nil, uploader: nil)
        let realtime = RealtimeSession(communicator: fake)

        realtime.setEnabled(true, for: .spo2)
        realtime.setEnabled(true, for: .hrv)
        #expect(Set(fake.enabledServiceCalls) == [.spo2, .hrv], "les deux services temps réel enregistrés simultanément")

        // Trame temps réel SpO2.
        fake.deliverRealtime(.spo2, Data([0x61, 0xE8, 0x03, 0x00, 0x00])) // 97%, ts=1000
        #expect(realtime.spo2?.rawValue == 97)
        #expect(realtime.hrv == nil, "HRV pas encore reçu — aucune interférence croisée entre services temps réel")

        // Une trame GFDI arrive entre-temps (AUTH_NEGOTIATION, 5101) : la
        // session temps réel ne doit RIEN voir, la session GFDI répond
        // normalement — non-interférence dans les deux sens.
        garmin.start()
        let framesBeforeAuth = fake.sentGfdiFrames.count
        fake.deliverGfdi(messageType: 5101, payload: Data([0x00, 0x00, 0x00, 0x00, 0x00]))
        #expect(fake.sentGfdiFrames.count == framesBeforeAuth + 1, "GFDI répond normalement, non perturbé par les services temps réel actifs")
        #expect(realtime.spo2?.rawValue == 97, "toujours la dernière valeur SpO2 — la trame GFDI ne l'a pas écrasée")
        #expect(realtime.hrv == nil)

        // Trame temps réel HRV après la trame GFDI.
        fake.deliverRealtime(.hrv, Data([0x52, 0x03, 0x40, 0xE2, 0x01, 0x00])) // rr=850, unk=123456
        #expect(realtime.hrv?.rrIntervalRaw == 850)
        #expect(realtime.spo2?.rawValue == 97, "SpO2 toujours intact après la trame HRV — les deux services coexistent sans se corrompre")
    }

    /// Chaque service temps réel garde son état de décodage séparé — une trame
    /// pour un service n'affecte jamais la valeur publiée d'un autre.
    @Test func multipleKnownServicesDecodeIndependently() throws {
        let fake = FakeMlCommunicator()
        let realtime = RealtimeSession(communicator: fake)

        realtime.setEnabled(true, for: .steps)
        realtime.setEnabled(true, for: .respiration)

        fake.deliverRealtime(.steps, stepsPayload(steps: 500, goal: 8000))
        fake.deliverRealtime(.respiration, Data([0x10])) // 16 /min

        #expect(realtime.steps?.steps == 500)
        #expect(realtime.respiration?.breathsPerMinute == 16)
    }
}

// MARK: - 3) Calcul stateful du delta de pas

struct RealtimeSessionStepsDeltaTests {
    @Test func stepsDeltaIsComputedAgainstThePreviousReading() throws {
        let fake = FakeMlCommunicator()
        let session = RealtimeSession(communicator: fake)
        session.setEnabled(true, for: .steps)

        fake.deliverRealtime(.steps, stepsPayload(steps: 1000, goal: 10000))
        #expect(session.steps?.steps == 1000)
        #expect(session.stepsDelta == nil, "pas de valeur précédente pour la toute première trame")

        fake.deliverRealtime(.steps, stepsPayload(steps: 1042, goal: 10000))
        #expect(session.stepsDelta == 42)

        fake.deliverRealtime(.steps, stepsPayload(steps: 1042, goal: 10000))
        #expect(session.stepsDelta == 0, "deux trames identiques -> delta nul, pas nil")
    }

    @Test func disablingStepsResetsTheStatefulDeltaWithoutLeakingIntoTheNextSession() throws {
        let fake = FakeMlCommunicator()
        let session = RealtimeSession(communicator: fake)
        session.setEnabled(true, for: .steps)
        fake.deliverRealtime(.steps, stepsPayload(steps: 1000, goal: 10000))
        fake.deliverRealtime(.steps, stepsPayload(steps: 1042, goal: 10000))
        #expect(session.stepsDelta == 42)

        session.setEnabled(false, for: .steps)
        #expect(session.steps == nil)
        #expect(session.stepsDelta == nil)

        // Reprise après réactivation : pas de delta artificiel calculé contre
        // l'ancienne valeur d'avant désactivation.
        session.setEnabled(true, for: .steps)
        fake.deliverRealtime(.steps, stepsPayload(steps: 5000, goal: 10000))
        #expect(session.stepsDelta == nil, "premier échantillon de la nouvelle session — pas d'état résiduel de l'ancienne")
    }
}

// MARK: - 4) Mode capture (harnais octets bruts, services opaques)

struct RealtimeSessionCaptureTests {
    @Test func captureCountsFramesOnlyWhileToggleIsActive() throws {
        let fake = FakeMlCommunicator()
        let session = RealtimeSession(communicator: fake)

        session.setCaptureEnabled(true, for: .stress)
        #expect(fake.enabledServiceCalls == [.stress])
        #expect(session.captureFrameCounts[.stress] == 0)

        fake.deliverRealtime(.stress, Data([0x01, 0x02, 0x03]))
        fake.deliverRealtime(.stress, Data([0x04, 0x05]))
        #expect(session.captureFrameCounts[.stress] == 2)

        session.setCaptureEnabled(false, for: .stress)
        #expect(fake.disabledServiceCalls == [.stress])
    }

    @Test func captureOfOneOpaqueServiceDoesNotCountFramesOfAnother() throws {
        let fake = FakeMlCommunicator()
        let session = RealtimeSession(communicator: fake)

        session.setCaptureEnabled(true, for: .bodyBattery)
        fake.deliverRealtime(.bodyBattery, Data([0xAA]))
        fake.deliverRealtime(.calories, Data([0xBB])) // capture PAS active pour calories

        #expect(session.captureFrameCounts[.bodyBattery] == 1)
        #expect(session.captureFrameCounts[.calories] == nil)
    }

    @Test func reenablingCaptureResetsTheFrameCounter() throws {
        let fake = FakeMlCommunicator()
        let session = RealtimeSession(communicator: fake)

        session.setCaptureEnabled(true, for: .intensity)
        fake.deliverRealtime(.intensity, Data([0x01]))
        fake.deliverRealtime(.intensity, Data([0x02]))
        #expect(session.captureFrameCounts[.intensity] == 2)

        session.setCaptureEnabled(false, for: .intensity)
        session.setCaptureEnabled(true, for: .intensity)
        #expect(session.captureFrameCounts[.intensity] == 0, "nouvelle session de capture — compteur repart de zéro")
    }
}
