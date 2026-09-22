//
//  Crc16Tests.swift
//  allTests
//
//  Vecteurs générés en exécutant réellement l'algorithme du pont (reproduction
//  verbatim de ChecksumCalculator.java, compilée et lancée avec javac/java) —
//  donc faisant autorité pour le CRC16 propriétaire Garmin.
//

import Testing
import Foundation
@testable import all

struct Crc16Tests {

    @Test func crc16OfFourBytes() throws {
        #expect(Crc16.compute(Data([0x01, 0x02, 0x03, 0x04])) == 0x0FA1)
    }

    @Test func crc16OfEmptyData() throws {
        #expect(Crc16.compute(Data()) == 0x0000)
    }

    @Test func crc16OfAsciiDigits() throws {
        let data = Data("123456789".utf8)
        #expect(Crc16.compute(data) == 0xBB3D)
    }

    @Test func crc16OfSixteenSequentialBytes() throws {
        let bytes = (UInt8(0x00)...UInt8(0x0F)).map { $0 }
        #expect(Crc16.compute(Data(bytes)) == 0x170A)
    }

    @Test func crc16OfMixedBytes() throws {
        #expect(Crc16.compute(Data([0xFF, 0x80, 0x7F, 0x00])) == 0xCC11)
    }

    @Test func crc16ChainedWithInitialValue() throws {
        let first = Crc16.compute(Data([0x01, 0x02, 0x03, 0x04]))
        #expect(first == 0x0FA1)

        let chained = Crc16.compute(Data("123456789".utf8), initial: first)
        #expect(chained == 0x6C88)
    }
}
