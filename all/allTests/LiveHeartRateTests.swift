//
//  LiveHeartRateTests.swift
//  allTests
//
//  Vecteurs de décodage de la trame Heart Rate Measurement (0x2A37) —
//  observés sur une Venu 2 réelle côté pont (`00 00` = pas de diffusion,
//  `06 4A` = drapeaux + 74 bpm, cf. LiveHeartRate.swift) — et transitions
//  warm-up/périmé du moteur, avec un « now » injecté (comme côté pont)
//  plutôt que l'horloge murale, pour des tests déterministes.
//

import Testing
import Foundation
@testable import all

struct LiveHeartRateTests {

    // MARK: - Décodage de trame

    @Test func emptyFrameIsNotBroadcasting() throws {
        let sample = LiveHeartRate.decode(Data([0x00, 0x00]), now: Date())
        #expect(sample?.heartRate == 0)
        #expect(sample?.broadcasting == false)
    }

    @Test func eightBitFrameDecodesHeartRateAndBroadcasting() throws {
        // flags = 0x06 (8 bits, capteur en contact), bpm = 0x4A = 74.
        let sample = LiveHeartRate.decode(Data([0x06, 0x4A]), now: Date())
        #expect(sample?.heartRate == 74)
        #expect(sample?.broadcasting == true)
    }

    @Test func sixteenBitFrameDecodesCombinedValue() throws {
        // flags = 0x01 (16 bits), bpm = 0x012C = 300 (petit-boutiste : octet bas puis haut).
        let sample = LiveHeartRate.decode(Data([0x01, 0x2C, 0x01]), now: Date())
        #expect(sample?.heartRate == 300)
        #expect(sample?.broadcasting == true)
    }

    @Test func sixteenBitFrameTooShortIsIgnored() throws {
        // Drapeaux annoncent 16 bits, mais un seul octet de valeur suit.
        let sample = LiveHeartRate.decode(Data([0x01, 0x2C]), now: Date())
        #expect(sample == nil)
    }

    @Test func framesBelowTwoBytesAreIgnored() throws {
        #expect(LiveHeartRate.decode(Data(), now: Date()) == nil)
        #expect(LiveHeartRate.decode(Data([0x06]), now: Date()) == nil)
    }

    @Test func contactBitWithoutRateStillCountsAsBroadcasting() throws {
        // flags = 0x04 (contact seul, bpm = 0) : capteur en marche mais rien
        // à rapporter cette seconde — distinct de la trame vide 00 00.
        let sample = LiveHeartRate.decode(Data([0x04, 0x00]), now: Date())
        #expect(sample?.heartRate == 0)
        #expect(sample?.broadcasting == true)
    }

    // MARK: - Moteur : warm-up / trames / périmé

    @Test func warmUpBeforeFirstFrameIsNotStaleAndHasNoHint() throws {
        let engine = LiveHeartRate.Engine()
        let t0 = Date()
        engine.start(now: t0)

        let reading = engine.reading(now: t0.addingTimeInterval(5))
        #expect(reading.enabled == true)
        #expect(reading.stale == false)
        #expect(reading.broadcasting == false)
        #expect(reading.hint == nil)
        #expect(reading.heartRate == nil)
    }

    @Test func staleAfterTenSecondsWithoutAnyFrame() throws {
        let engine = LiveHeartRate.Engine()
        let t0 = Date()
        engine.start(now: t0)

        let reading = engine.reading(now: t0.addingTimeInterval(11))
        #expect(reading.stale == true)
        #expect(reading.hint == nil) // pas de conseil quand c'est le lien, pas la montre
        #expect(reading.heartRate == nil)
    }

    @Test func notYetStaleJustBeforeTenSeconds() throws {
        let engine = LiveHeartRate.Engine()
        let t0 = Date()
        engine.start(now: t0)

        let reading = engine.reading(now: t0.addingTimeInterval(9))
        #expect(reading.stale == false)
    }

    @Test func notBroadcastingFrameProducesHint() throws {
        let engine = LiveHeartRate.Engine()
        let t0 = Date()
        engine.start(now: t0)
        engine.onFrame(Data([0x00, 0x00]), now: t0.addingTimeInterval(1))

        let reading = engine.reading(now: t0.addingTimeInterval(2))
        #expect(reading.stale == false)
        #expect(reading.broadcasting == false)
        #expect(reading.hint == LiveHeartRate.notBroadcastingHint)
        #expect(reading.heartRate == nil)
    }

    @Test func broadcastingFrameProducesHeartRateWithoutHint() throws {
        let engine = LiveHeartRate.Engine()
        let t0 = Date()
        engine.start(now: t0)
        let frameAt = t0.addingTimeInterval(1)
        engine.onFrame(Data([0x06, 0x4A]), now: frameAt)

        let reading = engine.reading(now: t0.addingTimeInterval(2))
        #expect(reading.stale == false)
        #expect(reading.broadcasting == true)
        #expect(reading.heartRate == 74)
        #expect(reading.hint == nil)
        #expect(reading.measuredAt == frameAt)
    }

    @Test func staleIsJudgedFromTheLastFrameNotFromStart() throws {
        let engine = LiveHeartRate.Engine()
        let t0 = Date()
        engine.start(now: t0)
        let frameAt = t0.addingTimeInterval(1)
        engine.onFrame(Data([0x06, 0x4A]), now: frameAt)

        // Onze secondes après la dernière trame (pas après le démarrage) :
        // devenu périmé, plus de bpm affiché.
        let reading = engine.reading(now: frameAt.addingTimeInterval(11))
        #expect(reading.stale == true)
        #expect(reading.heartRate == nil)
    }

    @Test func ignoredTooShortFrameDoesNotOverwriteThePreviousSample() throws {
        let engine = LiveHeartRate.Engine()
        let t0 = Date()
        engine.start(now: t0)
        engine.onFrame(Data([0x06, 0x4A]), now: t0.addingTimeInterval(1))
        // Trame invalide (16 bits annoncés, un seul octet) : ignorée.
        engine.onFrame(Data([0x01, 0x2C]), now: t0.addingTimeInterval(2))

        let reading = engine.reading(now: t0.addingTimeInterval(3))
        #expect(reading.heartRate == 74)
    }

    @Test func stopReturnsOff() throws {
        let engine = LiveHeartRate.Engine()
        let t0 = Date()
        engine.start(now: t0)
        engine.onFrame(Data([0x06, 0x4A]), now: t0.addingTimeInterval(1))
        engine.stop()

        let reading = engine.reading(now: t0.addingTimeInterval(2))
        #expect(reading == LiveHeartRate.Reading.off)
    }

    @Test func neverStartedReturnsOff() throws {
        let engine = LiveHeartRate.Engine()
        #expect(engine.reading(now: Date()) == LiveHeartRate.Reading.off)
    }
}
