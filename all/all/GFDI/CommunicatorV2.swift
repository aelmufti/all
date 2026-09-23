//
//  CommunicatorV2.swift
//  all (bridge-connect)
//
//  Transport GFDI V2 (Micro-Link) au-dessus de CoreBluetooth. Porté de
//  gadgetbridge/garmin-bridge, AGPL-3.0
//  (service/devices/garmin/communicator/v2/CommunicatorV2.java) : découverte de la
//  paire de caractéristiques ML (0x2810..0x2814 / +0x10), fermeture de tous les
//  services au rattachement (`closeAllServices`), enregistrement du service GFDI
//  par handle. Les services FILE_TRANSFER_*/REALTIME_* du pont ne sont PAS
//  portés : rien dans ce projet ne les utilise (musique/mesures en direct, hors
//  périmètre) — le téléchargement du manifeste directory passe par des messages
//  GFDI ordinaires sur le service GFDI lui-même (`DOWNLOAD_REQUEST` sur l'index 0,
//  cf. garmin-bridge/docs/roadmap.md, section « Ce que le protocole permet
//  vraiment »), pas par un service ML dédié.
//
//  MlrCommunicator (fiabilité Micro-Link : ACK/retransmission au niveau ML) N'EST
//  PAS porté. Dans le pont, `GarminSession` enregistre le service GFDI via
//  `mSupport.mlrEnabled()`, et le seul point d'entrée en production
//  (`BlueZOpener.java:83`, `new GarminSession(transport, inbox, acquired,
//  gfdiOptions)`) descend vers le constructeur à 4 arguments, qui fixe
//  `mlrEnabled=false` en dur. Autrement dit : contre la Venu 2 réelle, le pont
//  n'utilise JAMAIS le mode fiable ML — la fiabilité vient du niveau GFDI
//  lui-même (accusés RESPONSE/5000, CRC16 par fragment de fichier, cf.
//  `GfdiTransport`/`Crc16` déjà portés). On reproduit ce choix : le service GFDI
//  est toujours enregistré avec `reliable=false`.
//

import CoreBluetooth
import Foundation
import os

/// Base d'UUID Micro-Link (`CommunicatorV2.BASE_UUID` côté pont) et service
/// GFDI/ML (0x2800) : sa présence parmi les services découverts signale que la
/// montre parle le protocole V2.
enum MicroLinkUUID {
    private static let base = "6A4E%04X-667B-11E3-949A-0800200C9A66"

    static func make(_ code: UInt16) -> CBUUID {
        CBUUID(string: String(format: base, code))
    }

    static let service = make(0x2800)

    /// Codes de caractéristique de réception essayés dans l'ordre du pont
    /// (`initializeDevice` : 0x2810 à 0x2814) ; la caractéristique d'émission
    /// correspondante est toujours `code + 0x10`.
    static let receiveCandidates: [UInt16] = [0x2810, 0x2811, 0x2812, 0x2813, 0x2814]
}

/// Paire de caractéristiques ML réception/émission trouvée parmi celles déjà
/// découvertes par CoreBluetooth.
struct MicroLinkCharacteristics {
    let receive: CBCharacteristic
    let send: CBCharacteristic

    /// Cherche la première paire connue, tous services confondus — comme
    /// `mSupport.getCharacteristic(uuid)` côté pont, qui ne regarde que l'UUID et
    /// pas le service auquel elle appartient.
    static func find(in characteristicsByUUID: [CBUUID: CBCharacteristic]) -> MicroLinkCharacteristics? {
        for code in MicroLinkUUID.receiveCandidates {
            let receiveUUID = MicroLinkUUID.make(code)
            let sendUUID = MicroLinkUUID.make(code + 0x10)
            if let receive = characteristicsByUUID[receiveUUID], let send = characteristicsByUUID[sendUUID] {
                return MicroLinkCharacteristics(receive: receive, send: send)
            }
        }
        return nil
    }
}

