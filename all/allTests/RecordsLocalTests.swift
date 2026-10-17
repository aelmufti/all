//
//  RecordsLocalTests.swift
//  allTests
//
//  `GET api/stats/records` en local (`Local/RecordsStats.swift`) + décodage
//  du JSON du contrat par les modèles de l'UI (`RecordsModels.swift`).
//

import Testing
import Foundation
@testable import all

struct RecordsLocalTests {
    private func makeDb() throws -> LocalDb {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("records-tests-\(UUID().uuidString).sqlite").path
        return try LocalDb(path: path)
    }

    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    @discardableResult
    private func activity(
        _ db: LocalDb, _ n: Int, sport: String?, start: String, duration: Double? = nil, distance: Double? = nil,
        calories: Double? = nil, avgHr: Double? = nil, maxHr: Double? = nil
    ) throws -> Int {
        try db.storeActivity(
            FitActivityExtractor.Summary(
                sport: sport, subSport: nil, startTime: start, durationS: duration, distanceM: distance,
                calories: calories, avgHr: avgHr, maxHr: maxHr),
            hash: "rec-\(n)", fileName: "rec\(n).fit")
    }

    private func now(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }

    private func compute(_ db: LocalDb, at iso: String = "2026-10-17T10:00:00Z") throws -> RecordsDTO {
        try RecordsBackend.compute(db: db, now: now(iso), calendar: utc)
    }

    @Test func emptyDbGivesNullRecords() throws {
        let r = try compute(try makeDb())
        #expect(r.sports.isEmpty)
        #expect(r.sessions.count == 1)
        #expect(r.sessions[0].sport == nil && r.sessions[0].count == 0)
        #expect(r.sessions[0].longestDistance == nil && r.sessions[0].maxHr == nil)
        #expect(r.days == RecordsDaysDTO(mostSteps: nil, peakHr: nil, lowestRestingHr: nil))
        #expect(r.sleep == RecordsSleepDTO(longestNight: nil, bestScore: nil))
        #expect(r.streaks == RecordsStreaksDTO(longest: nil, current: nil))
    }

    @Test func globalAndPerSport() throws {
        let db = try makeDb()
        let a = try activity(db, 1, sport: "running", start: "2026-10-01T08:00:00.000Z", duration: 1800, distance: 5000, calories: 300, avgHr: 150, maxHr: 175)
        let b = try activity(db, 2, sport: "cycling", start: "2026-10-02T08:00:00.000Z", duration: 3600, distance: 20000, calories: 500, avgHr: 130, maxHr: 160)
        let c = try activity(db, 3, sport: "running", start: "2026-10-03T08:00:00.000Z", duration: 1200, distance: 3000, calories: 200, avgHr: 160, maxHr: 170)
        let r = try compute(db)
        #expect(r.sports == ["running", "cycling"])
        #expect(r.sessions.map(\.sport) == [nil, "running", "cycling"])
        let all = r.sessions[0]
        #expect(all.count == 3)
        #expect(all.longestDistance?.activityId == b)
        #expect(all.longestDistance?.value == 20000)
        #expect(all.longestDuration?.activityId == b)
        #expect(all.mostCalories?.activityId == b)
        #expect(all.maxHr?.activityId == a)
        #expect(all.highestAvgHr?.activityId == c)
        #expect(all.longestDistance?.startTime == "2026-10-02T08:00:00.000Z")
        // Allures : a 360 s/km, b 180 s/km, c 400 s/km.
        #expect(all.bestPace?.activityId == b)
        #expect(all.bestPace?.value == 180)
        #expect(r.sessions[1].bestPace?.activityId == a)
        let run = r.sessions[1]
        #expect(run.count == 2)
        #expect(run.longestDistance?.activityId == a)
        #expect(run.longestDistance?.sport == "running")
        #expect(run.highestAvgHr?.activityId == c)
    }

