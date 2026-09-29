//
//  ActivitiesExtractorTests.swift
//  allTests
//
//  Valide l'incrément L3 (`docs/stockage-local.md`) : l'extracteur d'activité
//  maison (`Local/Fit/FitActivityExtractor.swift`) face aux 2 échantillons
//  d'activité réels dont on dispose avec des segments non triviaux
//  (`custom-connect/samples/*.fit` — lecture de `.fit` déjà présents
//  localement, exception explicite de CLAUDE.md), l'ingestion
//  (`LocalIngestor`/`LocalDb.storeActivity`), et les routes
//  `GET api/activities`/`GET api/activities/:id` (`RealLocalPulseBackend`).
//
//  Références : sortie RÉELLE du SDK Garmin officiel
//  (`custom-connect/server/node_modules/@garmin/fitsdk`, déjà installé
//  localement), avec un script jetable (scratchpad de session, jamais
//  commité) qui réimplémente `extractSummary`/`parseDetail`
//  (`fit-parser.service.ts`) EN JS sur les messages décodés par le SDK —
//  même méthode que L1 (`FitDecoderTests.swift`) et L2
//  (`LocalDayDetailTests.swift`, `body-battery.ts` compilé avec `tsc`) :
//  comparer contre une sortie réelle du côté serveur, jamais recalculer à la
//  main. Cf. rapport d'incrément L3 pour le détail.
//

import Testing
import Foundation
@testable import all

private enum ActivitySample {
    static let root = "/Users/alielmufti/Documents/Projects/custom-connect/samples"

    /// Course à pied avec GPS — session/12 laps/18 splits/zones de FC,
    /// aucune série (`setMesgs`).
    static let running = "\(root)/user@example.com_306863786909.fit"
    /// Musculation — 34 `setMesgs` (17 "active", 17 "rest") + zones de FC,
    /// AUCUN lap/split (pas de sous-segments côté montre pour ce sport).
    static let strength = "\(root)/user@example.com_332754313137.fit"

    static func data(_ path: String) throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: path))
    }

    static func messages(_ path: String) throws -> [FitMessage] {
        try FitDecoder.decode(data(path)).messages
    }
}

// MARK: - `extractSummary` vs référence SDK

struct FitActivityExtractorSummaryTests {
    @Test func runningSummaryMatchesReferenceSdkOutput() throws {
        let summary = FitActivityExtractor.extractSummary(messages: try ActivitySample.messages(ActivitySample.running))
        #expect(summary.sport == "running")
        #expect(summary.subSport == "generic")
        #expect(summary.startTime == "2025-01-23T20:55:38.000Z")
        #expect(summary.durationS == 1960.173)
        #expect(summary.distanceM == 4636.4)
        #expect(summary.calories == 370)
        #expect(summary.avgHr == 154)
        #expect(summary.maxHr == 175)
    }

    @Test func strengthSummaryMatchesReferenceSdkOutput() throws {
        let summary = FitActivityExtractor.extractSummary(messages: try ActivitySample.messages(ActivitySample.strength))
        #expect(summary.sport == "training")
        #expect(summary.subSport == "strengthTraining")
        #expect(summary.startTime == "2025-05-05T09:41:22.000Z")
        #expect(summary.durationS == 2263.573)
        #expect(summary.distanceM == 0)
        #expect(summary.calories == 279)
        #expect(summary.avgHr == 121)
        #expect(summary.maxHr == 159)
    }
}

// MARK: - `extractDetail` (flux/laps/sets/splits/hrZones) vs référence SDK

struct FitActivityExtractorDetailTests {
    @Test func runningDetailMatchesReferenceSdkOutput() throws {
        let detail = FitActivityExtractor.extractDetail(messages: try ActivitySample.messages(ActivitySample.running))

        #expect(detail.streams.time.count == 529)
        #expect(detail.streams.time[0] == 0)
        #expect(detail.streams.time[1] == 1)
        #expect(detail.streams.time[2] == 9)
        #expect(detail.streams.hr[0] == 99)
        #expect(detail.streams.hr[1] == 102)
        #expect(detail.streams.hr[2] == 105)
        #expect(detail.streams.speed[2] == 2.146)
        #expect(detail.streams.altitude[0] == 41.799999999999955)
        #expect(detail.streams.altitude[2] == 41)
        #expect(detail.streams.time.last! == 1964)
        #expect(detail.streams.hr.last! == 139)

        #expect(detail.laps.count == 12)
        let lap1 = try #require(detail.laps.first)
        #expect(lap1.index == 1)
        #expect(lap1.durationS == 497.771)
        #expect(lap1.distanceM == 1000)
        #expect(lap1.avgHr == 145)
        #expect(lap1.maxHr == 159)

        #expect(detail.splits.count == 18)
        let split1 = try #require(detail.splits.first)
        #expect(split1.type == "rwdWalk")
        #expect(split1.durationS == 4)
        #expect(split1.ascentM == 0)
        #expect(split1.descentM == 0)
        #expect(split1.calories == 0)
        #expect(split1.avgVertSpeedMs == 0)

        #expect(detail.sets.isEmpty) // pas de séries dans une course à pied

        #expect(detail.hrZones.map(\.seconds) == [16.437, 138.705, 933.581, 865.545, 0])
        #expect(detail.hrZones.map(\.fromBpm) == [98, 117, 137, 156, 176])
        #expect(detail.hrZones.map(\.toBpm) == [117, 137, 156, 176, 195])
    }

