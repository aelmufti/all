//
//  Cobs.swift
//  all (bridge-connect)
//
//  Porté de gadgetbridge/garmin-bridge, AGPL-3.0 (communicator/CobsCoDec.java).
//  Variante COBS avec un octet 0x00 de tête ET de queue (le bourrage de tête
//  n'est pas dans l'implémentation COBS standard — c'est la convention Garmin).
//

import Foundation

/// Décodeur COBS à état, un par lien BLE : accumule les octets reçus notification
/// par notification et ne décode qu'une trame complète à la fois (délimitée par
/// un 0x00 de tête et de queue). Une trame décodée non retirée bloque le décodage
/// suivant — comportement du pont, à consommer par `retrieveMessage()` avant le
/// prochain fragment utile.
final class CobsDecoder {
    /// Même capacité que le pont (`ByteBuffer.allocate(10_000)`).
    private let maxBufferSize = 10_000
    private var buffer: [UInt8] = []
    private var decodedMessage: [UInt8]?

    /// Accumule des octets reçus et tente un décodage. Une trame malformée ou
    /// tronquée (notification BLE perdue) ne doit jamais bloquer durablement le
    /// décodeur : toute erreur réinitialise l'accumulateur, le prochain fragment
    /// complet redémarre proprement (trames auto-délimitées par 0x00).
    func receivedBytes(_ bytes: Data) {
        if buffer.count + bytes.count > maxBufferSize {
            reset()
            return
        }
        buffer.append(contentsOf: bytes)
        decode()
    }

    /// Rend le message décodé en attente, s'il y en a un, et le retire.
    func retrieveMessage() -> Data? {
        defer { decodedMessage = nil }
        return decodedMessage.map { Data($0) }
    }

    private func decode() {
        if decodedMessage != nil { return } // trame déjà en attente, non consommée
        if buffer.count < 4 { return } // longueur minimale (bourrage inclus)
        guard buffer[buffer.count - 1] == 0 else { return } // pas de 0x00 de queue -> pas de trame complète

        let frame = Array(buffer[0..<(buffer.count - 1)]) // tout sauf le 0x00 de queue
        guard frame.first == 0 else {
            // Pas de 0x00 de tête : le début de trame a été perdu (notification BLE
            // manquée). On jette plutôt que de bloquer le décodeur durablement.
            reset()
            return
        }

        var decoded: [UInt8] = []
        decoded.reserveCapacity(frame.count)
        var i = 1 // saute le 0x00 de tête
        let end = frame.count

        while i < end {
            let code = frame[i]
            i += 1
            if code == 0 { break }
            let payloadSize = Int(code) - 1
            guard end - i >= payloadSize else {
                // Le code réclame plus d'octets que ce qui a été reçu : trame tronquée.
                reset()
                return
            }
            if payloadSize > 0 {
                decoded.append(contentsOf: frame[i..<(i + payloadSize)])
                i += payloadSize
            }
            if code != 0xFF && i < end {
                decoded.append(0)
            }
        }

        decodedMessage = decoded
        buffer.removeAll(keepingCapacity: true)
    }

    private func reset() {
        decodedMessage = nil
        buffer.removeAll(keepingCapacity: true)
    }

    /// Encode `data` en trame COBS Garmin (0x00 de tête + groupes code/charge utile
    /// + 0x00 de queue). Statique et sans état, comme `CobsCoDec.encode` côté pont.
    static func encode(_ data: Data) -> Data {
        let bytes = [UInt8](data)
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count * 2 + 2)
        out.append(0) // bourrage initial Garmin

        var position = 0
        let limit = bytes.count
        var lastByteWasZero = false

        while position < limit {
            let startPos = position
            var zeroIndex = position

            while position < limit {
                let b = bytes[position]
                position += 1
                if b == 0 { break }
                zeroIndex += 1
            }

            lastByteWasZero = position > zeroIndex

            var payloadSize = zeroIndex - startPos
            var chunkStart = startPos
            while payloadSize >= 0xFE {
                out.append(0xFF)
                out.append(contentsOf: bytes[chunkStart..<(chunkStart + 0xFE)])
                payloadSize -= 0xFE
                chunkStart += 0xFE
            }
            out.append(UInt8(payloadSize + 1))
            out.append(contentsOf: bytes[chunkStart..<(chunkStart + payloadSize)])
        }

        if lastByteWasZero {
            out.append(0x01)
        }
        out.append(0) // délimiteur de fin de trame

        return Data(out)
    }
}
