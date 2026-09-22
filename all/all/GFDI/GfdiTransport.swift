//
//  GfdiTransport.swift
//  all (bridge-connect)
//
//  Réassemblage des fragments BLE en trames GFDI complètes (COBS + framing), et
//  accusés génériques au niveau transport (trame RESPONSE, `GFDIMessage.Status`).
//  Porté de gadgetbridge/garmin-bridge, AGPL-3.0 pour la mécanique COBS/framing
//  (CobsCoDec.java, GFDIMessage.java, GenericStatusMessage.java) ; l'enchaînement
//  receive→retrieve reproduit celui de `CommunicatorV1/V2.onCharacteristicChanged`.
//  Pas de protobuf ici (accusé KEPT/DISCARDED corrélé par requestId = incrément 4),
//  pas de sous-types de message (incrément 5).
//

import Foundation

/// Statut générique porté par une trame RESPONSE (5000) — accusé de réception au
/// niveau transport GFDI. Ordre des cas = ordinal de `GFDIMessage.Status` côté
/// pont ; ne pas réordonner, c'est l'octet envoyé sur le fil.
enum GfdiStatus: UInt8, Equatable {
    case ack = 0
    case nak = 1
    case unsupported = 2
    case decodeError = 3
    case crcError = 4
    case lengthError = 5
}

/// Accusés génériques au niveau transport (trame RESPONSE = 5000), distincts de
/// l'accusé protobuf KEPT/DISCARDED (incrément 4).
enum GfdiAck {
    static let responseMessageType: UInt16 = 5000

    /// Construit la trame RESPONSE accusant réception de `originalMessageType`
    /// (`GenericStatusMessage.generateOutgoing` côté pont : type d'origine 2 o LE +
    /// statut 1 o, sans les extensions par sous-type).
    static func statusFrame(for originalMessageType: UInt16, status: GfdiStatus = .ack) -> Data {
        var payload = Data()
        payload.append(UInt8(originalMessageType & 0xFF))
        payload.append(UInt8((originalMessageType >> 8) & 0xFF))
        payload.append(status.rawValue)
        return GfdiFrame.build(messageType: responseMessageType, payload: payload)
    }

    /// Décode le statut générique porté par une trame RESPONSE déjà parsée. `nil`
    /// si `frame` n'est pas une RESPONSE, ou si sa charge utile est trop courte.
    static func parseStatus(from frame: GfdiFrame) -> (originalMessageType: UInt16, status: GfdiStatus)? {
        guard frame.messageType == responseMessageType, frame.payload.count >= 3 else { return nil }
        let bytes = [UInt8](frame.payload)
        let originalType = UInt16(bytes[0]) | (UInt16(bytes[1]) << 8)
        guard let status = GfdiStatus(rawValue: bytes[2]) else { return nil }
        return (originalType, status)
    }
}

/// Réassemble des fragments BLE (notifications brutes, déjà dépouillées de tout
/// en-tête de version via `CommunicatorVersion.stripFragmentHeader`) en trames GFDI
/// complètes. Une instance par lien BLE (état interne : accumulateur COBS), comme
/// `CobsCoDec` côté pont.
final class GfdiTransport {
    private let decoder = CobsDecoder()

    /// Remet un fragment brut. Rend une trame **au plus** par appel, comme
    /// `onCharacteristicChanged` côté pont — une trame décodée non retirée reste en
    /// attente tant qu'elle n'est pas consommée (comportement du CoDec vendored).
    @discardableResult
    func receive(_ fragment: Data) -> Result<GfdiFrame, GfdiFrameError>? {
        decoder.receivedBytes(fragment)
        return drain()
    }

    /// Retente un décodage sans nouvel octet : draine une trame déjà complète dans
    /// l'accumulateur mais laissée en attente par un appel précédent (p. ex.
    /// plusieurs trames concaténées dans un même paquet BLE).
    @discardableResult
    func drainPending() -> Result<GfdiFrame, GfdiFrameError>? {
        decoder.receivedBytes(Data())
        return drain()
    }

    private func drain() -> Result<GfdiFrame, GfdiFrameError>? {
        guard let message = decoder.retrieveMessage() else { return nil }
        do {
            return .success(try GfdiFrame.parse(message))
        } catch let error as GfdiFrameError {
            return .failure(error)
        } catch {
            return .failure(.tooShort(actual: message.count)) // ne devrait pas arriver
        }
    }
}
