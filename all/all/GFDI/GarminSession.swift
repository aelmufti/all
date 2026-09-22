//
//  GarminSession.swift
//  all (bridge-connect)
//
//  Poignée de main GFDI + listing du manifeste directory + téléchargement du
//  contenu d'un fichier, au-dessus de `CommunicatorV2`. Porté de
//  gadgetbridge/garmin-bridge, AGPL-3.0 (session/GarminSession.java pour
//  l'enchaînement, les accusés et la reprise de fragment,
//  session/ProtobufAck.java pour les réponses protobuf codées en dur,
//  messages/*.java pour le format sur le fil de chaque message porté). La
//  reprise de fragment perdu/dupliqué proprement dite vit dans le type pur
//  `FileTransferReassembler.swift` (testable sans CoreBluetooth).
//
//  Périmètre : poignée de main, listing du manifeste directory (index 0,
//  métadonnées seules), téléchargement du contenu d'un fichier quelconque du
//  manifeste — un seul à la fois, déclenché manuellement
//  (`GarminSession.downloadFile`, cf. `BLEDiagnosticView`) OU via la traversée
//  automatique `syncNewFiles()` —, l'upload vers Pulse de chaque fichier acquis,
//  et l'archivage différé (`SET_FILE_FLAG` ARCHIVE) une fois qu'un fichier est
//  `delivered` dans le Spool. Les octets reçus vont au Spool
//  (`SpoolStore.recordAcquired`) sans jamais être parsés (cf. CLAUDE.md, « ne
//  pas parser le FIT sur le collecteur »).
//
//  `syncNewFiles()` délègue le calcul « quoi, dans quel ordre » au type pur
//  `Sync/SyncPlanner.swift` (testable sans CoreBluetooth) ; cette classe ne
//  fait qu'enchaîner les téléchargements un par un et publier `syncState`.
//  PIVOT 2026-09-22 (demande utilisateur, plus de sélection manuelle
//  fichier-par-fichier) : `syncNewFiles()` est désormais déclenchée
//  automatiquement dès que le manifeste directory est reçu (`finishDownload()`,
//  branche `.directory`) — la traversée démarre à la connexion de la montre,
//  sans action de l'utilisateur. Le bouton manuel de `BLEDiagnosticView` reste
//  un filet de secours.
//
//  Ce qui n'est délibérément PAS porté (hors périmètre de cet incrément, pas des
//  oublis) :
//  - `GdiSettingsService` (champ protobuf 42) : jamais de réponse applicative sur
//    Venu 2 fw 19.05 (cf. CLAUDE.md) — il reste dans `knownServices` (accusé KEPT,
//    comme le pont), mais sans réponse canée, exactement comme `ProtobufAck`
//    upstream qui n'a pas de cas pour 42 dans `responseFor`.
//
//  L'upload/push réseau vers Pulse (`Sync/PulseUploader.swift`) est câblé et
//  ÉMET RÉELLEMENT (autorisation utilisateur explicite, datée 2026-09-22) : cf.
//  `uploadSpoolEntry`/`uploadPendingAcquisitions` ci-dessous, qui appellent
//  l'`uploader` injecté (`SpoolUploading`, `nil` par défaut pour ne pas casser
//  les tests existants qui n'en passent pas).
//

import Foundation
import os

/// État de la poignée de main + du listing, affiché par la vue de diagnostic.
enum GarminHandshakeState: Equatable {
    case idle
    case gfdiChannelOpen
    case initialized
    case listingDirectory
    case listed
    case failed(String)

    var label: String {
        switch self {
        case .idle: return "Inactif"
        case .gfdiChannelOpen: return "Canal GFDI ouvert"
        case .initialized: return "Montre initialisée"
        case .listingDirectory: return "Listing en cours…"
        case .listed: return "Manifeste reçu"
        case .failed(let reason): return "Échec : \(reason)"
        }
    }
}

/// État de la traversée de synchronisation (`GarminSession.syncNewFiles()`),
/// distinct de `GarminHandshakeState` (poignée de main + listing). Observable
/// pour une UI future ; rien ne l'affiche cette session (pas de trigger UI,
/// hors périmètre de cette tâche).
enum GarminSyncState: Equatable {
    case idle
    case downloading(fileIndex: Int)
    case done
}

/// Orchestre la poignée de main GFDI puis le listing du manifeste directory sur
/// un `CommunicatorV2` déjà démarré. Une instance par lien BLE.
final class GarminSession: ObservableObject {
    private let log = Logger(subsystem: "CleanYourRoom.all", category: "gfdi")

    // MARK: - Constantes de message (GFDIMessage.GarminMessage côté pont)

    private enum MessageType {
        static let response: UInt16 = 5000
        static let downloadRequest: UInt16 = 5002
        static let fileTransferData: UInt16 = 5004
        static let filter: UInt16 = 5007
        static let setFileFlag: UInt16 = 5008
        static let deviceInformation: UInt16 = 5024
        static let systemEvent: UInt16 = 5030
        static let supportedFileTypesRequest: UInt16 = 5031
        static let synchronization: UInt16 = 5037
        static let protobufRequest: UInt16 = 5043
        static let protobufResponse: UInt16 = 5044
        static let configuration: UInt16 = 5050
        static let currentTimeRequest: UInt16 = 5052
        static let authNegotiation: UInt16 = 5101
    }

    private let communicator: CommunicatorV2
    /// `nil` si le spool n'a pas pu s'initialiser (cf. `SpoolStore.init`, qui
    /// peut lever) — un téléchargement de fichier reste alors possible mais ses
    /// octets ne seront pas écrits sur disque (journalisé en erreur au finish).
    private let spoolStore: SpoolStore?
    /// `nil` par défaut pour ne pas casser les init existants (tests, notamment)
    /// qui ne connaissent pas encore l'upload — `BLEManager` passe une vraie
    /// instance (`PulseSpoolUploader`) à la construction. Cf. `uploadSpoolEntry`.
    private let uploader: SpoolUploading?

    @Published private(set) var state: GarminHandshakeState = .idle
    @Published private(set) var files: [GarminDirectoryEntry] = []
    @Published private(set) var firmwareVersion: String?
    /// Index du fichier en cours de téléchargement (cible = fichier de contenu,
    /// pas le manifeste directory), pour que la vue de diagnostic affiche un état
    /// « en cours » sur la bonne ligne. `nil` hors téléchargement de fichier.
    @Published private(set) var downloadingFileIndex: Int?
    /// Index des fichiers déjà écrits dans le spool durant cette session (état
    /// facultatif pour l'UI ; la source de vérité reste `SpoolStore.entries`).
    @Published private(set) var acquiredFileIndexes: Set<Int> = []
    /// Index des fichiers déjà livrés à Pulse (2xx) durant cette session — même
    /// statut facultatif que `acquiredFileIndexes` (source de vérité :
    /// `SpoolStore.entries`), pour que `BLEDiagnosticView` distingue visuellement
    /// « acquis » de « livré » sans interroger le Spool directement.
    @Published private(set) var deliveredFileIndexes: Set<Int> = []
    /// État de la traversée `syncNewFiles()` — cf. `GarminSyncState`.
    @Published private(set) var syncState: GarminSyncState = .idle

