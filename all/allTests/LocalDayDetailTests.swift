//
//  LocalDayDetailTests.swift
//  allTests
//
//  Valide l'incrément L2 (`docs/stockage-local.md`) : `GET api/wellness/day/:date`
//  servi par `RealLocalPulseBackend`/`LocalDb.dayDetail`, et le simulateur de
//  pivot d'énergie corporelle (`Local/BodyBattery.swift`, portage de
//  `custom-connect/server/src/wellness/body-battery.ts`).
//
//  Références body-battery : la fonction `simulateBodyBatteryPivot` (TS) a
//  été compilée avec `tsc` (déjà installé localement,
//  `custom-connect/server/node_modules/.bin/tsc`, aucune installation/réseau)
//  et exécutée avec `node` sur des séries synthétiques (scratchpad de
//  session, jamais commité) — les valeurs ci-dessous sont recopiées TELLES
//  QUELLES depuis cette sortie réelle, pas recalculées à la main. Cf. rapport
//  d'incrément L2 pour le détail des cas.
//
//  Références `day/:date` : mêmes fichiers `.fit` d'exemple que L1
//  (`FitDecoderTests.swift`, `Sample`), mêmes totaux hr/stress/spo2/respiration
//  déjà validés contre le SDK officiel — `day()` ne fait que rebucketer les
//  mêmes échantillons par date, donc sommer ses résultats sur toutes les
//  dates d'un fichier doit reconstituer exactement les totaux déjà connus.
//

import Testing
import Foundation
@testable import all

private enum DaySample {
    static let root = "/Users/alielmufti/Documents/Projects/custom-connect/samples"
    static let wellness1 = "\(root)/user@example.com_263438980021.fit"
    static let wellness2 = "\(root)/user@example.com_450570856748.fit"
}

// MARK: - `BodyBattery.simulatePivot` vs référence TS (`body-battery.ts` compilé avec `tsc` local)

struct BodyBatteryTests {
    private func points(count: Int, spacingS: Double, value: Double) -> [LocalSample] {
        (0..<count).map { LocalSample(ts: Double($0) * spacingS, value: value) }
    }

    /// CASE_A (référence TS) : stress nul soutenu (charge), 8 points espacés
    /// de 600s (= `maxStepMin`), pas de sommeil/activité/repas.
    @Test func sustainedChargeMatchesTsReference() {
        let stress = points(count: 8, spacingS: 600, value: 0)
        let out = BodyBattery.simulatePivot(stress: stress)
        #expect(out.map { Int($0.value) } == [50, 51, 52, 53, 54, 55, 56, 57])
        #expect(out.map { $0.ts } == stress.map { $0.ts })
    }

    /// CASE_B (référence TS) : stress à 100 soutenu (décharge), même espacement.
    @Test func sustainedDrainMatchesTsReference() {
        let stress = points(count: 8, spacingS: 600, value: 100)
        let out = BodyBattery.simulatePivot(stress: stress)
        #expect(out.map { Int($0.value) } == [50, 47, 44, 42, 39, 37, 35, 33])
    }

    /// CASE_C (référence TS) : même série que le cas charge, mais avec une
    /// fenêtre de sommeil couvrant toute la plage — le boost (`sleepBoost`
    /// ×2.5, appliqué seulement quand `rate > 0`) doit accélérer la charge.
    @Test func sleepBoostAcceleratesChargeMatchesTsReference() {
        let stress = points(count: 8, spacingS: 600, value: 0)
        let sleep = [BBSleepInterval(from: 0, to: 4800)]
        let out = BodyBattery.simulatePivot(stress: stress, sleep: sleep)
        #expect(out.map { Int($0.value) } == [50, 53, 56, 58, 60, 62, 64, 66])
    }

    /// CASE_E (référence TS) : 4 points de stress (0/600/1200/1800) + une
    /// activité (`avgHr: 150`) couvrant [1800, 2400) — le point de stress à
    /// 1800 est exclu (`inActivity`), remplacé par les points générés minute
    /// par minute de l'activité (`activityStress(150)` ≈ 84).
    @Test func activityLoadMatchesTsReference() {
        let stress = points(count: 4, spacingS: 600, value: 20)
        let activities = [BBActivityLoad(from: 1800, to: 2400, avgHr: 150)]
        let out = BodyBattery.simulatePivot(stress: stress, activities: activities)

        let expectedTs: [Double] = [0, 600, 1200, 1800, 1860, 1920, 1980, 2040, 2100, 2160, 2220, 2280, 2340, 2400]
        let expectedValues = [50, 50, 51, 48, 48, 48, 48, 47, 47, 47, 47, 47, 46, 46]
        #expect(out.map { $0.ts } == expectedTs)
        #expect(out.map { Int($0.value) } == expectedValues)
    }

