//
//  ActivityEditsTests.swift
//  allTests
//
//  Modification et fusion d'activités côté téléphone — contrat
//  `custom-connect/docs/activity-edits-contract.md` : calcul pur (§4), routes du backend
//  local (§5), matérialisation et ordre d'arrivée (§2, §6), synchro `activityEdit` (§7).
//  `.fit` SYNTHÉTIQUES (`SyntheticFit`), bases et dossiers temporaires, aucun réseau.
//

import Testing
import Foundation
@testable import all

// MARK: - Aides

private let t0 = 1_790_000_000.0

private func iso(_ unix: Double) -> String { ActivityEditTime.format(unix) }

/// `w(hr)` du contrat §4.6, réécrit ici indépendamment du code testé.
private func keytel(_ hr: Int) -> Double { max(0.6309 * Double(hr) - 34, 1) }

private func zoneOf(_ hr: Int, bounds: [Int] = [100, 120, 140, 160, 180, 190]) -> Int {
    if hr <= bounds[0] { return 0 }
    for z in 1..<bounds.count where hr <= bounds[z] { return z }
    return bounds.count - 1
}

private struct Rig {
    let db: LocalDb
    let store: PulseFilesStore
    let locator: ActivityFitLocator
    let backend: RealLocalPulseBackend

    init() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("activity-edits-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        db = try LocalDb(path: dir.appendingPathComponent("db.sqlite").path)
        store = PulseFilesStore(root: dir.appendingPathComponent("files", isDirectory: true))
        try store.prepare()
        locator = ActivityFitLocator(spool: nil, pulledFiles: store)
        backend = RealLocalPulseBackend(db: db, spool: nil, pulledFiles: store)
    }

    /// Dépose le `.fit` dans le dossier des fichiers rapatriés (sans l'ingérer).
    @discardableResult
    func put(_ fit: SyntheticFit) throws -> String {
        let hash = fit.hash
        try fit.data().write(to: store.keptURL(hash: hash))
        return hash
    }

    /// Dépose puis ingère (`LocalIngestor.ingest`, donc avec le hook §6).
    @discardableResult
    func ingest(_ fit: SyntheticFit) throws -> String {
        let hash = try put(fit)
        let result = LocalIngestor.ingest(fileURL: store.keptURL(hash: hash), hash: hash, fileName: "\(hash).fit", into: db, locator: locator)
        #expect(result.kind == .activity)
        return hash
    }

    func id(_ hash: String) throws -> Int { try #require(try db.storedActivity(hash: hash)).id }

    func call(_ method: String, _ path: String, _ body: [String: Any?]? = nil) async throws -> Data {
        var data: Data?
        if let body {
            data = try JSONSerialization.data(withJSONObject: body.mapValues { $0 ?? NSNull() })
        }
        return try await backend.handle(method: method, path: path, query: [:], body: data)
    }

    func detail(_ id: Int) async throws -> ActivityDetail {
        try PulseAPIClient.decoder.decode(ActivityDetail.self, from: try await call("GET", "api/activities/\(id)"))
    }

    func list() async throws -> ActivityListResponse {
        try PulseAPIClient.decoder.decode(ActivityListResponse.self, from: try await call("GET", "api/activities"))
    }
}

private func decodeDetail(_ data: Data) throws -> ActivityDetail { try PulseAPIClient.decoder.decode(ActivityDetail.self, from: data) }

// MARK: - Calcul pur (§4)

struct FitActivityEditComputeTests {
    @Test func noEditGivesTheSameCurvesAsPlainExtraction() throws {
        let fit = SyntheticFit(startUnix: t0)
        let plain = FitActivityExtractor.extractDetail(messages: fit.messages)
        let edited = try #require(FitActivityEdit.compute(principal: fit.messages)).detail
        #expect(edited.streams.time == plain.streams.time)
        #expect(edited.streams.hr == plain.streams.hr)
        #expect(edited.streams.distance == plain.streams.distance)
        #expect(edited.streams.altitude == plain.streams.altitude)
        #expect(edited.track == plain.track)
        #expect(edited.laps.count == plain.laps.count)
        #expect(edited.laps.map(\.durationS) == plain.laps.map(\.durationS))
        #expect(edited.hrZones.map(\.fromBpm) == plain.hrZones.map(\.fromBpm))
        #expect(edited.hrZones.map(\.toBpm) == plain.hrZones.map(\.toBpm))
    }