    /// File d'attente de traversée, calculée une fois par `syncNewFiles()` à
    /// partir du dernier manifeste (`files`) et du journal Spool — pas re-triée
    /// à chaque fichier fini (cf. commentaire d'en-tête : un seul manifeste par
    /// appel de `syncNewFiles()`, pas un flux de listings ré-absorbés en cours
    /// de lien comme côté pont). Le tri/filtre proprement dits vivent dans le
    /// type pur `SyncPlanner.filesDue`.
    private var downloadQueue: [GarminDirectoryEntry] = []

    /// La montre re-liste de sa propre initiative en cours de lien
    /// (SYNCHRONIZATION → FILTER → `requestDirectoryListing`). Si ça tombe pendant
    /// qu'un transfert occupe déjà le slot unique, on NE l'écrase PAS (écraser
    /// faisait refuser la montre en `downloadStatus=3`, cf. `requestDirectoryListing`)
    /// : la demande est mise en attente ici et rejouée dès que le slot se libère
    /// (`advanceDownloadQueue`, file de traversée épuisée) — équivalent de
    /// « le pont ne lance rien tant que `isDownloading()` ».
    private var pendingDirectoryRelisting = false

    private var initialized = false

    /// Cible du téléchargement en cours — distingue le manifeste directory
    /// (parsé en interne, publié dans `files`) d'un fichier de contenu (remis au
    /// spool). `nil` = aucun téléchargement en cours.
    private enum DownloadTarget {
        case directory
        case file(GarminDirectoryEntry)
    }
    private var downloadTarget: DownloadTarget?
    /// Réassemblage + reprise du téléchargement en cours (cf. `FileTransferReassembler.swift`).
    /// `nil` = aucun téléchargement en cours ; un fragment reçu dans cet état est
    /// un traînard (cf. `handleFileTransferData`), pas une erreur.
    private var currentDownload: FileTransferReassembler?

    init(communicator: CommunicatorV2, spoolStore: SpoolStore?, uploader: SpoolUploading? = nil) {
        self.communicator = communicator
        self.spoolStore = spoolStore
        self.uploader = uploader
        communicator.onGfdiFrame = { [weak self] frame in self?.handle(frame) }
        communicator.onGfdiChannelReady = { [weak self] in self?.onGfdiChannelReady() }
    }

    func start() {
        log.info("GarminSession.start")
        communicator.start()
    }

    private func onGfdiChannelReady() {
        state = .gfdiChannelOpen
        log.info("Canal GFDI prêt — en attente de la poignée de main initiée par la montre")
    }

    // MARK: - Dispatch des trames entrantes

    private func handle(_ frame: GfdiFrame) {
        // GFDIMessage.parseIncoming côté pont : les types ≥ 5000 peuvent arriver
        // avec le bit haut armé (numéro de séquence dans l'octet haut) ; le type
        // réel est alors (type & 0xFF) + 5000.
        var messageType = frame.messageType
        if messageType & 0x8000 != 0 {
            messageType = (messageType & 0xFF) + 5000
        }
        log.debug("Trame reçue : type=\(messageType, privacy: .public) payload=\(frame.payload.count, privacy: .public) o \(frame.payload.gfdiHexDump, privacy: .public)")

        switch messageType {
        case MessageType.response:
            handleResponse(frame.payload)
        case MessageType.fileTransferData:
            handleFileTransferData(frame.payload)
        case MessageType.deviceInformation:
            handleDeviceInformation(frame.payload)
        case MessageType.configuration:
            handleConfiguration(frame.payload)
        case MessageType.synchronization:
            handleSynchronization(frame.payload)
        case MessageType.protobufRequest:
            handleProtobufRequest(frame.payload)
        case MessageType.currentTimeRequest:
            handleCurrentTimeRequest(frame.payload)
        case MessageType.authNegotiation:
            handleAuthNegotiation(frame.payload)
        default:
            log.warning("Type de message non porté : \(messageType, privacy: .public) — accusé UNSUPPORTED")
            send(GfdiAck.statusFrame(for: messageType, status: .unsupported), taskName: "unsupported \(messageType)")
        }
    }

    /// RESPONSE (5000) : dispatch sur le type d'origine porté dans les deux
    /// premiers octets — `GFDIStatusMessage.parseIncoming` côté pont.
    private func handleResponse(_ payload: Data) {
        var reader = GarminByteReader(payload)
        guard let originalType = reader.readUInt16LE() else { return }
        let rest = reader.readRemainingBytes()

        switch originalType {
        case MessageType.downloadRequest:
            handleDownloadRequestStatus(rest)
        case MessageType.filter:
            handleFilterStatus(rest)
        case MessageType.setFileFlag:
            handleSetFileFlagStatus(rest)
        case MessageType.protobufRequest, MessageType.protobufResponse:
            handleProtobufStatus(rest, originalType: originalType)
        default:
            if let status = rest.first {
                log.info("Accusé générique reçu pour type \(originalType, privacy: .public) : status=\(status, privacy: .public)")
            }
        }
    }

    // MARK: - AUTH_NEGOTIATION (5101)

    private func handleAuthNegotiation(_ payload: Data) {
        var reader = GarminByteReader(payload)
        let unknownByte = reader.readUInt8() ?? 0
        let flags = reader.readUInt32LE() ?? 0
        log.info("AUTH_NEGOTIATION reçu : unk=\(unknownByte, privacy: .public) flags=0x\(String(flags, radix: 16), privacy: .public)")

        // « bridge répond avec tous les indicateurs à zéro » (garmin-bridge,
        // GarminSession.java doc) : GUESS_OK, mêmes flags à zéro qu'on ne sait
        // pas interpréter. Une seule trame : AuthNegotiationMessage.generateOutgoing
        // (la « réponse ») rend false côté pont, seul cet accusé riche part.
        var writer = GarminByteWriter()
        writer.writeUInt16LE(MessageType.authNegotiation)
        writer.writeUInt8(0) // Status.ACK
        writer.writeUInt8(0) // AuthNegotiationStatus.GUESS_OK
        writer.writeUInt8(unknownByte)
        writer.writeUInt32LE(0) // flags renvoyés à zéro
        send(GfdiFrame.build(messageType: MessageType.response, payload: writer.data), taskName: "auth negotiation ack")
    }

