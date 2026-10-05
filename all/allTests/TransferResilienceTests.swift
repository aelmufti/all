//
//  TransferResilienceTests.swift
//  allTests
//
//  Audit ciblé des trois chemins de robustesse « corrects en théorie mais peu
//  éprouvés » du collecteur GFDI (cf. all/docs/robustesse-transferts.md pour la
//  confrontation détaillée à `GarminSession.java`, session/GarminSession.java,
//  AGPL-3.0, côté pont) :
//    1. reprise de fragment interrompu (en avance / en retard / traînard après
//       fin) — `GarminSession.handleFileTransferData`, au-delà de ce que
//       `FileTransferReassemblerTests` (GarminProtocolTests.swift) couvre déjà
//       au niveau du type pur `FileTransferReassembler` seul : ici on pilote
//       `GarminSession` de bout en bout, ce qui est le seul endroit où vit la
//       logique « traînard » (aucun download en cours) ;
//    2. CRC invalide au bon offset, au niveau du fil complet (accusé
//       RESPONSE/5000 réellement émis), pas seulement l'`Action` pure ;
//    3. interleaving de `SET_FILE_FLAG(ARCHIVE)` (5008) pendant que le
//       téléchargement suivant occupe déjà le slot unique, et re-list de
//       manifeste différée (`pendingDirectoryRelisting`) rejouée seulement une
//       fois le slot libéré ;
//    4. archivage confirmé par la montre (`archived` seulement sur accusé
//       appliqué, une demande à la fois, retenté en début de session) et
//       re-téléchargement d'un fichier dont la taille listée a changé
//       (`GarminSessionArchiveAckTests`).
//
//  Pilote `GarminSession` avec un communicator FACTICE (`FakeGfdiCommunicator`,
//  ci-dessous) — jamais de vrai CoreBluetooth/BLE, jamais de vraie donnée de
//  santé (règles immuables CLAUDE.md). Ce seam (`GfdiCommunicating`, cf.
//  CommunicatorV2.swift) a été ajouté par cette tâche : aucun comportement de
//  production n'en dépend, `CommunicatorV2` reste sa seule conformance réelle
//  (`BLEManager` continue de lui passer une vraie instance).
//

import Testing
import Foundation
@testable import all

// MARK: - Construction de trames (miroir des formats privés de GarminSession.swift)

private enum Wire {
    static let response: UInt16 = 5000
    static let downloadRequest: UInt16 = 5002
    static let fileTransferData: UInt16 = 5004
    static let setFileFlag: UInt16 = 5008
}

/// Octets synthétiques déterministes — jamais un vrai `.fit`, jamais parsés
/// (le collecteur ne parse pas le contenu, cf. CLAUDE.md) : juste de quoi
/// vérifier qu'un réassemblage produit exactement ce qui a été envoyé.
private func syntheticContent(_ count: Int, seed: UInt8 = 0x41) -> Data {
    Data((0..<count).map { UInt8((Int(seed) + $0) % 256) })
}

/// Payload de la trame RESPONSE(5000) « DOWNLOAD_REQUEST_STATUS » que la montre
/// renvoie après un DOWNLOAD_REQUEST — miroir de `handleDownloadRequestStatus`.
private func downloadRequestStatusPayload(maxFileSize: UInt32, status: UInt8 = 0, downloadStatus: UInt8 = 0) -> Data {
    var writer = GarminByteWriter()
    writer.writeUInt16LE(Wire.downloadRequest)
    writer.writeUInt8(status)
    writer.writeUInt8(downloadStatus)
    writer.writeUInt32LE(maxFileSize)
    return writer.data
}

/// Payload de FILE_TRANSFER_DATA (5004, trame directe) — miroir de
/// `handleFileTransferData`.
private func fileTransferDataPayload(dataOffset: UInt32, crc: UInt16, chunk: Data) -> Data {
    var writer = GarminByteWriter()
    writer.writeUInt8(0) // flags, non utilisé
    writer.writeUInt16LE(crc)
    writer.writeUInt32LE(dataOffset)
    writer.writeBytes(chunk)
    return writer.data
}

/// Une entrée de manifeste directory de 16 octets — même disposition que le
/// helper `entryBytes` de `GarminProtocolTests.swift`.
private func directoryEntryBytes(fileIndex: UInt16, dataType: UInt8, subType: UInt8, fileNumber: UInt16, fileSize: UInt32, timestamp: UInt32) -> Data {
    var writer = GarminByteWriter()
    writer.writeUInt16LE(fileIndex)
    writer.writeUInt8(dataType)
    writer.writeUInt8(subType)
    writer.writeUInt16LE(fileNumber)
    writer.writeUInt8(0) // specificFlags
    writer.writeUInt8(0) // fileFlags
    writer.writeUInt32LE(fileSize)
    writer.writeUInt32LE(timestamp)
    return writer.data
}

/// Payload de la trame RESPONSE(5000) « SET_FILE_FLAG_STATUS » renvoyée par la
/// montre — miroir de `SetFileFlagStatus.parse` (`handleSetFileFlagStatus`).
private func setFileFlagStatusPayload(status: UInt8 = 0, flagsStatus: UInt8 = 0, identifier: UInt16 = 0, flags: UInt8 = 0x10) -> Data {
    var writer = GarminByteWriter()
    writer.writeUInt16LE(Wire.setFileFlag)
    writer.writeUInt8(status)
    writer.writeUInt8(flagsStatus)
    writer.writeUInt16LE(identifier)
    writer.writeUInt8(flags)
    return writer.data
}

// MARK: - Lecture des trames sortantes capturées

private struct FileTransferAck: Equatable {
    let status: UInt8
    let transferStatus: UInt8
    let offset: UInt32
}

