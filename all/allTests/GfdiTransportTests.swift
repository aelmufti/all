//
//  GfdiTransportTests.swift
//  allTests
//
//  Bout en bout (construction → COBS → fragmentation → réassemblage → parsing),
//  sans vecteur pont fixe : exerce notre propre pipeline, déjà pinné par les
//  vecteurs pont des tests COBS/CRC16/GfdiFrame.
//

import Testing
import Foundation
@testable import all

struct GfdiTransportTests {

    @Test func reassemblesFragmentedFrameV1() throws {
        let frameBytes = GfdiFrame.build(messageType: 5007, payload: Data([0x01, 0x02, 0x03]))
        let encoded = CobsDecoder.encode(frameBytes)
        let fragments = CommunicatorVersion.v1.fragment(encoded, maxWriteSize: 8)
        #expect(fragments.count > 1)

        let transport = GfdiTransport()
        var results: [Result<GfdiFrame, GfdiFrameError>?] = []
        for fragment in fragments {
            results.append(transport.receive(fragment))
        }

        for result in results.dropLast() {
            #expect(result == nil)
        }
        switch results.last! {
        case .success(let frame):
            #expect(frame == GfdiFrame(messageType: 5007, payload: Data([0x01, 0x02, 0x03])))
        default:
            Issue.record("Attendu .success au dernier fragment")
        }
    }

    @Test func reassemblesFragmentedFrameV2WithHandleStripped() throws {
        let frameBytes = GfdiFrame.build(messageType: 5007, payload: Data([0x01, 0x02, 0x03]))
        let encoded = CobsDecoder.encode(frameBytes)
        let fragments = CommunicatorVersion.v2.fragment(encoded, maxWriteSize: 8, handle: 3)
        #expect(fragments.count > 1)

        let transport = GfdiTransport()
        var results: [Result<GfdiFrame, GfdiFrameError>?] = []
        for fragment in fragments {
            let stripped = CommunicatorVersion.v2.stripFragmentHeader(fragment)
            results.append(transport.receive(stripped))
        }

        for result in results.dropLast() {
            #expect(result == nil)
        }
        switch results.last! {
        case .success(let frame):
            #expect(frame == GfdiFrame(messageType: 5007, payload: Data([0x01, 0x02, 0x03])))
        default:
            Issue.record("Attendu .success au dernier fragment")
        }
    }

    @Test func singleFragmentWithDefaultMaxWriteSize() throws {
        let frameBytes = GfdiFrame.build(messageType: 5007, payload: Data([0x01, 0x02, 0x03]))
        let encoded = CobsDecoder.encode(frameBytes)
        let fragments = CommunicatorVersion.v1.fragment(encoded)
        #expect(fragments.count == 1)

        let transport = GfdiTransport()
        let result = transport.receive(fragments[0])
        switch result {
        case .success(let frame):
            #expect(frame == GfdiFrame(messageType: 5007, payload: Data([0x01, 0x02, 0x03])))
        default:
            Issue.record("Attendu .success dès le premier et unique fragment")
        }
    }

    @Test func reassemblesGenericAckEndToEnd() throws {
        let ackFrameBytes = GfdiAck.statusFrame(for: 5007, status: .ack)
        let encoded = CobsDecoder.encode(ackFrameBytes)
        let fragments = CommunicatorVersion.v1.fragment(encoded, maxWriteSize: 8)

        let transport = GfdiTransport()
        var lastResult: Result<GfdiFrame, GfdiFrameError>?
        for fragment in fragments {
            lastResult = transport.receive(fragment)
        }

        guard case .success(let frame) = lastResult else {
            Issue.record("Attendu .success pour l'accusé réassemblé")
            return
        }
        let status = GfdiAck.parseStatus(from: frame)
        #expect(status?.originalMessageType == 5007)
        #expect(status?.status == .ack)
    }

    @Test func malformedFrameYieldsChecksumMismatchWithoutCrashing() throws {
        var frameBytes = [UInt8](GfdiFrame.build(messageType: 5007, payload: Data([0x01, 0x02, 0x03])))
        // Altère le dernier octet (CRC haut) avant l'encodage COBS.
        frameBytes[frameBytes.count - 1] = frameBytes[frameBytes.count - 1] ^ 0xFF

        let encoded = CobsDecoder.encode(Data(frameBytes))
        let fragments = CommunicatorVersion.v1.fragment(encoded, maxWriteSize: 8)

        let transport = GfdiTransport()
        var lastResult: Result<GfdiFrame, GfdiFrameError>?
        for fragment in fragments {
            lastResult = transport.receive(fragment)
        }

        switch lastResult {
        case .failure(let error):
            if case .checksumMismatch = error {
                // attendu
            } else {
                Issue.record("Attendu .checksumMismatch, obtenu \(error)")
            }
        default:
            Issue.record("Attendu .failure pour la trame corrompue")
        }
    }
}