    @Test func trimRecomputesSummaryOnTheKeptWindow() throws {
        let fit = SyntheticFit(startUnix: t0)
        let window = FitActivityEdit.Window(start: t0 + 100, end: t0 + 410)
        let result = try #require(FitActivityEdit.compute(principal: fit.messages, window: window))
        let s = result.summary
        #expect(s.startTime == iso(t0 + 100))
        #expect(s.durationS == 310)
        #expect(s.distanceM == 933)            // d(410) − d⁻(100) : borne de début stricte (§4.4)
        #expect(s.avgHr == 125)                // moyenne pondérée par dt (records 100...409)
        #expect(s.maxHr == 141)                // le record de la borne (dt = 0) compte pour le max
        #expect(s.sport == "running")

        // Calories : 300 × (Σ w·dt gardés / Σ w·dt tous), arrondi à la fin.
        let kept = (100..<410).reduce(0.0) { $0 + keytel(fit.hr($1)) }
        let all = (0..<600).reduce(0.0) { $0 + keytel(fit.hr($1)) }
        #expect(s.calories == (300 * kept / all).rounded())

        // Courbes : records 100...410, `time` depuis le début de la fenêtre.
        let streams = result.detail.streams
        #expect(streams.time.count == 311)
        #expect(streams.time[0] == 0)
        #expect(streams.time.last == 310)
        #expect(streams.hr[0] == Double(fit.hr(100)))

        // Zones : Σ dt des records gardés par zone, arrondi au dixième.
        var expected = [Double](repeating: 0, count: 6)
        for i in 100..<410 { expected[zoneOf(fit.hr(i))] += 1 }
        let zones = result.detail.hrZones
        #expect(zones.map(\.zone) == [1, 2, 3, 4, 5])
        #expect(zones.map(\.seconds) == Array(expected[1...5]))
        #expect(zones.map(\.fromBpm) == [100, 120, 140, 160, 180])
    }

    @Test func pauseIsNotCounted() throws {
        let fit = SyntheticFit(startUnix: t0, pause: (stop: 300, resume: 400))
        let result = try #require(FitActivityEdit.compute(principal: fit.messages))
        #expect(result.summary.durationS == 500)       // [0,300] + [400,600]
        // Pas de trou dans l'axe du temps d'un même membre : `time` suit les timestamps.
        #expect(result.detail.streams.time[result.detail.streams.time.count - 1] == 600)
        // Fenêtre dans la pause : aucun record gardé.
        let inPause = FitActivityEdit.Window(start: t0 + 310, end: t0 + 390)
        #expect(FitActivityEdit.compute(principal: fit.messages, window: inPause) == nil)
    }

    @Test func emptyWindowGivesNil() throws {
        let fit = SyntheticFit(startUnix: t0)
        #expect(FitActivityEdit.compute(principal: fit.messages, window: .init(start: t0 + 700, end: t0 + 800)) == nil)
    }

    @Test func mergeCompressesTheGapBetweenMembers() throws {
        let a = SyntheticFit(startUnix: t0, seconds: 600, calories: 300)
        let b = SyntheticFit(startUnix: t0 + 1000, seconds: 300, calories: 100, salt: 1)
        // L'ordre des paramètres n'a pas d'importance : le calcul est chronologique.
        let result = try #require(FitActivityEdit.compute(principal: a.messages, others: [b.messages]))
        let s = result.summary
        #expect(s.startTime == iso(t0))
        #expect(s.durationS == 900)
        #expect(s.distanceM == 2700.0)             // somme des différences, chaque .fit repart de 0
        #expect(s.calories == 400)
        let streams = result.detail.streams
        #expect(streams.time.count == 601 + 301)
        #expect(streams.time[600] == 600)
        #expect(streams.time[601] == 600)              // premier point de b : 0 + durée de a, sans le trou de 400 s
        #expect(streams.time.last == 900)
        #expect(result.detail.laps.map(\.index) == [1, 2, 3, 4])
        // Le sport est celui de la principale, sauf modification.
        let cyclist = SyntheticFit(startUnix: t0 + 5000, sport: 2)
        #expect(FitActivityEdit.compute(principal: a.messages, others: [cyclist.messages])?.summary.sport == "running")
        #expect(FitActivityEdit.compute(principal: a.messages, others: [b.messages], sport: "hiking", subSport: "trail")?.summary.subSport == "trail")
    }

