//
//  CobsTests.swift
//  allTests
//
//  Reproduit CobsCoDecTest.java (garmin-bridge/src/test/java/.../communicator/
//  CobsCoDecTest.java) — mêmes octets, mêmes scénarios, faisant autorité pour le
//  comportement à état du décodeur COBS Garmin (bourrage de tête + queue 0x00).
//

import Testing
import Foundation
@testable import all

struct CobsTests {

    @Test func roundTripsPlainPayload() throws {
        let payload = Data([0x01, 0x02, 0x03, 0x04])
        let encoded = CobsDecoder.encode(payload)
        let decoder = CobsDecoder()
        decoder.receivedBytes(encoded)
        #expect(decoder.retrieveMessage() == payload)
    }

    @Test func roundTripsPayloadContainingZeroes() throws {
        let payload = Data([0x01, 0x00, 0x02, 0x00, 0x00, 0x03])
        let encoded = CobsDecoder.encode(payload)
        let decoder = CobsDecoder()
        decoder.receivedBytes(encoded)
        #expect(decoder.retrieveMessage() == payload)
    }

    @Test func roundTripsPayloadLongerThanOneCobsBlock() throws {
        var bytes = [UInt8](repeating: 0, count: 600)
        for i in 0..<600 {
            bytes[i] = UInt8(i % 251 + 1)
        }
        let payload = Data(bytes)
        let encoded = CobsDecoder.encode(payload)
        let decoder = CobsDecoder()
        decoder.receivedBytes(encoded)
        #expect(decoder.retrieveMessage() == payload)
    }

    @Test func decodesOnlyOnceTheFrameIsComplete() throws {
        let payload = Data([0x11, 0x22, 0x33, 0x44, 0x55, 0x66])
        let encoded = CobsDecoder.encode(payload)
        let frame = [UInt8](encoded)
        let half = frame.count / 2

        let decoder = CobsDecoder()
        decoder.receivedBytes(Data(frame[0..<half]))
        #expect(decoder.retrieveMessage() == nil)

        decoder.receivedBytes(Data(frame[half...]))
        #expect(decoder.retrieveMessage() == payload)
    }

    @Test func recoversAfterAFrameWithNoLeadingZero() throws {
        let decoder = CobsDecoder()
        decoder.receivedBytes(Data([0x05, 0x11, 0x22, 0x00]))
        #expect(decoder.retrieveMessage() == nil)

        let payload = Data([0x07, 0x08])
        let encoded = CobsDecoder.encode(payload)
        decoder.receivedBytes(encoded)
        #expect(decoder.retrieveMessage() == payload)
    }

    @Test func recoversAfterATruncatedFrame() throws {
        let decoder = CobsDecoder()
        decoder.receivedBytes(Data([0x00, 0x05, 0x11, 0x22, 0x00]))
        #expect(decoder.retrieveMessage() == nil)

        let payload = Data([0x09, 0x0a])
        let encoded = CobsDecoder.encode(payload)
        decoder.receivedBytes(encoded)
        #expect(decoder.retrieveMessage() == payload)
    }
}