/// Décode un accusé FILE_TRANSFER_DATA (RESPONSE/5000 nommant l'offset voulu,
/// `sendFileTransferAck` côté GarminSession) parmi les trames sortantes
/// capturées — `nil` si la trame n'en est pas une (pas de crash, cf. le reste
/// du décodeur GFDI qui préfère toujours `nil` à une exception).
private func parseFileTransferAck(_ data: Data) -> FileTransferAck? {
    guard let frame = try? GfdiFrame.parse(data), frame.messageType == Wire.response else { return nil }
    var reader = GarminByteReader(frame.payload)
    guard let originalType = reader.readUInt16LE(), originalType == Wire.fileTransferData,
          let status = reader.readUInt8(),
          let transferStatus = reader.readUInt8(),
          let offset = reader.readUInt32LE()
    else { return nil }
    return FileTransferAck(status: status, transferStatus: transferStatus, offset: offset)
}

/// Index de fichier porté par une trame DOWNLOAD_REQUEST(5002) sortante.
private func parseDownloadRequestFileIndex(_ data: Data) -> UInt16? {
    guard let frame = try? GfdiFrame.parse(data), frame.messageType == Wire.downloadRequest else { return nil }
    var reader = GarminByteReader(frame.payload)
    return reader.readUInt16LE()
}

private struct SetFileFlagFrame: Equatable {
    let fileIndex: UInt16
    let bitmask: UInt8
}

/// Décode une trame SET_FILE_FLAG(5008) sortante (`archiveFileOnWatch`).
private func parseSetFileFlag(_ data: Data) -> SetFileFlagFrame? {
    guard let frame = try? GfdiFrame.parse(data), frame.messageType == Wire.setFileFlag else { return nil }
    var reader = GarminByteReader(frame.payload)
    guard let fileIndex = reader.readUInt16LE(), let bitmask = reader.readUInt8() else { return nil }
    return SetFileFlagFrame(fileIndex: fileIndex, bitmask: bitmask)
}

// MARK: - Communicator GFDI factice

/// Jamais de vrai CoreBluetooth/BLE en test (règle immuable CLAUDE.md).
/// Capture les trames telles que `GarminSession` les construit (avant
/// COBS/fragmentation — la responsabilité de `CommunicatorV2`, hors périmètre
/// ici puisqu'on teste `GarminSession`, pas le transport) et permet de simuler
/// une trame entrante en appelant directement `onGfdiFrame`.
private final class FakeGfdiCommunicator: GfdiCommunicating {
    var onGfdiFrame: ((GfdiFrame) -> Void)?
    var onGfdiChannelReady: (() -> Void)?
    private(set) var sentFrames: [Data] = []

    func start() {}

    func sendGfdiMessage(_ frame: Data, taskName: String) {
        sentFrames.append(frame)
    }

    /// Simule une trame déjà décodée par le transport (COBS + réassemblage
    /// retirés en amont, hors périmètre ici).
    func deliver(messageType: UInt16, payload: Data) {
        onGfdiFrame?(GfdiFrame(messageType: messageType, payload: payload))
    }
}

// MARK: - Fixtures communes

private func fileEntry(fileIndex: Int, sizeBytes: Int = 8) -> GarminDirectoryEntry {
    GarminDirectoryEntry(fileIndex: fileIndex, dataType: 128, subType: 4, fileNumber: fileIndex, sizeBytes: sizeBytes, garminTimestamp: 0)!
}

private func makeSession() throws -> (session: GarminSession, fake: FakeGfdiCommunicator, store: SpoolStore, root: URL) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("bridge-connect-transfer-resilience-\(UUID().uuidString)", isDirectory: true)
    let store = try SpoolStore(root: root)
    let fake = FakeGfdiCommunicator()
    let session = GarminSession(communicator: fake, spoolStore: store, uploader: nil)
    return (session, fake, store, root)
}

/// Fait recevoir à la session un manifeste directory listant `entries` (chemin
/// réel : DOWNLOAD_REQUEST index 0 → statut → fragment complet → `finishDownload`
/// → archivages de début de session + `syncNewFiles`). Le slot doit être libre.
private func deliverManifest(_ session: GarminSession, _ fake: FakeGfdiCommunicator, _ entries: [GarminDirectoryEntry]) {
    session.requestDirectoryListing()
    var bytes = Data()
    for entry in entries {
        bytes.append(directoryEntryBytes(
            fileIndex: UInt16(entry.fileIndex), dataType: entry.dataType, subType: entry.subType,
            fileNumber: UInt16(entry.fileNumber), fileSize: UInt32(entry.sizeBytes), timestamp: 0))
    }
    fake.deliver(messageType: Wire.response, payload: downloadRequestStatusPayload(maxFileSize: UInt32(bytes.count)))
    fake.deliver(messageType: Wire.fileTransferData, payload: fileTransferDataPayload(dataOffset: 0, crc: Crc16.compute(bytes), chunk: bytes))
}

/// Index des SET_FILE_FLAG(ARCHIVE) émis jusque-là, dans l'ordre.
private func archivedIndexes(_ fake: FakeGfdiCommunicator) -> [UInt16] {
    fake.sentFrames.compactMap(parseSetFileFlag).map(\.fileIndex)
}

/// Index des DOWNLOAD_REQUEST émis jusque-là, dans l'ordre (0 = manifeste).
private func requestedIndexes(_ fake: FakeGfdiCommunicator) -> [UInt16] {
    fake.sentFrames.compactMap(parseDownloadRequestFileIndex)
}

// MARK: - 1) Reprise de fragment + 2) CRC invalide, au niveau GarminSession complet