    @Test func lapsAreKeptCutOrDropped() throws {
        let fit = SyntheticFit(startUnix: t0)              // tours [0,300] et [300,600]
        let cut = try #require(FitActivityEdit.compute(principal: fit.messages, window: .init(start: t0 + 100, end: nil)))
        #expect(cut.detail.laps.count == 2)
        #expect(cut.detail.laps.map(\.index) == [1, 2])
        #expect(cut.detail.laps[0].durationS == 200)       // à cheval : recalculé sur [100,300]
        #expect(cut.detail.laps[0].distanceM == 603)
        #expect(cut.detail.laps[1].durationS == 300)       // entièrement gardé : repris tel quel
        let dropped = try #require(FitActivityEdit.compute(principal: fit.messages, window: .init(start: t0 + 350, end: nil)))
        #expect(dropped.detail.laps.count == 1)
        #expect(dropped.detail.laps[0].index == 1)
        #expect(dropped.detail.laps[0].durationS == 250)
    }

    @Test func caloriesFollowDurationWithoutHeartRate() throws {
        let fit = SyntheticFit(startUnix: t0, withHr: false)
        let result = try #require(FitActivityEdit.compute(principal: fit.messages, window: .init(start: t0 + 100, end: t0 + 410)))
        #expect(result.summary.calories == (300.0 * 310 / 600).rounded())
        #expect(result.summary.avgHr == nil)
        #expect(result.summary.maxHr == nil)
    }

    @Test func noDistanceStaysNil() throws {
        let fit = SyntheticFit(startUnix: t0, withDistance: false)
        #expect(try #require(FitActivityEdit.compute(principal: fit.messages)).summary.distanceM == nil)
    }

    @Test func withoutTimerEventsUsesTheRecordSpan() throws {
        let fit = SyntheticFit(startUnix: t0, withTimerEvents: false)
        let span = try #require(FitActivityEdit.sourceSpan([fit.messages]))
        #expect(span.start == t0 && span.end == t0 + 600)
        #expect(try #require(FitActivityEdit.compute(principal: fit.messages)).summary.durationS == 600)
    }
}

// MARK: - Routes du backend local (§5)

struct ActivityEditRoutesTests {
    @Test func putTrimsThenDeleteRestoresTheOriginal() async throws {
        let rig = try Rig()
        let hash = try rig.ingest(SyntheticFit(startUnix: t0))
        let id = try rig.id(hash)
        let original = try await rig.detail(id)
        #expect(original.durationS == 600)
        #expect(original.edited == false)
        #expect(original.edit == nil)
        #expect(original.members?.isEmpty == true)
        #expect(original.source?.startTime == iso(t0))
        #expect(original.source?.endTime == iso(t0 + 600))

        let put = try await rig.call("PUT", "api/activities/\(id)/edit", ["startAt": iso(t0 + 100), "endAt": iso(t0 + 410), "name": "Footing", "note": "ok"])
        let trimmed = try decodeDetail(put)
        #expect(trimmed.durationS == 310)
        #expect(trimmed.distanceM == 933)
        #expect(trimmed.avgHr == 125)
        #expect(trimmed.edited == true)
        #expect(trimmed.name == "Footing")
        #expect(trimmed.note == "ok")
        #expect(trimmed.startTime == iso(t0 + 100))
        #expect(trimmed.streams?.time.count == 311)
        #expect(trimmed.edit == ActivityEditInfo(startAt: iso(t0 + 100), endAt: iso(t0 + 410), sport: nil, subSport: nil))
        #expect(trimmed.source?.startTime == iso(t0))   // les bornes d'origine ne bougent pas

        // La liste et les zones matérialisées reflètent la modification.
        let listed = try #require(try await rig.list().items.first)
        #expect(listed.durationS == 310 && listed.edited == true && listed.name == "Footing")
        var zones = 0
        try rig.db.db.run("SELECT COUNT(*) FROM activity_zones WHERE activity_id = ?", [.int(id)]) { zones = Int($0.double(0) ?? 0) }
        #expect(zones == 5)

        let reset = try decodeDetail(try await rig.call("DELETE", "api/activities/\(id)/edit"))
        #expect(reset.durationS == 600)
        #expect(reset.distanceM == 1800)
        #expect(reset.edited == false)
        #expect(reset.name == nil)
        #expect(reset.edit == nil)
        #expect(reset.startTime == original.startTime)
        #expect(try rig.db.activityEdit(hash: hash) == nil)       // ligne vide supprimée
        try rig.db.db.run("SELECT COUNT(*) FROM activity_zones WHERE activity_id = ?", [.int(id)]) { zones = Int($0.double(0) ?? 0) }
        #expect(zones == 0)
    }

