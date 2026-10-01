//
//  WatchAlarmUploadTests.swift
//  allTests
//
//  Généralisation du canal d'upload de réglages (`GarminSession.swift`) : le
//  poids avait jusqu'ici le seul flux montant (téléphone → montre, upload FIT
//  Settings). Cette tâche extrait une primitive générique
//  (`GarminSession.uploadSettingsFile`) et ajoute un second appelant
//  (`writeAlarms`, planning d'alarmes), les deux partageant un slot de
//  transfert UNIQUE.
//
//  Calqué sur `TransferResilienceTests.swift` : communicator GFDI FACTICE
//  (jamais de vrai CoreBluetooth/BLE, règle immuable CLAUDE.md), propre copie
//  ici (les types du fichier voisin sont `private`, donc invisibles d'ici).
//
//  Par construction du contrat de parallélisation (cf. `FitSettingsWriter.swift`,
//  dont le corps réel de `alarmSettings` est un STUB tenu par un autre agent en
//  même temps que cette tâche) : les tests qui exercent la primitive générique
//  `uploadSettingsFile` lui passent un `Data` synthétique NON VIDE fourni ici,
//  jamais le résultat de `FitSettingsWriter.alarmSettings` — on ne dépend
//  jamais de ses octets, seulement du FLUX protocole (CreateFile → chunks →
//  accusé). `uploadSettingsFile` n'est délibérément pas `private` (même raison
//  que `ourCapabilitiesBitfield()`/`setFileFlagsArchivePayload` dans
//  `GarminSession.swift` : rester testable sans communicator réel), les
//  appelants de production restant `writeWeight`/`writeAlarms`.
//

import Testing
import Foundation
@testable import all

// MARK: - Construction de trames (miroir des formats privés de GarminSession.swift)

private enum Wire {
    static let response: UInt16 = 5000
    static let downloadRequest: UInt16 = 5002
    static let uploadRequest: UInt16 = 5003
    static let fileTransferData: UInt16 = 5004
    static let createFile: UInt16 = 5005
    static let configuration: UInt16 = 5050
}

/// Octets synthétiques déterministes — jamais un vrai `.fit`, jamais parsés
/// (le collecteur ne parse pas le contenu, cf. CLAUDE.md) : juste de quoi
/// vérifier qu'un découpage/upload transporte exactement ce qui lui est passé.
private func syntheticContent(_ count: Int, seed: UInt8 = 0x11) -> Data {
    Data((0..<count).map { UInt8((Int(seed) + $0) % 256) })
}

/// Payload RESPONSE(5000) « DOWNLOAD_REQUEST_STATUS » — miroir de
/// `handleDownloadRequestStatus`. Sert uniquement à finir, avec un manifeste
/// VIDE, la poignée de main déclenchée par CONFIGURATION (cf.
/// `completeHandshakeWithEmptyManifest`) : ça libère le slot de transfert pour
/// que `writeWeight`/`writeAlarms` puissent démarrer tout de suite.
private func downloadRequestStatusPayload(maxFileSize: UInt32, status: UInt8 = 0, downloadStatus: UInt8 = 0) -> Data {
    var writer = GarminByteWriter()
    writer.writeUInt16LE(Wire.downloadRequest)
    writer.writeUInt8(status)
    writer.writeUInt8(downloadStatus)
    writer.writeUInt32LE(maxFileSize)
    return writer.data
}

/// Payload RESPONSE(5000) « CREATE_FILE status » — miroir de
/// `handleCreateFileStatus` (status générique, createStatus, fileIndex ; les
/// champs dataType/subType/fileNumber qui suivent côté montre ne sont pas
/// exploités par `GarminSession`, donc omis ici).
private func createFileStatusPayload(fileIndex: UInt16, status: UInt8 = 0, createStatus: UInt8 = 0) -> Data {
    var writer = GarminByteWriter()
    writer.writeUInt16LE(Wire.createFile)
    writer.writeUInt8(status)
    writer.writeUInt8(createStatus)
    writer.writeUInt16LE(fileIndex)
    return writer.data
}