/// Complète `FileTransferReassemblerTests` (GarminProtocolTests.swift), qui
/// couvre déjà le type pur `FileTransferReassembler` seul. Ici : le fil complet
/// (accusés RESPONSE/5000 réellement émis par `GarminSession`) ET le cas
/// « traînard après fin », qui n'existe qu'au niveau `GarminSession`
/// (`currentDownload == nil`, cf. son commentaire) — le type pur ne le voit
/// jamais puisqu'il n'y a alors pas d'instance à qui déléguer.
struct GarminSessionFragmentResumeTests {
    @Test func inOrderFragmentsAckEachOffsetAndCompleteTheFile() throws {
        let (session, fake, store, root) = try makeSession()
        defer { try? FileManager.default.removeItem(at: root) }

        let entry = fileEntry(fileIndex: 41, sizeBytes: 16)
        session.downloadFile(entry)
        #expect(parseDownloadRequestFileIndex(try #require(fake.sentFrames.last)) == 41)

        fake.deliver(messageType: Wire.response, payload: downloadRequestStatusPayload(maxFileSize: 16))

        let content = syntheticContent(16)
        let firstHalf = content.prefix(8)
        let secondHalf = content.suffix(8)
        let crc1 = Crc16.compute(firstHalf)
        fake.deliver(messageType: Wire.fileTransferData, payload: fileTransferDataPayload(dataOffset: 0, crc: crc1, chunk: firstHalf))
        #expect(parseFileTransferAck(try #require(fake.sentFrames.last))?.offset == 8)

        let crc2 = Crc16.compute(secondHalf, initial: crc1)
        fake.deliver(messageType: Wire.fileTransferData, payload: fileTransferDataPayload(dataOffset: 8, crc: crc2, chunk: secondHalf))
        #expect(parseFileTransferAck(try #require(fake.sentFrames.last))?.offset == 16)

        #expect(session.acquiredFileIndexes.contains(41))
        let (id, _) = SpoolStore.identity(for: entry)
        let saved = try #require(store.entries[id])
        #expect(saved.state == .acquired)
        #expect(try Data(contentsOf: store.fileURL(for: saved)) == content)
    }

    /// Porte le scénario `>` (fragment perdu, la montre est en avance) au
    /// niveau `GarminSession` : jamais `TransferStatus.RESEND`, on ré-accuse
    /// notre offset courant — la montre reprend d'elle-même.
    @Test func fragmentAheadOfExpectedIsNotAppliedAndReAsksForCurrentOffset() throws {
        let (session, fake, store, root) = try makeSession()
        defer { try? FileManager.default.removeItem(at: root) }

        let entry = fileEntry(fileIndex: 12, sizeBytes: 16)
        session.downloadFile(entry)
        fake.deliver(messageType: Wire.response, payload: downloadRequestStatusPayload(maxFileSize: 16))

        let content = syntheticContent(16, seed: 0x61)
        let firstHalf = content.prefix(8)
        let secondHalf = content.suffix(8)
        let crc1 = Crc16.compute(firstHalf)
        fake.deliver(messageType: Wire.fileTransferData, payload: fileTransferDataPayload(dataOffset: 0, crc: crc1, chunk: firstHalf))
        #expect(parseFileTransferAck(try #require(fake.sentFrames.last))?.offset == 8)

        // Saut en avant (octets 8..<12 jamais arrivés) : jamais appliqué.
        let tooFar = content.suffix(4)
        fake.deliver(messageType: Wire.fileTransferData, payload: fileTransferDataPayload(dataOffset: 12, crc: 0, chunk: tooFar))
        let aheadFrame = try #require(fake.sentFrames.last)
        let reAck = try #require(parseFileTransferAck(aheadFrame))
        #expect(reAck.offset == 8, "toujours à 8 : le saut n'a jamais été appliqué")
        #expect(reAck.transferStatus == 0, "TransferStatus.OK — jamais RESEND, même pour reprendre après une perte")

        let crc2 = Crc16.compute(secondHalf, initial: crc1)
        fake.deliver(messageType: Wire.fileTransferData, payload: fileTransferDataPayload(dataOffset: 8, crc: crc2, chunk: secondHalf))
        #expect(parseFileTransferAck(try #require(fake.sentFrames.last))?.offset == 16)

        let (id, _) = SpoolStore.identity(for: entry)
        let saved = try #require(store.entries[id])
        #expect(try Data(contentsOf: store.fileURL(for: saved)) == content, "le fragment en avance ne doit jamais être appliqué")
    }

    /// Porte le scénario `<` (doublon, notre ack précédent s'est perdu ou est
    /// arrivé en retard) au niveau `GarminSession`.
    @Test func duplicateFragmentIsReAckedWithoutBeingReapplied() throws {
        let (session, fake, store, root) = try makeSession()
        defer { try? FileManager.default.removeItem(at: root) }

        let entry = fileEntry(fileIndex: 13, sizeBytes: 16)
        session.downloadFile(entry)
        fake.deliver(messageType: Wire.response, payload: downloadRequestStatusPayload(maxFileSize: 16))

        let content = syntheticContent(16, seed: 0x71)
        let firstHalf = content.prefix(8)
        let secondHalf = content.suffix(8)
        let crc1 = Crc16.compute(firstHalf)
        fake.deliver(messageType: Wire.fileTransferData, payload: fileTransferDataPayload(dataOffset: 0, crc: crc1, chunk: firstHalf))
        #expect(parseFileTransferAck(try #require(fake.sentFrames.last))?.offset == 8)

        // La montre renvoie EXACTEMENT le même fragment.
        fake.deliver(messageType: Wire.fileTransferData, payload: fileTransferDataPayload(dataOffset: 0, crc: crc1, chunk: firstHalf))
        let duplicateFrame = try #require(fake.sentFrames.last)
        let reAck = try #require(parseFileTransferAck(duplicateFrame))
        #expect(reAck.offset == 8, "ré-accusé sans avancer")

        let crc2 = Crc16.compute(secondHalf, initial: crc1)
        fake.deliver(messageType: Wire.fileTransferData, payload: fileTransferDataPayload(dataOffset: 8, crc: crc2, chunk: secondHalf))
        #expect(parseFileTransferAck(try #require(fake.sentFrames.last))?.offset == 16)

        let (id, _) = SpoolStore.identity(for: entry)
        let saved = try #require(store.entries[id])
        #expect(try Data(contentsOf: store.fileURL(for: saved)) == content, "le doublon ne doit jamais être réappliqué (contenu non dupliqué)")
    }