    @Test func labelsAndSportDoNotRecompute() async throws {
        let rig = try Rig()
        let id = try rig.id(try rig.ingest(SyntheticFit(startUnix: t0)))
        let renamed = try decodeDetail(try await rig.call("PUT", "api/activities/\(id)/edit", ["name": "Sortie"]))
        #expect(renamed.edited == false)                  // un nom seul n'est pas une « modification »
        #expect(renamed.durationS == 600)
        let sport = try decodeDetail(try await rig.call("PUT", "api/activities/\(id)/edit", ["sport": "hiking", "subSport": "trail"]))
        #expect(sport.sport == "hiking" && sport.subSport == "trail")
        #expect(sport.edited == true)
        #expect(sport.durationS == 600)
        #expect(sport.edit?.sport == "hiking")
        #expect(sport.name == "Sortie")                   // champ absent = inchangé
        // `null` efface (et `sport: null` efface aussi le sous-sport).
        let cleared = try decodeDetail(try await rig.call("PUT", "api/activities/\(id)/edit", ["sport": nil, "name": nil]))
        #expect(cleared.sport == "running" && cleared.subSport == "generic")
        #expect(cleared.name == nil)
        #expect(cleared.edited == false)
    }

    @Test func putRejectsInvalidRequests() async throws {
        let rig = try Rig()
        let hash = try rig.ingest(SyntheticFit(startUnix: t0, pause: (stop: 300, resume: 400)))
        let id = try rig.id(hash)
        func rejects(_ body: [String: Any?]) async {
            await #expect(throws: LocalActivityEditValidationError.self) { _ = try await rig.call("PUT", "api/activities/\(id)/edit", body) }
        }
        await rejects(["startAt": iso(t0 + 200), "endAt": iso(t0 + 200)])           // start ≥ end
        await rejects(["startAt": iso(t0 + 300), "endAt": iso(t0 + 100)])
        await rejects(["startAt": iso(t0 - 60)])                                     // avant l'origine
        await rejects(["endAt": iso(t0 + 700)])                                      // après l'origine
        await rejects(["startAt": iso(t0 + 310), "endAt": iso(t0 + 390)])            // fenêtre vide (dans la pause)
        await rejects(["startAt": "pas une date"])
        await rejects(["sport": ""])
        await rejects(["sport": String(repeating: "x", count: 41)])
        await rejects(["name": String(repeating: "n", count: 81)])
        await rejects(["note": String(repeating: "n", count: 2001)])
        await rejects(["subSport": "trail"])                                         // sous-sport sans sport
        #expect(try rig.db.activityEdit(hash: hash) == nil)                          // rien d'écrit
        await #expect(throws: LocalActivityNotFoundError.self) { _ = try await rig.call("PUT", "api/activities/999/edit", ["name": "x"]) }
        await #expect(throws: LocalActivityNotFoundError.self) { _ = try await rig.call("DELETE", "api/activities/999/edit") }
        await #expect(throws: LocalActivityNotFoundError.self) { _ = try await rig.call("POST", "api/activities/999/split") }
        // Limites acceptées.
        _ = try await rig.call("PUT", "api/activities/\(id)/edit", ["name": String(repeating: "n", count: 80), "note": String(repeating: "n", count: 2000)])
    }

    @Test func mergeThenSplitRestoresTheOriginals() async throws {
        let rig = try Rig()
        let hashA = try rig.ingest(SyntheticFit(startUnix: t0, seconds: 600, calories: 300))
        let hashB = try rig.ingest(SyntheticFit(startUnix: t0 + 1000, seconds: 300, calories: 100, salt: 1))
        let idA = try rig.id(hashA), idB = try rig.id(hashB)
        let before = try await rig.list()
        #expect(before.total == 2)

        // Le premier id n'a pas à être le plus ancien : la principale est la plus ancienne.
        let merged = try PulseAPIClient.decoder.decode(ActivityMergeResponse.self, from: try await rig.call("POST", "api/activities/merge", ["ids": [idB, idA]]))
        #expect(merged.id == idA)
        let list = try await rig.list()
        #expect(list.total == 1)
        let item = try #require(list.items.first)
        #expect(item.id == idA && item.durationS == 900 && item.mergedCount == 1 && item.edited == true)
        #expect(item.calories == 400)
        let detail = try await rig.detail(idA)
        #expect(detail.members?.map(\.id) == [idA, idB])
        #expect(detail.streams?.time.count == 902)
        #expect(detail.source?.endTime == iso(t0 + 1300))
        await #expect(throws: LocalActivityNotFoundError.self) { _ = try await rig.detail(idB) }
        // Absorbée : toujours connue (jamais réingérée ni rapatriée).
        #expect(try rig.db.isActivityImported(hash: hashB))
        #expect(try rig.db.pulledKnownHashes().contains(hashB))

        let split = try PulseAPIClient.decoder.decode(ActivitySplitResponse.self, from: try await rig.call("POST", "api/activities/\(idA)/split"))
        #expect(split.ids == [idA, idB])
        let after = try await rig.list()
        #expect(after.total == 2)
        let restoredB = try #require(after.items.first { $0.id == idB })
        #expect(restoredB.durationS == 300 && restoredB.edited == false && restoredB.mergedCount == 0)
        let restoredA = try #require(after.items.first { $0.id == idA })
        #expect(restoredA.durationS == 600 && restoredA.calories == 300 && restoredA.edited == false)
        #expect(try rig.db.allActivityEdits().isEmpty)
        // Plus de fusion à séparer.
        await #expect(throws: LocalActivityEditValidationError.self) { _ = try await rig.call("POST", "api/activities/\(idA)/split") }
    }