/// Les quatre points d'entrée que `GarminSession` utilise réellement d'un
/// transport GFDI — extrait de `CommunicatorV2` UNIQUEMENT pour permettre un
/// communicator factice en test (`TransferResilienceTests.swift`) : jamais de
/// vrai CoreBluetooth/BLE en test (règle immuable CLAUDE.md), et `CBPeripheral`
/// ne se sous-classe/simule pas. Aucune logique ici, aucun comportement modifié
/// pour `CommunicatorV2` (seule conformance de production) — pur seam de test,
/// même famille que `SpoolUploading` (Sync/PulseUploader.swift).
protocol GfdiCommunicating: AnyObject {
    /// Rappelé à chaque trame GFDI complète décodée sur le service GFDI.
    var onGfdiFrame: ((GfdiFrame) -> Void)? { get set }
    /// Rappelé une fois le service GFDI (ré)enregistré et prêt à émettre.
    var onGfdiChannelReady: (() -> Void)? { get set }
    func start()
    func sendGfdiMessage(_ frame: Data, taskName: String)
}

/// Transport GFDI V2 (Micro-Link) : enregistrement du service GFDI par handle
/// puis relais des fragments vers/depuis `GfdiTransport`. Une instance par lien
/// BLE ; pilotée par `BLEManager` (délégué CoreBluetooth), qui lui relaie les
/// notifications et écritures.
final class CommunicatorV2: GfdiCommunicating {
    private let log = Logger(subsystem: "CleanYourRoom.all", category: "gfdi")

    /// Identifiant client ML, valeur du pont (`GADGETBRIDGE_CLIENT_ID`) gardée à
    /// l'identique. HYPOTHÈSE : cette valeur ne sert probablement qu'à distinguer
    /// un ré-appairage concurrent côté montre, mais rien ne garantit qu'une autre
    /// valeur fonctionnerait aussi bien — non vérifié contre le matériel.
    private static let clientID: UInt64 = 2

    private enum RequestType: UInt8 {
        case registerMlReq = 0
        case registerMlResp = 1
        case closeHandleReq = 2
        case closeHandleResp = 3
        case unkHandle = 4
        case closeAllReq = 5
        case closeAllResp = 6
        case unkReq = 7
        case unkResp = 8
    }

    /// Seul le service GFDI est porté (cf. en-tête de fichier) ; son code ML
    /// (1) vient de l'enum `Service` côté pont.
    private enum MlService: UInt16 {
        case gfdi = 1
    }

    private let peripheral: CBPeripheral
    private let characteristicReceive: CBCharacteristic
    private let characteristicSend: CBCharacteristic

    private var handleByService: [MlService: UInt8] = [:]
    private var serviceByHandle: [UInt8: MlService] = [:]
    /// Cf. `closingAll` côté pont : tant qu'un CLOSE_ALL_REQ est en vol, les
    /// CLOSE_HANDLE_RESP individuels ne doivent pas re-déclencher leur propre
    /// réenregistrement (CLOSE_ALL_RESP le fait déjà, une fois).
    private var closingAll = false

    private let gfdiTransport = GfdiTransport()

    /// Rappelé à chaque trame GFDI complète décodée sur le service GFDI.
    var onGfdiFrame: ((GfdiFrame) -> Void)?
    /// Rappelé une fois le service GFDI (ré)enregistré et prêt à émettre —
    /// équivalent du moment où `GfdiCallback` est branché côté pont.
    var onGfdiChannelReady: (() -> Void)?

    /// UUID de la caractéristique de réception ML, pour que `BLEManager` (seul
    /// délégué CoreBluetooth) sache lui relayer les notifications qui la
    /// concernent.
    var receiveCharacteristicUUID: CBUUID { characteristicReceive.uuid }

    /// `nil` si aucune paire de caractéristiques ML connue n'est présente parmi
    /// celles déjà découvertes : la montre ne parle pas V2 (ou pas encore assez
    /// découvert), à l'appelant de retomber sur le chemin générique / V1.
    init?(peripheral: CBPeripheral, characteristicsByUUID: [CBUUID: CBCharacteristic]) {
        guard let pair = MicroLinkCharacteristics.find(in: characteristicsByUUID) else { return nil }
        self.peripheral = peripheral
        self.characteristicReceive = pair.receive
        self.characteristicSend = pair.send
    }

