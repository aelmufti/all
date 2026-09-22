//
//  GarminProtocolTests.swift
//  allTests
//
//  Couvre les briques pures du portage de la poignée de main GFDI V2 et du
//  listing du manifeste directory : lecture/écriture d'octets LE, parsing du
//  manifeste (16 octets/entrée), et les helpers protobuf codés en dur
//  (varint/champ de service — ProtobufAck.java côté pont). Pas de test BLE ici :
//  CoreBluetooth ne se simule pas, cf. incrément 1 (harnais sur device réel).
//

import Testing
import Foundation
@testable import all

struct GarminByteIOTests {
    @Test func roundTripIntegers() {
        var writer = GarminByteWriter()
        writer.writeUInt8(0x7F)
        writer.writeUInt16LE(0x1234)
        writer.writeUInt32LE(0xDEAD_BEEF)
        writer.writeUInt64LE(0x0102_0304_0506_0708)
        writer.writeInt32LE(-1)

        var reader = GarminByteReader(writer.data)
        #expect(reader.readUInt8() == 0x7F)
        #expect(reader.readUInt16LE() == 0x1234)
        #expect(reader.readUInt32LE() == 0xDEAD_BEEF)
        #expect(reader.readUInt64LE() == 0x0102_0304_0506_0708)
        #expect(reader.readUInt32LE() == 0xFFFF_FFFF) // -1 relu comme UInt32
        #expect(reader.remaining == 0)
    }

    @Test func pascalStringRoundTrip() {
        var writer = GarminByteWriter()
        writer.writePascalString("bridge-connect")
        var reader = GarminByteReader(writer.data)
        #expect(reader.readPascalString() == "bridge-connect")
    }

    @Test func readsFailGracefullyPastEnd() {
        var reader = GarminByteReader(Data([0x01]))
        #expect(reader.readUInt8() == 0x01)
        #expect(reader.readUInt8() == nil)
        #expect(reader.readUInt16LE() == nil)
    }
}

struct GarminDirectoryParserTests {
    /// Construit une entrée de 16 octets, comme le manifeste que la montre
    /// renvoie (FileTransferHandler.Download.parseDirectoryEntries côté pont).
    private func entryBytes(fileIndex: UInt16, dataType: UInt8, subType: UInt8, fileNumber: UInt16, fileSize: UInt32, timestamp: UInt32) -> Data {
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

    @Test func parsesActivityEntryWithDate() {
        // 2024-01-01T00:00:00Z en epoch Garmin = epoch Unix − 631065600.
        let unixSeconds: UInt32 = 1_704_067_200
        let garminTs = UInt32(TimeInterval(unixSeconds) - GarminEpoch.offsetFromUnix)
        let data = entryBytes(fileIndex: 42, dataType: 128, subType: 4, fileNumber: 7, fileSize: 12345, timestamp: garminTs)

        let entries = GarminDirectoryParser.parse(data)
        #expect(entries.count == 1)
        let entry = entries[0]
        #expect(entry.fileIndex == 42)
        #expect(entry.typeName == "ACTIVITY")
        #expect(entry.sizeBytes == 12345)
        #expect(entry.date != nil)
        if let date = entry.date {
            #expect(abs(date.timeIntervalSince1970 - TimeInterval(unixSeconds)) < 1)
        }
    }

    @Test func timestampZeroMeansNoDate() {
        let data = entryBytes(fileIndex: 1, dataType: 128, subType: 32, fileNumber: 1, fileSize: 100, timestamp: 0)
        let entries = GarminDirectoryParser.parse(data)
        #expect(entries.count == 1)
        #expect(entries[0].date == nil)
        #expect(entries[0].typeName == "MONITOR")
    }

    @Test func unknownTypeFallsBackToTypeSubtypeLabel() {
        let data = entryBytes(fileIndex: 2, dataType: 200, subType: 9, fileNumber: 1, fileSize: 1, timestamp: 0)
        let entries = GarminDirectoryParser.parse(data)
        #expect(entries.count == 1)
        #expect(entries[0].typeName == "TYPE_200_9")
    }

    @Test func allZeroEntryIsDroppedAsAntiLoopSentinel() {
        let data = entryBytes(fileIndex: 0, dataType: 0, subType: 0, fileNumber: 0, fileSize: 0, timestamp: 0)
        #expect(GarminDirectoryParser.parse(data).isEmpty)
    }

    @Test func multipleEntriesParsedInOrder() {
        var data = Data()
        data.append(entryBytes(fileIndex: 1, dataType: 128, subType: 4, fileNumber: 1, fileSize: 10, timestamp: 0))
        data.append(entryBytes(fileIndex: 2, dataType: 128, subType: 49, fileNumber: 2, fileSize: 20, timestamp: 0))
        let entries = GarminDirectoryParser.parse(data)
        #expect(entries.map(\.fileIndex) == [1, 2])
        #expect(entries.map(\.typeName) == ["ACTIVITY", "SLEEP"])
    }

    @Test func lengthNotMultipleOf16YieldsNoEntries() {
        #expect(GarminDirectoryParser.parse(Data([0x01, 0x02, 0x03])).isEmpty)
    }
}

struct GarminProtobufAckTests {
    // Champ 1 = 0x0A (tag), longueur 4 -> clé varint = 0x0A -> field number 1.
    @Test func fieldNumberDecodesCalendarService() {
        let payload = Data([0x0A, 0x02, 0x08, 0x01]) // Smart{ calendar_service(1){...} }
        let key = GarminSession.firstVarint(payload)
        #expect(GarminSession.protobufFieldNumber(key) == 1)
        #expect(GarminSession.protobufInnerField(payload) == 1)
    }