    @Test func tieGoesToOldestThenSmallestId() throws {
        let db = try makeDb()
        // Inséré dans le désordre : la 2e ligne est la plus ancienne.
        _ = try activity(db, 1, sport: "running", start: "2026-10-05T08:00:00.000Z", distance: 5000)
        let older = try activity(db, 2, sport: "running", start: "2026-10-01T08:00:00.000Z", distance: 5000)
        #expect(try compute(db).sessions[0].longestDistance?.activityId == older)

        let db2 = try makeDb()
        let first = try activity(db2, 1, sport: "running", start: "2026-10-01T08:00:00.000Z", distance: 5000)
        _ = try activity(db2, 2, sport: "running", start: "2026-10-01T08:00:00.000Z", distance: 5000)
        #expect(try compute(db2).sessions[0].longestDistance?.activityId == first)
    }

    @Test func bestPaceNeedsOneKmAndTiesGoToOldest() throws {
        let db = try makeDb()
        // Trop court (< 1 km) : ignoré malgré l'allure.
        _ = try activity(db, 1, sport: "running", start: "2026-10-01T08:00:00.000Z", duration: 100, distance: 900)
        _ = try activity(db, 2, sport: "running", start: "2026-10-05T08:00:00.000Z", duration: 300, distance: 1000)
        let older = try activity(db, 3, sport: "running", start: "2026-10-02T08:00:00.000Z", duration: 600, distance: 2000)
        let r = try compute(db)
        #expect(r.sessions[0].bestPace?.activityId == older)
        #expect(r.sessions[0].bestPace?.value == 300)
    }

    @Test func nullAndNonPositiveValuesIgnored() throws {
        let db = try makeDb()
        _ = try activity(db, 1, sport: "running", start: "2026-10-01T08:00:00.000Z", duration: 0, distance: 0, calories: nil, avgHr: 0, maxHr: nil)
        let r = try compute(db)
        #expect(r.sessions[0].count == 1)
        #expect(r.sessions[0].longestDistance == nil)
        #expect(r.sessions[0].longestDuration == nil)
        #expect(r.sessions[0].bestPace == nil)
        #expect(r.sessions[0].mostCalories == nil)
        #expect(r.sessions[0].highestAvgHr == nil)
    }