/// Payload RESPONSE(5000) « UPLOAD_REQUEST status » — miroir de
/// `handleUploadRequestStatus`.
private func uploadRequestStatusPayload(status: UInt8 = 0, uploadStatus: UInt8 = 0) -> Data {
    var writer = GarminByteWriter()
    writer.writeUInt16LE(Wire.uploadRequest)
    writer.writeUInt8(status)
    writer.writeUInt8(uploadStatus)
    return writer.data
}

/// Payload RESPONSE(5000) « FILE_TRANSFER_DATA status » (accusé de NOTRE
/// morceau d'upload) — miroir de `handleUploadDataStatus`.
private func uploadDataStatusPayload(status: UInt8 = 0, transferStatus: UInt8 = 0) -> Data {
    var writer = GarminByteWriter()
    writer.writeUInt16LE(Wire.fileTransferData)
    writer.writeUInt8(status)
    writer.writeUInt8(transferStatus)
    return writer.data
}

/// Payload CONFIGURATION (5050, trame directe) minimal : zéro octet de
/// capacités montre — suffisant pour déclencher `completeInitializationIfNeeded`
/// côté `GarminSession` (`initialized = true`, demande du manifeste directory).
private let emptyConfigurationPayload = Data([0])

// MARK: - Lecture des trames sortantes capturées

private struct CreateFileFrame: Equatable {
    let fileSize: UInt32
    let dataType: UInt8
    let subType: UInt8
}

/// Décode une trame CREATE_FILE(5005) sortante (trame directe, pas enveloppée
/// en RESPONSE) — miroir de `uploadSettingsFile`.
private func parseCreateFile(_ data: Data) -> CreateFileFrame? {
    guard let frame = try? GfdiFrame.parse(data), frame.messageType == Wire.createFile else { return nil }
    var reader = GarminByteReader(frame.payload)
    guard let fileSize = reader.readUInt32LE(), let dataType = reader.readUInt8(), let subType = reader.readUInt8() else { return nil }
    return CreateFileFrame(fileSize: fileSize, dataType: dataType, subType: subType)
}

private struct UploadRequestFrame: Equatable {
    let fileIndex: UInt16
    let size: UInt32
}

/// Décode une trame UPLOAD_REQUEST(5003) sortante (trame directe) — miroir de
/// `handleCreateFileStatus`.
private func parseUploadRequest(_ data: Data) -> UploadRequestFrame? {
    guard let frame = try? GfdiFrame.parse(data), frame.messageType == Wire.uploadRequest else { return nil }
    var reader = GarminByteReader(frame.payload)
    guard let fileIndex = reader.readUInt16LE(), let size = reader.readUInt32LE() else { return nil }
    return UploadRequestFrame(fileIndex: fileIndex, size: size)
}

private struct FileTransferDataFrame: Equatable {
    let offset: UInt32
    let chunk: Data
}

/// Décode une trame FILE_TRANSFER_DATA(5004) sortante (trame directe, NOTRE
/// morceau d'upload — pas l'accusé d'un fragment de download) — miroir de
/// `sendNextSettingsChunk`.
private func parseFileTransferData(_ data: Data) -> FileTransferDataFrame? {
    guard let frame = try? GfdiFrame.parse(data), frame.messageType == Wire.fileTransferData else { return nil }
    var reader = GarminByteReader(frame.payload)
    guard reader.readUInt8() != nil, // flags
          reader.readUInt16LE() != nil, // CRC courante, non vérifiée ici
          let offset = reader.readUInt32LE()
    else { return nil }
    let chunk = reader.readRemainingBytes()
    return FileTransferDataFrame(offset: offset, chunk: chunk)
}

// MARK: - Communicator GFDI factice

/// Jamais de vrai CoreBluetooth/BLE en test (règle immuable CLAUDE.md). Capture
/// les trames telles que `GarminSession` les construit et permet de simuler une
/// trame entrante en appelant directement `onGfdiFrame` — copie locale du type
/// `private` de `TransferResilienceTests.swift` (invisible d'ici).
private final class FakeGfdiCommunicator: GfdiCommunicating {
    var onGfdiFrame: ((GfdiFrame) -> Void)?
    var onGfdiChannelReady: (() -> Void)?
    private(set) var sentFrames: [Data] = []