    @Test func cannedResponseMatchesKnownCombinations() {
        #expect(GarminSession.cannedProtobufResponse(service: 1, inner: 1) == Data([0x0A, 0x04, 0x12, 0x02, 0x08, 0x01]))
        #expect(GarminSession.cannedProtobufResponse(service: 13, inner: 3) == Data([0x6A, 0x04, 0x22, 0x02, 0x08, 0x02]))
        #expect(GarminSession.cannedProtobufResponse(service: 13, inner: 5) == Data([0x6A, 0x04, 0x32, 0x02, 0x08, 0x01]))
        #expect(GarminSession.cannedProtobufResponse(service: 16, inner: 4) == Data([0x82, 0x01, 0x04, 0x2A, 0x02, 0x08, 0x00]))
    }

    /// Champ 42 (GdiSettingsService) : connu (accusé KEPT) mais délibérément
    /// sans réponse canée — ne répond jamais applicativement sur Venu 2 fw 19.05
    /// (cf. CLAUDE.md), comme `ProtobufAck.responseFor` côté pont qui n'a pas de
    /// cas pour ce service.
    @Test func service42IsKnownButHasNoCannedResponse() {
        #expect(GarminSession.knownProtobufServices.contains(42))
        #expect(GarminSession.cannedProtobufResponse(service: 42, inner: 0) == nil)
        #expect(GarminSession.cannedProtobufResponse(service: 42, inner: 1) == nil)
    }

    @Test func unknownServiceHasNoCannedResponseAndIsNotInKnownSet() {
        #expect(!GarminSession.knownProtobufServices.contains(99))
        #expect(GarminSession.cannedProtobufResponse(service: 99, inner: 0) == nil)
    }
}

/// Couvre `FileTransferReassembler` — le cœur de la reprise de fragment
/// perdu/dupliqué (cf. `GarminSession.handleFileTransferData`). Vecteurs alignés
/// sur `GarminSessionDownloadTest` côté pont (net.garminbridge.session,
/// AGPL-3.0) : `ONE_ENTRY_DIRECTORY` (16 o, `directoryEntry(1458, 128, 4, 1024)`),
/// coupée en deux moitiés de 8 — mêmes offsets attendus (`List.of(8, 8)`) pour
/// les scénarios doublon/reprise que ceux du test Java de référence.
struct FileTransferReassemblerTests {
    /// Une entrée de manifeste de 16 octets, comme `ONE_ENTRY_DIRECTORY` côté pont.
    private static func oneEntryDirectory() -> Data {
        var writer = GarminByteWriter()
        writer.writeUInt16LE(1458) // fileIndex
        writer.writeUInt8(128) // dataType
        writer.writeUInt8(4) // subType
        writer.writeUInt16LE(1458) // fileNumber
        writer.writeUInt8(0) // specificFlags
        writer.writeUInt8(0) // fileFlags
        writer.writeUInt32LE(1024) // fileSize
        writer.writeUInt32LE(0) // timestamp
        return writer.data
    }