    /// Cas qui n'existe qu'au niveau `GarminSession` (pas dans
    /// `FileTransferReassembler` seul) : après la fin d'un téléchargement, la
    /// montre renvoie encore un fragment (notre dernier ack est arrivé en
    /// retard, cf. `answeredAFragmentOutOfStep`/NOTHING_TO_APPEND_TO côté
    /// pont). On l'accuse quand même (son propre offset), sans jamais le
    /// réappliquer ni recréer d'entrée dans le spool.
    @Test func stragglerFragmentAfterCompletionIsAckedButHasNoEffect() throws {
        let (session, fake, store, root) = try makeSession()
        defer { try? FileManager.default.removeItem(at: root) }

        let entry = fileEntry(fileIndex: 7, sizeBytes: 8)
        session.downloadFile(entry)
        fake.deliver(messageType: Wire.response, payload: downloadRequestStatusPayload(maxFileSize: 8))

        let content = syntheticContent(8, seed: 0x30)
        let crc = Crc16.compute(content)
        fake.deliver(messageType: Wire.fileTransferData, payload: fileTransferDataPayload(dataOffset: 0, crc: crc, chunk: content))
        #expect(parseFileTransferAck(try #require(fake.sentFrames.last))?.offset == 8)
        #expect(session.acquiredFileIndexes.contains(7))
        #expect(session.downloadingFileIndex == nil, "le download est bien terminé, plus de cible en cours")

        let framesBeforeStraggler = fake.sentFrames.count
        let entryCountBeforeStraggler = store.entries.count

        // Traînard : même fragment renvoyé, aucun download en cours pour le recevoir.
        fake.deliver(messageType: Wire.fileTransferData, payload: fileTransferDataPayload(dataOffset: 0, crc: crc, chunk: content))

        #expect(fake.sentFrames.count == framesBeforeStraggler + 1, "le traînard est quand même accusé")
        let stragglerFrame = try #require(fake.sentFrames.last)
        let stragglerAck = try #require(parseFileTransferAck(stragglerFrame))
        #expect(stragglerAck.offset == 8, "son PROPRE offset (dataOffset+len), jamais un progrès de download")
        #expect(store.entries.count == entryCountBeforeStraggler, "aucune double écriture dans le spool")

        let (id, _) = SpoolStore.identity(for: entry)
        #expect(store.entries[id]?.state == .acquired)
    }

    /// HYPOTHÈSE documentée dans `FileTransferReassembler` (non vérifiée
    /// matériel) : un CRC invalide au bon offset est traité comme un fragment
    /// à redemander (ré-accusé) plutôt qu'une panne fatale — ici au niveau du
    /// fil complet (l'accusé RESPONSE/5000 réellement émis par
    /// `GarminSession`, pas seulement l'`Action` pure déjà couverte par
    /// `FileTransferReassemblerTests`).
    @Test func invalidCrcAtExpectedOffsetIsNotAppliedAndReAsksTheSameOffset() throws {
        let (session, fake, store, root) = try makeSession()
        defer { try? FileManager.default.removeItem(at: root) }

        let entry = fileEntry(fileIndex: 3, sizeBytes: 8)
        session.downloadFile(entry)
        fake.deliver(messageType: Wire.response, payload: downloadRequestStatusPayload(maxFileSize: 8))

        let content = syntheticContent(8, seed: 0x50)
        let goodCrc = Crc16.compute(content)
        let badCrc = goodCrc ^ 0xFFFF

        fake.deliver(messageType: Wire.fileTransferData, payload: fileTransferDataPayload(dataOffset: 0, crc: badCrc, chunk: content))
        let badCrcFrame = try #require(fake.sentFrames.last)
        let reAck = try #require(parseFileTransferAck(badCrcFrame))
        #expect(reAck.offset == 0, "rien appliqué : on ré-accuse l'offset attendu (0), pas d'avancée")
        #expect(reAck.transferStatus == 0, "TransferStatus.OK — jamais RESEND, même pour un CRC invalide")
        #expect(store.entries.isEmpty, "rien écrit dans le spool tant que le fragment n'est pas valide")

        fake.deliver(messageType: Wire.fileTransferData, payload: fileTransferDataPayload(dataOffset: 0, crc: goodCrc, chunk: content))
        #expect(parseFileTransferAck(try #require(fake.sentFrames.last))?.offset == 8)
        #expect(session.acquiredFileIndexes.contains(3))
    }
}

// MARK: - 3) Interleaving ARCHIVE / téléchargement suivant, slot unique

