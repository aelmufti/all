//
//  Crc16.swift
//  all (bridge-connect)
//
//  Porté de gadgetbridge/garmin-bridge, AGPL-3.0 (ChecksumCalculator.java) — CRC16
//  propriétaire Garmin, traitement nibble par nibble.
//

import Foundation

/// CRC16 des trames GFDI. Porté à l'identique de `ChecksumCalculator` : la table et
/// l'ordre de traitement des nibbles doivent rester exacts pour matcher les CRC
/// calculés par le pont et par la montre — vérifié par test contre les mêmes octets.
enum Crc16 {
    private static let constants: [UInt16] = [
        0x0000, 0xCC01, 0xD801, 0x1400, 0xF001, 0x3C00, 0x2800, 0xE401,
        0xA001, 0x6C00, 0x7800, 0xB401, 0x5000, 0x9C01, 0x8801, 0x4400,
    ]

    /// `initial` permet de poursuivre un CRC déjà entamé (fragments successifs
    /// d'un même flux) ; par défaut 0.
    static func compute(_ data: Data, initial: UInt16 = 0) -> UInt16 {
        var crc = initial
        for byte in data {
            crc = (((crc >> 4) & 0x0FFF) ^ constants[Int(crc & 0x0F)]) ^ constants[Int(byte & 0x0F)]
            crc = (((crc >> 4) & 0x0FFF) ^ constants[Int(crc & 0x0F)]) ^ constants[Int((byte >> 4) & 0x0F)]
        }
        return crc
    }
}
