//
//  FitDecoder.swift
//  all (bridge-connect)
//
//  Décodeur FIT binaire maison — incrément L1 (`docs/stockage-local.md`).
//  Implémentation directe du format public FIT (spec Garmin, en-tête 12/14
//  octets, messages de définition/données, architecture par définition,
//  horodatage compressé, champs développeur) : aucune ligne du SDK
//  `@garmin/fitsdk` n'est reprise, seule sa sortie sert de RÉFÉRENCE de
//  validation dans les tests (`allTests/FitDecoderTests.swift`).
//
//  Portée : sous-ensemble minimal nécessaire au chemin bien-être (cf.
//  `FitProfile`) — nomme/met à l'échelle les champs connus, garde tout le
//  reste générique (brut, échelle 1) pour ne jamais planter sur un message
//  inconnu (activités/GPS/sessions = L3+, hors périmètre).
//

import Foundation

enum FitDecoder {
    /// Décode un fichier `.fit` complet en mémoire. Ne lève que si l'en-tête
    /// est illisible (trop court / signature absente) — un corps tronqué ou
    /// un CRC final invalide n'interrompt PAS le décodage (`crcValid` porte
    /// le verdict, cf. `FitFile`) : mieux vaut des messages partiels qu'un
    /// fichier entièrement rejeté (même philosophie que `FitParserService.decode`
    /// côté Pulse serveur, qui accepte un décodage avec erreurs tant qu'il y
    /// a quelque chose d'exploitable).
    static func decode(_ data: Data) throws -> FitFile {
        let bytes = [UInt8](data)
        guard bytes.count >= 12 else { throw FitDecodeError.tooShort }

        let headerSize = Int(bytes[0])
        guard headerSize >= 12, bytes.count >= headerSize else { throw FitDecodeError.tooShort }
        guard bytes[8] == 0x2E, bytes[9] == 0x46, bytes[10] == 0x49, bytes[11] == 0x54 else {
            // ".FIT"
            throw FitDecodeError.badSignature
        }
        let dataSize = Int(readUInt(bytes, at: 4, size: 4, bigEndian: false))

        let dataEnd = min(headerSize + dataSize, bytes.count)
        let crcValid = verifyCrc(bytes, headerSize: headerSize, dataEnd: dataEnd)

        var defs: [UInt8: FitLocalMessageDef] = [:]
        var messages: [FitMessage] = []
        var lastTimestamp: UInt32?

        var offset = headerSize
        while offset < dataEnd {
            let header = bytes[offset]
            offset += 1

            if header & 0x80 != 0 {
                // En-tête horodatage compressé (bit 7 = 1).
                let localType = (header >> 5) & 0x03
                let timeOffset = UInt32(header & 0x1F)
                guard let def = defs[localType] else { break } // définition inconnue : flux illisible au-delà
                let base = lastTimestamp ?? 0
                var newTimestamp = (base & ~UInt32(0x1F)) | timeOffset
                if timeOffset < (base & 0x1F) { newTimestamp &+= 32 }
                lastTimestamp = newTimestamp

                let (fields, consumed) = readDataFields(def: def, bytes: bytes, offset: offset, dataEnd: dataEnd)
                guard consumed >= 0 else { break }
                offset += consumed
                var fieldsOut = fields
                fieldsOut[253] = .number(Double(newTimestamp))
                messages.append(FitMessage(globalMessageNumber: def.globalMessageNumber, fields: fieldsOut))
                continue
            }

            let isDefinition = header & 0x40 != 0
            let localType = header & 0x0F

            if isDefinition {
                guard offset + 5 <= bytes.count else { break }
                offset += 1 // réservé
                let architectureByte = bytes[offset]
                offset += 1
                let bigEndian = architectureByte != 0
                let globalNum = UInt16(readUInt(bytes, at: offset, size: 2, bigEndian: bigEndian))
                offset += 2
                let numFields = Int(bytes[offset])
                offset += 1

                var fields: [(num: UInt8, size: UInt8, baseType: UInt8)] = []
                fields.reserveCapacity(numFields)
                for _ in 0..<numFields {
                    guard offset + 3 <= bytes.count else { break }
                    fields.append((bytes[offset], bytes[offset + 1], bytes[offset + 2]))
                    offset += 3
                }

                var devFields: [(num: UInt8, size: UInt8, devIndex: UInt8)] = []
                if header & 0x20 != 0 {
                    guard offset < bytes.count else { break }
                    let numDev = Int(bytes[offset])
                    offset += 1
                    for _ in 0..<numDev {
                        guard offset + 3 <= bytes.count else { break }
                        devFields.append((bytes[offset], bytes[offset + 1], bytes[offset + 2]))
                        offset += 3
                    }
                }

                defs[localType] = FitLocalMessageDef(
                    globalMessageNumber: globalNum, bigEndian: bigEndian, fields: fields, devFields: devFields)
            } else {
                guard let def = defs[localType] else { break }
                let (fields, consumed) = readDataFields(def: def, bytes: bytes, offset: offset, dataEnd: dataEnd)
                guard consumed >= 0 else { break }
                offset += consumed
                if let ts = fields[253]?.asNumber { lastTimestamp = UInt32(ts) }
                messages.append(FitMessage(globalMessageNumber: def.globalMessageNumber, fields: fields))
            }
        }

        return FitFile(messages: messages, crcValid: crcValid)
    }

    // MARK: - Définition locale (portée : une seule fois par n° local 0-15)