/// Couvre le garde anti-course sur le slot de transfert unique
/// (`downloadTarget`/`currentDownload`), sous deux angles distincts :
///   - `SET_FILE_FLAG(ARCHIVE)` émis pendant qu'un AUTRE fichier occupe déjà le
///     slot (déclenché en production par le callback réseau async de Pulse,
///     qui peut atterrir à tout moment — ici invoqué directement et
///     synchrone : c'est le point testé, pas la machinerie d'upload elle-même
///     déjà couverte par `SyncEngineTests.swift`) ;
///   - une re-list de manifeste demandée par la montre (SYNCHRONIZATION →
///     FILTER) pendant qu'un téléchargement de contenu est en vol : différée
///     (`pendingDirectoryRelisting`), jamais un deuxième `DOWNLOAD_REQUEST`
///     concurrent, rejouée automatiquement une fois le slot libéré.
struct GarminSessionSlotInterleavingTests {
    /// Le cœur du chemin #3 de l'audit : l'archive d'un fichier PRÉCÉDENT ne
    /// doit ni écraser ni perturber le téléchargement d'un fichier SUIVANT en
    /// cours — `archiveFileOnWatch` envoie une trame directe (5008) qui ne
    /// touche jamais `downloadTarget`/`currentDownload`, tout comme
    /// `archiveOnWatch` côté pont (session/GarminSession.java) ne passe jamais
    /// par le slot de transfert non plus. L'accusé de la montre, lui, arrive
    /// EN PLEIN téléchargement de B : c'est lui (et pas l'émission) qui marque A
    /// `archived`.
    @Test func archivingAPriorFileDoesNotDisturbAFileCurrentlyDownloading() throws {
        let (session, fake, store, root) = try makeSession()
        defer { try? FileManager.default.removeItem(at: root) }

        // Fichier A : acquis et livré (Pulse a déjà 2xx'é, lien ou appel
        // précédent) mais pas encore archivé sur la montre — exactement le
        // retard que l'archivage de début de session rattrape.
        let fileA = fileEntry(fileIndex: 5)
        let (idA, pathA) = SpoolStore.identity(for: fileA)
        try store.recordAcquired(idA, relativePath: pathA, data: Data("déjà livré".utf8), listedSize: fileA.sizeBytes)
        store.markDelivered(idA)

        // Manifeste = A (déjà tenu) + B (dû) : l'archive de A part, puis le
        // téléchargement de B occupe le slot.
        let fileB = fileEntry(fileIndex: 6, sizeBytes: 16)
        deliverManifest(session, fake, [fileA, fileB])
        #expect(session.downloadingFileIndex == 6, "B en vol")
        let archiveFrame = try #require(fake.sentFrames.compactMap(parseSetFileFlag).first)
        #expect(archiveFrame.fileIndex == 5)
        #expect(archiveFrame.bitmask == 0x10, "bit ARCHIVE")
        #expect(store.entries[idA]?.state == .delivered, "pas archivé à la seule émission")

        fake.deliver(messageType: Wire.response, payload: downloadRequestStatusPayload(maxFileSize: 16))
        let content = syntheticContent(16, seed: 0x42)
        let firstHalf = content.prefix(8)
        let secondHalf = content.suffix(8)
        let crc1 = Crc16.compute(firstHalf)
        fake.deliver(messageType: Wire.fileTransferData, payload: fileTransferDataPayload(dataOffset: 0, crc: crc1, chunk: firstHalf))
        #expect(session.downloadingFileIndex == 6, "B toujours en vol")

        // L'accusé de la montre pour A arrive pendant le transfert de B.
        fake.deliver(messageType: Wire.response, payload: setFileFlagStatusPayload())
        #expect(store.entries[idA]?.state == .archived)

        // Le slot de B n'a pas bougé : la suite de SON transfert continue
        // normalement (pas traité comme un traînard, pas corrompu).
        let crc2 = Crc16.compute(secondHalf, initial: crc1)
        fake.deliver(messageType: Wire.fileTransferData, payload: fileTransferDataPayload(dataOffset: 8, crc: crc2, chunk: secondHalf))
        #expect(parseFileTransferAck(try #require(fake.sentFrames.last))?.offset == 16)
        #expect(session.acquiredFileIndexes.contains(6))
        #expect(session.downloadingFileIndex == nil)

        let (idB, _) = SpoolStore.identity(for: fileB)
        let savedB = try #require(store.entries[idB])
        #expect(try Data(contentsOf: store.fileURL(for: savedB)) == content, "B complet et non corrompu malgré l'archive interleaved de A")
    }

    /// Le pendant « listing » du même garde : une re-list demandée par la
    /// montre pendant qu'un téléchargement de contenu occupe le slot est
    /// différée (`pendingDirectoryRelisting`), puis rejouée automatiquement
    /// une fois la traversée épuisée (`advanceDownloadQueue`) — jamais une
    /// seconde `DOWNLOAD_REQUEST` concurrente qui ferait refuser la montre en
    /// `downloadStatus=3` (cf. commentaire de `requestDirectoryListing`).
    @Test func directoryRelistRequestedMidDownloadIsDeferredThenReplayedOnceTheSlotFrees() throws {
        let (session, fake, store, root) = try makeSession()
        defer { try? FileManager.default.removeItem(at: root) }

        session.requestDirectoryListing()
        #expect(parseDownloadRequestFileIndex(try #require(fake.sentFrames.last)) == 0)

        // Manifeste d'une seule entrée (fichier index 55, pullable : ACTIVITY).
        fake.deliver(messageType: Wire.response, payload: downloadRequestStatusPayload(maxFileSize: 16))
        let entryBytes = directoryEntryBytes(fileIndex: 55, dataType: 128, subType: 4, fileNumber: 55, fileSize: 16, timestamp: 0)
        let entryCrc = Crc16.compute(entryBytes)
        fake.deliver(messageType: Wire.fileTransferData, payload: fileTransferDataPayload(dataOffset: 0, crc: entryCrc, chunk: entryBytes))

        // Pivot auto (`finishDownload` → `syncNewFiles`) : le seul fichier du
        // manifeste démarre tout de suite, sans action de test.
        #expect(session.downloadingFileIndex == 55)
        #expect(parseDownloadRequestFileIndex(try #require(fake.sentFrames.last)) == 55)

        fake.deliver(messageType: Wire.response, payload: downloadRequestStatusPayload(maxFileSize: 16))

        // La montre re-liste de sa propre initiative pendant que le contenu du
        // fichier 55 est encore en vol : ne doit RIEN envoyer tout de suite.
        let framesBeforeRelist = fake.sentFrames.count
        session.requestDirectoryListing()
        #expect(fake.sentFrames.count == framesBeforeRelist, "re-list différée : rien envoyé pendant que le slot est occupé")

        // Le fichier 55 se termine normalement.
        let content = syntheticContent(16, seed: 0x61)
        let crc = Crc16.compute(content)
        fake.deliver(messageType: Wire.fileTransferData, payload: fileTransferDataPayload(dataOffset: 0, crc: crc, chunk: content))

        // Traversée épuisée (un seul fichier) → slot libéré → re-list
        // différée rejouée automatiquement.
        #expect(session.downloadingFileIndex == nil)
        #expect(parseDownloadRequestFileIndex(try #require(fake.sentFrames.last)) == 0, "la re-list différée est bien rejouée une fois le slot libre")

        let (id55, _) = SpoolStore.identity(for: fileEntry(fileIndex: 55))
        #expect(store.entries[id55]?.state == .acquired, "le fichier 55 reste acquis normalement malgré la re-list interleaved")
    }
}

// MARK: - 4) Archivage confirmé par la montre + re-téléchargement d'un fichier qui a grossi

