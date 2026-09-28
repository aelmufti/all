//
//  FitDecoderTests.swift
//  allTests
//
//  Valide le décodeur FIT maison (`Local/Fit/*.swift`) et le pipeline
//  d'ingestion locale (`Local/LocalIngestor.swift`, `Local/Db/LocalDb.swift`)
//  face aux `.fit` d'exemple réels (`custom-connect/samples/*.fit` — lecture
//  de fichiers `.fit` déjà présents localement, exception explicite de
//  CLAUDE.md). Les valeurs attendues viennent d'un décodage RÉEL de ces
//  mêmes fichiers avec le SDK Garmin officiel, déjà installé localement
//  (`custom-connect/server/node_modules/@garmin/fitsdk`, script de
//  validation dans le scratchpad de session, aucun réseau) — cf. rapport
//  d'incrément L1 (`docs/stockage-local.md`) pour le détail de la méthode.
//
//  Fichiers échantillons référencés par CHEMIN ABSOLU (poste de dev) plutôt
//  que copiés dans le bundle de test : ce sont des données personnelles de
//  santé, autant ne pas en dupliquer une copie dans le dépôt git — même
//  logique que l'exception CLAUDE.md qui autorise la LECTURE de `.fit`
//  déjà présents dans les dépôts, pas leur recopie ailleurs.
//

import Testing
import Foundation
@testable import all

private enum Sample {
    static let root = "/Users/alielmufti/Documents/Projects/custom-connect/samples"

    /// Fichier bien-être (`monitoringB`) #1 — 2024-07-02/03, sans SpO2.
    static let wellness1 = "\(root)/user@example.com_263438980021.fit"
    /// Fichier bien-être (`monitoringB`) #2 — 2026-06-19, avec SpO2.
    static let wellness2 = "\(root)/user@example.com_450570856748.fit"
    /// Trois fichiers d'activité (GPS/sessions) — hors périmètre L1, servent
    /// juste à vérifier que le décodeur ne plante pas sur des messages
    /// inconnus (records/laps/gpsMetadata…) et lit l'en-tête/CRC/fileId.
    static let activities = [
        "\(root)/user@example.com_306863786909.fit",
        "\(root)/user@example.com_307525865897.fit",
        "\(root)/user@example.com_332754313137.fit",
    ]

    static func data(_ path: String) throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: path))
    }
}

// MARK: - En-tête / CRC / fileId (les 5 échantillons)

struct FitDecoderHeaderTests {
    @Test func decodesHeaderAndCrcForAllSamples() throws {
        for path in [Sample.wellness1, Sample.wellness2] + Sample.activities {
            let file = try FitDecoder.decode(Sample.data(path))
            #expect(file.crcValid, "CRC invalide pour \((path as NSString).lastPathComponent)")
            #expect(!file.messages.isEmpty)
            let fileId = file.messages.first { $0.globalMessageNumber == FitProfile.mesgFileId }
            #expect(fileId != nil, "message fileId absent pour \((path as NSString).lastPathComponent)")
        }
    }

    @Test func classifiesMonitoringBFiles() throws {
        for path in [Sample.wellness1, Sample.wellness2] {
            let file = try FitDecoder.decode(Sample.data(path))
            let type = file.messages.first { $0.globalMessageNumber == FitProfile.mesgFileId }?.double(0)
            #expect(type == FitProfile.fileTypeMonitoringB)
        }
    }

    /// Les fichiers d'activité (type `activity`, valeur d'énum 4) ne sont ni
    /// wellness (32) ni sleep (49) — `LocalIngestor` doit les classer
    /// `.skipped`, pas planter dessus malgré leurs milliers de messages
    /// `record`/`gpsMetadata` (hors profil connu, décodés génériquement).
    @Test func activityFilesDecodeWithoutCrashingAndAreNotWellnessOrSleep() throws {
        for path in Sample.activities {
            let file = try FitDecoder.decode(Sample.data(path))
            let type = file.messages.first { $0.globalMessageNumber == FitProfile.mesgFileId }?.double(0)
            #expect(type != nil)
            #expect(type != FitProfile.fileTypeMonitoringB)
            #expect(type != FitProfile.fileTypeSleep)
        }
    }
}

// MARK: - `extractWellness` vs référence SDK

struct FitWellnessExtractorTests {
    @Test func wellness1MatchesReferenceCountsAndSamples() throws {
        let file = try FitDecoder.decode(Sample.data(Sample.wellness1))
        let data = FitWellnessExtractor.extractWellness(messages: file.messages)

        let hr = data.samples.filter { $0.metric == "hr" }
        let stress = data.samples.filter { $0.metric == "stress" }
        let spo2 = data.samples.filter { $0.metric == "spo2" }
        let respiration = data.samples.filter { $0.metric == "respiration" }

        #expect(hr.count == 160)
        #expect(stress.count == 104)
        #expect(spo2.count == 0) // ce fichier n'a pas de message spo2Data
        #expect(respiration.count == 110)

        let sortedHr = hr.sorted { $0.ts < $1.ts }
        #expect(sortedHr.first?.ts == 1_719_941_640)
        #expect(sortedHr.first?.value == 76)
        #expect(sortedHr.last?.ts == 1_719_957_600)
        #expect(sortedHr.last?.value == 66)
    }