    // MARK: - DEVICE_INFORMATION (5024)

    private func handleDeviceInformation(_ payload: Data) {
        var reader = GarminByteReader(payload)
        let protocolVersion = Int(reader.readUInt16LE() ?? 0)
        let productNumber = reader.readUInt16LE() ?? 0
        let unitNumber = reader.readUInt32LE() ?? 0
        let softwareVersion = reader.readUInt16LE() ?? 0
        let maxPacketSize = reader.readUInt16LE() ?? 0
        let bluetoothFriendlyName = reader.readPascalString() ?? ""
        let deviceName = reader.readPascalString() ?? ""
        let deviceModel = reader.readPascalString() ?? ""

        let swMajor = Int(softwareVersion) / 100
        let swMinor = Int(softwareVersion) % 100
        firmwareVersion = String(format: "%d.%02d", swMajor, swMinor)
        log.info("""
            DEVICE_INFORMATION reçu : protocole=\(protocolVersion, privacy: .public) \
            produit=\(productNumber, privacy: .public) unité=\(unitNumber, privacy: .public) \
            fw=\(self.firmwareVersion ?? "?", privacy: .public) maxPaquet=\(maxPacketSize, privacy: .public) \
            btName=\(bluetoothFriendlyName, privacy: .public) device=\(deviceName, privacy: .public) \
            modèle=\(deviceModel, privacy: .public)
            """)

        // Deux trames, comme DeviceInformationMessage côté pont : l'accusé
        // générique 3 octets (this.statusMessage), PUIS la réponse riche
        // (this.generateOutgoing()) — les deux typées RESPONSE(5000) en sortie.
        send(GfdiAck.statusFrame(for: MessageType.deviceInformation, status: .ack), taskName: "device information ack")

        let protocolFlags: UInt8 = protocolVersion / 100 == 1 ? 1 : 0
        var writer = GarminByteWriter()
        writer.writeUInt16LE(MessageType.deviceInformation)
        writer.writeUInt8(0) // Status.ACK
        writer.writeUInt16LE(150) // ourProtocolVersion
        writer.writeUInt16LE(0xFFFF) // ourProductNumber (-1)
        writer.writeUInt32LE(0xFFFF_FFFF) // ourUnitNumber (-1)
        writer.writeUInt16LE(7791) // ourSoftwareVersion — valeur du pont, cf. commentaire de classe
        writer.writeUInt16LE(0xFFFF) // ourMaxPacketSize (-1, "on ne sait pas")
        writer.writePascalString("bridge-connect")
        // HYPOTHÈSE : ces deux chaînes sont purement informatives côté montre
        // (DeviceInformationMessage.getGBDeviceEvent ne fait que les journaliser
        // côté pont) — non vérifié contre le matériel.
        writer.writePascalString("Apple")
        writer.writePascalString(deviceModel.isEmpty ? "iPhone" : deviceModel)
        writer.writeUInt8(protocolFlags)
        send(GfdiFrame.build(messageType: MessageType.response, payload: writer.data), taskName: "device information reply")
    }

    // MARK: - CONFIGURATION (5050) — négociation de capacités

    private func handleConfiguration(_ payload: Data) {
        var reader = GarminByteReader(payload)
        let count = Int(reader.readUInt8() ?? 0)
        let watchCapabilities = reader.readBytes(count) ?? Data()
        log.info("CONFIGURATION reçu : \(count, privacy: .public) o de capacités montre = \(watchCapabilities.gfdiHexDump, privacy: .public)")

        // Accusé générique 3 octets (ConfigurationMessage.statusMessage), PUIS la
        // réponse — mais la réponse n'est PAS enveloppée en RESPONSE(5000) :
        // `ConfigurationMessage.generateOutgoing` écrit directement le type
        // CONFIGURATION en type de trame sortante.
        send(GfdiAck.statusFrame(for: MessageType.configuration, status: .ack), taskName: "configuration ack")

        var writer = GarminByteWriter()
        let ourCapabilities = Self.ourCapabilitiesBitfield()
        writer.writeUInt8(UInt8(ourCapabilities.count))
        writer.writeBytes(ourCapabilities)
        send(GfdiFrame.build(messageType: MessageType.configuration, payload: writer.data), taskName: "configuration reply")

        // Proxy de CapabilitiesDeviceEvent côté pont (déclenché quand la réponse
        // de configuration part) : c'est ce qui débloque SUPPORTED_FILE_TYPES /
        // SYNC_READY puis notre propre demande de manifeste.
        completeInitializationIfNeeded()
    }

    /// Bitfield de 120 indicateurs de capacité (15 octets), porté de
    /// `GarminCapability.OUR_CAPABILITIES` côté pont : tous les indicateurs à 1
    /// sauf les 14 réservés (`UNK_104..111`, `UNK_114..119`) que le pont retire
    /// explicitement — pure donnée, aucune logique de capacité individuelle
    /// n'est interprétée ici. Valeur reprise telle quelle, éprouvée contre une
    /// Venu 2 fw 19.05 par garmin-bridge.
    static func ourCapabilitiesBitfield() -> Data {
        let totalBits = 120
        let clearedOrdinals: Set<Int> = [104, 105, 106, 107, 108, 109, 110, 111, 114, 115, 116, 117, 118, 119]
        var bytes = [UInt8](repeating: 0, count: (totalBits + 7) / 8)
        for bit in 0..<totalBits where !clearedOrdinals.contains(bit) {
            bytes[bit / 8] |= UInt8(1 << (bit % 8))
        }
        return Data(bytes)
    }

    private func completeInitializationIfNeeded() {
        guard !initialized else { return }
        initialized = true
        send(GfdiFrame.build(messageType: MessageType.supportedFileTypesRequest, payload: Data()), taskName: "supported file types request")
        var systemEvent = GarminByteWriter()
        systemEvent.writeUInt8(8) // GarminSystemEventType.SYNC_READY (ordinal 8)
        systemEvent.writeUInt8(0) // value=0, comme new SystemEventMessage(SYNC_READY, 0)
        send(GfdiFrame.build(messageType: MessageType.systemEvent, payload: systemEvent.data), taskName: "system event sync ready")
        state = .initialized
        log.info("Montre initialisée (SYNC_READY envoyé) — demande du manifeste directory")
        requestDirectoryListing()
    }

    // MARK: - CURRENT_TIME_REQUEST (5052)