    @Test func strengthDetailMatchesReferenceSdkOutput() throws {
        let detail = FitActivityExtractor.extractDetail(messages: try ActivitySample.messages(ActivitySample.strength))

        #expect(detail.streams.time.count == 1225)
        #expect(detail.streams.hr[0] == 98)
        #expect(detail.streams.speed[0] == nil) // pas de GPS en muscu
        #expect(detail.streams.altitude[0] == nil)
        #expect(detail.streams.time.last! == 2264)
        #expect(detail.streams.hr.last! == 132)

        #expect(detail.laps.isEmpty)
        #expect(detail.splits.isEmpty)

        // 34 `setMesgs` (17 "active" + 17 "rest") — seules les "active" sont gardées.
        #expect(detail.sets.count == 17)
        let set1 = try #require(detail.sets.first)
        #expect(set1.durationS == 54.55)
        #expect(set1.category == "tricepsExtension")
        #expect(set1.repetitions == 23)
        #expect(detail.sets[1].category == "curl")
        #expect(detail.sets[1].repetitions == 21)
        #expect(detail.sets[2].category == "row")
        #expect(detail.sets[2].repetitions == 12)

        #expect(detail.hrZones.map(\.seconds) == [643.078, 1366.652, 134.557, 15.188, 0])
        #expect(detail.hrZones.map(\.toBpm) == [117, 137, 156, 176, 195])
    }
}

// MARK: - Ingestion (`LocalIngestor` → `activities`) + routes (`RealLocalPulseBackend`)

struct ActivityIngestThenServeTests {
    private func makeDb() throws -> LocalDb {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("l3-activity-db-\(UUID().uuidString).sqlite").path
        return try LocalDb(path: path)
    }

    /// Bout-en-bout complet : ingestion (fichier acquis dans un `SpoolStore`
    /// de test) → `activities` → `GET api/activities` (liste) → `GET
    /// api/activities/:id` (détail) → décodage par le décodeur RÉEL de l'app
    /// (`PulseAPIClient.decoder`) dans les modèles RÉELS de l'écran
    /// (`ActivityListResponse`/`ActivityDetail`, `ActivityModels.swift`).
    @Test func ingestActivityThenServeListAndDetailDecodableByRealAppModels() throws {
        let spoolRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("l3-activity-spool-\(UUID().uuidString)", isDirectory: true)
        let spool = try SpoolStore(root: spoolRoot)
        let rawData = try ActivitySample.data(ActivitySample.running)
        // fileType arbitraire (4 = énum FIT `file.activity`, cohérent sans
        // être une contrainte du spool — celui-ci ne l'interprète jamais).
        let watchId = WatchFileID(fileType: 4, index: 1, name: "running.fit")
        _ = try spool.recordAcquired(watchId, relativePath: "running.fit", data: rawData)

        let db = try makeDb()
        let url = URL(fileURLWithPath: ActivitySample.running)
        let hash = try PulseUploader.sha256Hex(ofFileAt: url)
        let ingestResult = LocalIngestor.ingest(fileURL: url, hash: hash, fileName: "running.fit", into: db)
        #expect(ingestResult.kind == .activity)
        #expect(try db.activitiesCount() == 1)

        let backend = RealLocalPulseBackend(db: db, spool: spool)

        let listData = try backend.handle(method: "GET", path: "api/activities", query: [:], body: nil)
        let list = try PulseAPIClient.decoder.decode(ActivityListResponse.self, from: listData)
        #expect(list.total == 1)
        let item = try #require(list.items.first)
        #expect(item.sport == "running")
        #expect(item.durationS == 1960.173)
        #expect(item.distanceM == 4636.4)

        let detailData = try backend.handle(method: "GET", path: "api/activities/\(item.id)", query: [:], body: nil)
        let detail = try PulseAPIClient.decoder.decode(ActivityDetail.self, from: detailData)
        #expect(detail.id == item.id)
        #expect(detail.sport == "running")
        // Décision actée L3 (cf. `FitActivityExtractor`) : le parcours GPS
        // n'est JAMAIS peuplé, même quand le `.fit` brut est retrouvé.
        #expect(detail.track.isEmpty)
        #expect(detail.streams?.hr.count == 529)
        #expect(detail.streams?.time.count == 529)
        #expect(detail.laps.count == 12)
        #expect(detail.splits.count == 18)
        #expect(detail.hrZones.count == 5)
        #expect(detail.sets.isEmpty)
    }