    private struct FitLocalMessageDef {
        let globalMessageNumber: UInt16
        let bigEndian: Bool
        let fields: [(num: UInt8, size: UInt8, baseType: UInt8)]
        let devFields: [(num: UInt8, size: UInt8, devIndex: UInt8)]
    }

    /// Lit les champs d'UN message de données selon sa définition. Renvoie
    /// `consumed = -1` si le tampon est trop court (flux tronqué) : l'appelant
    /// arrête le décodage plutôt que de lire hors limites.
    private static func readDataFields(
        def: FitLocalMessageDef, bytes: [UInt8], offset: Int, dataEnd: Int
    ) -> (fields: [UInt8: FitValue], consumed: Int) {
        var cursor = offset
        var out: [UInt8: FitValue] = [:]

        for (num, size, baseTypeByte) in def.fields {
            let size = Int(size)
            guard cursor + size <= bytes.count else { return (out, -1) }
            defer { cursor += size }

            guard let bt = FitBaseType(byte: baseTypeByte), bt.isDecodedGenerically, size > 0 else { continue }
            let elemSize = bt.elementSize
            guard elemSize > 0, size % elemSize == 0 else { continue }
            let count = size / elemSize

            let meta = FitProfile.fieldMeta(mesgNum: def.globalMessageNumber, fieldNum: num)
            let scale = meta?.scale ?? 1
            let fieldOffset = meta?.offset ?? 0

            if count == 1 {
                let raw = readUInt(bytes, at: cursor, size: elemSize, bigEndian: def.bigEndian)
                guard raw != bt.invalidRaw else { continue }
                let numeric = bt.isSigned ? Double(signedValue(raw, byteCount: elemSize)) : Double(raw)
                out[num] = .number(numeric / scale - fieldOffset)
            } else {
                // Même mise à l'échelle que la branche scalaire ci-dessus
                // (`numeric / scale - fieldOffset`) — jusqu'à l'incrément L3
                // aucun champ tableau connu du profil (`FitProfile`) n'avait
                // d'échelle ≠ 1, ce cas ne s'était donc jamais présenté
                // (bogue latent, découvert vs sortie SDK sur `timeInHrZone`,
                // échelle 1000 — cf. rapport d'incrément L3).
                var values: [Double] = []
                values.reserveCapacity(count)
                for i in 0..<count {
                    let raw = readUInt(bytes, at: cursor + i * elemSize, size: elemSize, bigEndian: def.bigEndian)
                    guard raw != bt.invalidRaw else { continue }
                    let numeric = bt.isSigned ? Double(signedValue(raw, byteCount: elemSize)) : Double(raw)
                    values.append(numeric / scale - fieldOffset)
                }
                if !values.isEmpty { out[num] = .numbers(values) }
            }
        }

        for (_, size, _) in def.devFields {
            // Champs développeur : sautés (hors périmètre L1, cf. tâche
            // d'incrément — on ne décode que le profil FIT standard).
            cursor += Int(size)
        }

        guard cursor <= bytes.count else { return (out, -1) }
        return (out, cursor - offset)
    }

    // MARK: - Lecture bas niveau

    private static func readUInt(_ bytes: [UInt8], at offset: Int, size: Int, bigEndian: Bool) -> UInt64 {
        var value: UInt64 = 0
        if bigEndian {
            for i in 0..<size { value = (value << 8) | UInt64(bytes[offset + i]) }
        } else {
            for i in stride(from: size - 1, through: 0, by: -1) { value = (value << 8) | UInt64(bytes[offset + i]) }
        }
        return value
    }

    private static func signedValue(_ raw: UInt64, byteCount: Int) -> Int64 {
        let bits = byteCount * 8
        let signBit = UInt64(1) << (bits - 1)
        if raw & signBit != 0 {
            return Int64(raw) - Int64(UInt64(1) << bits)
        }
        return Int64(raw)
    }

    // MARK: - CRC-16 FIT

    /// Table CRC-16 FIT (algorithme documenté dans la spécification publique
    /// du format, nibble par nibble — polynôme équivalent 0xA001). Vérifie le
    /// CRC de fin de fichier (2 octets LE, sur `bytes[0..<dataEnd]`) — les
    /// fichiers à en-tête 12 octets n'ont pas de CRC d'en-tête séparé.
    private static let crcTable: [UInt16] = [
        0x0000, 0xCC01, 0xD801, 0x1400, 0xF001, 0x3C00, 0x2800, 0xE401,
        0xA001, 0x6C00, 0x7800, 0xB401, 0x5000, 0x9C01, 0x8801, 0x4400,
    ]

    private static func crc16(_ bytes: ArraySlice<UInt8>) -> UInt16 {
        var crc: UInt16 = 0
        for byte in bytes {
            var tmp = crcTable[Int(crc & 0xF)]
            crc = (crc >> 4) & 0x0FFF
            crc = crc ^ tmp ^ crcTable[Int(byte & 0xF)]
            tmp = crcTable[Int(crc & 0xF)]
            crc = (crc >> 4) & 0x0FFF
            crc = crc ^ tmp ^ crcTable[Int((byte >> 4) & 0xF)]
        }
        return crc
    }

    private static func verifyCrc(_ bytes: [UInt8], headerSize: Int, dataEnd: Int) -> Bool {
        guard bytes.count >= dataEnd + 2 else { return false }
        let expected = UInt16(readUInt(bytes, at: dataEnd, size: 2, bigEndian: false))
        let computed = crc16(bytes[0..<dataEnd])
        return expected == computed
    }
}