    @Test func mergeAppliesThePrincipalWindowAndLabels() async throws {
        let rig = try Rig()
        let hashA = try rig.ingest(SyntheticFit(startUnix: t0, seconds: 600))
        let hashB = try rig.ingest(SyntheticFit(startUnix: t0 + 1000, seconds: 300, salt: 1))
        let idA = try rig.id(hashA), idB = try rig.id(hashB)
        _ = try await rig.call("PUT", "api/activities/\(idB)/edit", ["name": "B perdu"])
        _ = try await rig.call("POST", "api/activities/merge", ["ids": [idA, idB]])
        _ = try await rig.call("PUT", "api/activities/\(idA)/edit", ["startAt": iso(t0 + 100), "name": "Course"])
        let item = try #require(try await rig.list().items.first)
        #expect(item.durationS == 800.0)              // la fenêtre de la principale s'applique au résultat fusionné
        #expect(item.name == "Course")                    // le nom d'un absorbé est ignoré, conservé pour la séparation
        _ = try await rig.call("POST", "api/activities/\(idA)/split")
        let restored = try #require(try await rig.list().items.first { $0.id == idB })
        #expect(restored.name == "B perdu")
    }

    @Test func mergeRejectsInvalidRequests() async throws {
        let rig = try Rig()
        let a = try rig.id(try rig.ingest(SyntheticFit(startUnix: t0, seconds: 600)))
        let b = try rig.id(try rig.ingest(SyntheticFit(startUnix: t0 + 1000, seconds: 300, salt: 1)))
        let bike = try rig.id(try rig.ingest(SyntheticFit(startUnix: t0 + 5000, seconds: 300, sport: 2, salt: 2)))
        let overlapping = try rig.id(try rig.ingest(SyntheticFit(startUnix: t0 + 300, seconds: 600, salt: 3)))
        func rejects(_ ids: [Int]) async {
            await #expect(throws: LocalActivityEditValidationError.self) { _ = try await rig.call("POST", "api/activities/merge", ["ids": ids]) }
        }
        await rejects([a])
        await rejects([a, a])
        await rejects([a, bike])                // sports différents
        await rejects([a, overlapping])         // chevauchement
        await #expect(throws: LocalActivityNotFoundError.self) { _ = try await rig.call("POST", "api/activities/merge", ["ids": [a, 999]]) }
        _ = try await rig.call("POST", "api/activities/merge", ["ids": [a, b]])
        await rejects([b, bike])                // b est déjà absorbée
        #expect(try await rig.list().total == 3)
    }

    @Test func writesInvalidateBodyBattery() async throws {
        let rig = try Rig()
        let id = try rig.id(try rig.ingest(SyntheticFit(startUnix: t0)))   // 2026-09-21
        let day = String(iso(t0).prefix(10))
        for date in ["2026-01-01", day, "2027-01-01"] {
            try rig.db.db.run("INSERT INTO body_battery_state (date, start_value) VALUES (?, 50)", [.text(date)])
        }
        _ = try await rig.call("PUT", "api/activities/\(id)/edit", ["note": "x"])
        var dates: [String] = []
        try rig.db.db.run("SELECT date FROM body_battery_state ORDER BY date") { dates.append($0.text(0) ?? "") }
        #expect(dates == ["2026-01-01"])                  // à partir de la date de l'activité
    }

