//
//  RealtimeDecodersTests.swift
//  allTests
//
//  Vecteurs de décodage des charges utiles ML `REALTIME_*` (Live-2, GFDI V2).
//  Les cas entiers (FC, pas, VFC, SpO2, respiration) sont construits à la main à
//  partir du format documenté dans gadgetbridge upstream (petit-boutiste, comme
//  le reste du protocole GFDI déjà porté). Le cas accéléromètre — empaquetage en
//  nibbles signés 12 bits — est dérivé en exécutant un port Python fidèle de
//  `RealtimeAccelerometerCallback` (gadgetbridge upstream) sur des valeurs brutes
//  connues, la même méthode que `GfdiFrameTests.swift` pour les trames GFDI.
//

import Testing
import Foundation
@testable import all

struct RealtimeDecodersTests {

    // MARK: - RealtimeMlService (métadonnées, aucun décodage)

    @Test func knownDecodersMatchImplementedServices() throws {
        #expect(RealtimeMlService.heartRate.hasKnownDecoder)
        #expect(RealtimeMlService.steps.hasKnownDecoder)
        #expect(RealtimeMlService.hrv.hasKnownDecoder)
        #expect(RealtimeMlService.accelerometer.hasKnownDecoder)
        #expect(RealtimeMlService.spo2.hasKnownDecoder)
        #expect(RealtimeMlService.respiration.hasKnownDecoder)
        #expect(!RealtimeMlService.calories.hasKnownDecoder)
        #expect(!RealtimeMlService.intensity.hasKnownDecoder)
        #expect(!RealtimeMlService.stress.hasKnownDecoder)
        #expect(!RealtimeMlService.bodyBattery.hasKnownDecoder)
    }

    @Test func serviceCodesMatchGadgetbridgeEnum() throws {
        // CommunicatorV2.Service côté gadgetbridge upstream (non strippé) :
        // GFDI(1), REGISTRATION(4), REALTIME_HR(6), REALTIME_STEPS(7),
        // REALTIME_CALORIES(8), REALTIME_INTENSITY(10), REALTIME_HRV(12),
        // REALTIME_STRESS(13), REALTIME_ACCELEROMETER(16), REALTIME_SPO2(19),
        // REALTIME_BODY_BATTERY(20), REALTIME_RESPIRATION(21).
        #expect(RealtimeMlService.heartRate.rawValue == 6)
        #expect(RealtimeMlService.steps.rawValue == 7)
        #expect(RealtimeMlService.calories.rawValue == 8)
        #expect(RealtimeMlService.intensity.rawValue == 10)
        #expect(RealtimeMlService.hrv.rawValue == 12)
        #expect(RealtimeMlService.stress.rawValue == 13)
        #expect(RealtimeMlService.accelerometer.rawValue == 16)
        #expect(RealtimeMlService.spo2.rawValue == 19)
        #expect(RealtimeMlService.bodyBattery.rawValue == 20)
        #expect(RealtimeMlService.respiration.rawValue == 21)
    }

    // MARK: - Fréquence cardiaque (REALTIME_HR)

    @Test func heartRateDecodesTypeAndValues() throws {
        let sample = RealtimeHeartRate.decode(Data([0x03, 0x4A, 0x28]))
        #expect(sample?.rawType == 0x03)
        #expect(sample?.heartRate == 74)
        #expect(sample?.restingHeartRate == 40)
        #expect(sample?.isValid == true)
    }

    @Test func heartRateZeroIsNotValid() throws {
        let sample = RealtimeHeartRate.decode(Data([0x00, 0x00, 0x00]))
        #expect(sample?.heartRate == 0)
        #expect(sample?.isValid == false)
    }

    @Test func heartRateTooShortIsNil() throws {
        #expect(RealtimeHeartRate.decode(Data([0x01, 0x02])) == nil)
    }

    // MARK: - Pas (REALTIME_STEPS)

    @Test func stepsDecodesStepsAndGoal() throws {
        // steps = 1234 (0x000004D2), goal = 10000 (0x00002710), LE.
        let data = Data([0xD2, 0x04, 0x00, 0x00, 0x10, 0x27, 0x00, 0x00])
        let sample = RealtimeSteps.decode(data)
        #expect(sample?.steps == 1234)
        #expect(sample?.goal == 10000)
    }

    @Test func stepsTooShortIsNil() throws {
        let data = Data([0xD2, 0x04, 0x00, 0x00, 0x10, 0x27, 0x00]) // 7 octets
        #expect(RealtimeSteps.decode(data) == nil)
    }

    // MARK: - SpO2 (REALTIME_SPO2)

    @Test func spo2ValidValueExposesTimestamp() throws {
        // spo2 = 97, garminTs = 1000 (0x000003E8), LE.
        let data = Data([0x61, 0xE8, 0x03, 0x00, 0x00])
        let sample = RealtimeSpo2.decode(data)
        #expect(sample?.rawValue == 97)
        #expect(sample?.isValid == true)
        let expected = Date(timeIntervalSince1970: 1000 + GarminEpoch.offsetFromUnix)
        #expect(sample?.timestamp == expected)
    }

