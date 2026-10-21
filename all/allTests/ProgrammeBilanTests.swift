//
//  ProgrammeBilanTests.swift
//  allTests
//
//  Bilan de fin de programme (écran Bravo) : calculs purs + clé « déjà montré ».
//

import Testing
import Foundation
@testable import all

private func session(week: Int, key: String, done: Bool) throws -> ProgrammeSessionProgress {
    let json = """
    {"week": \(week),
     "session": {"key": "\(key)", "name": "S \(key)", "sport": "running", "subSport": null, "minMinutes": null, "items": []},
     "plannedOn": null, "status": "\(done ? "done" : "upcoming")", "done": \(done),
     "date": null, "activityId": null, "manual": true}
    """
    return try JSONDecoder().decode(ProgrammeSessionProgress.self, from: Data(json.utf8))
}

private func extra(id: Int, date: String) throws -> ProgrammeExtraActivity {
    let json = #"{"id": \#(id), "date": "\#(date)", "sport": null, "subSport": null, "durationS": null, "distanceM": null}"#
    return try JSONDecoder().decode(ProgrammeExtraActivity.self, from: Data(json.utf8))
}

struct ProgrammeBilanTests {
    @Test func countsDonePlannedAndPercent() throws {
        let sessions = [
            try session(week: 1, key: "a", done: true), try session(week: 1, key: "b", done: true),
            try session(week: 2, key: "a", done: true), try session(week: 2, key: "b", done: false),
        ]
        let bilan = programmeBilan(weeks: 2, startedOn: "2026-09-01", sessions: sessions, extras: [])
        #expect(bilan.done == 3)
        #expect(bilan.planned == 4)
        #expect(bilan.percent == 75)
        #expect(bilan.weeks.map(\.done) == [2, 1])
        #expect(bilan.endDate == "2026-09-14")
    }

    @Test func bestStreakCountsConsecutiveCompleteWeeks() throws {
        // Semaines : complète, complète, partielle, complète, vide.
        let sessions = [
            try session(week: 1, key: "a", done: true),
            try session(week: 2, key: "a", done: true),
            try session(week: 3, key: "a", done: true), try session(week: 3, key: "b", done: false),
            try session(week: 4, key: "a", done: true),
        ]
        let bilan = programmeBilan(weeks: 5, startedOn: "2026-09-01", sessions: sessions, extras: [])
        #expect(bilan.bestStreak == 2)
    }

    @Test func zeroPlannedHasNoPercentAndNoStreak() {
        let bilan = programmeBilan(weeks: 3, startedOn: "2026-09-01", sessions: [], extras: [])
        #expect(bilan.planned == 0)
        #expect(bilan.percent == nil)
        #expect(bilan.bestStreak == 0)
        #expect(bilan.weeks.count == 3)
    }

    @Test func zeroWeeksIsEmpty() {
        let bilan = programmeBilan(weeks: 0, startedOn: "2026-09-01", sessions: [], extras: [])
        #expect(bilan.weeks.isEmpty)
        #expect(bilan.endDate == nil)
        #expect(bilan.percent == nil)
    }

    @Test func extrasCountedOnlyWithinBlock() throws {
        let extras = [
            try extra(id: 1, date: "2026-08-31"),
            try extra(id: 2, date: "2026-09-01"),
            try extra(id: 3, date: "2026-09-14"),
            try extra(id: 4, date: "2026-09-15"),
        ]
        let bilan = programmeBilan(weeks: 2, startedOn: "2026-09-01", sessions: [], extras: extras)
        #expect(bilan.extras == 2)
    }
}

struct ProgrammeBravoSeenTests {
    private func freshDefaults() -> UserDefaults {
        let name = "bravo-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func keyCombinesProgrammeAndStartDate() {
        #expect(programmeBravoKey(programmeId: "p", startedOn: "2026-09-01") == "programme.bravo.p.2026-09-01")
    }

    @Test func seenOncePerRun() {
        let defaults = freshDefaults()
        #expect(!programmeBravoSeen(programmeId: "p", startedOn: "2026-09-01", defaults: defaults))
        programmeBravoMarkSeen(programmeId: "p", startedOn: "2026-09-01", defaults: defaults)
        #expect(programmeBravoSeen(programmeId: "p", startedOn: "2026-09-01", defaults: defaults))
        // Nouvelle exécution (autre date de début) : à remontrer.
        #expect(!programmeBravoSeen(programmeId: "p", startedOn: "2026-10-01", defaults: defaults))
    }
}