    @Test func daysAndSleepRecords() throws {
        let db = try makeDb()
        try db.db.run("INSERT INTO wellness_days (date, resting_hr) VALUES ('2026-10-01', 55), ('2026-10-02', 48), ('2026-10-03', 48), ('2026-10-04', 0)")
        try db.db.run("""
            INSERT INTO wellness_counters (date, activity_type, steps) VALUES
            ('2026-10-01','walking',4000), ('2026-10-01','running',3000),
            ('2026-10-02','walking',6000), ('2026-10-03','walking',7000)
            """)
        func noon(_ date: String) -> Double {
            var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!
            let parts = date.split(separator: "-").map { Int($0)! }
            let d = c.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12))!
            return d.timeIntervalSince1970 - LocalDb.localOffsetSeconds(forDate: date)
        }
        for (date, hr) in [("2026-10-01", 160.0), ("2026-10-02", 185.0), ("2026-10-03", 185.0)] {
            try db.db.run("INSERT INTO wellness_samples (metric, ts, value) VALUES ('hr', ?, ?)", [.double(noon(date)), .double(hr)])
        }
        try db.db.run("INSERT INTO wellness_sleep (date, start_ts, end_ts, duration_s, score) VALUES ('2026-10-01', 0, 1, 25000, 70), ('2026-10-02', 0, 1, 30000, 90), ('2026-10-03', 0, 1, 30000, 90)")
        let r = try compute(db)
        #expect(r.days.mostSteps == RecordsDayDTO(date: "2026-10-01", value: 7000))
        #expect(r.days.peakHr == RecordsDayDTO(date: "2026-10-02", value: 185))
        #expect(r.days.lowestRestingHr == RecordsDayDTO(date: "2026-10-02", value: 48))
        #expect(r.sleep.longestNight == RecordsDayDTO(date: "2026-10-02", value: 30000))
        #expect(r.sleep.bestScore == RecordsDayDTO(date: "2026-10-02", value: 90))
        // Même chiffre que la page Santé pour ces jours.
        let rows = try db.days(limit: 10)
        #expect(rows.first { $0.date == "2026-10-02" }?.maxHr == 185)
        #expect(rows.first { $0.date == "2026-10-01" }?.steps == 7000)
    }

    @Test func streaksLongestAndCurrent() throws {
        let starts = [
            "2026-10-01T08:00:00.000Z", "2026-10-01T18:00:00.000Z", "2026-10-02T08:00:00.000Z",
            "2026-10-03T08:00:00.000Z", "2026-10-10T08:00:00.000Z", "2026-10-16T08:00:00.000Z",
        ]
        // Aujourd'hui = 17 : la série se termine hier → gardée.
        let a = RecordsBackend.streaks(startTimes: starts, now: now("2026-10-17T10:00:00Z"), calendar: utc)
        #expect(a.longest == RecordsStreakDTO(start: "2026-10-01", end: "2026-10-03", days: 3))
        #expect(a.current == RecordsStreakDTO(start: "2026-10-16", end: "2026-10-16", days: 1))
        // Aujourd'hui = 18 : dernière activité avant-hier → pas de série en cours.
        let b = RecordsBackend.streaks(startTimes: starts, now: now("2026-10-18T10:00:00Z"), calendar: utc)
        #expect(b.current == nil)
        #expect(b.longest?.days == 3)
        // Fin aujourd'hui.
        let c = RecordsBackend.streaks(startTimes: starts + ["2026-10-17T07:00:00.000Z"], now: now("2026-10-17T10:00:00Z"), calendar: utc)
        #expect(c.current == RecordsStreakDTO(start: "2026-10-16", end: "2026-10-17", days: 2))
    }

    @Test func routeEncodesContractAndUiModelsDecode() async throws {
        let db = try makeDb()
        _ = try activity(db, 1, sport: "running", start: "2026-10-01T08:00:00.000Z", duration: 1800, distance: 5000)
        let backend = RealLocalPulseBackend(db: db)
        let data = try await backend.handle(method: "GET", path: "api/stats/records", query: [:], body: nil)
        let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let sessions = try #require(obj["sessions"] as? [[String: Any]])
        #expect(sessions[0]["sport"] is NSNull)
        #expect(sessions[0]["maxHr"] is NSNull)
        let payload = try PulseAPIClient.decoder.decode(RecordsPayload.self, from: data)
        #expect(payload.sports == ["running"])
        #expect(payload.sessions(for: nil)?.count == 1)
        #expect(payload.sessions(for: "running")?.longestDistance?.value == 5000)
        #expect(payload.days.mostSteps == nil)
    }

    @Test func uiModelsDecodeContractSample() throws {
        let json = """
        {"sports":["running","cycling"],
         "sessions":[{"sport":null,"count":42,
           "longestDistance":{"activityId":7,"value":21097.5,"startTime":"2026-09-01T07:00:00.000Z","sport":"running","subSport":null},
           "longestDuration":null,"bestPace":{"activityId":8,"value":295.5,"startTime":"2026-09-01T07:00:00.000Z","sport":"running","subSport":null},"mostCalories":null,"maxHr":null,"highestAvgHr":null}],
         "days":{"mostSteps":{"date":"2026-09-02","value":20000},"peakHr":null,"lowestRestingHr":{"date":"2026-09-03","value":44}},
         "sleep":{"longestNight":{"date":"2026-09-04","value":36000},"bestScore":null},
         "streaks":{"longest":{"start":"2026-09-01","end":"2026-09-05","days":5},"current":null}}
        """
        let p = try PulseAPIClient.decoder.decode(RecordsPayload.self, from: Data(json.utf8))
        #expect(p.sessions[0].sport == nil)
        #expect(p.sessions[0].longestDistance?.activityId == 7)
        #expect(p.sessions[0].longestDistance?.subSport == nil)
        #expect(p.sessions[0].bestPace?.value == 295.5)
        #expect(p.days.lowestRestingHr?.value == 44)
        #expect(p.streaks.longest?.days == 5)
        #expect(p.streaks.current == nil)
    }
}
