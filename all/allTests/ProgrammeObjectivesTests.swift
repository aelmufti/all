//
//  ProgrammeObjectivesTests.swift
//  allTests
//
//  Objectifs (paires entraînement + alimentation) et jours proposés d'après
//  les habitudes. Fonctions pures, aucun réseau.
//

import Testing
import Foundation
@testable import all

@Suite struct ProgrammeObjectivesTests {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Paris")!
        c.firstWeekday = 2
        return c
    }
    /// Mercredi 2026-10-21 à midi (Paris).
    private var now: Date { iso("2026-10-21T12:00:00+02:00") }

    private func iso(_ s: String) -> Date { ActivityDateFormatting.date(from: s)! }

    private func activity(_ start: String, sport: String = "rock_climbing") -> Activity {
        Activity(id: 0, fileName: "x", sport: sport, subSport: nil, startTime: start, durationS: 3600,
                 distanceM: nil, calories: nil, avgHr: nil, maxHr: nil)
    }

    private func suggest(_ acts: [Activity], perWeek: Int) -> ProgrammeDaySuggestion {
        programmeSuggestDays(activities: acts, perWeek: perWeek, now: now, calendar: calendar)
    }

    /// Une activité par semaine, `weeks` semaines en arrière, aux jours donnés (lundi=1…).
    private func weekly(days: [Int], weeks: Int, sport: String = "rock_climbing") -> [Activity] {
        // Lundi de la semaine courante : 2026-10-19.
        let monday = calendar.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: 18))!
        var out: [Activity] = []
        for w in 1...weeks {
            for d in days {
                let offset = -7 * w + ((d + 6) % 7)
                let date = calendar.date(byAdding: .day, value: offset, to: monday)!
                out.append(activity(ISO8601DateFormatter().string(from: date), sport: sport))
            }
        }
        return out
    }

    @Test func noActivityUsesDefaultOrder() {
        let s = suggest([], perWeek: 3)
        #expect(s.days == [1, 3, 5])
        #expect(!s.fromHabits)
    }

    @Test func walkingIsExcluded() {
        let s = suggest(weekly(days: [2, 4], weeks: 4, sport: "walking"), perWeek: 3)
        #expect(s.days == [1, 3, 5])
        #expect(!s.fromHabits)
    }

    @Test func fixedDaysAreProposed() {
        let s = suggest(weekly(days: [2, 4, 6], weeks: 5), perWeek: 3)
        #expect(s.days == [2, 4, 6])
        #expect(s.fromHabits)
        #expect(s.label == "M J S")
    }

    @Test func tieBreakFollowsDefaultOrder() {
        // 4 jours à égalité, 2 places : lundi et mercredi (ordre par défaut).
        let s = suggest(weekly(days: [1, 2, 3, 4], weeks: 3), perWeek: 2)
        #expect(s.days == [1, 3])
    }

    @Test func fillsWithDefaultOrderWhenNotEnoughHabits() {
        // Un seul jour habituel (samedi), 3 places : samedi + lun + mer.
        let s = suggest(weekly(days: [6], weeks: 4), perWeek: 3)
        #expect(s.days == [1, 3, 6])
        #expect(s.fromHabits)
    }

    @Test func daysWithOnlyOneActiveWeekDoNotCount() {
        let s = suggest(weekly(days: [2], weeks: 1), perWeek: 2)
        #expect(s.days == [1, 3])
        #expect(!s.fromHabits)
    }

    @Test func windowIsEightWeeks() {
        // Semaines 9 à 12 en arrière : hors fenêtre.
        let old = weekly(days: [2], weeks: 12).filter {
            (ActivityDateFormatting.date(from: $0.startTime)!) < calendar.date(byAdding: .day, value: -63, to: now)!
        }
        let s = suggest(old, perWeek: 1)
        #expect(!s.fromHabits)
        #expect(s.days == [1])
    }

    // MARK: - Objectifs

    private func domains(training: [String], nutrition: [String],
                         activeTraining: String? = nil, activeNutrition: String? = nil) throws -> [ProgrammeDomainView] {
        func choice(_ id: String) -> String {
            #"{"id":"\#(id)","name":"n","goal":"g","source":"s","weeks":12,"rules":0,"perWeek":4}"#
        }
        func active(_ id: String?) -> String {
            guard let id else { return "null" }
            return #"{"programmeId":"\#(id)","startedOn":"2026-10-01","name":"n","goal":"g","source":"s","week":1,"weeks":12,"days":[1],"perWeek":4,"notes":[]}"#
        }
        func domain(_ kind: String, _ ids: [String], _ act: String?) -> String {
            #"{"kind":"\#(kind)","label":"L","drives":"d","hint":"h","choices":[\#(ids.map(choice).joined(separator: ","))],"active":\#(active(act)),"detail":null}"#
        }
        let json = #"{"date":"2026-10-21","domains":[\#(domain("training", training, activeTraining)),\#(domain("nutrition", nutrition, activeNutrition))]}"#
        return try JSONDecoder().decode(ProgrammeCurrent.self, from: Data(json.utf8)).domains
    }

    @Test func activeObjectiveIsResolvedFromPair() throws {
        let o = ProgrammeObjective.all[2]
        let d = try domains(training: [o.trainingId], nutrition: [o.nutritionId],
                            activeTraining: o.trainingId, activeNutrition: o.nutritionId)
        #expect(programmeActiveObjective(domains: d) == o)
    }

    @Test func mixedPairMatchesNoObjective() throws {
        let a = ProgrammeObjective.all[0], b = ProgrammeObjective.all[1]
        let d = try domains(training: [a.trainingId], nutrition: [b.nutritionId],
                            activeTraining: a.trainingId, activeNutrition: b.nutritionId)
        #expect(programmeActiveObjective(domains: d) == nil)
    }

    @Test func objectiveUnavailableWhenAnIdIsMissing() throws {
        let o = ProgrammeObjective.all[0]
        let d = try domains(training: [o.trainingId], nutrition: [])
        #expect(programmeObjectiveChoices(o, domains: d) == nil)
        let full = try domains(training: [o.trainingId], nutrition: [o.nutritionId])
        #expect(programmeObjectiveChoices(o, domains: full) != nil)
    }
}