    private func handleCurrentTimeRequest(_ payload: Data) {
        var reader = GarminByteReader(payload)
        let referenceID = reader.readUInt32LE() ?? 0

        // Invariant protocole : secondes epoch Garmin = secondes epoch Unix −
        // 631065600 (cf. CLAUDE.md, GarminTimeUtils.GARMIN_TIME_EPOCH).
        let nowUnix = Date().timeIntervalSince1970
        let garminTimestamp = UInt32(max(0, nowUnix - GarminEpoch.offsetFromUnix))
        let tzOffsetSeconds = Int32(TimeZone.current.secondsFromGMT())
        log.info("CURRENT_TIME_REQUEST #\(referenceID, privacy: .public) — réponse ts=\(garminTimestamp, privacy: .public) tz=\(tzOffsetSeconds, privacy: .public)s")

        // HYPOTHÈSE : les champs de transition DST (nextTransitionEnds/Starts)
        // sont renvoyés à zéro plutôt que calculés (comme le fait déjà le pont
        // quand `ZoneRules.nextTransition` échoue) — non vérifié que la Venu 2
        // s'en accommode aussi bien qu'avec des valeurs réelles.
        var writer = GarminByteWriter()
        writer.writeUInt16LE(MessageType.currentTimeRequest)
        writer.writeUInt8(0) // Status.ACK — cette trame EST l'accusé (statusMessage=nil côté pont)
        writer.writeUInt32LE(referenceID)
        writer.writeUInt32LE(garminTimestamp)
        writer.writeInt32LE(tzOffsetSeconds)
        writer.writeUInt32LE(0) // nextTransitionEndsGarminTs
        writer.writeUInt32LE(0) // nextTransitionStartsGarminTs
        send(GfdiFrame.build(messageType: MessageType.response, payload: writer.data), taskName: "current time reply")
    }

    // MARK: - SYNCHRONIZATION (5037) / FILTER (5007)

    private func handleSynchronization(_ payload: Data) {
        var reader = GarminByteReader(payload)
        let type = reader.readUInt8() ?? 0
        let size = Int(reader.readUInt8() ?? 0)
        var bitmask: UInt64 = 0
        if size == 8 {
            bitmask = reader.readUInt64LE() ?? 0
        } else if size == 4 {
            bitmask = UInt64(reader.readUInt32LE() ?? 0)
        }
        log.info("SYNCHRONIZATION reçu : type=\(type, privacy: .public) bitmask=0x\(String(bitmask, radix: 16), privacy: .public)")

        // Accusé générique — SynchronizationMessage.statusMessage côté pont est
        // le GenericStatusMessage(ACK) par défaut.
        send(GfdiAck.statusFrame(for: MessageType.synchronization, status: .ack), taskName: "synchronization ack")

        // shouldProceed() côté pont : bits WORKOUTS(3), ACTIVITIES(5),
        // ACTIVITY_SUMMARY(21) ou SLEEP(26) du bitmask FileType imbriqué.
        let relevantBits: [Int] = [3, 5, 21, 26]
        let shouldProceed = relevantBits.contains { (bitmask & (1 << $0)) != 0 }
        guard shouldProceed else { return }

        // FilterMessage : trame FILTER(5007) directe (pas enveloppée en
        // RESPONSE), payload = FilterType.UNK_3.
        send(GfdiFrame.build(messageType: MessageType.filter, payload: Data([3])), taskName: "filter")
    }

    private func handleFilterStatus(_ rest: Data) {
        guard let status = rest.first, status == 0 else { return } // Status.ACK
        log.info("FILTER accusé par la montre — rafraîchissement du manifeste directory")
        requestDirectoryListing()
    }

    /// Réponse à `SET_FILE_FLAG` — porté de `SetFileFlagsStatusMessage.parseIncoming`
    /// (messages/status/GFDIStatusMessage.java, AGPL-3.0). Purement pour le
    /// journal/diagnostic : aucune action supplémentaire n'en dépend, l'état du
    /// Spool (`archived`) est déjà fixé à l'émission par
    /// `archivePendingDeliveries` (cf. son commentaire).
    private func handleSetFileFlagStatus(_ rest: Data) {
        var reader = GarminByteReader(rest)
        guard let status = reader.readUInt8() else { return }
        guard status == 0 else { // Status.ACK
            log.warning("SET_FILE_FLAG refusé par la montre : status=\(status, privacy: .public)")
            return
        }
        guard let flagsStatus = reader.readUInt8(),
              let fileIdentifierRaw = reader.readUInt16LE(),
              let flagsBitmask = reader.readUInt8()
        else { return }
        // HYPOTHÈSE reprise telle quelle du pont (commentaire "TODO: check if
        // always or only on archival" sur `SetFileFlagsStatusMessage` upstream,
        // jamais résolu même côté Java) : +1 sur l'identifiant renvoyé. Non
        // vérifié contre le matériel — purement informatif ici.
        let fileIdentifier = Int(fileIdentifierRaw) + 1
        log.info("""
            SET_FILE_FLAG accusé : flagsStatus=\(flagsStatus == 0 ? "APPLIED" : "ERROR", privacy: .public) \
            fileIdentifier=\(fileIdentifier, privacy: .public) flags=0x\(String(flagsBitmask, radix: 16), privacy: .public)
            """)
    }

    // MARK: - Téléchargement (DOWNLOAD_REQUEST/FILE_TRANSFER_DATA) — manifeste ou fichier

    /// Demande le manifeste directory (fichier virtuel d'index 0).
    ///
    /// Slot de transfert UNIQUE : ne jamais écraser un transfert en cours. La
    /// montre re-liste d'elle-même en plein milieu d'une traversée (FILTER) ;
    /// sans ce garde, on remplaçait `downloadTarget` par `.directory` par-dessus
    /// un download de fichier déjà en vol → deux `DOWNLOAD_REQUEST` concurrents,
    /// la montre en refusait un en `downloadStatus=3`, et comme `downloadTarget`
    /// valait alors `.directory`, l'échec basculait l'état en `.failed` (« Échec »
    /// ~1 s après le listing). On diffère plutôt la re-list (cf.
    /// `pendingDirectoryRelisting`, rejouée à la libération du slot).
    func requestDirectoryListing() {
        guard currentDownload == nil, downloadTarget == nil else {
            pendingDirectoryRelisting = true
            log.info("Re-list directory différée : un transfert occupe déjà le slot unique")
            return
        }
        pendingDirectoryRelisting = false
        downloadTarget = .directory
        currentDownload = nil
        downloadingFileIndex = nil
        state = .listingDirectory
        sendDownloadRequest(fileIndex: 0)
        log.info("DOWNLOAD_REQUEST envoyé pour le manifeste directory (index 0)")
    }