    /// Invariant non couvert par les cas TS ci-dessus (pas de repas dans les
    /// échantillons de référence utilisés) : `mealRechargeRate` reste dans
    /// une plage raisonnable et n'envoie jamais `bb` hors [0, 100] — vérifié
    /// structurellement plutôt que contre une sortie TS dédiée. Cf. rapport
    /// d'incrément : le chemin repas n'est donc validé qu'au niveau
    /// invariant, pas contre une sortie TS.
    @Test func staysWithinBoundsWithMeals() {
        let stress = points(count: 20, spacingS: 300, value: 60)
        let meals = [BBMealEnergy(ts: 0, kcal: 800), BBMealEnergy(ts: 3000, kcal: 400)]
        let out = BodyBattery.simulatePivot(stress: stress, meals: meals)
        #expect(out.allSatisfy { $0.value >= 0 && $0.value <= 100 })
    }

    /// `simulatePivot([])` (aucun stress) : `pivotSeries` côté `LocalDb`
    /// s'appuie sur ce cas pour son garde `guard !stress.isEmpty else {
    /// return [] }` — la fonction elle-même doit aussi bien se comporter sur
    /// une entrée vide (aucun point à produire).
    @Test func emptyStressProducesEmptySeries() {
        #expect(BodyBattery.simulatePivot(stress: []).isEmpty)
    }
}

// MARK: - `LocalDb.dayDetail` / `RealLocalPulseBackend` (`GET wellness/day/:date`)

struct LocalDayDetailTests {
    private func makeDb() throws -> LocalDb {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-day-detail-tests-\(UUID().uuidString).sqlite").path
        return try LocalDb(path: path)
    }

    private func ingest(_ path: String, fileName: String, into db: LocalDb) throws {
        let url = URL(fileURLWithPath: path)
        let hash = try PulseUploader.sha256Hex(ofFileAt: url)
        let result = LocalIngestor.ingest(fileURL: url, hash: hash, fileName: fileName, into: db)
        #expect(result.kind == .wellness)
    }

    /// Somme des `hr`/`stress`/`spo2`/`respiration` de `day()` sur TOUTES les
    /// dates connues d'un fichier == totaux déjà validés contre le SDK
    /// officiel en L1 (`FitWellnessExtractorTests`) — `day()` ne fait que
    /// rebucketer les mêmes lignes de `wellness_samples` par date/fuseau.
    @Test func wellness1DayTotalsAcrossDatesMatchL1Reference() throws {
        let db = try makeDb()
        try ingest(DaySample.wellness1, fileName: "w1.fit", into: db)
        let dates = try db.dates()
        #expect(dates == ["2024-07-02", "2024-07-03"])

        var totalHr = 0, totalStress = 0, totalSpo2 = 0, totalResp = 0
        for date in dates {
            let detail = try db.dayDetail(date: date)
            totalHr += detail.hr.count
            totalStress += detail.stress.count
            totalSpo2 += detail.spo2.count
            totalResp += detail.respiration.count
        }
        #expect(totalHr == 160)
        #expect(totalStress == 104)
        #expect(totalSpo2 == 0)
        #expect(totalResp == 110)
    }

    @Test func wellness2DayTotalsAcrossDatesMatchL1Reference() throws {
        let db = try makeDb()
        try ingest(DaySample.wellness2, fileName: "w2.fit", into: db)
        let dates = try db.dates()

        var totalHr = 0, totalStress = 0, totalSpo2 = 0, totalResp = 0
        for date in dates {
            let detail = try db.dayDetail(date: date)
            totalHr += detail.hr.count
            totalStress += detail.stress.count
            totalSpo2 += detail.spo2.count
            totalResp += detail.respiration.count
        }
        #expect(totalHr == 413)
        #expect(totalStress == 517)
        #expect(totalSpo2 == 515)
        #expect(totalResp == 517)
    }

    /// `summary` : `restingHr`/`bmrKcal` viennent de `wellness_days` (déjà
    /// validés L1) ; `steps`/`activeCalories` viennent de `wellness_counters`
    /// (idem, `LocalIngestorTests.ingestsWellnessFileIntoLocalDb`) ;
    /// `bodyBatteryHigh`/`Low` toujours `nil`, `sportCalories` toujours `0`
    /// (activités = L3, cf. `docs/stockage-local.md`).
    @Test func summaryFieldsMatchL1Reference() throws {
        let db = try makeDb()
        try ingest(DaySample.wellness1, fileName: "w1.fit", into: db)
        let detail = try db.dayDetail(date: "2024-07-02")

        #expect(detail.restingHr == 48)
        #expect(detail.bmrKcal == 2280)
        #expect(detail.steps == 9650) // 9647 (walking) + 3 (running)
        #expect(detail.activeCalories == 568) // 100 + 468 + 0
    }

