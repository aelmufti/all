//
//  GfdiFrameTests.swift
//  allTests
//
//  Vecteurs de trames complètes générés en exécutant l'algorithme du pont
//  (GfdiFrames.java : helpers frame()/payload(), reproduits verbatim et exécutés).
//  Chaque cas vérifie les deux sens : construction (GfdiFrame.build) et parsing
//  (GfdiFrame.parse) redonnent les mêmes octets / le même (messageType, payload).
//

import Testing
import Foundation
@testable import all

struct GfdiFrameTests {

    // Types de message (LE) utilisés dans les charges utiles ci-dessous.
    private static let RESPONSE: UInt16 = 5000
    private static let FILTER: UInt16 = 5007
    private static let SUPPORTED_FILE_TYPES_REQUEST: UInt16 = 5031
    private static let DOWNLOAD_REQUEST: UInt16 = 5002
    private static let PROTOBUF_REQUEST: UInt16 = 5043
    private static let CONFIGURATION: UInt16 = 5050

    @Test func filterStatus() throws {
        let payload = Data([0x8F, 0x13, 0x00, 0x00])
        let expected = Data([0x0A, 0x00, 0x88, 0x13, 0x8F, 0x13, 0x00, 0x00, 0xC0, 0x25])

        let built = GfdiFrame.build(messageType: Self.RESPONSE, payload: payload)
        #expect(built == expected)

        let parsed = try GfdiFrame.parse(expected)
        #expect(parsed == GfdiFrame(messageType: Self.RESPONSE, payload: payload))
    }

    @Test func downloadRequestStatusMaxFileSize() throws {
        let payload = Data([0x8A, 0x13, 0x00, 0x00, 0x40, 0x42, 0x0F, 0x00])
        let expected = Data([0x0E, 0x00, 0x88, 0x13, 0x8A, 0x13, 0x00, 0x00, 0x40, 0x42, 0x0F, 0x00, 0xAC, 0x1F])

        let built = GfdiFrame.build(messageType: Self.RESPONSE, payload: payload)
        #expect(built == expected)

        let parsed = try GfdiFrame.parse(expected)
        #expect(parsed == GfdiFrame(messageType: Self.RESPONSE, payload: payload))
    }

    @Test func supportedFileTypes() throws {
        var payload = Data([0xA7, 0x13, 0x00, 0x01, 0x80, 0x04, 0x0A])
        payload.append(Data([0x46, 0x49, 0x54, 0x5F, 0x54, 0x59, 0x50, 0x45, 0x5F, 0x34])) // "FIT_TYPE_4"
        let expected = Data([
            0x17, 0x00, 0x88, 0x13, 0xA7, 0x13, 0x00, 0x01, 0x80, 0x04, 0x0A,
            0x46, 0x49, 0x54, 0x5F, 0x54, 0x59, 0x50, 0x45, 0x5F, 0x34,
            0xC8, 0x98,
        ])
        #expect(expected.count == 23)

        let built = GfdiFrame.build(messageType: Self.RESPONSE, payload: payload)
        #expect(built == expected)

        let parsed = try GfdiFrame.parse(expected)
        #expect(parsed == GfdiFrame(messageType: Self.RESPONSE, payload: payload))
    }

    @Test func protobufRequestId1() throws {
        let payload = Data([
            0x01, 0x00, // requestId = 1
            0x00, 0x00, 0x00, 0x00, // dataOffset = 0
            0x02, 0x00, 0x00, 0x00, // totalLength = 2
            0x02, 0x00, 0x00, 0x00, // partLength = 2
            0x08, 0x01,
        ])
        let expected = Data([
            0x16, 0x00, 0xB3, 0x13,
            0x01, 0x00,
            0x00, 0x00, 0x00, 0x00,
            0x02, 0x00, 0x00, 0x00,
            0x02, 0x00, 0x00, 0x00,
            0x08, 0x01,
            0xC6, 0xDB,
        ])

        let built = GfdiFrame.build(messageType: Self.PROTOBUF_REQUEST, payload: payload)
        #expect(built == expected)

        let parsed = try GfdiFrame.parse(expected)
        #expect(parsed == GfdiFrame(messageType: Self.PROTOBUF_REQUEST, payload: payload))
    }