    @Test func migrationCreatesTheTables() throws {
        let rig = try Rig()
        #expect(try LocalDb.schemaVersion(rig.db.db) == LocalDb.migrations.count)
        var names: [String] = []
        try rig.db.db.run("SELECT name FROM sqlite_master WHERE name IN ('activity_edits', 'activities_merged')") { names.append($0.text(0) ?? "") }
        #expect(Set(names) == ["activity_edits", "activities_merged"])
        var columns: [String] = []
        try rig.db.db.run("SELECT name FROM pragma_table_info('activities')") { columns.append($0.text(0) ?? "") }
        for column in ["name", "note", "edited", "merged_count"] { #expect(columns.contains(column)) }
    }
}

// MARK: - Matérialisation et ordre d'arrivée (§2, §6)

struct ActivityEditMaterializationTests {
    @Test func editArrivingBeforeItsFitAppliesOnArrival() async throws {
        let rig = try Rig()
        let fit = SyntheticFit(startUnix: t0)
        let hash = fit.hash
        var edit = ActivityEdit(fileHash: hash)
        edit.startAt = iso(t0 + 100)
        edit.endAt = iso(t0 + 410)
        edit.name = "En avance"
        try rig.db.saveActivityEdit(edit)
        try rig.ingest(fit)
        let item = try #require(try await rig.list().items.first)
        #expect(item.durationS == 310 && item.name == "En avance" && item.edited == true)
    }

    @Test func memberArrivingBeforeOrAfterThePrincipalEndsUpAbsorbed() async throws {
        for memberFirst in [true, false] {
            let rig = try Rig()
            let a = SyntheticFit(startUnix: t0, seconds: 600, calories: 300)
            let b = SyntheticFit(startUnix: t0 + 1000, seconds: 300, calories: 100, salt: 1)
            var edit = ActivityEdit(fileHash: b.hash)
            edit.mergedInto = a.hash
            try rig.db.saveActivityEdit(edit)
            if memberFirst {
                try rig.ingest(b)
                #expect(try await rig.list().total == 1)           // principale absente : b reste autonome
                try rig.ingest(a)
            } else {
                try rig.ingest(a)
                #expect(try await rig.list().total == 1)           // membre absent : a seul
                try rig.ingest(b)
            }
            let list = try await rig.list()
            #expect(list.total == 1)
            let item = try #require(list.items.first)
            #expect(item.durationS == 900 && item.mergedCount == 1 && item.calories == 400)
            #expect(try rig.db.mergedActivity(hash: b.hash) != nil)
        }
    }

    @Test func absorbedMemberRepointsTheProgrammeDone() async throws {
        let rig = try Rig()
        let idA = try rig.id(try rig.ingest(SyntheticFit(startUnix: t0)))
        let idB = try rig.id(try rig.ingest(SyntheticFit(startUnix: t0 + 1000, seconds: 300, salt: 1)))
        try rig.db.db.run("INSERT INTO programme_done (programme_id, week, session, date, activity_id) VALUES ('p', 1, 's', '2026-09-21', ?)", [.int(idB)])
        _ = try await rig.call("POST", "api/activities/merge", ["ids": [idA, idB]])
        var target: Double?
        try rig.db.db.run("SELECT activity_id FROM programme_done WHERE programme_id = 'p'") { target = $0.double(0) }
        #expect(target == Double(idA))
    }

    @Test func ingestionWithoutEditsLeavesRowsUntouched() async throws {
        let rig = try Rig()
        let id = try rig.id(try rig.ingest(SyntheticFit(startUnix: t0)))
        let item = try #require(try await rig.list().items.first)
        #expect(item.id == id && item.edited == false && item.mergedCount == 0 && item.name == nil)
        // Aucune ligne de zones : seules les activités modifiées en matérialisent.
        var zones = 0
        try rig.db.db.run("SELECT COUNT(*) FROM activity_zones") { zones = Int($0.double(0) ?? 0) }
        #expect(zones == 0)
    }

    @Test func chainsFollowTheRootAndCyclesAreIgnored() throws {
        var a = ActivityEdit(fileHash: "a"), b = ActivityEdit(fileHash: "b"), c = ActivityEdit(fileHash: "c")
        a.mergedInto = "b"
        b.mergedInto = "c"
        let graph = ActivityEditGraph([a, b, c])
        #expect(graph.root(of: "a") == "c")
        #expect(graph.members(of: "c") == ["a", "b"])
        c.mergedInto = "a"                                  // cycle a → b → c → a
        let cyclic = ActivityEditGraph([a, b, c])
        #expect(cyclic.root(of: "a") == "a")
        #expect(cyclic.members(of: "a").isEmpty)
    }
}

// MARK: - Synchro des saisies : ressource `activityEdit` (§7)

struct ActivityEditSyncTests {
    private func change(_ key: String, at updatedAt: Int, deleted: Bool = false, _ data: [String: SaisieJSON]? = nil) -> SaisieChange {
        SaisieChange(resource: "activityEdit", key: key, updatedAt: updatedAt, deleted: deleted, data: deleted ? nil : data)
    }