    /// `initializeDevice` côté pont : abonnement sur la caractéristique de
    /// réception puis fermeture de tous les services ML déjà ouverts. La montre
    /// répond par CLOSE_ALL_RESP, qui déclenche l'enregistrement du service GFDI.
    func start() {
        log.info("CommunicatorV2.start — receive=\(self.characteristicReceive.uuid.uuidString, privacy: .public) send=\(self.characteristicSend.uuid.uuidString, privacy: .public)")
        peripheral.setNotifyValue(true, for: characteristicReceive)
        closingAll = true
        writeHandleManagement(closeAllServicesPayload())
    }

    /// À appeler par le délégué CoreBluetooth (`BLEManager`) pour chaque
    /// notification reçue sur la caractéristique de réception ML.
    func handleIncoming(_ value: Data) {
        guard let first = value.first else { return }
        if first & 0x80 != 0 {
            // Bit MLR : ne devrait jamais arriver, GFDI est toujours enregistré
            // non fiable (cf. en-tête de fichier).
            log.warning("Paquet MLR reçu alors qu'aucun service fiable n'est enregistré — ignoré (\(value.count, privacy: .public) o)")
            return
        }
        if first == 0x00 {
            processHandleManagement(value.dropFirst())
            return
        }
        guard let service = serviceByHandle[first] else {
            log.warning("Message pour handle inconnu \(first) — ignoré")
            return
        }
        switch service {
        case .gfdi:
            handleGfdiFragment(value.dropFirst())
        }
    }

    private func handleGfdiFragment(_ fragment: Data) {
        log.debug("Fragment GFDI reçu (\(fragment.count, privacy: .public) o)")
        guard let result = gfdiTransport.receive(fragment) else { return }
        switch result {
        case .success(let frame):
            log.info("Trame GFDI décodée : type=\(frame.messageType, privacy: .public) payload=\(frame.payload.count, privacy: .public) o")
            onGfdiFrame?(frame)
        case .failure(let error):
            log.error("Trame GFDI invalide, abandonnée : \(String(describing: error), privacy: .public)")
        }
    }

    /// Envoie une trame GFDI déjà construite (`GfdiFrame.build`) : encodage COBS
    /// puis fragmentation avec l'en-tête de handle ML — `sendMessage` côté pont,
    /// branche non fiable (pas de `MlrCommunicator`, cf. en-tête de fichier).
    func sendGfdiMessage(_ frame: Data, taskName: String = "") {
        guard let gfdiHandle = handleByService[.gfdi] else {
            log.error("Envoi impossible (\(taskName, privacy: .public)) : service GFDI non encore enregistré")
            return
        }
        let cobsEncoded = CobsDecoder.encode(frame)
        let fragments = CommunicatorVersion.v2.fragment(cobsEncoded, maxWriteSize: currentMaxWriteSize(), handle: gfdiHandle)
        for fragment in fragments {
            write(fragment)
        }
        log.debug("GFDI envoyé (\(taskName, privacy: .public)) : \(frame.count, privacy: .public) o -> \(fragments.count, privacy: .public) fragment(s)")
    }

    /// HYPOTHÈSE : `peripheral.maximumWriteValueLength(for:)` reflète la MTU
    /// négociée par iOS après connexion ; on retombe sur le défaut
    /// pré-négociation du pont (20) si iOS rend une valeur aberrante avant que la
    /// négociation ait eu lieu. Non mesuré contre le matériel.
    private func currentMaxWriteSize() -> Int {
        let negotiated = peripheral.maximumWriteValueLength(for: preferredWriteType())
        return negotiated > 0 ? negotiated : CommunicatorVersion.defaultMaxWriteSize
    }

    /// MESURÉ contre la Venu 2 (fw 19.05) : la caractéristique d'émission ML
    /// annonce à la fois Write et WriteWithoutResponse (propriétés 0x0C), mais la
    /// montre **rejette** les écritures « avec réponse » (`CBATTError` = *Writing is
    /// not permitted*). Le flux ML Garmin doit être écrit **sans réponse** — on le
    /// privilégie dès qu'il est disponible, repli sur « avec réponse » sinon.
    private func preferredWriteType() -> CBCharacteristicWriteType {
        characteristicSend.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
    }

    private func write(_ data: Data) {
        peripheral.writeValue(data, for: characteristicSend, type: preferredWriteType())
    }

    // MARK: - Gestion des handles ML (canal de contrôle, handle 0)

