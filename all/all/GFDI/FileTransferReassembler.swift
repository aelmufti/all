//
//  FileTransferReassembler.swift
//  all (bridge-connect)
//
//  Réassemblage + reprise d'un téléchargement de fichier GFDI (FILE_TRANSFER_DATA,
//  message 5004), extrait de `GarminSession` en un type PUR pour être testable
//  sans CoreBluetooth. `GarminSession` elle-même reste testable sans
//  `CBPeripheral` réel depuis l'introduction du seam `GfdiCommunicating`
//  (`CommunicatorV2.swift`) — cf. `TransferResilienceTests.swift`, qui pilote
//  `GarminSession` de bout en bout avec un communicator factice pour couvrir ce
//  que ce type pur ne voit pas seul (traînard après fin, interleaving de
//  l'archivage avec le téléchargement suivant).
//
//  Porté de gadgetbridge/garmin-bridge, AGPL-3.0 — l'algorithme est celui de
//  `net.garminbridge.session.GarminSession.answeredAFragmentOutOfStep` /
//  `trackWhereTheTransferIs` (session/GarminSession.java), PAS celui du pont
//  vendoré `FileTransferHandler.FileFragment.append`
//  (nodomain.freeyourgadget.gadgetbridge.service.devices.garmin), qui lève une
//  exception sur tout fragment hors séquence (doublon ou saut) — le bug que
//  cette reprise corrige. Vecteurs de test alignés sur
//  `GarminSessionDownloadTest` (net.garminbridge.session, côté pont).
//

import Foundation

/// Réassemble le flux d'octets d'un téléchargement de fichier GFDI, fragment
/// après fragment, et décide de l'accusé à renvoyer. Sur ce transport, MLR est
/// désactivé (cf. `CommunicatorV2.swift`) : l'accusé GFDI (RESPONSE/5000 nommant
/// l'offset voulu) EST toute la fiabilité — la montre retransmet le fragment en
/// cours sur une minuterie tant qu'il n'est pas accusé.
///
/// Type valeur : une instance par téléchargement en cours, détenue par
/// `GarminSession` dans un `FileTransferReassembler?` (`nil` = aucun download en
/// cours — le cas « fragment traînard » que `GarminSession` gère lui-même,
/// puisqu'il n'y a alors pas d'instance à qui déléguer).
struct FileTransferReassembler {
    let expectedSize: Int
    private(set) var buffer = Data()
    private(set) var runningCrc: UInt16 = 0

    /// Vrai dès que le fragment qui vient d'être appliqué a rempli le buffer —
    /// modélise `expectedDataOffset = NOTHING_TO_APPEND_TO` côté pont
    /// (`trackWhereTheTransferIs`). `GarminSession` doit alors relâcher ce
    /// reassembler (`currentDownload = nil`) pour que le prochain fragment (la
    /// fin du MÊME fichier, retransmise parce que notre ack fut tardif) tombe
    /// dans la branche « pas de download en cours » plutôt que d'être reçu ici.
    var isComplete: Bool { buffer.count >= expectedSize }

    enum Action: Equatable {
        /// Fragment attendu, appliqué. `complete` = le buffer est plein — le
        /// download doit être terminé par l'appelant.
        case appended(ackOffset: UInt32, complete: Bool)
        /// Doublon (`dataOffset < expected`), reprise après perte
        /// (`dataOffset > expected`), ou CRC invalide (`dataOffset == expected`
        /// mais corrompu) : rien n'est appliqué, on ré-accuse l'offset courant —
        /// jamais `TransferStatus.RESEND`, qui n'existe pas dans ce port (cf.
        /// `sendFileTransferAck` : seul `TransferStatus.OK` est jamais émis). La
        /// montre reprend d'elle-même à l'offset qu'on lui répète.
        case reAck(offset: UInt32)
    }

    /// Traite un fragment dont on sait déjà qu'un téléchargement est en cours —
    /// le cas « pas de download » (fragment traînard) est géré par l'appelant,
    /// qui n'a alors aucune instance de ce type à disposition.
    mutating func receive(dataOffset: UInt32, crc: UInt16, chunk: Data) -> Action {
        let expected = UInt32(buffer.count)

        guard dataOffset == expected else {
            // < expected : la montre a renvoyé un fragment déjà reçu (notre ack
            //   s'est perdu ou est arrivé en retard) — ré-accuser sans réappliquer.
            // > expected : un fragment a été perdu, la montre est en avance — on
            //   ré-accuse quand même NOTRE offset (jamais RESEND), ce qui vaut
            //   demande implicite de reprise à cet offset. Réf. branche
            //   `fragment.getDataOffset() < / > expected` de
            //   `answeredAFragmentOutOfStep` côté pont.
            return .reAck(offset: expected)
        }

        // HYPOTHÈSE — au-delà du pont, qui lèverait (`FileFragment.append` compare
        // et jette sur tout CRC invalide) : ici un CRC qui ne correspond pas est
        // traité comme un fragment à redemander plutôt qu'une panne fatale du
        // download. Non vérifié contre le matériel — à surveiller au premier
        // download réel si la montre se comporte différemment d'un simple retard
        // d'ack sur une portion corrompue.
        let computedCrc = Crc16.compute(chunk, initial: runningCrc)
        guard computedCrc == crc else {
            return .reAck(offset: expected)
        }

        runningCrc = computedCrc
        buffer.append(chunk)
        return .appended(ackOffset: UInt32(buffer.count), complete: isComplete)
    }
}