    private func apply(_ rig: Rig, _ changes: [SaisieChange]) throws -> LocalDb.SaisieApplyResult {
        try rig.db.applySaisieResponse(cursor: 1, changes: changes, sentMaxRev: nil, markInitialDone: false, activityLocator: rig.locator)
    }

    private func data(
        startAt: String? = nil, endAt: String? = nil, sport: String? = nil, subSport: String? = nil,
        name: String? = nil, note: String? = nil, mergedInto: String? = nil
    ) -> [String: SaisieJSON] {
        ["startAt": .opt(startAt), "endAt": .opt(endAt), "sport": .opt(sport), "subSport": .opt(subSport),
         "name": .opt(name), "note": .opt(note), "mergedInto": .opt(mergedInto)]
    }

    @Test func localEditsAreJournaledWithTheirData() async throws {
        let rig = try Rig()
        let hash = try rig.ingest(SyntheticFit(startUnix: t0))
        let id = try rig.id(hash)
        _ = try await rig.call("PUT", "api/activities/\(id)/edit", ["startAt": iso(t0 + 100), "name": "Local"])
        var batch = try rig.db.collectSaisieChanges(afterRev: 0, limit: 100)
        let sent = try #require(batch.changes.first { $0.resource == "activityEdit" })
        #expect(sent.key == hash && sent.deleted == false)
        #expect(sent.data?["startAt"] == .string(iso(t0 + 100)))
        #expect(sent.data?["name"] == .string("Local"))
        #expect(sent.data?["endAt"] == .null)
        #expect(sent.data?["mergedInto"] == .null)

        _ = try await rig.call("DELETE", "api/activities/\(id)/edit")    // ligne vide supprimée → pierre tombale
        batch = try rig.db.collectSaisieChanges(afterRev: 0, limit: 100)
        let tombstone = try #require(batch.changes.first { $0.resource == "activityEdit" })
        #expect(tombstone.deleted == true && tombstone.data == nil)
    }

    @Test func remoteMergeIsAppliedAndUndoneByItsTombstone() async throws {
        let rig = try Rig()
        let hashA = try rig.ingest(SyntheticFit(startUnix: t0, seconds: 600))
        let hashB = try rig.ingest(SyntheticFit(startUnix: t0 + 1000, seconds: 300, salt: 1))
        let idA = try rig.id(hashA)
        let applied = try apply(rig, [change(hashB, at: 4_000_000_000_000, data(mergedInto: hashA))])
        #expect(applied.applied == 1 && applied.skipped == 0)
        var item = try #require(try await rig.list().items.first)
        #expect(try await rig.list().total == 1)
        #expect(item.id == idA && item.durationS == 900 && item.mergedCount == 1)

        // Pierre tombale (plus récente) : retour à l'origine, la principale se recalcule sans lui.
        _ = try apply(rig, [change(hashB, at: 4_000_000_000_001, deleted: true)])
        #expect(try await rig.list().total == 2)
        item = try #require(try await rig.list().items.first { $0.id == idA })
        #expect(item.durationS == 600 && item.mergedCount == 0 && item.edited == false)
    }

    @Test func remoteWindowAndLabelsAreApplied() async throws {
        let rig = try Rig()
        let hash = try rig.ingest(SyntheticFit(startUnix: t0))
        let result = try apply(rig, [change(hash, at: 4_000_000_000_000, data(startAt: iso(t0 + 100), endAt: iso(t0 + 410), name: "Distant"))])
        #expect(result.applied == 1)
        let item = try #require(try await rig.list().items.first)
        #expect(item.durationS == 310 && item.name == "Distant" && item.edited == true)
        // Le plus récent gagne : une version plus ancienne est ignorée.
        let stale = try apply(rig, [change(hash, at: 1_000, data(name: "Vieux"))])
        #expect(stale.applied == 0 && stale.skipped == 1)
    }

