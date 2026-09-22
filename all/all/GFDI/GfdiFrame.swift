//
//  GfdiFrame.swift
//  all (bridge-connect)
//
//  Porté de gadgetbridge/garmin-bridge, AGPL-3.0 (messages/GFDIMessage.java —
//  uniquement le cadre générique : longueur, type, charge utile, CRC ; les ~48
//  sous-types de message concrets sont hors périmètre, cf. incrément 5).
//

import Foundation

/// Erreurs de parsing d'une trame GFDI reçue (après décodage COBS, avant tout
/// sous-type de message).
enum GfdiFrameError: Error, Equatable {
    /// Moins de 6 octets : pas la place pour longueur + type + CRC.
    case tooShort(actual: Int)
    /// Le champ longueur ne correspond pas au nombre d'octets effectivement reçus
    /// (`checkSize` côté pont).
    case lengthMismatch(declared: Int, actual: Int)
    /// CRC16 reçu ≠ CRC16 recalculé sur longueur+type+charge utile (`checkCRC`).
    case checksumMismatch(expected: UInt16, computed: UInt16)
}

/// Trame GFDI générique, une fois désencapsulée de COBS : longueur (2 o LE, trame
/// entière y compris elle-même), type (2 o LE), charge utile, CRC16 (2 o LE) — le
/// CRC couvre tout ce qui précède lui (longueur+type+charge utile), pas lui-même.
/// `messageType` reste un entier brut : la table de dispatch (`GarminMessage`,
/// avec son bit haut 0x8000 pour les numéros de séquence) est hors périmètre.
struct GfdiFrame: Equatable {
    let messageType: UInt16
    let payload: Data

    private static let overhead = 6 // 2 (longueur) + 2 (type) + 2 (CRC)

    /// Construit les octets d'une trame sortante (avant encodage COBS), comme
    /// `GfdiFrames.frame()` côté pont (test helper) / `addLengthAndChecksum()`
    /// côté `GFDIMessage` : longueur, type, charge utile, puis CRC16 calculé sur
    /// les octets déjà écrits.
    static func build(messageType: UInt16, payload: Data) -> Data {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(overhead + payload.count)

        let totalLength = UInt16(overhead + payload.count)
        bytes.append(UInt8(totalLength & 0xFF))
        bytes.append(UInt8(totalLength >> 8))
        bytes.append(UInt8(messageType & 0xFF))
        bytes.append(UInt8(messageType >> 8))
        bytes.append(contentsOf: payload)

        let crc = Crc16.compute(Data(bytes))
        bytes.append(UInt8(crc & 0xFF))
        bytes.append(UInt8(crc >> 8))

        return Data(bytes)
    }

    /// Parse une trame reçue (COBS déjà retiré). Vérifie longueur puis CRC, dans
    /// cet ordre — comme le constructeur de `MessageReader` côté pont.
    static func parse(_ data: Data) throws -> GfdiFrame {
        let bytes = [UInt8](data)
        guard bytes.count >= overhead else {
            throw GfdiFrameError.tooShort(actual: bytes.count)
        }

        let declaredLength = Int(UInt16(bytes[0]) | (UInt16(bytes[1]) << 8))
        guard declaredLength == bytes.count else {
            throw GfdiFrameError.lengthMismatch(declared: declaredLength, actual: bytes.count)
        }

        let crcOffset = bytes.count - 2
        let receivedCrc = UInt16(bytes[crcOffset]) | (UInt16(bytes[crcOffset + 1]) << 8)
        let computedCrc = Crc16.compute(Data(bytes[0..<crcOffset]))
        guard receivedCrc == computedCrc else {
            throw GfdiFrameError.checksumMismatch(expected: receivedCrc, computed: computedCrc)
        }

        let messageType = UInt16(bytes[2]) | (UInt16(bytes[3]) << 8)
        let payload = Data(bytes[4..<crcOffset])
        return GfdiFrame(messageType: messageType, payload: payload)
    }
}