    /// Ingère l'échantillon muscu (sets) et vérifie que le détail servi
    /// contient bien des séries nommées décodables — complète la couverture
    /// running ci-dessus sur un chemin différent (`sets` au lieu de
    /// `laps`/`splits`).
    @Test func strengthActivityDetailExposesNamedSets() throws {
        let spoolRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("l3-activity-spool-\(UUID().uuidString)", isDirectory: true)
        let spool = try SpoolStore(root: spoolRoot)
        let rawData = try ActivitySample.data(ActivitySample.strength)
        let watchId = WatchFileID(fileType: 4, index: 2, name: "strength.fit")
        _ = try spool.recordAcquired(watchId, relativePath: "strength.fit", data: rawData)

        let db = try makeDb()
        let url = URL(fileURLWithPath: ActivitySample.strength)
        let hash = try PulseUploader.sha256Hex(ofFileAt: url)
        #expect(LocalIngestor.ingest(fileURL: url, hash: hash, fileName: "strength.fit", into: db).kind == .activity)

        let backend = RealLocalPulseBackend(db: db, spool: spool)
        let listData = try backend.handle(method: "GET", path: "api/activities", query: [:], body: nil)
        let list = try PulseAPIClient.decoder.decode(ActivityListResponse.self, from: listData)
        let item = try #require(list.items.first)
        #expect(item.subSport == "strengthTraining")

        let detailData = try backend.handle(method: "GET", path: "api/activities/\(item.id)", query: [:], body: nil)
        let detail = try PulseAPIClient.decoder.decode(ActivityDetail.self, from: detailData)
        #expect(detail.sets.count == 17)
        #expect(detail.sets.first?.category == "tricepsExtension")
        #expect(detail.laps.isEmpty)
        #expect(detail.splits.isEmpty)
    }

    /// Réingérer le MÊME fichier activité deux fois ne duplique rien — dédup
    /// par `activities.file_hash` (cf. `LocalDb.isActivityImported`, PAS
    /// `imported_files` : divergence assumée vs wellness/sommeil).
    @Test func reingestingTheSameActivityIsIdempotent() throws {
        let db = try makeDb()
        let url = URL(fileURLWithPath: ActivitySample.running)
        let hash = try PulseUploader.sha256Hex(ofFileAt: url)

        let first = LocalIngestor.ingest(fileURL: url, hash: hash, fileName: "running.fit", into: db)
        #expect(first.kind == .activity)
        let second = LocalIngestor.ingest(fileURL: url, hash: hash, fileName: "running.fit", into: db)
        #expect(second.kind == .duplicate)
        #expect(try db.activitiesCount() == 1)
    }
}

// MARK: - Cas limites (`RealLocalPulseBackend`)

struct ActivityBackendEdgeCaseTests {
    private func makeDb() throws -> LocalDb {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("l3-activity-edge-db-\(UUID().uuidString).sqlite").path
        return try LocalDb(path: path)
    }

    @Test func emptyDbProducesEmptyList() throws {
        let backend = RealLocalPulseBackend(db: try makeDb())
        let data = try backend.handle(method: "GET", path: "api/activities", query: [:], body: nil)
        let list = try PulseAPIClient.decoder.decode(ActivityListResponse.self, from: data)
        #expect(list.total == 0)
        #expect(list.items.isEmpty)
    }

