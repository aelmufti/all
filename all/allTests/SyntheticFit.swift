//
//  SyntheticFit.swift
//  allTests
//
//  Générateur de `.fit` d'activité SYNTHÉTIQUES (aucune donnée réelle) pour les tests
//  de modification/fusion d'activités : miroir Swift de `syntheticActivityFit`
//  (`custom-connect/server/src/activities/test-fit.ts`), avec en plus des événements
//  timer (pauses), deux tours et un `time_in_zone`. Encodage binaire FIT minimal
//  (en-tête 12 octets, définitions little-endian, CRC final), relu par `FitDecoder`.
//
//  Profil : `hr(i) = 100 + i / 10` (entier), `distance = 3 m × i`, un record par seconde.
//

import Foundation
@testable import all

struct SyntheticFit {
    /// Début, en secondes UNIX.
    var startUnix: Double
    /// Nombre de secondes d'activité (records `0...seconds`).
    var seconds = 600
    /// Code FIT du sport (1 = course, 2 = vélo).
    var sport = 1
    var calories = 300
    /// Pause : pas de record entre `stop` et `resume` (secondes depuis le début).
    var pause: (stop: Int, resume: Int)?
    var withTimerEvents = true
    var withLaps = true
    var withZones = true
    var withDistance = true
    var withHr = true
    /// Fait varier le contenu (donc le hash) entre deux fichiers identiques par ailleurs.
    var salt = 0

    static let fitEpoch = 631_065_600.0

    var fitStart: UInt32 { UInt32(startUnix - Self.fitEpoch) }

    func hr(_ i: Int) -> Int { 100 + i / 10 }

    func data() -> Data {
        var body = [UInt8]()

        func u16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
        func u32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * UInt32($0))) & 0xFF) } }
        func i32(_ v: Int32) -> [UInt8] { u32(UInt32(bitPattern: v)) }

        // (numéro de champ, taille, type de base)
        func message(_ local: UInt8, _ global: Int, fields: [(UInt8, UInt8, UInt8)], values: [UInt8]) {
            body += [0x40 | local, 0, 0] + u16(global) + [UInt8(fields.count)]
            for f in fields { body += [f.0, f.1, f.2] }
            body += [local] + values
        }
        let enumT: UInt8 = 0x00, u8: UInt8 = 0x02, u16T: UInt8 = 0x84, u32T: UInt8 = 0x86, s32: UInt8 = 0x85

        message(0, 0, fields: [(0, 1, enumT), (3, 4, u32T)], values: [4] + u32(UInt32(1000 + salt)))

        func ts(_ s: Int) -> UInt32 { fitStart + UInt32(s) }
        func event(_ s: Int, type: UInt8) {
            message(1, 21, fields: [(253, 4, u32T), (0, 1, enumT), (1, 1, enumT)], values: u32(ts(s)) + [0, type])
        }
        if withTimerEvents {
            event(0, type: 0)
            if let pause {
                event(pause.stop, type: 1)
                event(pause.resume, type: 0)
            }
        }
        for i in 0...seconds {
            if let pause, i > pause.stop, i < pause.resume { continue }
            var fields: [(UInt8, UInt8, UInt8)] = [(253, 4, u32T)]
            var values = u32(ts(i))
            if withHr { fields.append((3, 1, u8)); values += [UInt8(hr(i))] }
            if withDistance {
                fields.append((5, 4, u32T))
                values += u32(UInt32(i * 3 * 100))
                fields.append((0, 4, s32)); fields.append((1, 4, s32))
                values += i32(Int32((48.85 + Double(i) * 0.00003) * 2_147_483_648 / 180))
                values += i32(Int32((2.35 + Double(salt) * 0.001) * 2_147_483_648 / 180))
            }
            message(2, 20, fields: fields, values: values)
        }
        if withTimerEvents {
            event(seconds, type: 4)
        }
        if withLaps {
            let half = seconds / 2
            for (start, end) in [(0, half), (half, seconds)] {
                let dur = UInt32((end - start) * 1000)
                message(3, 19, fields: [(253, 4, u32T), (2, 4, u32T), (7, 4, u32T), (8, 4, u32T), (9, 4, u32T), (15, 1, u8), (16, 1, u8)],
                        values: u32(ts(end)) + u32(ts(start)) + u32(dur) + u32(dur) + u32(UInt32((end - start) * 300))
                            + [UInt8(hr(start)), UInt8(hr(end))])
            }
        }
        if withZones {
            let times = [0, 100_000, 200_000, 300_000, 0, 0].flatMap { u32(UInt32($0)) }
            message(4, 216, fields: [(0, 2, u16T), (2, 24, u32T), (6, 6, u8)],
                    values: u16(18) + times + [100, 120, 140, 160, 180, 190])
        }
        let total = UInt32(seconds * 1000)
        message(5, 18, fields: [(253, 4, u32T), (2, 4, u32T), (5, 1, enumT), (6, 1, enumT), (7, 4, u32T), (8, 4, u32T),
                                (9, 4, u32T), (11, 2, u16T), (16, 1, u8), (17, 1, u8)],
                values: u32(ts(seconds)) + u32(ts(0)) + [UInt8(sport), 0] + u32(total) + u32(total)
                    + u32(UInt32(seconds * 300)) + u16(calories) + [UInt8(hr(seconds) - 10), UInt8(hr(seconds))])

        var out: [UInt8] = [12, 0x10] + u16(2000) + u32(UInt32(body.count)) + Array(".FIT".utf8) + body
        out += u16(Int(Self.crc16(out)))
        return Data(out)
    }

    /// CRC-16 FIT (nibble par nibble).
    private static func crc16(_ bytes: [UInt8]) -> UInt16 {
        let table: [UInt16] = [0x0000, 0xCC01, 0xD801, 0x1400, 0xF001, 0x3C00, 0x2800, 0xE401,
                               0xA001, 0x6C00, 0x7800, 0xB401, 0x5000, 0x9C01, 0x8801, 0x4400]
        var crc: UInt16 = 0
        for byte in bytes {
            var tmp = table[Int(crc & 0xF)]
            crc = (crc >> 4) & 0x0FFF
            crc = crc ^ tmp ^ table[Int(byte & 0xF)]
            tmp = table[Int(crc & 0xF)]
            crc = (crc >> 4) & 0x0FFF
            crc = crc ^ tmp ^ table[Int((byte >> 4) & 0xF)]
        }
        return crc
    }

    var messages: [FitMessage] { (try? FitDecoder.decode(data()).messages) ?? [] }
    var hash: String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("synthetic-\(UUID().uuidString).fit")
        try? data().write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        return (try? PulseUploader.sha256Hex(ofFileAt: url)) ?? ""
    }
}