    @Test func spo2UnknownValueHasNoTimestamp() throws {
        // spo2 = -1 (0xFF), garminTs = 12345 (0x00003039), LE — non fiable ici.
        let data = Data([0xFF, 0x39, 0x30, 0x00, 0x00])
        let sample = RealtimeSpo2.decode(data)
        #expect(sample?.rawValue == -1)
        #expect(sample?.isValid == false)
        #expect(sample?.timestamp == nil)
    }

    @Test func spo2TooShortIsNil() throws {
        #expect(RealtimeSpo2.decode(Data([0x61, 0xE8, 0x03, 0x00])) == nil) // 4 octets
    }

    // MARK: - Respiration (REALTIME_RESPIRATION)

    @Test func respirationDecodesPositiveValue() throws {
        let sample = RealtimeRespiration.decode(Data([0x10])) // 16
        #expect(sample?.breathsPerMinute == 16)
    }

    @Test func respirationDecodesNegativeSentinel() throws {
        let sample = RealtimeRespiration.decode(Data([0xFE])) // -2
        #expect(sample?.breathsPerMinute == -2)
    }

    @Test func respirationEmptyIsNil() throws {
        #expect(RealtimeRespiration.decode(Data()) == nil)
    }

    // MARK: - VFC / intervalle RR (REALTIME_HRV)

    @Test func hrvDecodesRrAndUnknown() throws {
        // rr = 850 (0x0352), unk = 123456 (0x0001E240), LE.
        let data = Data([0x52, 0x03, 0x40, 0xE2, 0x01, 0x00])
        let sample = RealtimeHrv.decode(data)
        #expect(sample?.rrIntervalRaw == 850)
        #expect(sample?.unknown == 123456)
    }

    @Test func hrvTooShortIsNil() throws {
        let data = Data([0x52, 0x03, 0x40, 0xE2, 0x01]) // 5 octets
        #expect(RealtimeHrv.decode(data) == nil)
    }

    // MARK: - Accéléromètre (REALTIME_ACCELEROMETER)
    //
    // Vecteur dérivé d'un port Python fidèle de `RealtimeAccelerometerCallback`
    // (gadgetbridge upstream), exécuté sur 9 valeurs brutes signées 12 bits
    // choisies pour couvrir zéro, positif, négatif, et les bornes (-2048, 2047,
    // 4095 = -1 en complément à deux, 2048 = -2048, etc.) :
    // raws = [0, 2047, -2048, 100, -100, 4095, 1, 4094, 2048]
    // header : numSamples=3, timestamp=1234 (0x4D2) -> 0x64D2 -> octets D2 64.

    @Test func accelerometerDecodesThreeSamples() throws {
        let data = Data([
            0xD2, 0x64, 0x00, 0xF0, 0x7F, 0x00, 0x48, 0x06,
            0x9C, 0xFF, 0xFF, 0x01, 0xE0, 0xFF, 0x00, 0x08,
        ])
        #expect(data.count == 16)

        let frame = try #require(RealtimeAccelerometerFrame.decode(data))
        #expect(frame.timestampMs13Bit == 1234)
        #expect(frame.samples.count == 3)

        let tolerance: Float = 0.001

        #expect(abs(frame.samples[0].x - 0) < tolerance)
        #expect(abs(frame.samples[0].y - (-78.44168)) < tolerance)
        #expect(abs(frame.samples[0].z - 78.48) < tolerance)

        #expect(abs(frame.samples[1].x - (-3.832031)) < tolerance)
        #expect(abs(frame.samples[1].y - 3.832031) < tolerance)
        #expect(abs(frame.samples[1].z - 0.038320) < tolerance)

        #expect(abs(frame.samples[2].x - (-0.038320)) < tolerance)
        #expect(abs(frame.samples[2].y - 0.076641) < tolerance)
        #expect(abs(frame.samples[2].z - 78.48) < tolerance)
    }

    @Test func accelerometerWrongLengthIsNil() throws {
        #expect(RealtimeAccelerometerFrame.decode(Data(repeating: 0, count: 15)) == nil)
        #expect(RealtimeAccelerometerFrame.decode(Data(repeating: 0, count: 17)) == nil)
    }

    @Test func accelerometerZeroSamplesDecodesEmptyArray() throws {
        // numSamples = 0 dans l'en-tête -> tableau vide, pas nil (le pont ne
        // traite simplement aucune itération de sa boucle).
        var bytes = [UInt8](repeating: 0, count: 16)
        let header: UInt16 = 42 // numSamples = 0 (bits 13..15), timestamp = 42
        bytes[0] = UInt8(header & 0xFF)
        bytes[1] = UInt8(header >> 8)
        let frame = try #require(RealtimeAccelerometerFrame.decode(Data(bytes)))
        #expect(frame.timestampMs13Bit == 42)
        #expect(frame.samples.isEmpty)
    }

    @Test func accelerometerTooManySamplesIsNil() throws {
        // numSamples = 4 (bits 13..15 = 100) est aberrant (max 3 côté pont).
        var bytes = [UInt8](repeating: 0, count: 16)
        let header: UInt16 = 4 << 13
        bytes[0] = UInt8(header & 0xFF)
        bytes[1] = UInt8(header >> 8)
        #expect(RealtimeAccelerometerFrame.decode(Data(bytes)) == nil)
    }
}