    private static var firstHalf: Data { oneEntryDirectory().prefix(8) }
    private static var secondHalf: Data { oneEntryDirectory().suffix(8) }
    private static var crcOfFirstHalf: UInt16 { Crc16.compute(firstHalf) }

    @Test func sequentialFragmentsCompleteTheTransfer() {
        var reassembler = FileTransferReassembler(expectedSize: 16)

        let first = reassembler.receive(dataOffset: 0, crc: Crc16.compute(Self.firstHalf), chunk: Self.firstHalf)
        #expect(first == .appended(ackOffset: 8, complete: false))

        let second = reassembler.receive(dataOffset: 8, crc: Crc16.compute(Self.secondHalf, initial: Self.crcOfFirstHalf), chunk: Self.secondHalf)
        #expect(second == .appended(ackOffset: 16, complete: true))
        #expect(reassembler.buffer == Self.oneEntryDirectory())
    }

    /// Porte `tellsTheWatchWhereWeAreWhenSheSendsAFragmentTwiceRatherThanGoingSilent`.
    @Test func duplicateFragmentIsReAckedWithoutBeingReapplied() {
        var reassembler = FileTransferReassembler(expectedSize: 16)
        _ = reassembler.receive(dataOffset: 0, crc: Crc16.compute(Self.firstHalf), chunk: Self.firstHalf)

        // La montre renvoie exactement le même fragment (notre ack s'est perdu ou
        // est arrivé en retard) : ré-accuser notre offset courant sans réappliquer.
        let action = reassembler.receive(dataOffset: 0, crc: Crc16.compute(Self.firstHalf), chunk: Self.firstHalf)
        #expect(action == .reAck(offset: 8))
        #expect(reassembler.buffer.count == 8, "le doublon ne doit pas être réappliqué")
    }

    /// Porte `asksTheWatchToResumeWhereWeAreWhenAFragmentNeverArrived`.
    @Test func lostFragmentAsksTheWatchToResumeAtOurOffset() {
        var reassembler = FileTransferReassembler(expectedSize: 16)
        _ = reassembler.receive(dataOffset: 0, crc: Crc16.compute(Self.firstHalf), chunk: Self.firstHalf)

        // Les octets 8..11 ne sont jamais arrivés ; la montre envoie déjà depuis 12.
        let tooFar = Self.oneEntryDirectory().subdata(in: 12..<16)
        let action = reassembler.receive(dataOffset: 12, crc: 0, chunk: tooFar)
        #expect(action == .reAck(offset: 8), "on est toujours à 8, et c'est ce qu'on doit répéter")
        #expect(reassembler.buffer.count == 8)

        // Reprend bien à 8 une fois la montre revenue au bon offset.
        let resumed = reassembler.receive(dataOffset: 8, crc: Crc16.compute(Self.secondHalf, initial: Self.crcOfFirstHalf), chunk: Self.secondHalf)
        #expect(resumed == .appended(ackOffset: 16, complete: true))
    }

    /// HYPOTHÈSE non vérifiée matériel (cf. `FileTransferReassembler`) : un CRC
    /// invalide à l'offset attendu est traité comme un fragment à redemander
    /// plutôt qu'une panne fatale (le pont vendoré lèverait ici).
    @Test func invalidCrcAtExpectedOffsetIsNotAppliedAndReAsksTheSameOffset() {
        var reassembler = FileTransferReassembler(expectedSize: 16)
        let action = reassembler.receive(dataOffset: 0, crc: 0xFFFF, chunk: Self.firstHalf)
        #expect(action == .reAck(offset: 0))
        #expect(reassembler.buffer.isEmpty)
    }

    @Test func expectedSizeZeroIsImmediatelyComplete() {
        let reassembler = FileTransferReassembler(expectedSize: 0)
        #expect(reassembler.isComplete)
    }
}

/// Couvre `SpoolStore.recordAcquired` + le nommage canonique (`GarminUtils.buildExportPath`
/// côté pont). Chaque test pointe vers un répertoire temporaire (`SpoolStore.init(root:)`,
/// l'init interne testable) plutôt que l'Application Support réelle.
struct SpoolStoreRecordAcquiredTests {
    private func makeTempStore() throws -> (store: SpoolStore, root: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bridge-connect-spool-tests-\(UUID().uuidString)", isDirectory: true)
        return (try SpoolStore(root: root), root)
    }