    /// Télécharge le contenu d'un fichier listé par le manifeste directory —
    /// généralisation de `requestDirectoryListing()` à un index quelconque.
    /// Déclenché manuellement (cf. `BLEDiagnosticView`) : pas de traversée
    /// automatique, un seul fichier à la fois (le pont vendoré ne tient lui
    /// aussi qu'un seul slot de transfert, cf. `FileTransferHandler.Download`).
    func downloadFile(_ entry: GarminDirectoryEntry) {
        guard currentDownload == nil else {
            log.warning("downloadFile(\(entry.fileIndex, privacy: .public)) ignoré : un téléchargement est déjà en cours")
            return
        }
        guard !entry.isDirectory else {
            log.warning("downloadFile(\(entry.fileIndex, privacy: .public)) ignoré : entrée DIRECTORY, pas un fichier de contenu")
            return
        }
        downloadTarget = .file(entry)
        downloadingFileIndex = entry.fileIndex
        sendDownloadRequest(fileIndex: entry.fileIndex)
        log.info("DOWNLOAD_REQUEST envoyé pour le fichier index=\(entry.fileIndex, privacy: .public) type=\(entry.typeName, privacy: .public)")
    }

    // MARK: - Traversée de synchronisation (récent→ancien, un fichier à la fois)

    /// Calcule les fichiers dus (diff manifeste vs Spool, via `SyncPlanner`) et
    /// démarre leur téléchargement, un par un, récent→ancien — porté de
    /// `processDownloadQueue`/`absorbListing`/`nextStillWanted` côté pont
    /// (session/GarminSession.java, AGPL-3.0), simplifié à un seul manifeste
    /// déjà reçu (`files`) plutôt qu'un flux ré-absorbé en cours de lien (cf.
    /// commentaire d'en-tête de fichier).
    ///
    /// **Automatique depuis le pivot 2026-09-22** : déclenchée par
    /// `finishDownload()` dès que le manifeste directory est reçu (cf. en-tête
    /// de fichier) — plus de sélection manuelle fichier-par-fichier. Reste
    /// appelable directement (bouton de secours `BLEDiagnosticView`).
    /// N'interrompt jamais un téléchargement déjà en cours (`downloadFile`
    /// manuel ou traversée précédente) : un seul slot de transfert, comme le
    /// pont — c'est aussi ce qui protège contre une double exécution si
    /// `finishDownload()` et un tap manuel se chevauchaient.
    func syncNewFiles() {
        guard let spoolStore else {
            log.error("syncNewFiles ignoré : SpoolStore indisponible")
            return
        }
        guard currentDownload == nil, downloadTarget == nil else {
            log.warning("syncNewFiles ignoré : un téléchargement est déjà en cours")
            return
        }
        // Repousse d'abord ce qui est déjà acquis mais pas encore livré (upload
        // resté en échec/dormant lors d'une session précédente) — avant même de
        // calculer la nouvelle file de téléchargement, pour ne pas laisser
        // traîner du travail d'upload en attente pendant toute la traversée.
        uploadPendingAcquisitions()
        let alreadyAcquired = Set(spoolStore.entries.keys)
        downloadQueue = SyncPlanner.filesDue(from: files, alreadyAcquired: alreadyAcquired)
        log.info("syncNewFiles : \(self.downloadQueue.count, privacy: .public) fichier(s) dû(s) sur \(self.files.count, privacy: .public) listé(s), récent→ancien")
        advanceDownloadQueue()
    }

    /// Démarre le prochain téléchargement de la file, ou publie `.done` si elle
    /// est épuisée — `nextStillWanted`/`finishSync` simplifiés (pas de second
    /// listing à réabsorber ici, cf. `syncNewFiles`). Appelée à nouveau depuis
    /// `finishDownload`/`failCurrentDownload` tant que la traversée est en
    /// cours (`syncState == .downloading`), jamais pour un `downloadFile` manuel
    /// isolé déclenché hors traversée.
    private func advanceDownloadQueue() {
        guard !downloadQueue.isEmpty else {
            syncState = .done
            log.info("syncNewFiles terminé : file de traversée épuisée")
            // Slot désormais libre : rejouer une re-list différée (FILTER reçu
            // pendant qu'un transfert l'occupait, cf. `requestDirectoryListing`).
            // `requestDirectoryListing` remet le drapeau à false → pas de boucle.
            if pendingDirectoryRelisting {
                log.info("Slot libéré — rejeu de la re-list directory différée")
                requestDirectoryListing()
            }
            return
        }
        let next = downloadQueue.removeFirst()
        syncState = .downloading(fileIndex: next.fileIndex)
        downloadFile(next)
    }

    // MARK: - Archivage différé (SET_FILE_FLAG / ARCHIVE) — après accusé Pulse

    /// Un seul flag posé ici : ARCHIVE (bit 0x10). DELETE (bit 0x20,
    /// `SetFileFlagsMessage.FileFlags` côté pont) n'est pas porté — hors
    /// périmètre, jamais utilisé par ce collecteur.
    private static let archiveFlagBit: UInt8 = 0x10

    /// Payload pur de `SET_FILE_FLAG(ARCHIVE)` — `UInt16LE(fileIndex)` +
    /// `UInt8(bitvector)`, porté octet-pour-octet de
    /// `SetFileFlagsMessage.generateOutgoing` (messages/SetFileFlagsMessage.java,
    /// AGPL-3.0). Statique et sans dépendance à l'instance, comme
    /// `ourCapabilitiesBitfield()`, pour rester testable sans CommunicatorV2.
    static func setFileFlagsArchivePayload(fileIndex: Int) -> Data {
        var writer = GarminByteWriter()
        writer.writeUInt16LE(UInt16(fileIndex))
        writer.writeUInt8(archiveFlagBit)
        return writer.data
    }

    /// Émet `SET_FILE_FLAG(ARCHIVE)` (message 5008) pour un fichier — porté de
    /// `archiveOnWatch` côté pont (session/GarminSession.java, AGPL-3.0). Trame
    /// directe (pas enveloppée en RESPONSE/5000), comme
    /// `SetFileFlagsMessage.generateOutgoing` qui écrit son propre type en
    /// sortie. Jamais appelée pour une entrée DIRECTORY : les appelants de
    /// cette méthode (`archivePendingDeliveries`) ne connaissent que des
    /// `WatchFileID` qui, par construction du Spool, ne sont jamais des
    /// entrées DIRECTORY (cf. commentaire de `archivePendingDeliveries`).
    private func archiveFileOnWatch(fileIndex: Int) {
        let payload = Self.setFileFlagsArchivePayload(fileIndex: fileIndex)
        send(GfdiFrame.build(messageType: MessageType.setFileFlag, payload: payload), taskName: "archive file \(fileIndex)")
        log.info("SET_FILE_FLAG(ARCHIVE) envoyé pour fileIndex=\(fileIndex, privacy: .public)")
    }