struct GarminSessionArchiveAckTests {
    /// Entrée `delivered` dont la taille listée (8 par défaut de `fileEntry`) est
    /// celle enregistrée à l'acquisition.
    @discardableResult
    private func holdDelivered(_ entry: GarminDirectoryEntry, in store: SpoolStore, content: String = "livré") throws -> WatchFileID {
        let (id, path) = SpoolStore.identity(for: entry)
        try store.recordAcquired(id, relativePath: path, data: Data(content.utf8), listedSize: entry.sizeBytes)
        store.markDelivered(id)
        return id
    }

    @Test func archivedIsMarkedOnlyOnceTheWatchAcknowledgesAnAppliedFlag() throws {
        let (session, fake, store, root) = try makeSession()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = fileEntry(fileIndex: 21)
        let id = try holdDelivered(file, in: store)

        deliverManifest(session, fake, [file])

        #expect(archivedIndexes(fake) == [21], "demande émise au manifeste")
        #expect(store.entries[id]?.state == .delivered, "pas archivé à l'émission")

        fake.deliver(messageType: Wire.response, payload: setFileFlagStatusPayload())
        #expect(store.entries[id]?.state == .archived)
    }

    @Test func aRefusalLeavesTheEntryDeliveredAndANewSessionRetriesIt() throws {
        let (session, fake, store, root) = try makeSession()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = fileEntry(fileIndex: 21)
        let id = try holdDelivered(file, in: store)

        deliverManifest(session, fake, [file])
        fake.deliver(messageType: Wire.response, payload: setFileFlagStatusPayload(flagsStatus: 1))

        #expect(store.entries[id]?.state == .delivered)
        #expect(archivedIndexes(fake) == [21], "pas de renvoi en boucle sur le même lien")

        // Statut non-ACK : même issue.
        let second = GarminSession(communicator: fake, spoolStore: store, uploader: nil)
        deliverManifest(second, fake, [file])
        #expect(archivedIndexes(fake) == [21, 21], "retenté au début de la session suivante")
        fake.deliver(messageType: Wire.response, payload: setFileFlagStatusPayload(status: 1))
        #expect(store.entries[id]?.state == .delivered)
    }

    @Test func noResponseLeavesTheEntryDeliveredStopsTheLinkAndALateAckIsIgnored() throws {
        let (session, fake, store, root) = try makeSession()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = fileEntry(fileIndex: 21), b = fileEntry(fileIndex: 22)
        let idA = try holdDelivered(a, in: store)
        let idB = try holdDelivered(b, in: store)

        deliverManifest(session, fake, [a, b])
        #expect(archivedIndexes(fake).count == 1, "une seule demande en vol")

        session.expireInFlightArchive() // pas de réponse à temps
        #expect(archivedIndexes(fake).count == 1, "plus aucune demande sur ce lien après une absence de réponse")

        // Réponse tardive de la montre : rien en vol, jamais attribuée à une entrée.
        fake.deliver(messageType: Wire.response, payload: setFileFlagStatusPayload())
        #expect(store.entries[idA]?.state == .delivered)
        #expect(store.entries[idB]?.state == .delivered)

        // Session suivante : retenté.
        let next = GarminSession(communicator: fake, spoolStore: store, uploader: nil)
        let before = archivedIndexes(fake).count
        deliverManifest(next, fake, [a, b])
        #expect(archivedIndexes(fake).count == before + 1)
    }

    @Test func requestsGoOneAtATimeAndEachAckAdvancesTheNext() throws {
        let (session, fake, store, root) = try makeSession()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = fileEntry(fileIndex: 21), b = fileEntry(fileIndex: 22)
        let idA = try holdDelivered(a, in: store)
        let idB = try holdDelivered(b, in: store)

        deliverManifest(session, fake, [a, b])
        #expect(archivedIndexes(fake).count == 1)
        let first = try #require(archivedIndexes(fake).first)

        fake.deliver(messageType: Wire.response, payload: setFileFlagStatusPayload())
        #expect(archivedIndexes(fake).count == 2, "l'accusé libère la demande suivante")
        #expect(Set(archivedIndexes(fake)) == [21, 22])
        #expect(store.entries[first == 21 ? idA : idB]?.state == .archived)
        #expect(store.entries[first == 21 ? idB : idA]?.state == .delivered, "la seconde n'est pas encore accusée")

        fake.deliver(messageType: Wire.response, payload: setFileFlagStatusPayload())
        #expect(store.entries[idA]?.state == .archived)
        #expect(store.entries[idB]?.state == .archived)
    }

    @Test func aDeliveredEntryAbsentFromTheManifestIsNeitherArchivedNorLost() throws {
        let (session, fake, store, root) = try makeSession()
        defer { try? FileManager.default.removeItem(at: root) }
        let absent = fileEntry(fileIndex: 21)
        let id = try holdDelivered(absent, in: store)

        deliverManifest(session, fake, [fileEntry(fileIndex: 99)]) // l'index 21 n'y est pas

        #expect(archivedIndexes(fake).isEmpty, "jamais d'archivage à l'aveugle par index")
        #expect(store.entries[id]?.state == .delivered)
    }

    @Test func aFileWhoseListedSizeChangedIsReDownloadedAndNotArchivedFirst() throws {
        let (session, fake, store, root) = try makeSession()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = fileEntry(fileIndex: 21, sizeBytes: 8)
        let id = try holdDelivered(original, in: store, content: "ancien")
        store.markPushedToPulse(id)
        let before = try #require(store.entries[id])

        // La montre liste maintenant le MÊME fichier (même identité) avec 16 octets.
        let grown = fileEntry(fileIndex: 21, sizeBytes: 16)
        deliverManifest(session, fake, [grown])

        #expect(archivedIndexes(fake).isEmpty, "jamais archivé avant d'avoir été relu")
        #expect(requestedIndexes(fake) == [0, 21], "re-téléchargement demandé")
        #expect(session.downloadingFileIndex == 21)

        fake.deliver(messageType: Wire.response, payload: downloadRequestStatusPayload(maxFileSize: 16))
        let content = syntheticContent(16, seed: 0x55)
        fake.deliver(messageType: Wire.fileTransferData, payload: fileTransferDataPayload(dataOffset: 0, crc: Crc16.compute(content), chunk: content))

        let after = try #require(store.entries[id])
        #expect(after.state == .acquired, "repasse à acquired : nouvel envoi à Pulse puis nouvel archivage")
        #expect(after.listedSize == 16)
        #expect(after.pushedToPulse == false)
        #expect(after.deliveredAt == nil)
        #expect(after.acquiredAt > before.acquiredAt)
        #expect(try Data(contentsOf: store.fileURL(for: after)) == content)

        // Même manifeste revu : taille enregistrée = taille listée → pas de boucle,
        // et l'entrée `acquired` n'est pas archivable.
        let requestsBefore = requestedIndexes(fake).count
        deliverManifest(session, fake, [grown])
        #expect(requestedIndexes(fake).count == requestsBefore + 1, "seulement la demande de manifeste (index 0), aucun re-téléchargement")
        #expect(archivedIndexes(fake).isEmpty)
    }