    func start() {}

    func sendGfdiMessage(_ frame: Data, taskName: String) {
        sentFrames.append(frame)
    }

    func deliver(messageType: UInt16, payload: Data) {
        onGfdiFrame?(GfdiFrame(messageType: messageType, payload: payload))
    }
}

private func makeSession() throws -> (session: GarminSession, fake: FakeGfdiCommunicator, store: SpoolStore, root: URL) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("bridge-connect-watch-alarm-upload-\(UUID().uuidString)", isDirectory: true)
    let store = try SpoolStore(root: root)
    let fake = FakeGfdiCommunicator()
    let session = GarminSession(communicator: fake, spoolStore: store, uploader: nil)
    return (session, fake, store, root)
}

/// Fait passer la session par une poignée de main CONFIGURATION minimale, puis
/// referme IMMÉDIATEMENT le listing directory automatique qu'elle déclenche
/// (manifeste vide) — nécessaire UNIQUEMENT pour les tests qui passent par
/// l'API publique `writeWeight`/`writeAlarms` (`tryStartPendingSettingsUpload`
/// exige `initialized == true` ET le slot de transfert libre). Les tests qui
/// pilotent `uploadSettingsFile` directement n'en ont pas besoin : cette
/// primitive ne garde ni sur l'un ni sur l'autre.
private func completeHandshakeWithEmptyManifest(_ session: GarminSession, _ fake: FakeGfdiCommunicator) {
    fake.deliver(messageType: Wire.configuration, payload: emptyConfigurationPayload)
    fake.deliver(messageType: Wire.response, payload: downloadRequestStatusPayload(maxFileSize: 0))
}

// MARK: - 1) La primitive générique `uploadSettingsFile`

struct SettingsUploadPrimitiveTests {
    /// CreateFile → CreateFileStatus(OK) → UploadRequest → UploadRequestStatus(OK)
    /// → FileTransferData (le `Data` synthétique EXACT fourni au test, pas un
    /// contenu FIT) → FileTransferDataStatus(OK) → `.sent`. Pilote
    /// `uploadSettingsFile` directement (pas `writeAlarms`), donc indépendant du
    /// stub `FitSettingsWriter.alarmSettings`.
    @Test func uploadSettingsFileSendsCreateFileThenChunksTheExactDataProvidedThenCompletes() throws {
        let (session, fake, _, root) = try makeSession()
        defer { try? FileManager.default.removeItem(at: root) }

        let synthetic = syntheticContent(40)
        session.uploadSettingsFile(synthetic, kind: .alarms)
        #expect(session.alarmWriteState == .uploading)

        let createFileSent = try #require(fake.sentFrames.last)
        let createFile = try #require(parseCreateFile(createFileSent))
        #expect(createFile.fileSize == 40)
        #expect(createFile.dataType == 128, "FileType SETTINGS dataType")
        #expect(createFile.subType == 2, "FileType SETTINGS subType")

        fake.deliver(messageType: Wire.response, payload: createFileStatusPayload(fileIndex: 9))
        let uploadRequestSent = try #require(fake.sentFrames.last)
        let uploadRequest = try #require(parseUploadRequest(uploadRequestSent))
        #expect(uploadRequest.fileIndex == 9)
        #expect(uploadRequest.size == 40)

        fake.deliver(messageType: Wire.response, payload: uploadRequestStatusPayload())
        let dataFrameSent = try #require(fake.sentFrames.last)
        let dataFrame = try #require(parseFileTransferData(dataFrameSent))
        #expect(dataFrame.offset == 0, "tient en un seul morceau (40 o < maxPacketSize-13 par défaut)")
        #expect(dataFrame.chunk == synthetic, "les octets transportés sont EXACTEMENT ceux fournis par l'appelant — la primitive ne connaît pas le contenu FIT")

        fake.deliver(messageType: Wire.response, payload: uploadDataStatusPayload())
        #expect(session.alarmWriteState == .sent)
    }