    /// Archive sur la montre tout fichier `delivered`-non-`archived` du Spool —
    /// à appeler **après** que `SpoolStore.markDelivered(_:)` a fait passer un
    /// fichier à `delivered` (2xx de Pulse), jamais avant (contrat d'ingestion
    /// §7 : « rien n'est archivé sur la montre ni purgé du téléphone avant le
    /// 2xx »). Câblée depuis le pivot 2026-09-22 (autorisation réseau explicite
    /// de l'utilisateur) : `handleUploadOutcome` ci-dessus l'appelle juste après
    /// chaque `markDelivered` réussi.
    ///
    /// Marque `archived` dès l'émission plutôt qu'après un accusé de la montre
    /// — fidèle à `archiveOnWatch` côté pont, qui ne fait pas non plus
    /// dépendre son état d'un accusé (la réponse SET_FILE_FLAG est décodée par
    /// `handleSetFileFlagStatus`, mais purement pour le journal/diagnostic).
    func archivePendingDeliveries() {
        guard let spoolStore else { return }
        for entry in spoolStore.pendingArchive() {
            // Garde défensive, fidèle au `if DIRECTORY return` explicite
            // d'`archiveOnWatch` côté pont : ne devrait jamais se déclencher
            // ici, puisque seul `finishDownload().file` écrit dans le Spool
            // (jamais le manifeste directory lui-même, dataType=subType=0).
            guard entry.id.fileType != 0 else {
                log.warning("archivePendingDeliveries ignore une entrée DIRECTORY inattendue : \(entry.relativePath, privacy: .public)")
                continue
            }
            archiveFileOnWatch(fileIndex: entry.id.index)
            spoolStore.markArchived(entry.id)
        }
    }

    // MARK: - Upload Pulse (après acquisition dans le Spool)

    /// Pousse un .fit du Spool vers Pulse. Complétion ramenée sur le main (les
    /// callbacks URLSession arrivent sur une file de fond ; tout l'état publié et
    /// le Spool se manipulent sur le main, comme les callbacks BLE).
    private func uploadSpoolEntry(_ entry: SpoolEntry) {
        guard let uploader, let spoolStore else { return }
        let fileURL = spoolStore.fileURL(for: entry)
        let filename = entry.id.name
        uploader.upload(fileURL: fileURL, watchFilename: filename) { [weak self] outcome in
            DispatchQueue.main.async { self?.handleUploadOutcome(outcome, for: entry.id) }
        }
    }

    private func handleUploadOutcome(_ outcome: PulseUploadOutcome, for id: WatchFileID) {
        switch outcome {
        case .delivered:
            spoolStore?.markDelivered(id)
            deliveredFileIndexes.insert(id.index)
            archivePendingDeliveries()
        case .keepConfigError:
            log.error("Upload Pulse: token/URL absent ou invalide — fichier gardé, pas de retry auto (renseigner les réglages)")
        case .keepRetryLater:
            log.warning("Upload Pulse: source active ≠ phone (403) — gardé, réessai prochaine sync")
        case .keepRetry:
            log.warning("Upload Pulse: indisponible / erreur réseau — gardé, réessai prochaine sync")
        case .quarantine:
            log.error("Upload Pulse: fichier rejeté (400/413/415/422) — gardé en spool, à investiguer")
        }
    }

    /// Repousse tout ce qui est déjà `acquired` mais pas encore `delivered` :
    /// fichiers téléchargés lors de sessions précédentes quand l'upload était
    /// dormant, ou échecs d'upload passés. Idempotent (markDelivered l'est).
    private func uploadPendingAcquisitions() {
        guard let spoolStore else { return }
        for entry in spoolStore.entries.values where entry.state == .acquired {
            uploadSpoolEntry(entry)
        }
    }

    /// Même format de requête pour le manifeste (index 0, hardcodé par
    /// `requestDirectoryListing`) et un fichier de contenu quelconque.
    private func sendDownloadRequest(fileIndex: Int) {
        var writer = GarminByteWriter()
        writer.writeUInt16LE(UInt16(fileIndex))
        writer.writeUInt32LE(0) // dataOffset
        writer.writeUInt8(1) // REQUEST_TYPE.NEW
        writer.writeUInt16LE(0) // crcSeed
        writer.writeUInt32LE(0) // dataSize (inconnue, la montre répond avec la vraie taille)
        send(GfdiFrame.build(messageType: MessageType.downloadRequest, payload: writer.data), taskName: "download request (index \(fileIndex))")
    }

    private func handleDownloadRequestStatus(_ rest: Data) {
        var reader = GarminByteReader(rest)
        guard let status = reader.readUInt8() else { return }
        guard status == 0 else {
            log.error("DOWNLOAD_REQUEST refusé : status=\(status, privacy: .public)")
            failCurrentDownload("DOWNLOAD_REQUEST status=\(status)")
            return
        }
        guard let downloadStatus = reader.readUInt8(), let maxFileSize = reader.readUInt32LE() else { return }
        guard downloadStatus == 0 else { // DownloadStatus.OK
            log.error("DOWNLOAD_REQUEST refusé par la montre : downloadStatus=\(downloadStatus, privacy: .public)")
            failCurrentDownload("downloadStatus=\(downloadStatus)")
            return
        }
        switch downloadTarget {
        case .directory:
            log.info("Manifeste directory annoncé : \(maxFileSize, privacy: .public) o")
        case .file(let entry):
            log.info("Fichier index=\(entry.fileIndex, privacy: .public) annoncé : \(maxFileSize, privacy: .public) o")
        case nil:
            log.warning("DOWNLOAD_REQUEST_STATUS reçu sans cible connue — ignoré")
            return
        }

        // Dimensionne le reassembler courant quelle que soit la cible (manifeste
        // ou fichier) : `handleFileTransferData`/`finishDownload` ne distinguent
        // ensuite que par `downloadTarget`.
        currentDownload = FileTransferReassembler(expectedSize: Int(maxFileSize))
        if maxFileSize == 0 {
            // Rien à réassembler (manifeste vide ou fichier de taille nulle).
            finishDownload()
        }
    }