    /// Aucune nuit dans les échantillons wellness (cf. L1,
    /// `extractSleepReturnsNilOnWellnessFiles`) — le sommeil du jour doit
    /// rester une structure vide/`nil`, pas une erreur.
    @Test func sleepIsEmptyWithoutSleepData() throws {
        let db = try makeDb()
        try ingest(DaySample.wellness1, fileName: "w1.fit", into: db)
        let detail = try db.dayDetail(date: "2024-07-02")

        #expect(detail.sleepMain == nil)
        #expect(detail.sleepStages.isEmpty)
        #expect(detail.sleepSegments.isEmpty)
        #expect(detail.sleepScore == nil)
    }

    /// `bodyBatteryPivot` : du stress est présent ce jour-là (104 échantillons
    /// répartis sur les deux dates), donc la série ne doit PAS être vide
    /// (contrairement au cas `stress.isEmpty` de `pivotSeries`) — et rester
    /// dans les bornes [0, 100]. Pas de sommeil/activités dans ces
    /// échantillons, donc c'est le chemin "stress seul" de `BodyBattery`
    /// (déjà cross-vérifié contre la sortie TS ci-dessus) qui est exercé ici.
    @Test func bodyBatteryPivotIsNonEmptyAndBounded() throws {
        let db = try makeDb()
        try ingest(DaySample.wellness1, fileName: "w1.fit", into: db)
        let detail = try db.dayDetail(date: "2024-07-02")

        #expect(!detail.bodyBatteryPivot.isEmpty)
        #expect(detail.bodyBatteryPivot.allSatisfy { $0.value >= 0 && $0.value <= 100 })
        // `bodyBatteryStart` doit avoir mis en cache une valeur de départ.
        #expect(try db.bodyBatteryStart(date: "2024-07-02") >= 0)
    }

    /// Une date sans AUCUNE donnée (aucun stress notamment) : `bodyBatteryPivot`
    /// vide (`pivotSeries` renvoie `[]` sur `stress.isEmpty`), le reste des
    /// séries vide aussi, mais pas d'erreur — miroir du comportement serveur
    /// sur un jour "creux".
    @Test func emptyDayProducesEmptySeriesNotError() throws {
        let db = try makeDb()
        try ingest(DaySample.wellness1, fileName: "w1.fit", into: db)
        let detail = try db.dayDetail(date: "2000-01-01")

        #expect(detail.hr.isEmpty)
        #expect(detail.stress.isEmpty)
        #expect(detail.bodyBatteryPivot.isEmpty)
        #expect(detail.restingHr == nil)
        #expect(detail.steps == nil)
    }

    // MARK: - Bout-en-bout via `RealLocalPulseBackend` (décodage `WellnessDayDetail` réel)

    /// Sert la route EXACTEMENT comme `PulseAPIClient` l'appellerait, décode
    /// avec le décodeur réel de l'app (`PulseAPIClient.decoder`) dans le
    /// modèle réel de l'écran Santé (`WellnessDayDetail`,
    /// `Pulse/Screens/Health/HealthModels.swift`) — valide la FORME JSON en
    /// plus des valeurs (un champ manquant/mal typé ferait échouer le
    /// décodage, pas juste une assertion de valeur).
    @Test func backendServesDayDetailDecodableByRealAppModel() throws {
        let db = try makeDb()
        try ingest(DaySample.wellness1, fileName: "w1.fit", into: db)
        let backend = RealLocalPulseBackend(db: db)

        let data = try backend.handle(method: "GET", path: "api/wellness/day/2024-07-02", query: [:], body: nil)
        let detail = try PulseAPIClient.decoder.decode(WellnessDayDetail.self, from: data)

        #expect(detail.date == "2024-07-02")
        #expect(detail.summary.restingHr == 48)
        #expect(detail.summary.bmrKcal == 2280)
        #expect(detail.summary.steps == 9650)
        #expect(detail.summary.activeCalories == 568)
        #expect(detail.summary.bodyBatteryHigh == nil)
        #expect(detail.summary.bodyBatteryLow == nil)
        #expect(detail.summary.sportCalories == 0)
        #expect(detail.activities.isEmpty)
        #expect(detail.sleep.main == nil)
        #expect(detail.sleep.stages.isEmpty)
        #expect(!detail.bodyBatteryPivot.isEmpty)
        #expect(!detail.hr.isEmpty)
    }

