//
//  FitSettingsWriter.swift
//  all (bridge-connect)
//
//  Écrit un fichier FIT « Settings » minimal (FILE_ID + un enregistrement
//  USER_PROFILE) que la montre accepte en upload pour mettre à jour le profil.
//  Seul le champ `weight` est porté : c'est le seul que la Venu 2 fw 19.05
//  honore réellement (vérifié matériel — les champs d'objectif d'intensité,
//  eux, sont acceptés dans le fichier puis ignorés, cf. CLAUDE.md / spike
//  objectif intensité). Reproduit octet pour octet la structure produite par
//  garmin-bridge (`GarminSession.buildUserProfileSettingsFile` + gadgetbridge
//  `FitFile`/`RecordDefinition`/`RecordData`, AGPL-3.0), validée contre le
//  matériel par `ProfileWeightFitTest`.
//
//  Détails de format hérités de gadgetbridge (à ne pas réapprendre) :
//  - En-tête FIT de 14 o, **little-endian** : taille=14, version protocole=16,
//    version profil=21117, dataSize (u32), magic « .FIT » (0x5449462E), puis
//    CRC16 de l'en-tête (o 0..11).
//  - Les enregistrements (définition + données) sont écrits **big-endian**
//    (octet d'architecture = 1) — c'est le choix de `FitRecordDataBuilder`.
//  - L'ordre des champs dans un enregistrement = l'ordre des appels `setX`
//    côté builder garmin-bridge (LinkedHashMap), **pas** l'ordre des numéros de
//    champ : pour FILE_ID c'est type, manufacturer, product, time_created,
//    serial_number, number.
//  - CRC16 final (2 o, little-endian) calculé sur la zone de données seule
//    (à partir de l'octet 14) — l'en-tête, CRC compris, contribue 0 au CRC.
//

import Foundation

enum FitSettingsWriter {

    // MARK: - Identifiants de base type FIT (BaseType.java, gadgetbridge)
    private enum BaseType {
        static let enumType: UInt8 = 0x00
        static let uint16: UInt8 = 0x84
        static let uint32: UInt8 = 0x86
        static let uint32z: UInt8 = 0x8C
    }

    private static let fitHeaderSize: UInt8 = 14
    private static let fitProtocolVersion: UInt8 = 16
    private static let fitProfileVersion: UInt16 = 21117
    private static let fitMagic: [UInt8] = [0x2E, 0x46, 0x49, 0x54] // « .FIT » (0x5449462E en LE)

    /// Valeur d'énumération FIT `file_id.type` pour un fichier Settings
    /// (`FileType.FILETYPE.SETTINGS(128, 2)` → 2).
    private static let fileTypeSettings: UInt8 = 2

    /// Poids en kg → fichier FIT Settings prêt à uploader. `timeCreated` en
    /// secondes epoch **Unix** (comme garmin-bridge, qui passe
    /// `System.currentTimeMillis()/1000` sans décalage epoch Garmin — la montre
    /// l'accepte tel quel).
    static func userProfileSettings(weightKg: Double, timeCreated: UInt32 = UInt32(Date().timeIntervalSince1970)) -> Data {
        // Poids : UINT16 à l'échelle 0.1 kg. Borné au plausible (25–300 kg) pour
        // ne jamais écrire une valeur aberrante dans le profil de la montre.
        let clampedKg = min(max(weightKg, 25), 300)
        let weightScaled = UInt16((clampedKg * 10).rounded())

        var records = Data()

        // --- FILE_ID (global msg 0) : définition (local 0) ---
        records.append(contentsOf: [
            0x40,       // en-tête d'enregistrement : bit définition (0x40) | local 0
            0x00,       // réservé
            0x01,       // architecture = 1 (big-endian)
            0x00, 0x00, // numéro de message global = 0 (big-endian)
            0x06,       // 6 champs
            // champ : numéro, taille, base type — ORDRE = appels setX côté pont
            0x00, 0x01, BaseType.enumType,  // type
            0x01, 0x02, BaseType.uint16,    // manufacturer
            0x02, 0x02, BaseType.uint16,    // product
            0x04, 0x04, BaseType.uint32,    // time_created
            0x03, 0x04, BaseType.uint32z,   // serial_number
            0x05, 0x02, BaseType.uint16,    // number
        ])
        // --- FILE_ID : données (local 0), big-endian ---
        records.append(0x00)                       // en-tête d'enregistrement (données, local 0)
        records.append(fileTypeSettings)           // type = SETTINGS (2)
        records.append(bigEndianU16(1))            // manufacturer = 1 (garmin)
        records.append(bigEndianU16(65534))        // product = 65534 (connect)
        records.append(bigEndianU32(timeCreated))  // time_created
        records.append(bigEndianU32(1))            // serial_number = 1
        records.append(bigEndianU16(1))            // number = 1

        // --- USER_PROFILE (global msg 3) : définition (local 0) ---
        records.append(contentsOf: [
            0x40,       // définition | local 0
            0x00,       // réservé
            0x01,       // big-endian
            0x00, 0x03, // numéro de message global = 3
            0x02,       // 2 champs
            0xFE, 0x02, BaseType.uint16,    // message_index
            0x04, 0x02, BaseType.uint16,    // weight
        ])
        // --- USER_PROFILE : données (local 0), big-endian ---
        records.append(0x00)                       // en-tête (données, local 0)
        records.append(bigEndianU16(0))            // message_index = 0
        records.append(bigEndianU16(weightScaled)) // weight (×10)

        // --- En-tête FIT (14 o, little-endian) + CRC en-tête ---
        var header = Data()
        header.append(fitHeaderSize)
        header.append(fitProtocolVersion)
        header.append(littleEndianU16(fitProfileVersion))
        header.append(littleEndianU32(UInt32(records.count)))
        header.append(contentsOf: fitMagic)
        let headerCrc = Crc16.compute(header) // sur les 12 premiers octets
        header.append(littleEndianU16(headerCrc))

        // --- Assemblage + CRC final (sur la zone de données seule) ---
        var file = header
        file.append(records)
        let fileCrc = Crc16.compute(records) // en-tête (CRC inclus) contribue 0
        file.append(littleEndianU16(fileCrc))
        return file
    }

    // MARK: - Petits encodeurs d'entiers

    private static func bigEndianU16(_ v: UInt16) -> Data { Data([UInt8(v >> 8), UInt8(v & 0xFF)]) }
    private static func bigEndianU32(_ v: UInt32) -> Data {
        Data([UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)])
    }
    private static func littleEndianU16(_ v: UInt16) -> Data { Data([UInt8(v & 0xFF), UInt8(v >> 8)]) }
    private static func littleEndianU32(_ v: UInt32) -> Data {
        Data([UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8(v >> 24)])
    }
}