    /// DOWNLOAD_REQUEST refusé par la montre : abandonne la cible en cours.
    /// L'état `.failed` de la poignée de main n'est publié que pour le manifeste
    /// directory — l'échec d'un téléchargement de fichier individuel ne doit pas
    /// être lu comme un échec du lien GFDI lui-même.
    private func failCurrentDownload(_ reason: String) {
        let failedTarget = downloadTarget
        if case .directory = downloadTarget {
            state = .failed(reason)
        }
        currentDownload = nil
        downloadTarget = nil
        downloadingFileIndex = nil

        // Résilience de traversée : un fichier individuel refusé par la montre
        // ne bloque pas `syncNewFiles()` — enchaîne sur le suivant de la file,
        // comme le fait implicitement le pont (`processDownloadQueue` est
        // réinvoqué à chaque message reçu, donc un échec silencieux n'arrête
        // jamais la traversée). Ne concerne jamais un `downloadFile` manuel
        // isolé (hors traversée, `syncState == .idle`).
        if case .file = failedTarget, case .downloading = syncState {
            log.warning("Téléchargement échoué pendant syncNewFiles (\(reason, privacy: .public)) — passage au fichier suivant")
            advanceDownloadQueue()
        }
    }

    /// FILE_TRANSFER_DATA (5004) : réassemblage + reprise de fragment
    /// perdu/dupliqué. L'ack GFDI (RESPONSE/5000 nommant l'offset voulu) est
    /// toute la fiabilité de ce transport (MLR désactivé, cf. `CommunicatorV2`) —
    /// voir `FileTransferReassembler` pour l'algorithme, porté de
    /// `GarminSession.answeredAFragmentOutOfStep`/`trackWhereTheTransferIs` côté
    /// pont (session/GarminSession.java, AGPL-3.0).
    private func handleFileTransferData(_ payload: Data) {
        var reader = GarminByteReader(payload)
        guard reader.readUInt8() != nil, // flags, non utilisé
              let crc = reader.readUInt16LE(),
              let dataOffset = reader.readUInt32LE()
        else { return }
        let chunk = reader.readRemainingBytes()

        guard var download = currentDownload else {
            // Pas de download en cours : fragment traînard — la fin d'un fichier
            // déjà tenu, renvoyé car notre ack fut tardif (branche
            // NOTHING_TO_APPEND_TO de `answeredAFragmentOutOfStep` côté pont). On
            // accuse SON PROPRE offset ; ça ne compte jamais comme un progrès, et
            // rien n'est jamais réappliqué puisqu'il n'y a pas de buffer où le mettre.
            let ownOffset = dataOffset + UInt32(chunk.count)
            log.debug("Fragment traînard (offset=\(dataOffset, privacy: .public), +\(chunk.count, privacy: .public) o) — ack \(ownOffset, privacy: .public) sans effet")
            sendFileTransferAck(offset: ownOffset)
            return
        }

        let action = download.receive(dataOffset: dataOffset, crc: crc, chunk: chunk)
        currentDownload = download

        switch action {
        case .appended(let ackOffset, let complete):
            log.debug("Fragment reçu : +\(chunk.count, privacy: .public) o, cumulé \(ackOffset, privacy: .public)")
            sendFileTransferAck(offset: ackOffset)
            if complete {
                finishDownload()
            }
        case .reAck(let offset):
            log.debug("Fragment hors séquence ou dupliqué (offset reçu=\(dataOffset, privacy: .public)) — ré-accusé \(offset, privacy: .public)")
            sendFileTransferAck(offset: offset)
        }
    }

    private func sendFileTransferAck(offset: UInt32) {
        var writer = GarminByteWriter()
        writer.writeUInt16LE(MessageType.fileTransferData)
        writer.writeUInt8(0) // Status.ACK
        writer.writeUInt8(0) // TransferStatus.OK — jamais RESEND, cf. FileTransferReassembler
        writer.writeUInt32LE(offset)
        send(GfdiFrame.build(messageType: MessageType.response, payload: writer.data), taskName: "file transfer data ack")
    }