    /// Entrée antérieure à `listedSize` : jamais relue, archivable.
    @Test func anOldEntryWithoutRecordedSizeIsNotReDownloaded() throws {
        let (session, fake, store, root) = try makeSession()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = fileEntry(fileIndex: 21, sizeBytes: 8)
        let (id, path) = SpoolStore.identity(for: file)
        try store.recordAcquired(id, relativePath: path, data: Data("ancien".utf8)) // pas de listedSize
        store.markDelivered(id)

        deliverManifest(session, fake, [fileEntry(fileIndex: 21, sizeBytes: 500)])

        #expect(requestedIndexes(fake) == [0], "pas de re-téléchargement massif à la mise à jour")
        #expect(archivedIndexes(fake) == [21])
    }
}

// MARK: - 5) Verrou d'archivage : pas de SET_FILE_FLAG sans preuve d'ingestion locale

/// Compteurs des coutures d'ingestion injectées (jamais de vraie passe : le spool
/// de l'app n'est jamais ouvert depuis un test).
private final class IngestHooks {
    var ingestRequests = 0
    var verifierCalls: [Int] = [] // index des entrées vérifiées, dans l'ordre
}

struct GarminSessionIngestLockTests {
    private func makeLockedSession(
        requires: Bool = true, hooks: IngestHooks, verifier: ((SpoolEntry) -> Bool)? = nil
    ) throws -> (session: GarminSession, fake: FakeGfdiCommunicator, store: SpoolStore, root: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bridge-connect-ingest-lock-\(UUID().uuidString)", isDirectory: true)
        let store = try SpoolStore(root: root)
        let fake = FakeGfdiCommunicator()
        let session = GarminSession(
            communicator: fake, spoolStore: store, uploader: nil,
            requiresLocalIngest: { requires },
            ingestProofVerifier: verifier,
            requestLocalIngest: { hooks.ingestRequests += 1 })
        return (session, fake, store, root)
    }

    @discardableResult
    private func holdDelivered(_ entry: GarminDirectoryEntry, in store: SpoolStore) throws -> WatchFileID {
        let (id, path) = SpoolStore.identity(for: entry)
        try store.recordAcquired(id, relativePath: path, data: Data("livré".utf8), listedSize: entry.sizeBytes)
        store.markDelivered(id)
        return id
    }

    private func prove(_ id: WatchFileID, _ status: SpoolIngestStatus = .ingested, in store: SpoolStore) {
        store.markIngest(id, outcome: SpoolIngestOutcome(status: status, hash: "h", at: Date()))
    }

    @Test func noArchiveWhileProofIsMissingThenItLeavesOnceProvenAndPumped() throws {
        let hooks = IngestHooks()
        let (session, fake, store, root) = try makeLockedSession(hooks: hooks)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = fileEntry(fileIndex: 21)
        let id = try holdDelivered(file, in: store)

        deliverManifest(session, fake, [file])
        #expect(archivedIndexes(fake).isEmpty, "aucune SET_FILE_FLAG sans preuve")
        #expect(store.entries[id]?.state == .delivered)

        session.archivePendingDeliveries()
        #expect(archivedIndexes(fake).isEmpty, "toujours verrouillé")

        prove(id, in: store)
        session.archivePendingDeliveries()
        #expect(archivedIndexes(fake) == [21])

        fake.deliver(messageType: Wire.response, payload: setFileFlagStatusPayload())
        #expect(store.entries[id]?.state == .archived)
    }

    /// En production la preuve est posée par l'instance de `SpoolStore` de la
    /// passe d'ingestion, pas par celle de la session : la session doit relire
    /// le journal, sinon son cache ne voit jamais la preuve.
    @Test func proofWrittenByAnotherSpoolStoreInstanceUnlocksArchiving() throws {
        let hooks = IngestHooks()
        let (session, fake, store, root) = try makeLockedSession(hooks: hooks)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = fileEntry(fileIndex: 21)
        let id = try holdDelivered(file, in: store)
        deliverManifest(session, fake, [file])
        #expect(archivedIndexes(fake).isEmpty)

        let ingestorStore = try SpoolStore(root: root)
        prove(id, in: ingestorStore)
        session.archivePendingDeliveries()
        #expect(archivedIndexes(fake) == [21])
    }

    /// `failed` et `skipped` débloquent aussi : on tient la copie, et ne pas
    /// archiver saturerait l'index de la montre.
    @Test(arguments: [SpoolIngestStatus.failed, .skipped, .ingested])
    func everyKindOfProofUnlocksArchiving(status: SpoolIngestStatus) throws {
        let hooks = IngestHooks()
        let (session, fake, store, root) = try makeLockedSession(hooks: hooks)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = fileEntry(fileIndex: 21)
        let id = try holdDelivered(file, in: store)
        prove(id, status, in: store)

        deliverManifest(session, fake, [file])
        #expect(archivedIndexes(fake) == [21])
    }

