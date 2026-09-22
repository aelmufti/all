//
//  GarminByteIO.swift
//  all (bridge-connect)
//
//  Petits lecteur/écrivain d'octets little-endian pour les champs des messages
//  GFDI, équivalents minimaux de `MessageReader`/`MessageWriter` côté pont
//  (gadgetbridge/garmin-bridge, AGPL-3.0 — messages/MessageWriter.java,
//  GarminByteBufferReader.java). On ne porte que ce dont les messages GFDI de ce
//  périmètre (handshake + listing) ont besoin : entiers non signés 8/16/32/64
//  bits LE et chaînes « pascal » (1 octet de longueur + UTF-8), comme
//  `GarminByteBufferReader.readString()` / `MessageWriter.writeString()`.
//

import Foundation

/// Lecteur séquentiel à état, sur une copie des octets d'un payload GFDI déjà
/// désencapsulé (COBS + trame retirés). Toute lecture qui dépasse la fin rend
/// `nil` plutôt que de planter — un fragment tronqué ne doit jamais faire
/// crasher le décodeur (cf. `GFDIMessage.MessageReader` côté pont, qui lève une
/// exception ; ici on préfère un `nil` que l'appelant journalise et abandonne).
struct GarminByteReader {
    private let bytes: [UInt8]
    private(set) var offset: Int = 0

    init(_ data: Data) {
        bytes = [UInt8](data)
    }

    var remaining: Int { bytes.count - offset }

    mutating func readUInt8() -> UInt8? {
        guard offset < bytes.count else { return nil }
        defer { offset += 1 }
        return bytes[offset]
    }

    mutating func readUInt16LE() -> UInt16? {
        guard remaining >= 2 else { return nil }
        let value = UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
        offset += 2
        return value
    }

    mutating func readUInt32LE() -> UInt32? {
        guard remaining >= 4 else { return nil }
        let value = UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
        offset += 4
        return value
    }

    mutating func readUInt64LE() -> UInt64? {
        guard remaining >= 8 else { return nil }
        var value: UInt64 = 0
        for i in 0..<8 {
            value |= UInt64(bytes[offset + i]) << (8 * i)
        }
        offset += 8
        return value
    }

    mutating func readBytes(_ count: Int) -> Data? {
        guard count >= 0, remaining >= count else { return nil }
        defer { offset += count }
        return Data(bytes[offset..<(offset + count)])
    }

    /// Reste du buffer, sans avancer au-delà (équivalent de `reader.remaining()`
    /// utilisé côté pont pour lire « tout ce qu'il reste »).
    mutating func readRemainingBytes() -> Data {
        readBytes(remaining) ?? Data()
    }

    /// Chaîne « pascal » : 1 octet de longueur puis les octets UTF-8.
    mutating func readPascalString() -> String? {
        guard let length = readUInt8(), let bytes = readBytes(Int(length)) else { return nil }
        return String(data: bytes, encoding: .utf8) ?? ""
    }
}

/// Écrivain séquentiel minimal pour construire un payload GFDI sortant.
struct GarminByteWriter {
    private(set) var data = Data()

    mutating func writeUInt8(_ value: UInt8) {
        data.append(value)
    }

    mutating func writeUInt16LE(_ value: UInt16) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
    }

    mutating func writeUInt32LE(_ value: UInt32) {
        for i in 0..<4 {
            data.append(UInt8((value >> (8 * i)) & 0xFF))
        }
    }

    mutating func writeUInt64LE(_ value: UInt64) {
        for i in 0..<8 {
            data.append(UInt8((value >> (8 * i)) & 0xFF))
        }
    }

    mutating func writeInt32LE(_ value: Int32) {
        writeUInt32LE(UInt32(bitPattern: value))
    }

    mutating func writeBytes(_ bytes: Data) {
        data.append(bytes)
    }

    /// Chaîne « pascal », tronquée à 255 octets UTF-8 comme
    /// `MessageWriter.writeString` (qui lève au-delà ; ici on tronque plutôt que
    /// de faire échouer l'envoi pour un champ purement informatif).
    mutating func writePascalString(_ value: String) {
        let utf8 = Array(value.utf8.prefix(255))
        writeUInt8(UInt8(utf8.count))
        data.append(contentsOf: utf8)
    }
}

extension Data {
    /// Représentation hexadécimale espacée, pour les logs `os.Logger` — on
    /// débogue le protocole contre le matériel via Console.app, ces logs sont
    /// les seuls yeux qu'on a sur ce qui a réellement transité (cf. `GB.hexdump`
    /// côté pont, utilisé partout dans `ProtobufAck`).
    var gfdiHexDump: String {
        map { String(format: "%02x", $0) }.joined(separator: " ")
    }
}