    @Test func protobufRequestId42() throws {
        let payload = Data([
            0x2A, 0x00, // requestId = 42
            0x00, 0x00, 0x00, 0x00,
            0x02, 0x00, 0x00, 0x00,
            0x02, 0x00, 0x00, 0x00,
            0x08, 0x01,
        ])
        let expected = Data([
            0x16, 0x00, 0xB3, 0x13,
            0x2A, 0x00,
            0x00, 0x00, 0x00, 0x00,
            0x02, 0x00, 0x00, 0x00,
            0x02, 0x00, 0x00, 0x00,
            0x08, 0x01,
            0x98, 0x34,
        ])

        let built = GfdiFrame.build(messageType: Self.PROTOBUF_REQUEST, payload: payload)
        #expect(built == expected)

        let parsed = try GfdiFrame.parse(expected)
        #expect(parsed == GfdiFrame(messageType: Self.PROTOBUF_REQUEST, payload: payload))
    }

    @Test func configuration() throws {
        let payload = Data([0x01, 0x00])
        let expected = Data([0x08, 0x00, 0xBA, 0x13, 0x01, 0x00, 0xD4, 0x05])

        let built = GfdiFrame.build(messageType: Self.CONFIGURATION, payload: payload)
        #expect(built == expected)

        let parsed = try GfdiFrame.parse(expected)
        #expect(parsed == GfdiFrame(messageType: Self.CONFIGURATION, payload: payload))
    }

    @Test func genericAckFilterOk() throws {
        let expected = Data([0x09, 0x00, 0x88, 0x13, 0x8F, 0x13, 0x00, 0x41, 0x40])

        let built = GfdiAck.statusFrame(for: Self.FILTER, status: .ack)
        #expect(built == expected)

        let parsed = try GfdiFrame.parse(expected)
        let status = GfdiAck.parseStatus(from: parsed)
        #expect(status?.originalMessageType == Self.FILTER)
        #expect(status?.status == .ack)
    }

    @Test func genericAckSupportedFileTypesUnsupported() throws {
        let expected = Data([0x09, 0x00, 0x88, 0x13, 0xA7, 0x13, 0x02, 0x40, 0x89])

        let built = GfdiAck.statusFrame(for: Self.SUPPORTED_FILE_TYPES_REQUEST, status: .unsupported)
        #expect(built == expected)

        let parsed = try GfdiFrame.parse(expected)
        let status = GfdiAck.parseStatus(from: parsed)
        #expect(status?.originalMessageType == Self.SUPPORTED_FILE_TYPES_REQUEST)
        #expect(status?.status == .unsupported)
    }

    // MARK: - Erreurs de parsing

    @Test func parseThrowsTooShortBelowSixBytes() throws {
        let tooShort = Data([0x01, 0x02, 0x03, 0x04, 0x05])
        do {
            _ = try GfdiFrame.parse(tooShort)
            Issue.record("Attendu GfdiFrameError.tooShort")
        } catch let error as GfdiFrameError {
            #expect(error == .tooShort(actual: 5))
        }
    }

    @Test func parseThrowsLengthMismatch() throws {
        // Longueur déclarée = 0x0A (10) mais seulement 9 octets réellement présents.
        let malformed = Data([0x0A, 0x00, 0x88, 0x13, 0x8F, 0x13, 0x00, 0x00, 0xC0])
        do {
            _ = try GfdiFrame.parse(malformed)
            Issue.record("Attendu GfdiFrameError.lengthMismatch")
        } catch let error as GfdiFrameError {
            #expect(error == .lengthMismatch(declared: 10, actual: 9))
        }
    }

    @Test func parseThrowsChecksumMismatchOnAlteredCrc() throws {
        // Vecteur filterStatus valide, dernier octet (CRC haut) altéré.
        var corrupted = Data([0x0A, 0x00, 0x88, 0x13, 0x8F, 0x13, 0x00, 0x00, 0xC0, 0x25])
        corrupted[corrupted.count - 1] = 0x26

        do {
            _ = try GfdiFrame.parse(corrupted)
            Issue.record("Attendu GfdiFrameError.checksumMismatch")
        } catch let error as GfdiFrameError {
            #expect(error == .checksumMismatch(expected: 0x26C0, computed: 0x25C0))
        }
    }
}
