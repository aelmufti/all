//
//  CommunicatorVersion.swift
//  all (bridge-connect)
//
//  Modélise la distinction V1/V2 du transport GFDI (CommunicatorV1/V2 du pont,
//  AGPL-3.0) au niveau strictement nécessaire pour tester le parsing de trame par
//  version : découpage en fragments à l'émission, et l'en-tête propre à V2 (octet
//  de handle ML) à retirer à la réception avant de nourrir le décodeur COBS. La
//  vraie sélection par GATT (découverte de services/caractéristiques, négociation
//  MLR) est hors périmètre incrément 2 — elle viendra avec le lien BLE réel.
//

import Foundation

/// Version du protocole de transport GFDI vue par la montre : V1 (caractéristiques
/// GFDI directes, Vivomove/Forerunner) ou V2 (Micro-Link, Venu 2 — cf.
/// `CommunicatorV1`/`CommunicatorV2` du pont).
enum CommunicatorVersion: Equatable {
    case v1
    case v2

    /// Taille d'écriture par défaut avant négociation MTU (ATT 23 o − 3 o d'en-tête) :
    /// `maxWriteSize = 20` dans les deux communicateurs du pont.
    static let defaultMaxWriteSize = 20

    /// Découpe une trame déjà encodée COBS en fragments tels qu'écrits sur la
    /// caractéristique d'émission (`sendMessage` du pont). V1 : fragments bruts. V2 :
    /// chaque fragment est préfixé d'un octet de handle ML (mode non-MLR de
    /// `CommunicatorV2.sendMessage`).
    func fragment(_ cobsEncoded: Data, maxWriteSize: Int = CommunicatorVersion.defaultMaxWriteSize, handle: UInt8 = 1) -> [Data] {
        let chunkSize = max(1, maxWriteSize - 1)
        let bytes = [UInt8](cobsEncoded)
        var fragments: [Data] = []
        var index = 0
        while index < bytes.count {
            let end = min(index + chunkSize, bytes.count)
            var fragment: [UInt8] = []
            if self == .v2 {
                fragment.append(handle)
            }
            fragment.append(contentsOf: bytes[index..<end])
            fragments.append(Data(fragment))
            index = end
        }
        if fragments.isEmpty {
            fragments.append(self == .v2 ? Data([handle]) : Data())
        }
        return fragments
    }

    /// Retire l'en-tête propre à la version d'un fragment BRUT reçu de la
    /// caractéristique de notification, avant de le remettre au décodeur COBS.
    /// V1 : rien à retirer. V2 : l'octet de handle ML (déjà retiré par
    /// `GfdiCallback.onMessage` côté pont avant d'atteindre le CoDec — modélisé ici
    /// explicitement pour rester testable sans la couche ML/MLR complète).
    func stripFragmentHeader(_ rawFragment: Data) -> Data {
        switch self {
        case .v1:
            return rawFragment
        case .v2:
            return rawFragment.isEmpty ? rawFragment : rawFragment.dropFirst()
        }
    }
}