    @Test func wellness1MatchesReferenceDaysAndCounters() throws {
        let file = try FitDecoder.decode(Sample.data(Sample.wellness1))
        let data = FitWellnessExtractor.extractWellness(messages: file.messages)

        let daysByDate = Dictionary(uniqueKeysWithValues: data.days.map { ($0.date, $0) })
        #expect(daysByDate["2024-07-02"]?.restingHr == 48)
        #expect(daysByDate["2024-07-02"]?.bmrKcal == 2280)
        #expect(daysByDate["2024-07-03"]?.restingHr == 48)
        #expect(daysByDate["2024-07-03"]?.bmrKcal == nil)

        let countersByKey = Dictionary(uniqueKeysWithValues: data.counters.map { ("\($0.date)|\($0.activityType)", $0) })
        let generic = try #require(countersByKey["2024-07-02|generic"])
        #expect(generic.steps == nil)
        #expect(generic.activeCalories == 100)
        #expect(generic.distanceM == 0)
        #expect(generic.activeTimeS == 1385)

        let walking = try #require(countersByKey["2024-07-02|walking"])
        #expect(walking.steps == 9647)
        #expect(walking.activeCalories == 468)
        #expect(walking.distanceM == 8207.72)
        #expect(walking.activeTimeS == 6575)

        let running = try #require(countersByKey["2024-07-02|running"])
        #expect(running.steps == 3)
        #expect(running.activeCalories == 0)
        #expect(running.distanceM == 3.83)
        #expect(running.activeTimeS == 2)
    }

    @Test func wellness2MatchesReferenceCountsAndSamples() throws {
        let file = try FitDecoder.decode(Sample.data(Sample.wellness2))
        let data = FitWellnessExtractor.extractWellness(messages: file.messages)

        let hr = data.samples.filter { $0.metric == "hr" }
        let stress = data.samples.filter { $0.metric == "stress" }
        let spo2 = data.samples.filter { $0.metric == "spo2" }
        let respiration = data.samples.filter { $0.metric == "respiration" }

        #expect(hr.count == 413)
        #expect(stress.count == 517)
        #expect(spo2.count == 515)
        #expect(respiration.count == 517)

        let sortedHr = hr.sorted { $0.ts < $1.ts }
        #expect(sortedHr.first?.ts == 1_781_820_600)
        #expect(sortedHr.first?.value == 78)
        #expect(sortedHr.last?.ts == 1_781_852_460)
        #expect(sortedHr.last?.value == 72)
    }

    @Test func wellness2MatchesReferenceDaysAndCounters() throws {
        let file = try FitDecoder.decode(Sample.data(Sample.wellness2))
        let data = FitWellnessExtractor.extractWellness(messages: file.messages)

        let daysByDate = Dictionary(uniqueKeysWithValues: data.days.map { ($0.date, $0) })
        #expect(daysByDate["2026-06-19"]?.restingHr == 51)
        #expect(daysByDate["2026-06-19"]?.bmrKcal == 2365)

        let countersByKey = Dictionary(uniqueKeysWithValues: data.counters.map { ("\($0.date)|\($0.activityType)", $0) })
        let walking = try #require(countersByKey["2026-06-19|walking"])
        #expect(walking.steps == 110)
        #expect(walking.activeCalories == 15)
        #expect(walking.distanceM == 93.6)
        #expect(walking.activeTimeS == 368)
    }

    /// Aucun des 5 échantillons ne contient de fichier "sommeil" (ni
    /// `sleepLevelMesgs`, ni fileId.type == 49) — `extractSleep` doit
    /// simplement renvoyer `nil` sur un fichier bien-être plutôt que planter,
    /// exactement comme `FitParserService.extractSleep` côté serveur (`levels.length === 0 → null`).
    /// Cf. rapport d'incrément : le chemin sommeil n'est donc validé qu'au
    /// niveau structurel (types/champs du profil), pas contre une vraie nuit.
    @Test func extractSleepReturnsNilOnWellnessFiles() throws {
        for path in [Sample.wellness1, Sample.wellness2] {
            let file = try FitDecoder.decode(Sample.data(path))
            #expect(FitWellnessExtractor.extractSleep(messages: file.messages) == nil)
        }
    }
}

// MARK: - Ingestion locale bout-en-bout (décodeur → `LocalDb`)