    @Test func unknownIdFailsCleanly() throws {
        let backend = RealLocalPulseBackend(db: try makeDb())
        #expect(throws: LocalActivityNotFoundError.self) {
            try backend.handle(method: "GET", path: "api/activities/999", query: [:], body: nil)
        }
    }

    @Test func nonNumericIdFailsCleanly() throws {
        let backend = RealLocalPulseBackend(db: try makeDb())
        #expect(throws: LocalActivityNotFoundError.self) {
            try backend.handle(method: "GET", path: "api/activities/not-an-id", query: [:], body: nil)
        }
    }

    /// Résumé présent en base mais AUCUN `SpoolStore` injecté (donc `.fit`
    /// brut introuvable) — miroir de la branche `!fs.existsSync(filePath)`
    /// côté serveur (`activities.controller.ts`) : résumé seul, `track: []`,
    /// `streams: null`, tout le reste vide.
    @Test func missingRawFileFallsBackToSummaryOnly() throws {
        let db = try makeDb()
        let messages = try ActivitySample.messages(ActivitySample.strength)
        let summary = FitActivityExtractor.extractSummary(messages: messages)
        let hash = try PulseUploader.sha256Hex(ofFileAt: URL(fileURLWithPath: ActivitySample.strength))
        let id = try db.storeActivity(summary, hash: hash, fileName: "strength.fit")

        let backend = RealLocalPulseBackend(db: db) // pas de spool → fichier introuvable
        let data = try backend.handle(method: "GET", path: "api/activities/\(id)", query: [:], body: nil)
        let detail = try PulseAPIClient.decoder.decode(ActivityDetail.self, from: data)

        #expect(detail.sport == "training")
        #expect(detail.track.isEmpty)
        #expect(detail.streams == nil)
        #expect(detail.laps.isEmpty)
        #expect(detail.sets.isEmpty)
        #expect(detail.splits.isEmpty)
        #expect(detail.hrZones.isEmpty)
    }
}

// MARK: - Sommeil (vérification — cf. rapport d'incrément L3)
//
// `SommeilViewModel` (`Pulse/Screens/Sommeil/SommeilViewModel.swift`) n'a
// besoin QUE de 3 routes déjà servies par `RealLocalPulseBackend` depuis
// L1/L2 (`wellness/dates`, `wellness/days`, `wellness/day/:date`) + un 4ᵉ
// appel `try?` best-effort (`stats/sleep-recommendation`, non implémenté ici
// — reste volontairement en échec silencieux). Couverture détaillée du
// contenu déjà dans `LocalDayDetailTests.swift` (L2) ; ce test-ci vérifie
// spécifiquement que les TROIS routes de l'écran Sommeil répondent, avec les
// query params EXACTS que `SommeilViewModel.load()` envoie
// (`wellness/days?limit=30&days=30`, `days` étant un paramètre en trop
// ignoré côté backend local — pas d'erreur pour autant).
struct SommeilRouteCoverageTests {
    private enum WellnessSample {
        static let root = "/Users/alielmufti/Documents/Projects/custom-connect/samples"
        static let wellness1 = "\(root)/user@example.com_263438980021.fit"
    }

    /// CAVEAT connu (déjà noté en L1) : aucun `.fit` "sommeil" (`fileId.type
    /// == 49`) dans les échantillons disponibles — le décodage `sleepLevel`/
    /// `sleepAssessment`/l'événement `start`/`data16` n'est donc validé QUE
    /// structurellement (types/échelles du profil), jamais contre une vraie
    /// nuit. Ce test-ci confirme seulement que le bloc `sleep` du JSON EST
    /// bien présent et décodable (vide, en l'absence de nuit) — pas que son
    /// contenu est correct sur une vraie nuit. Toujours vrai après L3.
    @Test func sommeilViewModelRoutesAllRespond() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("l3-sommeil-coverage-\(UUID().uuidString).sqlite").path
        let db = try LocalDb(path: path)
        let url = URL(fileURLWithPath: WellnessSample.wellness1)
        let hash = try PulseUploader.sha256Hex(ofFileAt: url)
        #expect(LocalIngestor.ingest(fileURL: url, hash: hash, fileName: "w.fit", into: db).kind == .wellness)

        let backend = RealLocalPulseBackend(db: db)

        let datesData = try backend.handle(method: "GET", path: "api/wellness/dates", query: [:], body: nil)
        let dates = try PulseAPIClient.decoder.decode([String].self, from: datesData)
        #expect(!dates.isEmpty)

        let daysData = try backend.handle(
            method: "GET", path: "api/wellness/days", query: ["limit": "30", "days": "30"], body: nil)
        let days = try PulseAPIClient.decoder.decode([WellnessDayRow].self, from: daysData)
        #expect(!days.isEmpty)

        let dayData = try backend.handle(
            method: "GET", path: "api/wellness/day/\(dates[0])", query: [:], body: nil)
        let day = try PulseAPIClient.decoder.decode(WellnessDayDetail.self, from: dayData)
        #expect(day.date == dates[0])
        // Bloc `sleep` présent et décodable (vide ici, cf. CAVEAT ci-dessus).
        #expect(day.sleep.stages.isEmpty)
        #expect(day.sleep.main == nil)

        // `stats/sleep-recommendation` : jamais servie localement (`try?`
        // côté `SommeilViewModel`) — `RealLocalPulseBackend` doit échouer
        // proprement, pas planter, sur cette route non portée.
        #expect(throws: LocalPulseUnavailableError.self) {
            try backend.handle(method: "GET", path: "api/stats/sleep-recommendation", query: ["days": "30"], body: nil)
        }
    }
}