    private func processHandleManagement(_ rest: Data) {
        var reader = GarminByteReader(rest)
        guard let typeRaw = reader.readUInt8(), let requestType = RequestType(rawValue: typeRaw) else {
            log.error("Type de requête de gestion de handle inconnu")
            return
        }
        guard let incomingClientID = reader.readUInt64LE() else { return }
        guard incomingClientID == Self.clientID else {
            log.warning("Message de gestion de handle ignoré : clientID \(incomingClientID) ≠ le nôtre")
            return
        }

        switch requestType {
        case .registerMlResp:
            guard let serviceCode = reader.readUInt16LE(), let status = reader.readUInt8() else { return }
            guard let service = MlService(rawValue: serviceCode) else {
                log.warning("REGISTER_ML_RESP pour un service non porté (code=\(serviceCode, privacy: .public)) — ignoré")
                return
            }
            guard status == 0 else {
                log.warning("Échec d'enregistrement de \(String(describing: service), privacy: .public) : status=\(status, privacy: .public)")
                return
            }
            guard let handle = reader.readUInt8(), let reliable = reader.readUInt8() else { return }
            log.info("Service \(String(describing: service), privacy: .public) enregistré : handle=\(handle, privacy: .public) fiable=\(reliable != 0, privacy: .public)")
            handleByService[service] = handle
            serviceByHandle[handle] = service
            if service == .gfdi {
                onGfdiChannelReady?()
            }
        case .closeHandleResp:
            guard let serviceCode = reader.readUInt16LE(), let handle = reader.readUInt8(), let status = reader.readUInt8() else { return }
            let service = MlService(rawValue: serviceCode)
            log.debug("CLOSE_HANDLE_RESP service=\(String(describing: service), privacy: .public) handle=\(handle, privacy: .public) status=\(status, privacy: .public)")
            if let service {
                handleByService.removeValue(forKey: service)
            }
            serviceByHandle.removeValue(forKey: handle)
            if service == .gfdi, !closingAll {
                log.warning("Canal GFDI fermé de manière inattendue — réenregistrement")
                writeHandleManagement(registerServicePayload(.gfdi, reliable: false))
            }
        case .closeAllResp:
            log.debug("CLOSE_ALL_RESP reçu — réenregistrement du service GFDI")
            closingAll = false
            handleByService.removeAll()
            serviceByHandle.removeAll()
            writeHandleManagement(registerServicePayload(.gfdi, reliable: false))
        case .registerMlReq, .closeHandleReq, .closeAllReq, .unkReq:
            log.warning("Requête de gestion de handle reçue alors qu'on attendait une réponse (type=\(String(describing: requestType), privacy: .public))")
        case .unkHandle, .unkResp:
            log.debug("Message de gestion de handle non porté (type=\(String(describing: requestType), privacy: .public))")
        }
    }

    private func writeHandleManagement(_ payload: Data) {
        peripheral.writeValue(payload, for: characteristicSend, type: preferredWriteType())
    }

    /// 13 octets fixes, comme `CommunicatorV2.closeAllServices()` côté pont :
    /// `ByteBuffer.allocate(13)` avec seulement 12 octets écrits laisse un octet
    /// de bourrage nul final (`array()` rend tout le buffer, pas seulement la
    /// position écrite) — reproduit tel quel au cas où la montre attendrait
    /// exactement 13 octets pour un message de gestion de handle.
    private func closeAllServicesPayload() -> Data {
        var writer = GarminByteWriter()
        writer.writeUInt8(0) // handle de contrôle
        writer.writeUInt8(RequestType.closeAllReq.rawValue)
        writer.writeUInt64LE(Self.clientID)
        writer.writeUInt16LE(0)
        writer.writeUInt8(0) // bourrage (13e octet du buffer Java)
        return writer.data
    }

    private func registerServicePayload(_ service: MlService, reliable: Bool) -> Data {
        var writer = GarminByteWriter()
        writer.writeUInt8(0)
        writer.writeUInt8(RequestType.registerMlReq.rawValue)
        writer.writeUInt64LE(Self.clientID)
        writer.writeUInt16LE(service.rawValue)
        writer.writeUInt8(reliable ? 2 : 0)
        return writer.data
    }
}