    /// Le download en cours vient de se remplir : bascule sur la cible pour
    /// décider du sort des octets (manifeste → parse + publie ; fichier → Spool).
    /// Relâche systématiquement `currentDownload`/`downloadTarget` en premier,
    /// pour que le prochain fragment (traînard éventuel) tombe dans la branche
    /// « pas de download en cours » de `handleFileTransferData`.
    private func finishDownload() {
        guard let download = currentDownload, let target = downloadTarget else {
            currentDownload = nil
            downloadTarget = nil
            downloadingFileIndex = nil
            return
        }
        let buffer = download.buffer
        currentDownload = nil
        downloadTarget = nil
        downloadingFileIndex = nil

        switch target {
        case .directory:
            let entries = GarminDirectoryParser.parse(buffer)
            files = entries
            state = .listed
            log.info("Manifeste directory complet : \(buffer.count, privacy: .public) o, \(entries.count, privacy: .public) entrée(s)")
            for entry in entries {
                log.debug("  entrée directory : index=\(entry.fileIndex, privacy: .public) type=\(entry.typeName, privacy: .public) taille=\(entry.sizeBytes, privacy: .public) o date=\(entry.date?.description ?? "—", privacy: .public)")
            }
            // Pivot 2026-09-22 (demande utilisateur) : traversée automatique à la
            // connexion, plus de sélection manuelle fichier-par-fichier.
            // `syncNewFiles()` se garde lui-même contre une double exécution
            // (guard `currentDownload == nil, downloadTarget == nil`), donc rien
            // à ajouter ici pour éviter un chevauchement avec un `downloadFile`
            // manuel ou une traversée déjà en cours.
            syncNewFiles()

        case .file(let entry):
            log.info("Fichier index=\(entry.fileIndex, privacy: .public) type=\(entry.typeName, privacy: .public) complet : \(buffer.count, privacy: .public) o")
            // Poursuit la file de `syncNewFiles()` — mais SEULEMENT si c'est
            // bien la traversée qui a lancé ce téléchargement (`syncState ==
            // .downloading`) : un `downloadFile` manuel isolé
            // (`BLEDiagnosticView`, hors traversée) ne doit jamais faire
            // apparaître un état `.done` inattendu.
            defer {
                if case .downloading = syncState {
                    advanceDownloadQueue()
                }
            }
            guard let spoolStore else {
                log.error("SpoolStore indisponible — octets reçus (\(buffer.count, privacy: .public) o) mais pas écrits sur disque")
                return
            }
            let (id, relativePath) = SpoolStore.identity(for: entry)
            do {
                let saved = try spoolStore.recordAcquired(id, relativePath: relativePath, data: buffer)
                acquiredFileIndexes.insert(entry.fileIndex)
                log.info("Fichier acquis dans le spool : \(relativePath, privacy: .public)")
                uploadSpoolEntry(saved)
            } catch {
                log.error("Échec d'écriture dans le spool (\(relativePath, privacy: .public)) : \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - PROTOBUF_REQUEST (5043) — accusés codés en dur, pas de swift-protobuf

    /// Champs de service `Smart` (gdi_smart_proto.proto) que Gadgetbridge sait
    /// interpréter — porté de `ProtobufAck.KNOWN_SERVICES`. Le champ 42
    /// (`GdiSettingsService`) y figure pour fidélité au pont (accusé KEPT), mais
    /// n'a délibérément aucune réponse canée : il ne répond jamais
    /// applicativement sur Venu 2 fw 19.05 (cf. CLAUDE.md) et `responseFor`
    /// upstream n'a pas de cas pour lui non plus.
    static let knownProtobufServices: Set<Int> = [1, 2, 3, 4, 7, 8, 12, 13, 16, 22, 27, 39, 42, 43, 49]

    private func handleProtobufRequest(_ payload: Data) {
        var reader = GarminByteReader(payload)
        guard let requestId = reader.readUInt16LE(),
              let dataOffset = reader.readUInt32LE(),
              let totalLength = reader.readUInt32LE(),
              let dataLength = reader.readUInt32LE()
        else { return }
        let messageBytes = reader.readBytes(Int(dataLength)) ?? Data()
        let isComplete = dataOffset == 0 && totalLength == dataLength
        let service = Self.protobufFieldNumber(Self.firstVarint(messageBytes))

        log.info("""
            PROTOBUF_REQUEST #\(requestId, privacy: .public) offset=\(dataOffset, privacy: .public) \
            total=\(totalLength, privacy: .public) service=\(service, privacy: .public) \
            payload=\(messageBytes.gfdiHexDump, privacy: .public)
            """)

        guard isComplete else {
            // Chunk intermédiaire : KEPT/NO_ERROR sans réponse, comme
            // ProtobufMessage.statusMessage par défaut quand !isComplete.
            var writer = GarminByteWriter()
            writer.writeUInt16LE(MessageType.protobufRequest)
            writer.writeUInt8(0) // Status.ACK
            writer.writeUInt16LE(requestId)
            writer.writeUInt32LE(dataOffset)
            writer.writeUInt8(0) // ProtobufChunkStatus.KEPT
            writer.writeUInt8(0) // ProtobufStatusCode.NO_ERROR
            send(GfdiFrame.build(messageType: MessageType.response, payload: writer.data), taskName: "protobuf chunk ack")
            return
        }

        let known = Self.knownProtobufServices.contains(service)
        var ackWriter = GarminByteWriter()
        ackWriter.writeUInt16LE(MessageType.protobufRequest)
        ackWriter.writeUInt8(0) // Status.ACK
        ackWriter.writeUInt16LE(requestId)
        ackWriter.writeUInt32LE(0) // dataOffset
        ackWriter.writeUInt8(known ? 0 : 1) // KEPT / DISCARDED
        ackWriter.writeUInt8(known ? 0 : 100) // NO_ERROR / UNKNOWN_REQUEST_ID
        let ackFrame = GfdiFrame.build(messageType: MessageType.response, payload: ackWriter.data)
        log.info("Protobuf #\(requestId, privacy: .public) accusé \(known ? "KEPT" : "DISCARDED", privacy: .public) : \(ackFrame.gfdiHexDump, privacy: .public)")
        send(ackFrame, taskName: "protobuf ack")

        guard known, let response = Self.cannedProtobufResponse(service: service, inner: Self.protobufInnerField(messageBytes)) else {
            return
        }
        var responseWriter = GarminByteWriter()
        responseWriter.writeUInt16LE(requestId)
        responseWriter.writeUInt32LE(0) // dataOffset
        responseWriter.writeUInt32LE(UInt32(response.count)) // totalProtobufLength
        responseWriter.writeUInt32LE(UInt32(response.count)) // protobufDataLength
        responseWriter.writeBytes(response)
        let responseFrame = GfdiFrame.build(messageType: MessageType.protobufResponse, payload: responseWriter.data)
        log.info("Protobuf #\(requestId, privacy: .public) réponse canée (\(response.count, privacy: .public) o) : \(responseFrame.gfdiHexDump, privacy: .public)")
        send(responseFrame, taskName: "protobuf response")
    }

    private func handleProtobufStatus(_ rest: Data, originalType: UInt16) {
        guard let status = rest.first else { return }
        log.debug("Accusé PROTOBUF reçu (type=\(originalType, privacy: .public)) status=\(status, privacy: .public)")
    }

    /// Réponses `Smart` canées, hexdump-pour-hexdump identiques à
    /// `ProtobufAck.RESPONSES` côté pont — chaque payload y est documenté champ
    /// par champ à partir du `.proto` Gadgetbridge.
    static func cannedProtobufResponse(service: Int, inner: Int) -> Data? {
        switch service {
        case 1: return inner == 1 ? Data([0x0A, 0x04, 0x12, 0x02, 0x08, 0x01]) : nil
        case 13:
            switch inner {
            case 3: return Data([0x6A, 0x04, 0x22, 0x02, 0x08, 0x02])
            case 5: return Data([0x6A, 0x04, 0x32, 0x02, 0x08, 0x01])
            default: return nil
            }
        case 16: return inner == 4 ? Data([0x82, 0x01, 0x04, 0x2A, 0x02, 0x08, 0x00]) : nil
        default: return nil
        }
    }

    /// Premier varint (clé protobuf) d'un payload `Smart` — champ de service.
    static func firstVarint(_ data: Data) -> UInt64 {
        var position = 0
        return varint(data, at: &position)
    }

    static func protobufFieldNumber(_ key: UInt64) -> Int {
        Int(key >> 3)
    }

    /// Numéro de champ du sous-message à l'intérieur du service — ce qui
    /// distingue par ex. la localisation demandée de sa mise à jour, côté
    /// service `core`. Porté de `ProtobufAck.innerField`.
    static func protobufInnerField(_ data: Data) -> Int {
        var position = 0
        _ = varint(data, at: &position) // clé du service
        _ = varint(data, at: &position) // longueur du service
        guard position < data.count else { return -1 }
        return protobufFieldNumber(varint(data, at: &position))
    }

    static func varint(_ data: Data, at position: inout Int) -> UInt64 {
        let bytes = [UInt8](data)
        var value: UInt64 = 0
        var shift: UInt64 = 0
        while position < bytes.count {
            let byte = bytes[position]
            position += 1
            value |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { break }
            shift += 7
        }
        return value
    }

    // MARK: - Envoi

    private func send(_ frame: Data, taskName: String) {
        communicator.sendGfdiMessage(frame, taskName: taskName)
    }
}