    /// CREATE_FILE refusé par la montre (`createStatus != 0`, CreateStatus pas
    /// OK) : `.refused`, pas `.failed` (distinction portée du poids).
    @Test func createFileRefusedByWatchSetsRefusedState() throws {
        let (session, fake, _, root) = try makeSession()
        defer { try? FileManager.default.removeItem(at: root) }

        session.uploadSettingsFile(syntheticContent(12), kind: .alarms)
        fake.deliver(messageType: Wire.response, payload: createFileStatusPayload(fileIndex: 0, createStatus: 3))

        #expect(session.alarmWriteState == .refused("createStatus=3"))
    }

    /// Accusé générique CREATE_FILE non-ACK (`status != 0`) : `.failed`, pas
    /// `.refused` — même distinction que `handleCreateFileStatus` fait pour le
    /// poids (status générique vs. CreateStatus applicatif).
    @Test func createFileGenericStatusErrorSetsFailedState() throws {
        let (session, fake, _, root) = try makeSession()
        defer { try? FileManager.default.removeItem(at: root) }

        session.uploadSettingsFile(syntheticContent(12), kind: .alarms)
        fake.deliver(messageType: Wire.response, payload: createFileStatusPayload(fileIndex: 0, status: 1))

        #expect(session.alarmWriteState == .failed("CREATE_FILE status=1"))
    }

    /// Le poids suit exactement le même chemin générique (`kind: .weight`) —
    /// seul l'état `@Published` ciblé diffère.
    @Test func uploadSettingsFileRoutesWeightKindToWeightWriteState() throws {
        let (session, fake, _, root) = try makeSession()
        defer { try? FileManager.default.removeItem(at: root) }

        session.uploadSettingsFile(syntheticContent(8), kind: .weight(70))
        #expect(session.weightWriteState == .uploading)
        #expect(session.alarmWriteState == .idle, "l'upload poids ne doit jamais publier dans l'état alarmes")

        fake.deliver(messageType: Wire.response, payload: createFileStatusPayload(fileIndex: 1))
        fake.deliver(messageType: Wire.response, payload: uploadRequestStatusPayload())
        fake.deliver(messageType: Wire.response, payload: uploadDataStatusPayload())
        #expect(session.weightWriteState == .sent)
    }
}

// MARK: - 2) `writeAlarms` — déclenchement public, mêmes garde-fous que `writeWeight`

struct WriteAlarmsTests {
    /// Sans lien initialisé, la demande reste `.queued` et ne part pas tout de
    /// suite (même garde que `writeWeight`/`tryStartPendingSettingsUpload`).
    @Test func writeAlarmsBeforeHandshakeStaysQueuedAndSendsNothing() throws {
        let (session, fake, _, root) = try makeSession()
        defer { try? FileManager.default.removeItem(at: root) }

        session.writeAlarms(schedule: [2: 7 * 60])
        #expect(session.alarmWriteState == .queued)
        #expect(fake.sentFrames.isEmpty)
    }

    /// Une fois le lien initialisé et le slot de transfert libre, la demande en
    /// attente démarre automatiquement (CREATE_FILE envoyé) — rejoue le même
    /// seam que `tryStartPendingWeightUpload` avant la généralisation.
    @Test func writeAlarmsStartsAutomaticallyOnceSlotFreesUp() throws {
        let (session, fake, _, root) = try makeSession()
        defer { try? FileManager.default.removeItem(at: root) }

        session.writeAlarms(schedule: [2: 7 * 60])
        completeHandshakeWithEmptyManifest(session, fake)

        #expect(session.alarmWriteState == .uploading)
        #expect(parseCreateFile(try #require(fake.sentFrames.last)) != nil)
    }
}

// MARK: - 3) Coexistence poids/alarmes — un seul slot d'upload de réglages