    private func sampleEntry(fileIndex: Int = 42, garminTimestamp: UInt32 = 0) -> GarminDirectoryEntry {
        GarminDirectoryEntry(
            fileIndex: fileIndex, dataType: 128, subType: 4, fileNumber: fileIndex,
            sizeBytes: 6, garminTimestamp: garminTimestamp)!
    }

    @Test func recordAcquiredWritesTheFileAndTheJournalEntry() throws {
        let (store, root) = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let entry = sampleEntry()
        let (id, relativePath) = SpoolStore.identity(for: entry)
        let data = Data("pas vraiment un FIT".utf8)

        try store.recordAcquired(id, relativePath: relativePath, data: data)

        #expect(store.entries[id]?.state == .acquired)
        #expect(store.entries[id]?.relativePath == relativePath)

        let onDisk = try Data(contentsOf: root.appendingPathComponent("files").appendingPathComponent(relativePath))
        #expect(onDisk == data)
    }

    /// « relit le journal » : une seconde instance pointée sur la même racine
    /// doit retrouver l'entrée `acquired` persistée par la première.
    @Test func recordAcquiredPersistsAcrossAFreshInstance() throws {
        let (store, root) = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let entry = sampleEntry(fileIndex: 5)
        let (id, relativePath) = SpoolStore.identity(for: entry)
        try store.recordAcquired(id, relativePath: relativePath, data: Data("x".utf8))

        let reloaded = try SpoolStore(root: root)
        #expect(reloaded.entries[id]?.state == .acquired)
        #expect(reloaded.entries[id]?.relativePath == relativePath)
    }

    @Test func canonicalRelativePathIncludesYearSubfolderWhenDated() {
        // 2024-01-01T00:00:00Z en epoch Garmin, comme GarminDirectoryParserTests.
        let unixSeconds: UInt32 = 1_704_067_200
        let garminTs = UInt32(TimeInterval(unixSeconds) - GarminEpoch.offsetFromUnix)
        let entry = sampleEntry(fileIndex: 7, garminTimestamp: garminTs)

        #expect(SpoolStore.canonicalRelativePath(for: entry) == "ACTIVITY/2024/ACTIVITY_2024-01-01_00-00-00_7.fit")
    }

    @Test func canonicalRelativePathOmitsYearWhenUndated() {
        let entry = sampleEntry(fileIndex: 9, garminTimestamp: 0)
        #expect(SpoolStore.canonicalRelativePath(for: entry) == "ACTIVITY/ACTIVITY_9.fit")
    }

    @Test func identityNameIsTheBasenameNotTheFullPath() {
        let entry = sampleEntry(fileIndex: 9, garminTimestamp: 0)
        let (id, relativePath) = SpoolStore.identity(for: entry)
        #expect(id.name == "ACTIVITY_9.fit")
        #expect(relativePath == "ACTIVITY/ACTIVITY_9.fit")
        #expect(id.index == 9)
        #expect(id.fileType == (128 << 8) | 4)
    }
}

struct GarminCapabilitiesBitfieldTests {
    /// Porté de `GarminCapability.OUR_CAPABILITIES` : 120 indicateurs (15
    /// octets), tous à 1 sauf les 14 réservés retirés côté pont.
    @Test func bitfieldHas15BytesWithExactlyTheReservedBitsCleared() {
        let bitfield = GarminSession.ourCapabilitiesBitfield()
        #expect(bitfield.count == 15)

        let cleared: Set<Int> = [104, 105, 106, 107, 108, 109, 110, 111, 114, 115, 116, 117, 118, 119]
        let bytes = [UInt8](bitfield)
        for bit in 0..<120 {
            let isSet = (bytes[bit / 8] & (1 << (bit % 8))) != 0
            #expect(isSet == !cleared.contains(bit), "bit \(bit) devrait être \(cleared.contains(bit) ? "à 0" : "à 1")")
        }
    }
}
