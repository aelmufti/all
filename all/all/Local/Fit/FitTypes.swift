//
//  FitTypes.swift
//  all (bridge-connect)
//
//  Table des types de base FIT — la spécification publique du format (§ "Base
//  Types"), PAS du code repris du SDK (`custom-connect/server/node_modules/
//  @garmin/fitsdk` sert seulement de référence de validation, cf.
//  `FitProfile.swift` et les tests). Seules les constantes numériques
//  (taille en octets, sentinelle "invalide" par type) sont reprises — elles
//  font partie du format FIT lui-même, pas de l'implémentation du SDK.
//
//  Décodeur maison, incrément L1 (`docs/stockage-local.md`) : sous-ensemble
//  minimal — juste ce qu'il faut pour lire les messages bien-être/sommeil
//  utilisés par `FitWellnessExtractor`, en restant robuste (jamais de crash)
//  sur les types/messages qu'on ne connaît pas.
//

import Foundation

/// Un type de base FIT — les 5 bits bas de l'octet "base type" d'une
/// définition de champ (les bits hauts sont des drapeaux qu'on ignore :
/// l'architecture du message suffit à savoir lire les multi-octets).
enum FitBaseType: Equatable {
    case enumT, sint8, uint8, sint16, uint16, sint32, uint32, string
    case float32, float64, uint8z, uint16z, uint32z, byteT, sint64, uint64, uint64z

    init?(byte: UInt8) {
        switch byte & 0x1F {
        case 0x00: self = .enumT
        case 0x01: self = .sint8
        case 0x02: self = .uint8
        case 0x03: self = .sint16
        case 0x04: self = .uint16
        case 0x05: self = .sint32
        case 0x06: self = .uint32
        case 0x07: self = .string
        case 0x08: self = .float32
        case 0x09: self = .float64
        case 0x0A: self = .uint8z
        case 0x0B: self = .uint16z
        case 0x0C: self = .uint32z
        case 0x0D: self = .byteT
        case 0x0E: self = .sint64
        case 0x0F: self = .uint64
        case 0x10: self = .uint64z
        default: return nil
        }
    }

    /// Taille en octets d'UN élément (un champ peut être un tableau de
    /// plusieurs éléments de cette taille — la taille totale du champ, elle,
    /// vient de la définition, pas d'ici).
    var elementSize: Int {
        switch self {
        case .enumT, .sint8, .uint8, .string, .uint8z, .byteT: return 1
        case .sint16, .uint16, .uint16z: return 2
        case .sint32, .uint32, .float32, .uint32z: return 4
        case .float64, .sint64, .uint64, .uint64z: return 8
        }
    }

    var isSigned: Bool {
        switch self {
        case .sint8, .sint16, .sint32, .sint64: return true
        default: return false
        }
    }

    var isString: Bool { self == .string }

    /// Types qu'on ne décode PAS numériquement (hors périmètre du
    /// sous-ensemble bien-être/sommeil : aucun champ utilisé n'est flottant
    /// ni 64 bits) — leurs octets sont sautés comme le reste, pas exposés
    /// dans le dictionnaire de sortie. Évite d'interpréter à tort un motif de
    /// bits flottant comme un entier.
    var isDecodedGenerically: Bool {
        switch self {
        case .float32, .float64, .sint64, .uint64, .uint64z, .string: return false
        default: return true
        }
    }

    /// Valeur "invalide" (sentinelle FIT) pour ce type — un champ dont la
    /// valeur brute vaut EXACTEMENT ceci est absent, pas juste "zéro" (ex.
    /// `heartRate == 0xFF` veut dire "pas de mesure", pas "0 bpm").
    var invalidRaw: UInt64 {
        switch self {
        case .enumT, .uint8, .byteT: return 0xFF
        case .sint8: return 0x7F
        case .uint8z: return 0x00
        case .sint16: return 0x7FFF
        case .uint16: return 0xFFFF
        case .uint16z: return 0x0000
        case .sint32: return 0x7FFF_FFFF
        case .uint32, .float32: return 0xFFFF_FFFF
        case .uint32z: return 0x0000_0000
        case .string: return 0x00
        case .sint64: return 0x7FFF_FFFF_FFFF_FFFF
        case .uint64, .float64: return 0xFFFF_FFFF_FFFF_FFFF
        case .uint64z: return 0x0000_0000_0000_0000
        }
    }
}

/// Valeur décodée d'un champ — un scalaire ou un petit tableau (champs FIT
/// `array: true`, ex. `monitoringInfo.activityType`). Le sous-ensemble
/// bien-être n'exploite que des scalaires ; les tableaux restent décodés
/// génériquement pour ne jamais planter sur un message inconnu.
enum FitValue {
    case number(Double)
    case numbers([Double])

    var asNumber: Double? {
        if case .number(let v) = self { return v }
        return nil
    }
}

/// Un message décodé : son numéro de message global (`Profile.mesgNum`) +
/// les champs présents, indexés par numéro de champ. Volontairement plat —
/// pas de "nom" de message ici (cf. `FitProfile`, qui sait nommer/mettre à
/// l'échelle le sous-ensemble utile) : `FitWellnessExtractor` filtre par
/// `globalMessageNumber` directement.
struct FitMessage {
    let globalMessageNumber: UInt16
    let fields: [UInt8: FitValue]

    func double(_ field: UInt8) -> Double? { fields[field]?.asNumber }

    /// Valeur "tableau" d'un champ — utilisé par le chemin activité (L3, cf.
    /// `FitActivityExtractor`) pour `set.category`/`timeInZone.timeInHrZone`/
    /// `timeInZone.hrZoneHighBoundary`. Traite aussi un scalaire comme un
    /// tableau à un élément : un champ FIT `array: true` qui n'a qu'UNE
    /// valeur sur le fil est stocké `.number` par `FitDecoder` (branche
    /// `count == 1`, cf. `readDataFields`), jamais `.numbers([x])` — même
    /// idée que `Array.isArray(x) ? x : [x]` côté TS
    /// (`FitParserService.extractSets`). Absent → tableau vide, jamais `nil`
    /// (l'appelant n'a pas à re-tester la présence).
    func numberList(_ field: UInt8) -> [Double] {
        switch fields[field] {
        case .numbers(let values): return values
        case .number(let value): return [value]
        case nil: return []
        }
    }
}

/// Résultat complet d'un décodage — les messages dans l'ordre du fichier, +
/// un verdict CRC (§ en-tête + fin de fichier) purement diagnostique :
/// `LocalIngestor` continue même si `crcValid == false` (mieux vaut ingérer
/// un fichier légèrement corrompu que perdre la donnée — cf. commentaire
/// équivalent côté `FitParserService.decode`, Pulse serveur, qui accepte
/// aussi un décodage partiel).
struct FitFile {
    let messages: [FitMessage]
    let crcValid: Bool
}

enum FitDecodeError: Error, LocalizedError {
    case tooShort
    case badSignature

    var errorDescription: String? {
        switch self {
        case .tooShort: return "Fichier FIT trop court pour contenir un en-tête valide."
        case .badSignature: return "Signature « .FIT » absente — pas un fichier FIT."
        }
    }
}