    /// Même route, décodée aussi dans le sous-ensemble utilisé par l'Accueil
    /// (`HomeDayDetail`, `Pulse/Screens/Home/HomeModels.swift`) — mêmes clés,
    /// moins `bodyBatteryPivot`/`activities`/`counterSeries`/`bodyBattery*`/
    /// `sportCalories`, ignorées silencieusement par `Decodable`. Couvre la
    /// divergence de type `ts` (`Int` côté Accueil vs `Double` côté Santé,
    /// cf. `HomeModels.swift`) : les `ts` de `hr`/`stress`/`spo2`/`respiration`
    /// sont toujours des entiers "purs" (epoch + décalage entiers), donc
    /// décodables dans les deux représentations.
    @Test func backendServesDayDetailDecodableByHomeModel() throws {
        let db = try makeDb()
        try ingest(DaySample.wellness1, fileName: "w1.fit", into: db)
        let backend = RealLocalPulseBackend(db: db)

        let data = try backend.handle(method: "GET", path: "api/wellness/day/2024-07-02", query: [:], body: nil)
        let detail = try PulseAPIClient.decoder.decode(HomeDayDetail.self, from: data)

        #expect(detail.date == "2024-07-02")
        #expect(detail.summary.restingHr == 48)
        #expect(detail.hasData)
    }

    /// `api/activities` — stub minimal (cf. `LocalPulseBackend.swift`) sans
    /// lequel `HomeViewModel.load()` échouerait tout l'écran (elle attend
    /// cette route dans le même bloc `try` que `wellness/day`, pas en
    /// "best-effort").
    @Test func backendServesEmptyActivityList() throws {
        let db = try makeDb()
        let backend = RealLocalPulseBackend(db: db)
        let data = try backend.handle(method: "GET", path: "api/activities", query: ["limit": "40"], body: nil)
        let list = try PulseAPIClient.decoder.decode(HomeActivityListResponse.self, from: data)
        #expect(list.total == 0)
        #expect(list.items.isEmpty)
    }

    /// Une date malformée (pas `YYYY-MM-DD`) échoue proprement plutôt que de
    /// planter la base — miroir dégradé du `BadRequestException` serveur
    /// (pas de code HTTP côté backend local, cf. `PulseAPIClient.routedData`).
    @Test func malformedDateThrowsCleanly() throws {
        let db = try makeDb()
        let backend = RealLocalPulseBackend(db: db)
        #expect(throws: LocalPulseUnavailableError.self) {
            try backend.handle(method: "GET", path: "api/wellness/day/not-a-date", query: [:], body: nil)
        }
    }
}

// MARK: - Ingestion → service bout-en-bout (`LocalIngestor.ingestAll` → `dayDetail`)

struct IngestThenServeTests {
    /// Rejoue le spool ENTIER (`ingestAll`, câblée en L2 — cf.
    /// `LocalIngestor.ingestIfNeeded`) dans une base temporaire à partir d'un
    /// `SpoolStore` de test peuplé des deux fichiers wellness d'exemple, puis
    /// sert `day/:date` pour une date connue — bout-en-bout spool → base →
    /// backend, sans passer par le vrai réseau BLE.
    @Test func ingestAllThenServeDayDetailForKnownDate() throws {
        let spoolRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-ingest-then-serve-\(UUID().uuidString)", isDirectory: true)
        let spool = try SpoolStore(root: spoolRoot)

        let entry1 = try recordSample(DaySample.wellness1, relativePath: "20240702_w1.fit", index: 1, into: spool)
        let entry2 = try recordSample(DaySample.wellness2, relativePath: "20260619_w2.fit", index: 2, into: spool)
        #expect(spool.entries.count == 2)
        _ = entry1
        _ = entry2

        let dbPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-ingest-then-serve-\(UUID().uuidString).sqlite").path
        let db = try LocalDb(path: dbPath)

        let results = LocalIngestor.ingestAll(from: spool, into: db)
        #expect(results.filter { $0.kind == .wellness }.count == 2)

        let detail = try db.dayDetail(date: "2024-07-02")
        #expect(!detail.hr.isEmpty)
        #expect(detail.restingHr == 48)

        let detail2 = try db.dayDetail(date: "2026-06-19")
        #expect(!detail2.hr.isEmpty)
        #expect(!detail2.spo2.isEmpty)
    }

    /// Copie un `.fit` d'exemple dans le spool de test et l'enregistre
    /// `acquired` — même effet que `GarminSession.finishDownload` sur le
    /// vrai chemin BLE, sans passer par CoreBluetooth.
    private func recordSample(_ path: String, relativePath: String, index: Int, into spool: SpoolStore) throws -> SpoolEntry {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        // fileType 32 = monitoringB (`FitProfile.fileTypeMonitoringB`), jamais
        // 0 (réservé DIRECTORY, cf. `GarminSession.archivePendingDeliveries`).
        let id = WatchFileID(fileType: 32, index: index, name: relativePath)
        return try spool.recordAcquired(id, relativePath: relativePath, data: data)
    }
}