    @Test func invalidRemoteEditsAreSkipped() async throws {
        let rig = try Rig()
        let hash = try rig.ingest(SyntheticFit(startUnix: t0, pause: (stop: 300, resume: 400)))
        let bad: [[String: SaisieJSON]] = [
            data(startAt: iso(t0 + 200), endAt: iso(t0 + 100)),                 // start ≥ end
            data(startAt: "n'importe quoi"),
            data(startAt: iso(t0 - 100)),                                        // hors de l'activité (le .fit est là)
            data(sport: String(repeating: "x", count: 41)),
            data(subSport: "trail"),                                             // sous-sport sans sport
            data(name: String(repeating: "n", count: 81)),
            data(note: String(repeating: "n", count: 2001)),
            data(mergedInto: hash),                                              // se fusionne dans lui-même
        ]
        for (i, payload) in bad.enumerated() {
            let r = try apply(rig, [change(hash, at: 4_000_000_000_000 + i, payload)])
            #expect(r.applied == 0 && r.skipped == 1, "cas \(i)")
        }
        #expect(try rig.db.activityEdit(hash: hash) == nil)
        #expect(try #require(try await rig.list().items.first).edited == false)
    }

    @Test func emptyWindowIsKeptButFallsBackToTheOrigin() async throws {
        let rig = try Rig()
        let hash = try rig.ingest(SyntheticFit(startUnix: t0, pause: (stop: 300, resume: 400)))
        let r = try apply(rig, [change(hash, at: 4_000_000_000_000, data(startAt: iso(t0 + 310), endAt: iso(t0 + 390), name: "Vide"))])
        #expect(r.applied == 1)
        #expect(try rig.db.activityEdit(hash: hash)?.startAt != nil)
        let item = try #require(try await rig.list().items.first)
        #expect(item.durationS == 500 && item.name == "Vide")
    }

    @Test func valuelessRemoteEditDeletesTheLocalRow() async throws {
        let rig = try Rig()
        let hash = try rig.ingest(SyntheticFit(startUnix: t0))
        _ = try apply(rig, [change(hash, at: 4_000_000_000_000, data(name: "Temp"))])
        #expect(try rig.db.activityEdit(hash: hash) != nil)
        _ = try apply(rig, [change(hash, at: 4_000_000_000_001, data())])
        #expect(try rig.db.activityEdit(hash: hash) == nil)
        #expect(try #require(try await rig.list().items.first).name == nil)
    }

    @Test func editWithoutItsFitIsKeptWithoutBoundsCheck() async throws {
        let rig = try Rig()
        let fit = SyntheticFit(startUnix: t0)
        let r = try apply(rig, [change(fit.hash, at: 4_000_000_000_000, data(startAt: iso(t0 + 100), name: "Attend"))])
        #expect(r.applied == 1)
        #expect(try rig.db.activityEdit(hash: fit.hash)?.name == "Attend")
    }

    @Test func programmeDoneIsAppliedBeforeActivityEdit() throws {
        let order = LocalDb.saisieResources
        let done = try #require(order.firstIndex(of: "programmeDone"))
        let edit = try #require(order.firstIndex(of: "activityEdit"))
        #expect(done < edit)
    }

    @Test func remoteProgrammeDoneOnAnAbsorbedActivityPointsAtThePrincipal() async throws {
        let rig = try Rig()
        let hashA = try rig.ingest(SyntheticFit(startUnix: t0))
        let hashB = try rig.ingest(SyntheticFit(startUnix: t0 + 1000, seconds: 300, salt: 1))
        let idA = try rig.id(hashA)
        let done = SaisieChange(
            resource: "programmeDone", key: "p|1|s", updatedAt: 4_000_000_000_000, deleted: false,
            data: ["date": .string("2026-09-21"), "activityFileHash": .string(hashB)])
        // Dans la MÊME réponse, la fusion arrive après le pointage (ordre du contrat) : le
        // pointage vise d'abord b (actif), puis la fusion le repointe sur a.
        _ = try apply(rig, [change(hashB, at: 4_000_000_000_000, data(mergedInto: hashA)), done])
        var target: Double?
        try rig.db.db.run("SELECT activity_id FROM programme_done WHERE programme_id = 'p'") { target = $0.double(0) }
        #expect(target == Double(idA))
        // Un pointage reçu APRÈS la fusion vise lui aussi la principale.
        let later = SaisieChange(
            resource: "programmeDone", key: "p|2|s", updatedAt: 4_000_000_000_002, deleted: false,
            data: ["date": .string("2026-09-22"), "activityFileHash": .string(hashB)])
        _ = try apply(rig, [later])
        try rig.db.db.run("SELECT activity_id FROM programme_done WHERE programme_id = 'p' AND week = 2") { target = $0.double(0) }
        #expect(target == Double(idA))
    }
}