struct SettingsUploadCoexistenceTests {
    /// Un upload de poids en vol fait patienter une demande d'alarmes : elle
    /// reste `.queued`, sans second CREATE_FILE concurrent, et démarre
    /// automatiquement dès que le poids est transmis (`settingsUploadDidFinish`
    /// → `tryStartPendingSettingsUpload`) — c'est le cœur du slot UNIQUE partagé.
    @Test func pendingAlarmsWaitForAnInFlightWeightUploadThenStartWhenItCompletes() throws {
        let (session, fake, _, root) = try makeSession()
        defer { try? FileManager.default.removeItem(at: root) }

        completeHandshakeWithEmptyManifest(session, fake)

        session.writeWeight(kg: 71.2)
        #expect(session.weightWriteState == .uploading, "le poids démarre tout de suite, slot libre")
        let createFileFramesAfterWeightStart = fake.sentFrames.compactMap(parseCreateFile)
        #expect(createFileFramesAfterWeightStart.count == 1)

        session.writeAlarms(schedule: [2: 7 * 60, 3: 7 * 60])
        #expect(session.alarmWriteState == .queued, "le slot est occupé par le poids — pas de second CREATE_FILE")
        #expect(fake.sentFrames.compactMap(parseCreateFile).count == 1, "aucun CREATE_FILE supplémentaire émis pour les alarmes tant que le poids est en vol")

        // Fait aboutir l'upload poids (fichier FIT réel, pas un stub — un seul
        // morceau, cf. commentaire de classe de `GarminSession`).
        fake.deliver(messageType: Wire.response, payload: createFileStatusPayload(fileIndex: 3))
        guard let uploadRequestFrame = fake.sentFrames.last, parseUploadRequest(uploadRequestFrame) != nil else {
            Issue.record("UPLOAD_REQUEST attendu après CREATE_FILE accepté")
            return
        }
        fake.deliver(messageType: Wire.response, payload: uploadRequestStatusPayload())
        guard let dataFrame = fake.sentFrames.last, let parsed = parseFileTransferData(dataFrame) else {
            Issue.record("FILE_TRANSFER_DATA attendu après UPLOAD_REQUEST accepté")
            return
        }
        fake.deliver(messageType: Wire.response, payload: uploadDataStatusPayload())
        #expect(parsed.offset == 0)
        #expect(session.weightWriteState == .sent)

        // Slot libéré : le planning d'alarmes resté en attente démarre
        // automatiquement — c'est la preuve de la coexistence demandée. Son
        // propre handshake utilise le stub `FitSettingsWriter.alarmSettings`
        // (potentiellement `Data()` tant qu'il n'est pas remplacé), donc on ne
        // pousse PAS la vérification au-delà du démarrage ici.
        #expect(session.alarmWriteState == .uploading, "les alarmes démarrent dès que le poids libère le slot")
        #expect(fake.sentFrames.compactMap(parseCreateFile).count == 2, "un second CREATE_FILE est parti, cette fois pour les alarmes")
    }

    /// Symétrique : des alarmes en vol font patienter un poids demandé entre
    /// temps.
    @Test func pendingWeightWaitsForAnInFlightAlarmUpload() throws {
        let (session, fake, _, root) = try makeSession()
        defer { try? FileManager.default.removeItem(at: root) }

        completeHandshakeWithEmptyManifest(session, fake)

        // Démarre directement la primitive (plutôt que `writeAlarms`, dont le
        // stub produirait un fichier vide) pour simuler un upload d'alarmes
        // RÉALISTE en vol, avec un contenu non vide à faire aboutir.
        session.uploadSettingsFile(syntheticContent(16), kind: .alarms)
        #expect(session.alarmWriteState == .uploading)

        session.writeWeight(kg: 68.0)
        #expect(session.weightWriteState == .queued)
        #expect(fake.sentFrames.compactMap(parseCreateFile).count == 1, "aucun CREATE_FILE poids tant que les alarmes occupent le slot")

        fake.deliver(messageType: Wire.response, payload: createFileStatusPayload(fileIndex: 4))
        fake.deliver(messageType: Wire.response, payload: uploadRequestStatusPayload())
        fake.deliver(messageType: Wire.response, payload: uploadDataStatusPayload())
        #expect(session.alarmWriteState == .sent)

        #expect(session.weightWriteState == .uploading, "le poids démarre dès que les alarmes libèrent le slot")
        #expect(fake.sentFrames.compactMap(parseCreateFile).count == 2)
    }
}