    @Test func withoutTheRequirementNothingChanges() throws {
        let hooks = IngestHooks()
        let (session, fake, store, root) = try makeLockedSession(requires: false, hooks: hooks, verifier: { _ in false })
        defer { try? FileManager.default.removeItem(at: root) }
        let file = fileEntry(fileIndex: 21)
        try holdDelivered(file, in: store)

        deliverManifest(session, fake, [file])
        #expect(archivedIndexes(fake) == [21], "mode Pulse : pas de verrou, pas de vérification")
        #expect(hooks.ingestRequests <= 1, "au plus la demande de fin de traversée, aucune relance de vérification")
    }

    /// Vérificateur négatif : pas d'archivage, preuve effacée, ré-ingestion
    /// demandée, rien ne reste « en vol » ni « tenté » pour elle — les autres
    /// entrées partent, et elle part plus tard sur le MÊME lien.
    @Test func aRejectedProofClearsItRequestsReingestionAndStillLeavesLaterOnTheSameLink() throws {
        let hooks = IngestHooks()
        var healthy = false // devient vrai quand la base « retrouve » l'entrée 21
        let (session, fake, store, root) = try makeLockedSession(hooks: hooks, verifier: { entry in
            hooks.verifierCalls.append(entry.id.index)
            return entry.id.index != 21 || healthy
        })
        defer { try? FileManager.default.removeItem(at: root) }
        let a = fileEntry(fileIndex: 21), b = fileEntry(fileIndex: 22)
        let idA = try holdDelivered(a, in: store)
        let idB = try holdDelivered(b, in: store)
        prove(idA, in: store)
        prove(idB, in: store)

        deliverManifest(session, fake, [a, b])

        #expect(archivedIndexes(fake) == [22], "21 refusée par la vérification, 22 part : aucune demande bloquée en vol")
        #expect(store.entries[idA]?.ingest == nil, "preuve de 21 effacée")
        #expect(store.entries[idA]?.state == .delivered)
        #expect(hooks.ingestRequests >= 1, "ré-ingestion demandée")

        fake.deliver(messageType: Wire.response, payload: setFileFlagStatusPayload())
        #expect(store.entries[idB]?.state == .archived)
        #expect(archivedIndexes(fake) == [22], "21 est de nouveau sans preuve : verrouillée")

        // La passe d'ingestion repose la preuve, la base la confirme : 21 part, sur le même lien.
        healthy = true
        prove(idA, in: store)
        session.archivePendingDeliveries()
        #expect(archivedIndexes(fake) == [22, 21])
        fake.deliver(messageType: Wire.response, payload: setFileFlagStatusPayload())
        #expect(store.entries[idA]?.state == .archived)
    }

    /// Un vérificateur qui répond toujours faux ne fait pas boucler
    /// effacement → ingestion → rejet : un seul cycle par acquisition et par lien.
    @Test func aProofRejectedTwiceOnTheSameLinkIsNotClearedAgain() throws {
        let hooks = IngestHooks()
        let (session, fake, store, root) = try makeLockedSession(hooks: hooks, verifier: { _ in false })
        defer { try? FileManager.default.removeItem(at: root) }
        let file = fileEntry(fileIndex: 21)
        let id = try holdDelivered(file, in: store)
        prove(id, in: store)

        deliverManifest(session, fake, [file])
        let afterFirst = hooks.ingestRequests
        #expect(store.entries[id]?.ingest == nil)

        prove(id, in: store)
        session.archivePendingDeliveries()
        #expect(archivedIndexes(fake).isEmpty)
        #expect(store.entries[id]?.ingest != nil, "deuxième rejet : la preuve n'est pas ré-effacée")
        #expect(hooks.ingestRequests == afterFirst, "et aucune nouvelle passe n'est demandée")
    }

    /// Une requête de vérification par archivage, pas une par entrée éligible.
    @Test func theVerifierIsConsultedOnlyForTheEntryThatLeaves() throws {
        let hooks = IngestHooks()
        let (session, fake, store, root) = try makeLockedSession(hooks: hooks, verifier: { entry in
            hooks.verifierCalls.append(entry.id.index)
            return true
        })
        defer { try? FileManager.default.removeItem(at: root) }
        let files = [fileEntry(fileIndex: 21), fileEntry(fileIndex: 22), fileEntry(fileIndex: 23)]
        for file in files { prove(try holdDelivered(file, in: store), in: store) }

        deliverManifest(session, fake, files)

        #expect(archivedIndexes(fake).count == 1)
        #expect(hooks.verifierCalls.count == 1)
    }

    @Test func skippedAndFailedProofsAreNotCheckedAgainstTheDatabase() throws {
        let hooks = IngestHooks()
        let (session, fake, store, root) = try makeLockedSession(hooks: hooks, verifier: { entry in
            hooks.verifierCalls.append(entry.id.index)
            return false
        })
        defer { try? FileManager.default.removeItem(at: root) }
        let a = fileEntry(fileIndex: 21), b = fileEntry(fileIndex: 22)
        prove(try holdDelivered(a, in: store), .skipped, in: store)
        prove(try holdDelivered(b, in: store), .failed, in: store)

        deliverManifest(session, fake, [a, b])

        #expect(archivedIndexes(fake).count == 1, "rien à confirmer en base pour skipped/failed")
        #expect(hooks.verifierCalls.isEmpty)
    }

    /// Une passe d'ingestion est demandée dès qu'un fichier est acquis (puis à la
    /// fin de la traversée), sans attendre la fin de la traversée.
    @Test func acquiringAFileRequestsALocalIngestion() throws {
        let hooks = IngestHooks()
        let (session, fake, store, root) = try makeLockedSession(hooks: hooks)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = fileEntry(fileIndex: 30, sizeBytes: 16)

        deliverManifest(session, fake, [file])
        let beforeDownload = hooks.ingestRequests
        fake.deliver(messageType: Wire.response, payload: downloadRequestStatusPayload(maxFileSize: 16))
        let content = syntheticContent(16)
        fake.deliver(messageType: Wire.fileTransferData, payload: fileTransferDataPayload(dataOffset: 0, crc: Crc16.compute(content), chunk: content))

        #expect(store.entries.count == 1)
        #expect(hooks.ingestRequests == beforeDownload + 2, "une demande à l'acquisition, une à la fin de la traversée")
    }
}