struct LocalIngestorTests {
    private func makeDb() throws -> LocalDb {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-pulse-tests-\(UUID().uuidString).sqlite").path
        return try LocalDb(path: path)
    }

    @Test func ingestsWellnessFileIntoLocalDb() throws {
        let db = try makeDb()
        let url = URL(fileURLWithPath: Sample.wellness1)
        let hash = try PulseUploader.sha256Hex(ofFileAt: url)

        let result = LocalIngestor.ingest(fileURL: url, hash: hash, fileName: "wellness1.fit", into: db)
        #expect(result.kind == .wellness)

        #expect(try db.dates() == ["2024-07-02", "2024-07-03"])
        #expect(try db.sampleCount(metric: "hr") == 160)
        #expect(try db.sampleCount(metric: "stress") == 104)
        #expect(try db.sampleCount(metric: "respiration") == 110)

        let days = try db.days(limit: 30)
        let day1 = try #require(days.first { $0.date == "2024-07-02" })
        #expect(day1.restingHr == 48)
        #expect(day1.bmrKcal == 2280)
        // steps/activeCalories du jour = somme des compteurs par type
        // d'activité (generic+walking+running), cf. `WellnessController.days`.
        #expect(day1.steps == 9650) // 9647 (walking) + 3 (running)
        #expect(day1.activeCalories == 568) // 100 + 468 + 0
    }

    /// Rejouer le MÊME fichier deux fois ne duplique rien — dédup par hash
    /// (`imported_files`), même contrat que Pulse (`IngestService.ingestBuffer`).
    @Test func reingestingTheSameFileIsIdempotent() throws {
        let db = try makeDb()
        let url = URL(fileURLWithPath: Sample.wellness1)
        let hash = try PulseUploader.sha256Hex(ofFileAt: url)

        let first = LocalIngestor.ingest(fileURL: url, hash: hash, fileName: "wellness1.fit", into: db)
        #expect(first.kind == .wellness)
        let second = LocalIngestor.ingest(fileURL: url, hash: hash, fileName: "wellness1.fit", into: db)
        #expect(second.kind == .duplicate)

        #expect(try db.sampleCount(metric: "hr") == 160) // pas doublé
    }

    /// Un fichier d'activité (hors périmètre bien-être L1) est ingéré
    /// (décodé sans erreur) mais n'écrit rien — `.skipped`, comme côté Pulse
    /// (`IngestService.ingestBuffer`, branche `kind === 'other'`).
    @Test func activityFileIsSkippedNotErrored() throws {
        let db = try makeDb()
        let url = URL(fileURLWithPath: Sample.activities[0])
        let hash = try PulseUploader.sha256Hex(ofFileAt: url)

        let result = LocalIngestor.ingest(fileURL: url, hash: hash, fileName: "activity.fit", into: db)
        #expect(result.kind == .skipped)
        #expect(try db.dates().isEmpty)
    }
}

// MARK: - `RealLocalPulseBackend` (routes `wellness/days`/`wellness/dates`)

struct RealLocalPulseBackendTests {
    @Test func serveDatesAndDaysAfterIngestion() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-pulse-backend-tests-\(UUID().uuidString).sqlite").path
        let db = try LocalDb(path: path)
        let url = URL(fileURLWithPath: Sample.wellness1)
        let hash = try PulseUploader.sha256Hex(ofFileAt: url)
        #expect(LocalIngestor.ingest(fileURL: url, hash: hash, fileName: "w.fit", into: db).kind == .wellness)

        let backend = RealLocalPulseBackend(db: db)

        let datesData = try backend.handle(method: "GET", path: "api/wellness/dates", query: [:], body: nil)
        let dates = try PulseAPIClient.decoder.decode([String].self, from: datesData)
        #expect(dates == ["2024-07-02", "2024-07-03"])

        let daysData = try backend.handle(method: "GET", path: "api/wellness/days", query: ["limit": "30"], body: nil)
        let days = try PulseAPIClient.decoder.decode([WellnessDayRow].self, from: daysData)
        let day1 = try #require(days.first { $0.date == "2024-07-02" })
        #expect(day1.restingHr == 48)
        #expect(day1.bmrKcal == 2280)
        #expect(day1.steps == 9650)
        #expect(day1.bodyBatteryHigh == nil) // non implémenté en L1, cf. rapport

        // `wellness/day/:date` : portée à L2, cf. `LocalDayDetailTests.swift`
        // pour la couverture détaillée. Ici, juste vérifier qu'une route
        // encore non portée (L3+, ex. sommeil détaillé) échoue toujours
        // proprement, pas de crash.
        #expect(throws: LocalPulseUnavailableError.self) {
            try backend.handle(method: "GET", path: "api/wellness/sleep-export/2024-07-02", query: [:], body: nil)
        }
    }
}
